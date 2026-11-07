import Foundation
import SynologyAPI

struct MetadataCollectionObservation: Sendable {
    let id: UUID
    let changes: AsyncStream<Void>
}
struct MetadataCollectionInvalidation: Sendable { let days: Set<CaptureDay>? }
struct MetadataCollectionObserver {
    let collection: PhotoCollectionDescriptor
    let continuation: AsyncStream<Void>.Continuation
    var allDays = false
    var days: Set<CaptureDay> = []
}

extension CachedPhotosRepository {
    func metadataObservationSource(for collection: PhotoCollectionDescriptor) -> PhotoCollectionDescriptor {
        if let id = collection.libraryFilterID, let state = metadata.sessions.libraryFilters[id] {
            return state.registration.sourceCollection.isMapFilter ? mediaCollection(for: state.registration.sourceCollection) : state.registration.sourceCollection
        }
        return collection.isMapFilter ? mediaCollection(for: collection) : collection
    }

    func observeMetadataChanges(collection: PhotoCollectionDescriptor) -> MetadataCollectionObservation {
        let id = UUID()
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            metadata.collectionObservers[id] = MetadataCollectionObserver(collection: collection, continuation: continuation)
            continuation.onTermination = { @Sendable _ in Task { await self.removeMetadataObserver(id) } }
        }
        return MetadataCollectionObservation(id: id, changes: stream)
    }
    func takeMetadataChanges(_ id: UUID) -> MetadataCollectionInvalidation? {
        guard var observer = metadata.collectionObservers[id], observer.allDays || !observer.days.isEmpty else { return nil }
        let value = MetadataCollectionInvalidation(days: observer.allDays ? nil : observer.days)
        observer.allDays = false; observer.days.removeAll()
        metadata.collectionObservers[id] = observer
        return value
    }
    private func removeMetadataObserver(_ id: UUID) { metadata.collectionObservers.removeValue(forKey: id) }

    /// Without a collection, every observed collection of the space's namespace is invalidated.
    func publishMetadataInvalidation(space: PhotoSpace = .personal, collection: PhotoCollectionDescriptor? = nil, days: Set<CaptureDay>? = nil) {
        let spaceNamespace = metadataNamespace(for: space)
        for id in Array(metadata.collectionObservers.keys) {
            guard var observer = metadata.collectionObservers[id], collection == nil || observer.collection == collection else { continue }
            if collection == nil && metadataNamespace(for: observer.collection) != spaceNamespace { continue }
            if let days { observer.days.formUnion(days) } else { observer.allDays = true; observer.days.removeAll() }
            metadata.collectionObservers[id] = observer
            observer.continuation.yield(())
        }
        let sources = Set(metadata.collectionPageObservers.values.map(\.collection))
        for source in sources where collection == nil || collection == source || (source.isMapFilter && collection == mediaCollection(for: source)) {
            if collection == nil && metadataNamespace(for: source) != spaceNamespace { continue }
            for section in metadata.latestTimelines[source]?.sections ?? [] {
                if let raw = section.list.first, let day = try? CaptureDay(year: raw.year, month: raw.month, day: raw.day),
                   days == nil || days!.contains(day), let key = CacheKey.page(scope: source.contentScope, namespace: namespace, section: section, collection: source) {
                    publishCollectionPage(key: key)
                }
            }
        }
    }
}
