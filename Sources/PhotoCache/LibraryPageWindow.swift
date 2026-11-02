import Foundation
import SynologyAPI

public struct LibraryPage: Sendable {
    public let sectionIndex: Int
    public let slots: [PhotoItemSlot]
    public let verified: Bool
    public let membershipVerified: Bool
    public var items: [PhotoItem] { slots.compactMap(\.item) }
    public var completeItems: [PhotoItem]? {
        guard slots.allSatisfy({ $0.item != nil }) else { return nil }
        return slots.compactMap(\.item)
    }
    public func slot(at offset: Int) -> PhotoItemSlot? { slots.indices.contains(offset) ? slots[offset] : nil }
    public init(sectionIndex: Int, slots: [PhotoItemSlot], verified: Bool, membershipVerified: Bool? = nil) {
        self.sectionIndex = sectionIndex; self.slots = slots; self.verified = verified; self.membershipVerified = membershipVerified ?? verified
    }
    public init(sectionIndex: Int, items: [PhotoItem], verified: Bool) {
        self.init(sectionIndex: sectionIndex, slots: items.map { .init(itemID: $0.id, item: $0, verified: verified) }, verified: verified)
    }
}

/// Reconstructs derived pages from exact membership while retaining available item details.
public enum FilterPageRebaser {
    public static func rebase(pages: [Int: LibraryPage], membership: [[Int64]], sourceAuthority: [[Bool]]? = nil) -> [Int: LibraryPage] {
        var known: [Int64: PhotoItemSlot] = [:]
        for page in pages.values {
            for slot in page.slots where slot.item != nil { known[slot.itemID] = slot }
        }
        var result: [Int: LibraryPage] = [:]
        for (section, ids) in membership.enumerated() {
            guard ids.contains(where: { known[$0] != nil }) else { continue }
            let slots = ids.enumerated().map { offset, id in
                let existing = known[id]
                let authoritative = sourceAuthority.map { $0.indices.contains(section) && $0[section].indices.contains(offset) && $0[section][offset] } ?? true
                return PhotoItemSlot(itemID: id, item: existing?.item, verified: existing?.verified == true && authoritative)
            }
            let unchanged = pages.values.contains { $0.slots.map(\.itemID) == ids && $0.verified }
            result[section] = LibraryPage(sectionIndex: section, slots: slots,
                                          verified: unchanged && slots.allSatisfy { $0.item != nil && $0.verified },
                                          membershipVerified: sourceAuthority.map { $0.indices.contains(section) && $0[section].count == ids.count && $0[section].allSatisfy { $0 } } ?? true)
        }
        return result
    }
}

public enum LibraryPageEvent: Sendable {
    case page(LibraryPage, fingerprint: String)
    case removed(sectionIndex: Int)
    case failure(sectionIndex: Int, message: String)
}

