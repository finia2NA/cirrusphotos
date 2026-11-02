import Foundation
import SynologyAPI

/// Coalesced hints carry no photo payloads. Each subscriber's pending set is
/// bounded by its captured timeline; draining it cannot lose a dropped wakeup.
struct CollectionPageObservation: Sendable {
    let id: UUID
    let changes: AsyncStream<Void>
}

struct CollectionPageObserver {
    let collection: PhotoCollectionDescriptor
    let sectionsByKey: [String: TimelineSection]
    var pending: Set<TimelineSection> = []
    let continuation: AsyncStream<Void>.Continuation
}

extension CachedPhotosRepository {
    func observeCollectionPages(collection: PhotoCollectionDescriptor, sections: Set<TimelineSection>) -> CollectionPageObservation {
        let id = UUID()
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let pairs = sections.compactMap { section in
                CacheKey.page(scope: collection.contentScope, namespace: namespace, section: section, collection: collection).map { ($0, section) }
            }
            metadata.collectionPageObservers[id] = .init(
                collection: collection, sectionsByKey: Dictionary(uniqueKeysWithValues: pairs), continuation: continuation)
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeCollectionPageObserver(id) }
            }
        }
        return .init(id: id, changes: stream)
    }

    func takeCollectionPageChanges(_ id: UUID) -> Set<TimelineSection> {
        guard let observer = metadata.collectionPageObservers[id] else { return [] }
        metadata.collectionPageObservers[id]?.pending.removeAll()
        return observer.pending
    }

    func removeCollectionPageObserver(_ id: UUID) {
        metadata.collectionPageObservers.removeValue(forKey: id)?.continuation.finish()
    }

    func publishDerivedPageChanges(ids: Set<Int64>, space: PhotoSpace) {
        for observer in Array(metadata.collectionPageObservers.values) where observer.collection.isMapFilter {
            guard let id = observer.collection.mapFilterID, let map = metadata.mapFilters[id], map.space == space else { continue }
            for (section, members) in map.idsBySection where members.contains(where: { ids.contains($0) }) {
                if let key = CacheKey.page(scope: observer.collection.contentScope, namespace: namespace, section: section, collection: observer.collection) {
                    publishCollectionPage(key: key)
                }
            }
        }
    }

    func publishCollectionPage(key: String) {
        for id in Array(metadata.collectionPageObservers.keys) {
            guard let section = metadata.collectionPageObservers[id]?.sectionsByKey[key] else { continue }
            metadata.collectionPageObservers[id]?.pending.insert(section)
            metadata.collectionPageObservers[id]?.continuation.yield(())
        }
    }
}
