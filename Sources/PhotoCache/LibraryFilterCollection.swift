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
        if let source = metadata.latestTimelines[.personalLibrary], LibraryIndex(snapshot: source).fingerprint != registration.sourceFingerprint {
            throw SynologyAPIError.unsupported("The source collection changed before this filter was registered.")
        }
        var mapping: [TimelineSection: [LibraryFilterReference]] = [:]
        for (section, references) in zip(registration.snapshot.sections, registration.referencesBySection) {
            mapping[section] = references
        }
        metadata.libraryFilters[id] = .init(registrationID: UUID(), metadataEpoch: metadata.admissionEpoch,
                                            registration: registration, referencesBySection: mapping)
        metadata.latestTimelines[registration.descriptor] = registration.snapshot
    }

    public func unregisterLibraryFilter(_ descriptor: PhotoCollectionDescriptor) {
        guard let id = descriptor.libraryFilterID,
              let state = metadata.libraryFilters.removeValue(forKey: id) else { return }
        metadata.latestTimelines.removeValue(forKey: descriptor)
    }

    func libraryFilterPage(_ section: TimelineSection, collection: PhotoCollectionDescriptor,
                           allowNetwork: Bool, priority: RequestPriority) -> AsyncStream<ResourceEvent<PhotoPageSnapshot>> {
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let subscriber = UUID()
                metadata.directSubscribers.insert(subscriber)
                defer { metadata.directSubscribers.remove(subscriber); cancelIdleLogin() }
                do {
                    try await initializeMetadataEngine()
                    guard let id = collection.libraryFilterID, let state = metadata.libraryFilters[id],
                          let references = state.referencesBySection[section] else { throw SynologyAPIError.unsupported("This library filter is no longer available.") }
                    let address = try DayPageAddress(section: section, collection: collection)
                    let ids = references.map(\.itemID)
                    func current() -> Bool {
                        guard !Task.isCancelled, metadata.admissionEpoch == state.metadataEpoch,
                              metadata.libraryFilters[id]?.registrationID == state.registrationID else { return false }
                        if let source = metadata.latestTimelines[.personalLibrary], LibraryIndex(snapshot: source).fingerprint != state.registration.sourceFingerprint { return false }
                        return true
                    }
                    func snapshot(_ details: [Int64: PhotoItemSlot]) -> PhotoPageSnapshot {
                        let slots = ids.map { id -> PhotoItemSlot in
                            guard let detail = details[id], let item = detail.item,
                                  state.registration.filter.matches(item), (try? CaptureDay(time: item.time)) == address.day else {
                                return PhotoItemSlot(itemID: id, item: nil, verified: false)
                            }
                            return detail
                        }
                        return PhotoPageSnapshot(address: address, membershipRevision: state.registration.revision, membershipVerified: true, slots: slots)
                    }
                    let cached = snapshot(try await store.metadataDetails(metadataNamespace, ids: ids, currentRun: runID))
                    guard current() else { continuation.finish(); return }
                    if cached.slots.contains(where: { $0.item != nil }) {
                        continuation.yield(.value(applyingFavoriteOverrides(cached), verified: cached.verified))
                    }
                    guard allowNetwork && !cached.verified else { continuation.finish(); return }
                    try await connect()
                    try await reconcileMetadataSource()
                    guard current() else { continuation.finish(); return }
                    _ = try await resolveMetadataItems(ids, priority: priority)
                    guard current() else { continuation.finish(); return }
                    let result = snapshot(try await store.metadataDetails(metadataNamespace, ids: ids, currentRun: runID))
                    guard current() else { continuation.finish(); return }
                    guard result.verified else { throw SynologyAPIError.unsupported("The requested photos no longer match this filter.") }
                    continuation.yield(.value(applyingFavoriteOverrides(result), verified: true))
                } catch {
                    if !Task.isCancelled { continuation.yield(.failure(error.localizedDescription)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in producer.task?.cancel() }
        }
    }

    func promoteLibraryFilterSources(_ section: TimelineSection, collection: PhotoCollectionDescriptor) {
        guard let id = collection.libraryFilterID, let references = metadata.libraryFilters[id]?.referencesBySection[section] else { return }
        for reference in references {
            if let job = metadata.detailJobByID[reference.itemID] { Task { await gate.promote(job) } }
        }
    }
}