/// Keeps only the demanded section pages. The caller supplies exact section indices, so a
/// split day never forces all of its pages into memory at once.
public actor LibraryPageWindow {
    private struct Request {
        let id: UUID
        let descriptor: TimelineSection
        let allowNetwork: Bool
        let task: Task<Void, Never>
    }
    private struct Completion {
        let descriptor: TimelineSection
        let allowNetwork: Bool
    }
    private let repository: CachedPhotosRepository
    private let collection: PhotoCollectionDescriptor
    public let maximumPages: Int
    private var fingerprint: String?
    private var sectionDescriptors: [TimelineSection] = []
    private var pages: [Int: LibraryPage] = [:]
    private var requests: [Int: Request] = [:]
    private var completed: [Int: Completion] = [:]
    private var failedSections: Set<Int> = []
    private var retryRevision = 0
    private var observers: [UUID: AsyncStream<LibraryPageEvent>.Continuation] = [:]
    private var metadataTask: Task<Void, Never>?
    private var lastDemand: (index: LibraryIndex, allowNetwork: Bool, visible: [Int], prefetch: [Int], retry: Int)?
    private var favoriteTask: Task<Void, Never>?
    private var itemMutationTask: Task<Void, Never>?
    private var favoriteValues: [Int64: Bool] = [:]

    public init(repository: CachedPhotosRepository,
                collection: PhotoCollectionDescriptor,
                maximumPages: Int = 8) {
        self.repository = repository
        self.collection = collection
        self.maximumPages = max(1, maximumPages)
    }

    public func events() -> AsyncStream<LibraryPageEvent> {
        observeFavoritesIfNeeded()
        observeItemMutationsIfNeeded()
        observeMetadataIfNeeded()
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(maximumPages * 2 + 4)) { continuation in
            observers[id] = continuation
            if let fingerprint {
                for page in pages.values.sorted(by: { $0.sectionIndex < $1.sectionIndex }) {
                    continuation.yield(.page(page, fingerprint: fingerprint))
                }
            }
            continuation.onTermination = { @Sendable _ in Task { await self.removeObserver(id) } }
        }
    }

    public func retainedPages() -> [LibraryPage] {
        pages.values.sorted(by: { $0.sectionIndex < $1.sectionIndex })
    }

    public func update(snapshot: TimelineSnapshot, allowNetwork: Bool,
                       visible: [Int], prefetch: [Int]) {
        update(index: LibraryIndex(snapshot: snapshot), allowNetwork: allowNetwork,
               visible: visible, prefetch: prefetch)
    }

    /// Reuse a prebuilt index while the viewport changes; hashing the full timeline is unnecessary.
    public func update(index: LibraryIndex, allowNetwork: Bool,
                       visible: [Int], prefetch: [Int], retryRevision: Int = 0) {
        observeFavoritesIfNeeded()
        observeMetadataIfNeeded()
        lastDemand = (index, allowNetwork, visible, prefetch, retryRevision)
        if self.retryRevision != retryRevision {
            self.retryRevision = retryRevision
            for section in failedSections {
                completed.removeValue(forKey: section)
                requests.removeValue(forKey: section)?.task.cancel()
            }
            failedSections.removeAll()
        }
        rebase(to: index)
        var desired: [Int] = []
        var visibleSet: Set<Int> = []
        for section in visible where index.sections.indices.contains(section) {
            if visibleSet.insert(section).inserted { desired.append(section) }
        }
        let visibleCount = desired.count
        for section in prefetch where desired.count < maximumPages &&
            index.sections.indices.contains(section) && !desired.contains(section) {
            desired.append(section)
            if desired.count == maximumPages { break }
        }
        let retained = Set(desired)
        for section in requests.keys where !retained.contains(section) {
            requests.removeValue(forKey: section)?.task.cancel()
        }
        completed = completed.filter { retained.contains($0.key) }
        failedSections = failedSections.intersection(retained)
        for section in pages.keys where !retained.contains(section) {
            pages.removeValue(forKey: section)
            publish(.removed(sectionIndex: section))
        }
        for (position, section) in desired.enumerated() {
            let descriptor = index.sections[section]
            if let request = requests[section] {
                if request.descriptor == descriptor && request.allowNetwork == allowNetwork {
                    if position < visibleCount {
                        Task { await repository.promotePage(descriptor, collection: collection) }
                    }
                    continue
                }
                request.task.cancel()
                requests.removeValue(forKey: section)
            }
            if let completion = completed[section], completion.descriptor == descriptor,
               completion.allowNetwork == allowNetwork { continue }
            // A verified page is current for this repository run. A provisional page must
            // be retried when network validation becomes available.
            if let page = pages[section], page.verified { continue }
            let id = UUID()
            let identity = index.fingerprint
            let priority: RequestPriority = position < visibleCount ? .visible : .prefetch
            let task = Task {
                for await event in await repository.page(descriptor, collection: collection,
                                                          allowNetwork: allowNetwork, priority: priority) {
                    if Task.isCancelled { break }
                    receive(event, section: section, fingerprint: identity, id: id)
                }
                finish(section: section, id: id)
            }
            requests[section] = Request(id: id, descriptor: descriptor,
                                        allowNetwork: allowNetwork, task: task)
        }
    }

    /// Numeric section positions may move while stable day slots remain reusable.
    public func rebase(to index: LibraryIndex, filterMembership: [[Int64]]? = nil, filterAuthority: [[Bool]]? = nil) {
        guard fingerprint != index.fingerprint || filterMembership != nil else { return }
        for request in requests.values { request.task.cancel() }
        requests.removeAll(); completed.removeAll(); failedSections.removeAll()
        var positions: [DayPageAddress: Int] = [:]
        for (position, section) in index.sections.enumerated() {
            if let address = try? DayPageAddress(section: section, collection: collection) { positions[address] = position }
        }
        var rebased: [Int: LibraryPage] = [:]
        if let filterMembership {
            rebased = FilterPageRebaser.rebase(pages: pages, membership: filterMembership, sourceAuthority: filterAuthority)
        } else {
        for (position, page) in pages {
            guard sectionDescriptors.indices.contains(position),
                  let address = try? DayPageAddress(section: sectionDescriptors[position], collection: collection),
                  let next = positions[address], sectionDescriptors[position].list == index.sections[next].list else { continue }
            rebased[next] = LibraryPage(sectionIndex: next, slots: page.slots, verified: page.verified, membershipVerified: page.membershipVerified)
        }
        }
        for position in pages.keys { publish(.removed(sectionIndex: position)) }
        pages = rebased
        sectionDescriptors = index.sections
        fingerprint = index.fingerprint
        for page in rebased.values { publish(.page(page, fingerprint: index.fingerprint)) }
    }

    public func cancelAll() {
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
        completed.removeAll()
        failedSections.removeAll()
        for section in pages.keys { publish(.removed(sectionIndex: section)) }
        pages.removeAll()
        favoriteTask?.cancel()
        favoriteTask = nil
        metadataTask?.cancel()
        metadataTask = nil
        lastDemand = nil
    }

    private func receive(_ event: ResourceEvent<PhotoPageSnapshot>, section: Int,
                         fingerprint identity: String, id: UUID) {
        guard fingerprint == identity, requests[section]?.id == id else { return }
        switch event {
        case .value(let items, let verified):
            failedSections.remove(section)
            let page = LibraryPage(sectionIndex: section,
                                   slots: items.slots.map { slot in
                                       let item = slot.item.map { item in favoriteValues[item.id].map { item.withFavorite($0) } ?? item }
                                       return PhotoItemSlot(itemID: slot.itemID, item: item, verified: slot.verified)
                                   }, verified: verified, membershipVerified: items.membershipVerified)
            pages[section] = page
            publish(.page(page, fingerprint: identity))
        case .failure(let message):
            failedSections.insert(section)
            publish(.failure(sectionIndex: section, message: message))
        }
    }

    private func finish(section: Int, id: UUID) {
        if let request = requests[section], request.id == id {
            completed[section] = Completion(descriptor: request.descriptor,
                                            allowNetwork: request.allowNetwork)
            requests.removeValue(forKey: section)
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func observeFavoritesIfNeeded() {
        guard favoriteTask == nil else { return }
        let repository = repository
        favoriteTask = Task { [weak self, collection] in
            let scope = await repository.mediaCollection(for: collection).contentScope
            guard scope.space != nil else { return }
            for await change in await repository.favoriteChanges(space: scope.space!) {
                guard !Task.isCancelled else { return }
                await self?.receiveFavorite(change)
            }
        }
    }

    private func observeItemMutationsIfNeeded() {
        guard itemMutationTask == nil else { return }
        let repository = repository
        itemMutationTask = Task { [weak self, collection] in
            let scope = await repository.mediaCollection(for: collection).contentScope
            for await change in await repository.photoItemChanges() {
                guard !Task.isCancelled else { return }
                guard change.scope == scope else { continue }
                await self?.receiveItems(change)
            }
        }
    }

    private func observeMetadataIfNeeded() {
        guard metadataTask == nil else { return }
        metadataTask = Task { [weak self, repository, collection] in
            let observation = await repository.observeMetadataChanges(collection: collection)
            for await _ in observation.changes {
                guard !Task.isCancelled else { return }
                if let change = await repository.takeMetadataChanges(observation.id) { await self?.invalidate(change) }
            }
        }
    }
    private func invalidate(_ change: MetadataCollectionInvalidation) {
        guard let fingerprint else { return }
        for position in sectionDescriptors.indices {
            guard let raw = sectionDescriptors[position].list.first,
                  let day = try? CaptureDay(year: raw.year, month: raw.month, day: raw.day),
                  change.days == nil || change.days!.contains(day) else { continue }
            completed.removeValue(forKey: position)
            if let page = pages[position] {
                let stale = LibraryPage(sectionIndex: position, slots: page.slots.map { PhotoItemSlot(itemID: $0.itemID, item: $0.item, verified: false) }, verified: false, membershipVerified: false)
                pages[position] = stale
                publish(.page(stale, fingerprint: fingerprint))
            }
        }
        if let demand = lastDemand { update(index: demand.index, allowNetwork: demand.allowNetwork, visible: demand.visible, prefetch: demand.prefetch, retryRevision: demand.retry) }
    }

    private func receiveItems(_ change: PhotoItemChange) {
        if !change.favoriteValues.isEmpty { receiveFavorite(FavoriteChange(values: change.favoriteValues, sourceCollection: collection)) }
        guard let fingerprint else { return }
        for (section, page) in pages {
            var modified = false
            let slots = page.slots.map { slot -> PhotoItemSlot in
                guard let replacement = change.items[slot.itemID] else { return slot }
                modified = true
                let updated = slot.item?.withRotationMetadata(from: replacement) ?? replacement
                let projected = favoriteValues[slot.itemID].map { updated.withFavorite($0) } ?? updated
                return PhotoItemSlot(itemID: slot.itemID, item: projected, verified: slot.verified)
            }
            if modified {
                let updated = LibraryPage(sectionIndex: section, slots: slots, verified: page.verified, membershipVerified: page.membershipVerified)
                pages[section] = updated
                publish(.page(updated, fingerprint: fingerprint))
            }
        }
    }

    private func receiveFavorite(_ change: FavoriteChange) {
        for (id, val) in change.values {
            favoriteValues[id] = val
        }
        guard let fingerprint else { return }
        for (section, page) in pages {
            var modified = false
            let slots = page.slots.map { slot -> PhotoItemSlot in
                guard let item = slot.item, let value = change.values[slot.itemID], item.isFavorite != value else { return slot }
                modified = true
                return PhotoItemSlot(itemID: slot.itemID, item: item.withFavorite(value), verified: slot.verified)
            }
            if modified {
                let updated = LibraryPage(sectionIndex: section, slots: slots, verified: page.verified, membershipVerified: page.membershipVerified)
                pages[section] = updated
                publish(.page(updated, fingerprint: fingerprint))
            }
        }
    }
    private func publish(_ event: LibraryPageEvent) {
        for observer in observers.values { observer.yield(event) }
    }
}
