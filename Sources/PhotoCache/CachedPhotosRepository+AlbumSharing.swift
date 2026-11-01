import Foundation
import SynologyAPI

public struct AlbumSharingSnapshot: Sendable {
    public let album: AlbumSummary
    public let principals: [SharingPrincipal]
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
    public func saveAlbumSharing(snapshot: AlbumSharingSnapshot, changes: [SharingPermissionChange], disable: Bool) async throws -> AlbumSummary {
        try Task.checkCancellation()
        guard !metadata.albumMutationInProgress else { throw SynologyAPIError.unsupported("Another album change is in progress.") }
        metadata.albumMutationInProgress = true
        metadata.albumMutationWriting = true
        metadata.albumListEpoch &+= 1
        metadata.albumListJob?.task.cancel(); metadata.albumListJob = nil
        let task = Task { try await self.performSharingWrite(snapshot: snapshot, changes: changes, disable: disable) }
        return try await task.value
    }

    private func performSharingWrite(snapshot: AlbumSharingSnapshot, changes: [SharingPermissionChange], disable: Bool) async throws -> AlbumSummary {
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
                guard change.member.type == "user", changedIDs.insert(change.member.id).inserted,
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
                guard current.sharingInfo?.privacyType == "private" else {
                    throw SynologyAPIError.unsupported("Public sharing settings cannot be edited here.")
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
                if !current.shared || !changes.isEmpty {
                    let defaultExpiry = !current.shared && (current.sharingInfo?.expiration ?? 0) == 0
                    try await client.updateAlbumSharing(reference: reference, changes: changes, initial: defaultExpiry)
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
                    guard readback.sharingInfo?.privacyType == "private" else { throw SynologyAPIError.unsupported("The server did not confirm private sharing.") }
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
