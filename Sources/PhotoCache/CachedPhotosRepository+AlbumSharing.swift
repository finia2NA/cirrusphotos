import Foundation
import SynologyAPI

public struct AlbumSharingSnapshot: Sendable {
    public let album: AlbumSummary
    public let principals: [SharingPrincipal]
}

public enum AlbumSharingAccessChange: Sendable, Equatable {
    case unchanged, `private`, publicView
}

extension CachedPhotosRepository {
    /// Always verifies ownership against the current Photos identity and reads fresh state.
    public func albumSharing(id: Int64) async throws -> AlbumSharingSnapshot {
        try await initializeMetadataEngine()
        try await connect()
        try await reconcileMetadataSource()
        guard !metadata.albumMutationInProgress else { throw SynologyAPIError.unsupported("Another album change is in progress.") }
        let epoch = metadata.albumListEpoch
        let admissionEpoch = metadata.admissionEpoch
        let user = try await client.currentPhotosUserID()
        let album = try await client.album(id: id)
        let principals = try await client.sharingPrincipals()
        guard epoch == metadata.albumListEpoch, admissionEpoch == metadata.admissionEpoch,
              !metadata.resetInProgress, !metadata.albumMutationInProgress else { throw SynologyAPIError.unsupported("Album sharing changed. Open it again.") }
        guard album.type == "normal", album.ownerUserID == user else { throw SynologyAPIError.unsupported("Only the album owner can manage sharing.") }
        return AlbumSharingSnapshot(album: album, principals: principals.filter { $0.type == "user" })
    }

