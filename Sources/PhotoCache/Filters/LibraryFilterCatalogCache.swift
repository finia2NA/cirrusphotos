import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    func loadFilterOptionCatalog(for collection: PhotoCollectionDescriptor) async throws -> (LibraryFilterCatalog?, MetadataStoreAdmission) {
        try await initializeMetadataEngine()
        guard !metadata.resetInProgress, !Task.isCancelled else { throw MetadataAdmissionError.superseded }
        let epoch = metadata.admissionEpoch
        let admission = try await store.metadataAdmission(metadataNamespace(for: collection))
        let catalog: LibraryFilterCatalog?
        if collection.isSessionDerived { catalog = metadata.sessions.filterCatalogs[collection] }
        else { catalog = try await store.filterOptionCatalog(CollectionKey(namespace: metadataNamespace(for: collection), collection: collection)) }
        guard !Task.isCancelled, isAdmitted(epoch) else { throw MetadataAdmissionError.superseded }
        return (catalog, admission)
    }

    func storeFilterOptionCatalog(_ catalog: LibraryFilterCatalog, for collection: PhotoCollectionDescriptor,
                                  originalAdmission: MetadataStoreAdmission) async throws {
        guard !metadata.resetInProgress, !Task.isCancelled else { throw MetadataAdmissionError.superseded }
        let epoch = metadata.admissionEpoch
        for _ in 0..<2 {
            let current = try await store.metadataAdmission(metadataNamespace(for: collection))
            guard !Task.isCancelled, isAdmitted(epoch),
                  current.generation == originalAdmission.generation,
                  current.metadataGeneration == originalAdmission.metadataGeneration,
                  current.resetEpoch == originalAdmission.resetEpoch else { throw MetadataAdmissionError.superseded }
            if collection.isSessionDerived {
                guard metadata.latestTimelines[collection] != nil else { throw MetadataAdmissionError.superseded }
                metadata.sessions.filterCatalogs[collection] = catalog
                return
            }
            do {
                try await store.storeFilterOptionCatalog(catalog, key: CollectionKey(namespace: metadataNamespace(for: collection), collection: collection), admission: current)
                return
            } catch MetadataAdmissionError.superseded { continue }
        }
        throw MetadataAdmissionError.superseded
    }
}
