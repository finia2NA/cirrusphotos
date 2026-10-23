import Foundation
import SynologyAPI

/// Coalesced hints carry no photo payloads. Each subscriber's pending set is
/// bounded by its captured timeline; draining it cannot lose a dropped wakeup.
struct PersonalPageObservation: Sendable {
    let id: UUID
    let changes: AsyncStream<Void>
}

struct PersonalPageObserver {
    let sectionsByKey: [String: TimelineSection]
    var pending: Set<TimelineSection> = []
    let continuation: AsyncStream<Void>.Continuation
}

extension CachedPhotosRepository {
    func observePersonalPages(sections: Set<TimelineSection>) -> PersonalPageObservation {
        let id = UUID()
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let pairs = sections.compactMap { section in
                CacheKey.page(namespace: namespace, section: section).map { ($0, section) }
            }
            metadata.personalPageObservers[id] = .init(
                sectionsByKey: Dictionary(uniqueKeysWithValues: pairs), continuation: continuation)
            continuation.onTermination = { @Sendable _ in
                Task { await self.removePersonalPageObserver(id) }
            }
        }
        return .init(id: id, changes: stream)
    }

    func takePersonalPageChanges(_ id: UUID) -> Set<TimelineSection> {
        guard let observer = metadata.personalPageObservers[id] else { return [] }
        metadata.personalPageObservers[id]?.pending.removeAll()
        return observer.pending
    }

    func removePersonalPageObserver(_ id: UUID) {
        metadata.personalPageObservers.removeValue(forKey: id)?.continuation.finish()
    }

    func publishPersonalPage(key: String) {
        for id in Array(metadata.personalPageObservers.keys) {
            guard let section = metadata.personalPageObservers[id]?.sectionsByKey[key] else { continue }
            metadata.personalPageObservers[id]?.pending.insert(section)
            metadata.personalPageObservers[id]?.continuation.yield(())
        }
    }
}