    public func albumSharingChanges() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            metadata.albumSharingObservers[id] = continuation
            continuation.onTermination = { @Sendable _ in Task { await self.removeAlbumSharingObserver(id) } }
        }
    }
    private func removeAlbumSharingObserver(_ id: UUID) { metadata.albumSharingObservers.removeValue(forKey: id) }

    /// A dispatched operation outlives its caller so cancellation cannot skip reconciliation.
    public func saveAlbumSharing(snapshot: AlbumSharingSnapshot, changes: [SharingPermissionChange], disable: Bool, access: AlbumSharingAccessChange = .unchanged, password: SharingPasswordChange = .unchanged, expiration: Int64? = nil) async throws -> AlbumSummary {
        try Task.checkCancellation()
        guard !metadata.albumMutationInProgress else { throw SynologyAPIError.unsupported("Another album change is in progress.") }
        metadata.albumMutationInProgress = true
        metadata.albumMutationWriting = true
        metadata.albumListEpoch &+= 1
        metadata.albumListJob?.task.cancel(); metadata.albumListJob = nil
        let task = Task { try await self.performSharingWrite(snapshot: snapshot, changes: changes, disable: disable, access: access, password: password, expiration: expiration) }
        return try await task.value
    }

    private func performSharingWrite(snapshot: AlbumSharingSnapshot, changes: [SharingPermissionChange], disable: Bool, access: AlbumSharingAccessChange = .unchanged, password: SharingPasswordChange = .unchanged, expiration: Int64? = nil) async throws -> AlbumSummary {
        defer { metadata.albumMutationInProgress = false; metadata.albumMutationWriting = false }
        var operationError: (any Error)?
        var result: AlbumSummary?
        var activated = false
        do {
            let admission = try await store.metadataAdmission(metadataNamespace)
            try await store.invalidateMetadataAlbumSummaries(metadataNamespace, admission: admission)
            let user = try await client.currentPhotosUserID()
            let current = try await client.album(id: snapshot.album.id)
            guard current.type == "normal", current.ownerUserID == user,
                  current.shared == snapshot.album.shared, current.sharingInfo == snapshot.album.sharingInfo else {
                throw SynologyAPIError.unsupported("Sharing settings changed. Reload before saving.")
            }
            let existing = current.shared ? (current.sharingInfo?.permission ?? []) : []
            var changedIDs = Set<Int64>()
            for change in changes {
                guard change.member.type == "user", let memberID = change.member.id, changedIDs.insert(memberID).inserted,
                      (change.action == "delete" && change.role == nil) ||
                      (change.action == "update" && (change.role == "view" || change.role == "download")) else {
                    throw SynologyAPIError.unsupported("Unsupported sharing change.")
                }
                if let grant = existing.first(where: { $0.type == "user" && $0.principalID == change.member.id }),
                   grant.role != "view" && grant.role != "download" {
                    throw SynologyAPIError.unsupported("An unsupported role cannot be edited.")
                }
                if change.action == "update", !snapshot.principals.contains(where: { $0.type == "user" && $0.id == change.member.id }),
                   !existing.contains(where: { $0.type == "user" && $0.principalID == change.member.id }) {
                    throw SynologyAPIError.unsupported("The selected user is no longer available.")
                }
            }
            if disable {
                guard current.shared else { throw SynologyAPIError.unsupported("Sharing is already disabled.") }
                _ = try await client.setAlbumShared(id: current.id, enabled: false)
            } else {
                guard ["private", "public-view", "public-download"].contains(current.sharingInfo?.privacyType ?? "") else {
                    throw SynologyAPIError.unsupported("Unsupported sharing access.")
                }
                guard expiration == nil || expiration! >= 0 else { throw SynologyAPIError.unsupported("Invalid expiry.") }
                if case .set(let value) = password, value.isEmpty { throw SynologyAPIError.unsupported("Enter a password or choose to clear it.") }
                var updates = changes
                switch access {
                case .unchanged: break
                case .private:
                    if current.shared && current.sharingInfo?.privacyType != "private" { updates.append(.init(action: "delete", member: .init(type: "public"))) }
                case .publicView:
                    if !current.shared || current.sharingInfo?.privacyType != "public-view" { updates.append(.init(action: "update", role: "view", member: .init(type: "public"))) }
                }
                let reference: String
                if current.shared {
                    guard let existing = current.sharingInfo?.reference, !existing.isEmpty else { throw SynologyAPIError.invalidResponse }
                    reference = existing
                } else {
                    reference = try await client.setAlbumShared(id: current.id, enabled: true).passphrase
                    activated = true
                    guard !reference.isEmpty else { throw SynologyAPIError.invalidResponse }
                }
                if !current.shared || !updates.isEmpty || password != .unchanged || expiration != nil {
                    let expiry = expiration ?? (!current.shared && (current.sharingInfo?.expiration ?? 0) == 0 ? 0 : nil)
                    try await client.updateAlbumSharing(reference: reference, changes: updates, password: password, expiration: expiry)
                }
            }
        } catch { operationError = error }
        // Even a failed or cancelled request may have reached the NAS.
        do {
            let readback = try await client.album(id: snapshot.album.id)
            result = readback
            if operationError == nil {
                guard readback.shared != disable else { throw SynologyAPIError.unsupported("The server did not confirm the requested sharing state.") }
                if !disable {
                    let expectedAccess: String?
                    switch access {
                    case .unchanged: expectedAccess = snapshot.album.shared ? snapshot.album.sharingInfo?.privacyType : "private"
                    case .private: expectedAccess = "private"
                    case .publicView: expectedAccess = "public-view"
                    }
                    guard readback.sharingInfo?.privacyType == expectedAccess else { throw SynologyAPIError.unsupported("The server did not confirm access.") }
                    if let expiration, readback.sharingInfo?.expiration != expiration { throw SynologyAPIError.unsupported("The server did not confirm expiry.") }
                    switch password {
                    case .unchanged: break
                    case .set: guard readback.sharingInfo?.enablePassword == true else { throw SynologyAPIError.unsupported("The server did not confirm the password.") }
                    case .clear: guard readback.sharingInfo?.enablePassword == false else { throw SynologyAPIError.unsupported("The server did not confirm password removal.") }
                    }
                    for change in changes {
                        let grant = readback.sharingInfo?.permission?.first { $0.type == "user" && $0.principalID == change.member.id }
                        guard change.action == "delete" ? grant == nil : grant?.role == change.role else {
                            throw SynologyAPIError.unsupported("The server did not confirm all permission changes.")
                        }
                    }
                }
            }
        } catch { if operationError == nil { operationError = error } }
        metadata.albumListEpoch &+= 1
        metadata.albumListJob?.task.cancel(); metadata.albumListJob = nil
        do {
            let admission = try await store.metadataAdmission(metadataNamespace)
            try await store.invalidateMetadataAlbumSummaries(metadataNamespace, admission: admission)
        } catch { if operationError == nil { operationError = error } }
        metadata.albumMutationWriting = false
        for observer in metadata.albumSharingObservers.values { observer.yield(()) }
        if operationError != nil {
            let message = activated ? "Sharing was enabled, but the remaining changes could not be confirmed. Reload to check the current settings." : "Sharing may have changed. Reload to check the current settings."
            throw SynologyAPIError.unsupported(message)
        }
        guard let result else { throw SynologyAPIError.invalidResponse }
        return result
    }
}
