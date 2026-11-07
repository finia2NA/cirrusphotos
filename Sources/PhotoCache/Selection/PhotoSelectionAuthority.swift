import Foundation
import SynologyAPI

/// Opaque identity of the collection state displayed when a selection was captured.
public struct PhotoSelectionAuthority: Sendable, Equatable {
    fileprivate let collection: PhotoCollectionDescriptor
    fileprivate let fingerprint: String
    fileprivate let epoch: UInt64
    fileprivate let mutationEpoch: UInt64
    fileprivate let registrationID: UUID?
    fileprivate let source: PhotoCollectionDescriptor?
    fileprivate let sourceRegistrationID: UUID?
    fileprivate let sourceMutationEpoch: UInt64
    fileprivate let retentions: [SelectionRegistrationRetention]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.collection == rhs.collection && lhs.fingerprint == rhs.fingerprint && lhs.epoch == rhs.epoch &&
        lhs.mutationEpoch == rhs.mutationEpoch && lhs.registrationID == rhs.registrationID &&
        lhs.source == rhs.source && lhs.sourceRegistrationID == rhs.sourceRegistrationID &&
        lhs.sourceMutationEpoch == rhs.sourceMutationEpoch
    }

    var originatingCollection: PhotoCollectionDescriptor { source ?? collection }

    func retain() -> SelectionSnapshotRetention { SelectionSnapshotRetention(retentions) }
}

/// A resolved selection and its repository-owned membership evidence.
public struct ResolvedPhotoSelection: Sendable {
    public let items: [PhotoItem]
    let authority: PhotoSelectionAuthority
    let proofs: [SelectionMembershipProof]
    private let retention: SelectionSnapshotRetention

    init(items: [PhotoItem], authority: PhotoSelectionAuthority, proofs: [SelectionMembershipProof]) {
        self.items = items
        self.authority = authority
        self.proofs = proofs
        self.retention = authority.retain()
    }
}

struct SelectionMembershipProof: Sendable {
    let address: DayPageAddress
    let revision: UInt64
    let offsetsAndIDs: [(Int, Int64)]
}

extension DiskCache {
    // This actor-isolated read has no suspension points: every selected page is
    // checked against one store state, including same-shaped replacements.
    func verifySelectionMembershipGroups(_ groups: [([SelectionMembershipProof], MetadataNamespace)], currentRun: String) throws -> Bool {
        for (proofs, namespace) in groups {
            guard try verifySelectionMembership(proofs, namespace: namespace, currentRun: currentRun) else { return false }
        }
        return true
    }

    func verifySelectionMembership(_ proofs: [SelectionMembershipProof], namespace: MetadataNamespace, currentRun: String) throws -> Bool {
        for proof in proofs {
            guard let page = try metadataPage(proof.address, namespace: namespace, currentRun: currentRun),
                  page.membershipVerified, page.membershipRevision == proof.revision,
                  proof.offsetsAndIDs.allSatisfy({ offset, id in
                      guard let slot = page.slot(at: offset) else { return false }
                      return slot.verified && slot.itemID == id
                  }) else { return false }
        }
        return true
    }
}

extension CachedPhotosRepository {
    /// Obtain this with the displayed timeline, not later when starting an operation.
    public func selectionAuthority(collection: PhotoCollectionDescriptor, snapshot: TimelineSnapshot) -> PhotoSelectionAuthority? {
        let fingerprint = LibraryIndex(snapshot: snapshot).fingerprint
        guard !metadata.resetInProgress, let current = metadata.latestTimelines[collection],
              LibraryIndex(snapshot: current).fingerprint == fingerprint else { return nil }
        let filter = collection.libraryFilterID.flatMap { metadata.sessions.libraryFilters[$0] }
        let map = collection.mapFilterID.flatMap { metadata.sessions.mapFilters[$0] }
        if collection.isLibraryFilter && filter == nil { return nil }
        if collection.isMapFilter && map == nil { return nil }
        let source = filter?.registration.sourceCollection
        let sourceID = source?.mapFilterID.flatMap { metadata.sessions.mapFilters[$0]?.registrationID }
        if source?.isMapFilter == true && sourceID == nil { return nil }
        return PhotoSelectionAuthority(collection: collection, fingerprint: fingerprint,
            epoch: metadata.admissionEpoch, mutationEpoch: metadata.mutationEpochs[collection, default: 0],
            registrationID: filter?.registrationID ?? map?.registrationID, source: source,
            sourceRegistrationID: sourceID, sourceMutationEpoch: source.map { metadata.mutationEpochs[$0, default: 0] } ?? 0,
            retentions: [metadata.sessions.selectionRetentions[collection], source.flatMap { metadata.sessions.selectionRetentions[$0] }].compactMap { $0 })
    }

    func verifySelectionFence(_ authority: PhotoSelectionAuthority, proofs: [SelectionMembershipProof]) async -> Bool {
        guard selectionAuthorityIsCurrent(authority), !Task.isCancelled else { return false }
        let valid = (try? await store.verifySelectionMembership(proofs, namespace: metadataNamespace(for: authority.originatingCollection), currentRun: runID)) == true
        return valid && !Task.isCancelled && selectionAuthorityIsCurrent(authority)
    }

    func verifySelectionFences(_ first: PhotoSelectionAuthority, proofs: [SelectionMembershipProof],
                               _ second: PhotoSelectionAuthority, proofs otherProofs: [SelectionMembershipProof]) async -> Bool {
        guard selectionAuthorityIsCurrent(first), selectionAuthorityIsCurrent(second), !Task.isCancelled else { return false }
        let valid = (try? await store.verifySelectionMembershipGroups([
            (proofs, metadataNamespace(for: first.originatingCollection)),
            (otherProofs, metadataNamespace(for: second.originatingCollection))
        ], currentRun: runID)) == true
        return valid && !Task.isCancelled && selectionAuthorityIsCurrent(first) && selectionAuthorityIsCurrent(second)
    }

