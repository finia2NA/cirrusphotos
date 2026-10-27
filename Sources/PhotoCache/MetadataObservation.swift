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

    func publishMetadataInvalidation(collection: PhotoCollectionDescriptor? = nil, days: Set<CaptureDay>? = nil) {
        for id in Array(metadata.collectionObservers.keys) {
            guard var observer = metadata.collectionObservers[id], collection == nil || observer.collection == collection else { continue }
            if let days { observer.days.formUnion(days) } else { observer.allDays = true; observer.days.removeAll() }
            metadata.collectionObservers[id] = observer
            observer.continuation.yield(())
        }
        if collection == nil || collection == .personalLibrary {
            for section in metadata.latestTimelines[.personalLibrary]?.sections ?? [] {
                if let raw = section.list.first, let day = try? CaptureDay(year: raw.year, month: raw.month, day: raw.day),
                   days == nil || days!.contains(day), let key = CacheKey.page(namespace: namespace, section: section) {
                    publishPersonalPage(key: key)
                }
            }
        }
    }
}
