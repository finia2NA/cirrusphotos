import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    public func suggestPeople(prefix: String, space: PhotoSpace) async throws -> [CollectionIndexEntry] {
        guard !prefix.isEmpty, !metadata.peopleMutationSpaces.contains(space) else { return [] }
        let epoch = metadata.peopleEpoch[space, default: 0]
        try await connect()
        let result = try await metadataReadRequest(priority: .visible) {
            try await client.suggestPeople(prefix: prefix, space: space)
        }
        try Task.checkCancellation()
        guard epoch == metadata.peopleEpoch[space, default: 0], !metadata.peopleMutationSpaces.contains(space) else {
            throw MetadataAdmissionError.superseded
        }
        return result
    }

    public func renamePerson(id: Int64, name: String, space: PhotoSpace) async throws {
        try await changePerson(sourceID: nil, targetID: id, name: name, space: space)
    }

    public func mergePerson(sourceID: Int64, targetID: Int64, name: String, space: PhotoSpace) async throws {
        guard sourceID != targetID else { throw SynologyAPIError.unsupported("Choose a different person to merge.") }
        try await changePerson(sourceID: sourceID, targetID: targetID, name: name, space: space)
    }

    private func changePerson(sourceID: Int64?, targetID: Int64, name: String, space: PhotoSpace) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, targetID > 0,
              !metadata.peopleMutationsInProgress.contains(space) else {
            throw SynologyAPIError.unsupported("Enter a name and wait for any other People change to finish.")
        }
        metadata.peopleMutationsInProgress.insert(space)
        metadata.peopleMutationSpaces.insert(space)
        let collections = [targetID, sourceID].compactMap { $0 }.map { PhotoCollectionDescriptor.person($0, space: space) }
        metadata.peopleMutationCollections.formUnion(collections)
        defer {
            metadata.peopleMutationsInProgress.remove(space)
            metadata.peopleMutationSpaces.remove(space)
            metadata.peopleMutationCollections.subtract(collections)
        }
        try await initializeMetadataEngine()
        try await connect()
        try await reconcileMetadataSource(for: .library(space))
        let current = try await client.collectionIndex(.person, space: space)
        guard current.contains(where: { $0.id == targetID }), sourceID.map({ id in current.contains(where: { $0.id == id }) }) ?? true else {
            throw SynologyAPIError.unsupported("The selected people have changed. Refresh People and try again.")
        }
        try Task.checkCancellation()
        try await invalidatePeopleMutation(space: space, collections: collections)
        var result: Result<Void, Error>
        do {
            if let sourceID { _ = try await client.mergePerson(sourceID: sourceID, targetID: targetID, name: name, space: space) }
            else { _ = try await client.renamePerson(id: targetID, name: name, space: space) }
            result = .success(())
        } catch { result = .failure(error) }
        // A failed or cancelled request may still have reached the NAS. Finish
        // invalidation and readback independently of the caller's cancellation.
        let reconcile = Task { try await self.finishPeopleMutation(space: space, collections: collections, sourceID: sourceID, targetID: targetID, name: name) }
        do { try await reconcile.value }
        catch {
            if case .success = result { result = .failure(error) }
        }
        if case .failure = result {
            throw SynologyAPIError.unsupported("The change could not be confirmed. Refresh People before trying again.")
        }
    }

    private func invalidatePeopleMutation(space: PhotoSpace, collections: [PhotoCollectionDescriptor]) async throws {
        metadata.peopleEpoch[space, default: 0] &+= 1
        metadata.collectionIndexJobs.removeValue(forKey: CollectionIndexJobKey(kind: .person, space: space))?.task.cancel()
        for collection in collections {
            metadata.mutationEpochs[collection, default: 0] &+= 1
            metadata.timelineJobs.removeValue(forKey: collection)?.task.cancel()
            metadata.collectionRecoveries.removeValue(forKey: collection)?.task.cancel()
            let filterIDs = metadata.libraryFilters.filter { $0.value.registration.sourceCollection == collection }.map(\.key)
            for id in filterIDs {
                if let state = metadata.libraryFilters.removeValue(forKey: id) {
                    metadata.selectionRetentions.removeValue(forKey: state.registration.descriptor)
                    metadata.deferredSelectionUnregisters.remove(state.registration.descriptor)
                    metadata.latestTimelines.removeValue(forKey: state.registration.descriptor)
                }
            }
        }
        let namespace = metadataNamespace(for: space)
        let admission = try await store.metadataAdmission(namespace)
        try await store.invalidateMetadataCollectionIndex(.person, namespace: namespace, admission: admission)
        for collection in collections {
            let admission = try await store.metadataAdmission(namespace)
            try await store.invalidateMetadataCollection(CollectionKey(namespace: namespace, collection: collection), admission: admission)
            publishMetadataInvalidation(collection: collection)
        }
    }

    private func finishPeopleMutation(space: PhotoSpace, collections: [PhotoCollectionDescriptor], sourceID: Int64?, targetID: Int64, name: String) async throws {
        try await invalidatePeopleMutation(space: space, collections: collections)
        metadata.peopleMutationSpaces.remove(space)
        metadata.peopleMutationCollections.subtract(collections)
        var verified: [CollectionIndexEntry]?
        for await event in collectionIndex(.person, space: space) {
            if case .value(let list, true) = event { verified = list }
        }
        guard let verified, verified.contains(where: { $0.id == targetID && $0.name == name }),
              sourceID.map({ id in !verified.contains(where: { $0.id == id }) }) ?? true else {
            throw SynologyAPIError.unsupported("The server did not confirm the People change.")
        }
        if sourceID != nil {
            let collection = PhotoCollectionDescriptor.person(targetID, space: space)
            let snapshot = try await verifiedTimelineSnapshot(collection: collection)
            publishTimelineProjection(snapshot, collection: collection)
        }
    }
}
