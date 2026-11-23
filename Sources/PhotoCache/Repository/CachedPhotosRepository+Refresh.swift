import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Reads each space's change feed now and withdraws this run's validation of what the
    /// feeds do not cover (collection catalogs and album, folder and summary lists), so
    /// the next read of each fetches it again. Nothing is reset: feed changes reach open
    /// views through the usual per-day invalidation, and consumers re-subscribe to merge
    /// re-read lists over what they show. Folder validation is always withdrawn because
    /// folders have no feed and folder-only Shared Space may have no cursor.
    public func refreshMetadata() async throws {
        try await initializeMetadataEngine()
        metadata.folderRefreshRevision &+= 1
        for job in metadata.folderJobs.values { job.task.cancel() }
        metadata.folderJobs.removeAll()
        for space in PhotoSpace.allCases {
            let namespace = metadataNamespace(for: space)
            try await store.withdrawFolderValidation(namespace: namespace, admission: store.metadataAdmission(namespace))
        }
        var reconciled: [PhotoSpace] = []
        var failure: (any Error)?
        for space in PhotoSpace.allCases {
            // An unused space has no feed to continue; reading it would start a full import.
            if space != .personal {
                guard let state = try? await store.metadataState(metadataNamespace(for: space)),
                      state.cursor != nil else { continue }
            }
            do {
                try await reconcileMetadataSource(space: space, force: true)
                reconciled.append(space)
            } catch {
                if failure == nil { failure = error }
            }
        }
        if reconciled.isEmpty {
            if let failure { throw failure }
            return
        }
        for space in reconciled {
            let namespace = metadataNamespace(for: space)
            let admission = try await store.metadataAdmission(namespace)
            try await store.withdrawSummaryValidation(namespace: namespace, admission: admission)
        }
        if let failure { throw failure }
    }
}