    func selectionAuthorityMatches(_ authority: PhotoSelectionAuthority, collection: PhotoCollectionDescriptor, fingerprint: String) -> Bool {
        authority.collection == collection && authority.fingerprint == fingerprint && selectionAuthorityIsCurrent(authority)
    }

    func selectionAuthorityIsCurrent(_ authority: PhotoSelectionAuthority) -> Bool {
        guard let current = selectionAuthority(collection: authority.collection,
                                                snapshot: metadata.latestTimelines[authority.collection] ?? TimelineSnapshot(sections: [])),
              current == authority else { return false }
        if let source = authority.source, let filterID = authority.collection.libraryFilterID,
           let filter = metadata.sessions.libraryFilters[filterID] {
            guard let timeline = metadata.latestTimelines[source],
                  LibraryIndex(snapshot: timeline).fingerprint == filter.registration.sourceFingerprint else { return false }
        }
        return true
    }

    struct SelectionSourceCheck: Sendable {
        let collection: PhotoCollectionDescriptor
        let section: TimelineSection
        let offsetsAndIDs: [(Int, Int64)]
    }

    func selectionSourceChecks(_ authority: PhotoSelectionAuthority, locations: [LibraryIndex.Location]) -> [SelectionSourceCheck]? {
        guard selectionAuthorityIsCurrent(authority) else { return nil }
        guard let filterID = authority.collection.libraryFilterID,
              let state = metadata.sessions.libraryFilters[filterID] else { return [] }
        let source = state.registration.sourceCollection
        guard let sourceTimeline = metadata.latestTimelines[source] else { return nil }
        var grouped: [Int: [(Int, Int64)]] = [:]
        for location in locations {
            guard state.registration.referencesBySection.indices.contains(location.sectionIndex),
                  state.registration.referencesBySection[location.sectionIndex].indices.contains(location.pageOffset) else { return nil }
            let reference = state.registration.referencesBySection[location.sectionIndex][location.pageOffset]
            guard reference.sourceVerified, sourceTimeline.sections.indices.contains(reference.sourceSectionIndex) else { return nil }
            grouped[reference.sourceSectionIndex, default: []].append((reference.sourcePageOffset, reference.itemID))
        }
        return grouped.keys.sorted().map { SelectionSourceCheck(collection: source, section: sourceTimeline.sections[$0], offsetsAndIDs: grouped[$0]!) }
    }

    func beginSelectionLease(_ authority: PhotoSelectionAuthority) -> UUID? {
        guard selectionAuthorityIsCurrent(authority) else { return nil }
        let id = UUID()
        var descriptors: Set<PhotoCollectionDescriptor> = [authority.collection]
        if let source = authority.source { descriptors.insert(source) }
        metadata.sessions.selectionLeases[id] = descriptors
        return id
    }

    func endSelectionLease(_ id: UUID) {
        guard let descriptors = metadata.sessions.selectionLeases.removeValue(forKey: id) else { return }
        for descriptor in descriptors where metadata.sessions.deferredUnregisters.contains(descriptor) {
            guard metadata.sessions.selectionRetentions[descriptor]?.isRetained != true,
                  !metadata.sessions.selectionLeases.values.contains(where: { $0.contains(descriptor) }) else { continue }
            metadata.sessions.deferredUnregisters.remove(descriptor)
            if descriptor.isMapFilter { removeMapFilter(descriptor) }
            if descriptor.isLibraryFilter { removeLibraryFilter(descriptor) }
        }
    }

    func installSelectionRetention(_ descriptor: PhotoCollectionDescriptor) {
        metadata.sessions.selectionRetentions[descriptor] = SelectionRegistrationRetention { [weak self] in
            Task { await self?.finishDeferredSelectionUnregister(descriptor) }
        }
    }

    func finishDeferredSelectionUnregister(_ descriptor: PhotoCollectionDescriptor) {
        guard metadata.sessions.deferredUnregisters.contains(descriptor),
              metadata.sessions.selectionRetentions[descriptor]?.isRetained != true,
              !metadata.sessions.selectionLeases.values.contains(where: { $0.contains(descriptor) }) else { return }
        metadata.sessions.deferredUnregisters.remove(descriptor)
        if descriptor.isMapFilter { removeMapFilter(descriptor) }
        if descriptor.isLibraryFilter { removeLibraryFilter(descriptor) }
    }

    func deferSelectionUnregister(_ descriptor: PhotoCollectionDescriptor) -> Bool {
        guard metadata.sessions.selectionRetentions[descriptor]?.isRetained == true || metadata.sessions.selectionLeases.values.contains(where: { $0.contains(descriptor) }) else { return false }
        metadata.sessions.deferredUnregisters.insert(descriptor)
        return true
    }
}

/// Synchronous pin used to transfer a displayed registration into an accepted job.
final class SelectionRegistrationRetention: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let onEmpty: @Sendable () -> Void
    init(onEmpty: @escaping @Sendable () -> Void) { self.onEmpty = onEmpty }
    var isRetained: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    func retain() { lock.lock(); count += 1; lock.unlock() }
    func release() {
        lock.lock(); count -= 1; let empty = count == 0; lock.unlock()
        if empty { onEmpty() }
    }
}

final class SelectionSnapshotRetention: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [SelectionRegistrationRetention]
    init(_ handles: [SelectionRegistrationRetention]) {
        self.handles = handles
        for handle in handles { handle.retain() }
    }
    func release() {
        lock.lock(); let old = handles; handles = []; lock.unlock()
        for handle in old { handle.release() }
    }
    deinit { release() }
}
