import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    public func registerLibraryFilter(_ registration: LibraryFilterRegistration) throws {
        try storeLibraryFilter(registration)
    }

    public func replaceLibraryFilterSnapshot(_ registration: LibraryFilterRegistration) throws {
        try storeLibraryFilter(registration)
    }

    private func storeLibraryFilter(_ registration: LibraryFilterRegistration) throws {
        guard let id = registration.descriptor.libraryFilterID,
              registration.referencesBySection.count == registration.snapshot.sections.count else {
            throw SynologyAPIError.unsupported("An invalid library filter registration was supplied.")
        }
        guard !metadata.resetInProgress else { throw MetadataAdmissionError.resetInProgress }
        var mapping: [TimelineSection: [LibraryFilterReference]] = [:]
        for (section, references) in zip(registration.snapshot.sections, registration.referencesBySection) {
            mapping[section] = references
        }
        if let prior = metadata.libraryFilters[id] {
            for section in prior.registration.snapshot.sections {
                if let key = CacheKey.page(namespace: namespace, section: section, collection: registration.descriptor) {
                    metadata.libraryFilterPages.removeValue(forKey: key)
                    metadata.libraryFilterPageOrder.removeAll { $0 == key }
                }
            }
        }
        metadata.libraryFilters[id] = .init(registrationID: UUID(), metadataEpoch: metadata.admissionEpoch,
                                            registration: registration, referencesBySection: mapping)
        metadata.latestTimelines[registration.descriptor] = registration.snapshot
    }

    public func unregisterLibraryFilter(_ descriptor: PhotoCollectionDescriptor) {
        guard let id = descriptor.libraryFilterID,
              let state = metadata.libraryFilters.removeValue(forKey: id) else { return }
        for section in state.registration.snapshot.sections {
            if let key = CacheKey.page(namespace: namespace, section: section, collection: descriptor) {
                metadata.libraryFilterPages.removeValue(forKey: key)
                metadata.libraryFilterPageOrder.removeAll { $0 == key }
            }
        }
        metadata.latestTimelines.removeValue(forKey: descriptor)
    }

    func libraryFilterPage(_ section: TimelineSection, collection: PhotoCollectionDescriptor,
                           allowNetwork: Bool, priority: RequestPriority) -> AsyncStream<ResourceEvent<[PhotoItem]>> {
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                guard let id = collection.libraryFilterID, let state = metadata.libraryFilters[id],
                      let references = state.referencesBySection[section] else {
                    continuation.yield(.failure("This library filter is no longer available."))
                    continuation.finish(); return
                }
                let key = CacheKey.page(namespace: namespace, section: section, collection: collection)
                if let key, let cached = metadata.libraryFilterPages[key] {
                    continuation.yield(.value(favorites.applyingOverrides(cached), verified: true))
                    continuation.finish(); return
                }
                let registrationID = state.registrationID
                let grouped = Dictionary(grouping: references, by: \.sourceSectionIndex)
                var resolved: [Int64: PhotoItem] = [:]
                var allVerified = true
                var failure: String?
                for sourceIndex in grouped.keys.sorted() {
                    guard sourceSnapshotSection(sourceIndex) != nil else { allVerified = false; continue }
                    guard let sourceSection = sourceSnapshotSection(sourceIndex) else { continue }
                    var latest: [PhotoItem]?
                    var verified = false
                    for await event in page(sourceSection, collection: .personalLibrary,
                                            allowNetwork: allowNetwork, priority: priority) {
                        switch event {
                        case .value(let items, let current): latest = items; verified = current
                        case .failure(let message): failure = message
                        }
                    }
                    guard metadata.libraryFilters[id]?.registrationID == registrationID else {
                        continuation.finish(); return
                    }
                    allVerified = allVerified && verified
                    guard let latest else { continue }
                    for reference in grouped[sourceIndex, default: []]
                    where latest.indices.contains(reference.sourcePageOffset) {
                        let item = latest[reference.sourcePageOffset]
                        if item.id == reference.itemID && state.registration.filter.matches(item) {
                            resolved[item.id] = item
                        }
                    }
                }
                let items = references.compactMap { resolved[$0.itemID] }
                let complete = allVerified && items.count == references.count
                if complete, let key {
                    metadata.libraryFilterPages[key] = items
                    metadata.libraryFilterPageOrder.append(key)
                    while metadata.libraryFilterPageOrder.count > 8 {
                        metadata.libraryFilterPages.removeValue(forKey: metadata.libraryFilterPageOrder.removeFirst())
                    }
                }
                if !items.isEmpty || references.isEmpty { continuation.yield(.value(favorites.applyingOverrides(items), verified: complete)) }
                if let failure { continuation.yield(.failure(failure)) }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in producer.task?.cancel() }
        }
    }

    private func sourceSnapshotSection(_ index: Int) -> TimelineSection? {
        guard let sections = metadata.latestTimelines[.personalLibrary]?.sections,
              sections.indices.contains(index) else { return nil }
        return sections[index]
    }

    func promoteLibraryFilterSources(_ section: TimelineSection, collection: PhotoCollectionDescriptor) {
        guard let id = collection.libraryFilterID, let state = metadata.libraryFilters[id],
              let references = state.referencesBySection[section] else { return }
        for sourceIndex in Set(references.map(\.sourceSectionIndex)) {
            guard let source = sourceSnapshotSection(sourceIndex),
                  let key = CacheKey.page(namespace: namespace, section: source, collection: .personalLibrary),
                  !metadata.pendingPagePromotions.contains(key) else { continue }
            metadata.pendingPagePromotions.append(key)
        }
    }
}
