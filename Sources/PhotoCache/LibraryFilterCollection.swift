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
                let sourceSnapshot = metadata.latestTimelines[.personalLibrary]
                let grouped = Dictionary(grouping: references, by: \.sourceSectionIndex)
                var contributions: [Int: (items: [PhotoItem], verified: Bool)] = [:]
                var failure: String?

                func isCurrent() -> Bool {
                    guard !Task.isCancelled else { return false }
                    guard metadata.admissionEpoch == state.metadataEpoch else { return false }
                    guard metadata.libraryFilters[id]?.registrationID == registrationID else { return false }
                    return metadata.latestTimelines[.personalLibrary]?.sections == sourceSnapshot?.sections
                }

                func assembled() -> (items: [PhotoItem], verified: Bool) {
                    let items = references.compactMap { reference -> PhotoItem? in
                        guard let source = contributions[reference.sourceSectionIndex],
                              source.items.indices.contains(reference.sourcePageOffset) else { return nil }
                        let item = source.items[reference.sourcePageOffset]
                        guard item.id == reference.itemID, state.registration.filter.matches(item) else { return nil }
                        return item
                    }
                    let verified = contributions.count == grouped.count &&
                        contributions.values.allSatisfy(\.verified) && items.count == references.count
                    return (favorites.applyingOverrides(items), verified)
                }

                func emit() -> Bool {
                    let value = assembled()
                    if value.verified, let key {
                        metadata.libraryFilterPages[key] = value.items
                        metadata.libraryFilterPageOrder.removeAll { $0 == key }
                        metadata.libraryFilterPageOrder.append(key)
                        while metadata.libraryFilterPageOrder.count > 8 {
                            metadata.libraryFilterPages.removeValue(forKey: metadata.libraryFilterPageOrder.removeFirst())
                        }
                    }
                    if !value.items.isEmpty || references.isEmpty {
                        continuation.yield(.value(value.items, verified: value.verified))
                    }
                    return value.verified
                }

                // Read all cached contributions before any network-backed stream
                // can suspend, including cached sources after an uncached source.
                for sourceIndex in grouped.keys.sorted() {
                    guard isCurrent() else { continuation.finish(); return }
                    guard let sections = sourceSnapshot?.sections, sections.indices.contains(sourceIndex) else {
                        failure = "A source section is no longer available."
                        continue
                    }
                    for await event in page(sections[sourceIndex], collection: .personalLibrary,
                                            allowNetwork: false, priority: priority) {
                        guard isCurrent() else { continuation.finish(); return }
                        switch event {
                        case .value(let items, let verified): contributions[sourceIndex] = (items, verified)
                        case .failure(let message): failure = message
                        }
                    }
                    guard isCurrent() else { continuation.finish(); return }
                }
                let complete = emit()
                if complete || !allowNetwork {
                    if let failure { continuation.yield(.failure(failure)) }
                    continuation.finish(); return
                }

                do {
                    _ = try await verifiedTimelineSnapshot(collection: .personalLibrary)
                } catch {
                    if isCurrent() { continuation.yield(.failure(error.localizedDescription)) }
                    continuation.finish(); return
                }
                guard isCurrent() else { continuation.finish(); return }
                for sourceIndex in grouped.keys.sorted() {
                    guard let sections = sourceSnapshot?.sections, sections.indices.contains(sourceIndex) else { continue }
                    for await event in page(sections[sourceIndex], collection: .personalLibrary,
                                            allowNetwork: true, priority: priority) {
                        guard isCurrent() else { continuation.finish(); return }
                        switch event {
                        case .value(let items, let verified):
                            contributions[sourceIndex] = (items, verified)
                        case .failure(let message): failure = message
                        }
                    }
                    guard isCurrent() else { continuation.finish(); return }
                }
                _ = emit()
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
