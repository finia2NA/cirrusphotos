import Foundation
import SynologyAPI

public struct PhotoViewerLocation: Sendable, Equatable, Hashable {
    public let sectionIndex: Int
    public let pageOffset: Int
    public let ordinal: Int

    public init(sectionIndex: Int, pageOffset: Int, ordinal: Int) {
        self.sectionIndex = sectionIndex
        self.pageOffset = pageOffset
        self.ordinal = ordinal
    }
}

/// The grid supplies the exact page coordinate because a visual row may span API pages.
public struct PhotoViewerSeed: Sendable {
    public let sectionIndex: Int
    public let pageOffset: Int
    public let item: PhotoItem
    public let page: [PhotoItem]?
    public let pageVerified: Bool

    public init(sectionIndex: Int, pageOffset: Int, item: PhotoItem,
                page: [PhotoItem]? = nil, pageVerified: Bool = false) {
        self.sectionIndex = sectionIndex
        self.pageOffset = pageOffset
        self.item = item
        self.page = page
        self.pageVerified = pageVerified
    }
}

public struct PhotoViewerSelection: Sendable, Equatable {
    public let generation: UInt64
    public let itemID: Int64?

    public init(generation: UInt64, itemID: Int64?) {
        self.generation = generation
        self.itemID = itemID
    }
}

public enum PhotoViewerResourceStatus: Sendable, Equatable {
    case idle
    case loading
    /// Cached data remains usable when its attempted validation fails.
    case ready(verified: Bool, validationFailure: String?)
    case failure(String)
    case unsupported(String)
}

public struct PhotoViewerState: Sendable {
    public let selection: PhotoViewerSelection
    public let desiredLocation: PhotoViewerLocation
    public let item: PhotoItem?
    public let metadataVerified: Bool
    public let thumbnailData: Data?
    public let fullImageData: Data?
    public let metadataStatus: PhotoViewerResourceStatus
    public let thumbnailStatus: PhotoViewerResourceStatus
    public let fullImageStatus: PhotoViewerResourceStatus
    public let canNavigatePrevious: Bool
    public let canNavigateNext: Bool
    public let allowNetwork: Bool
    public let favoriteUpdating: Bool
    public let favoriteFailure: String?
    public let isClosed: Bool
}

/// Owns one viewer's bounded metadata and encoded-image work for one immutable LibraryIndex.
/// Recreate the session when the app replaces that index during cached-to-server validation.
/// All callbacks are checked against request identities in addition to task cancellation,
/// so a late result cannot
/// replace a newer selection.
public actor PhotoViewerSession {
    private struct SectionSpan: Sendable {
        let sectionIndex: Int
        let start: Int
        let count: Int
    }
    private struct PageEntry: Sendable {
        let items: [PhotoItem]
        let verified: Bool
    }
    private struct PageJob {
        let id: UUID
        let allowNetwork: Bool
        let task: Task<Void, Never>
    }
    private struct FullJob {
        let id: UUID
        let location: PhotoViewerLocation
        let resource: FullImageResource
        let allowNetwork: Bool
        let task: Task<Void, Never>
        var data: Data?
        var verified = false
        var failure: String?
        var completed = false
    }
    private struct ThumbnailPrefetchJob {
        let id: UUID
        let allowNetwork: Bool
        let task: Task<Void, Never>
    }

    private let repository: CachedPhotosRepository
    private let collection: PhotoCollectionDescriptor
    private let index: LibraryIndex
    private let spans: [SectionSpan]
    private let totalCount: Int
    private let thumbnailSize: ThumbnailSize
    private let maximumPages: Int

    private var allowNetwork: Bool
    private var desired: PhotoViewerLocation
    private var generation: UInt64 = 1
    private var currentItem: PhotoItem?
    private var currentIdentity: String?
    private var metadataVerified = false
    private var thumbnailData: Data?
    private var fullImageData: Data?
    private var metadataStatus: PhotoViewerResourceStatus = .loading
    private var thumbnailStatus: PhotoViewerResourceStatus = .idle
    private var fullImageStatus: PhotoViewerResourceStatus = .idle
    private var started = false
    private var closed = false
    private var retryRevision = 0
    private var favoriteUpdating = false
    private var favoriteFailure: String?
    private var favoriteValues: [Int64: Bool] = [:]
    private var favoriteTask: Task<Void, Never>?

    private var pages: [Int: PageEntry] = [:]
    private var pageJobs: [Int: PageJob] = [:]
    private var thumbnailTask: Task<Void, Never>?
    private var thumbnailAttempt: UUID?
    private var thumbnailTaskAllowsNetwork = false
    private var thumbnailPrefetchJobs: [String: ThumbnailPrefetchJob] = [:]
    private var fullTask: Task<Void, Never>?
    private var fullAttempt: UUID?
    private var fullTaskAllowsNetwork = false
    private var fullJobs: [String: FullJob] = [:]
    private var prefetchEnabledGeneration: UInt64?
    private var observers: [UUID: AsyncStream<PhotoViewerState>.Continuation] = [:]

    public init(repository: CachedPhotosRepository, collection: PhotoCollectionDescriptor = .personalLibrary,
                index: LibraryIndex,
                seed: PhotoViewerSeed, thumbnailSize: ThumbnailSize = .xl,
                allowNetwork: Bool, maximumPages: Int = 3) {
        self.repository = repository
        self.collection = collection
        self.index = index
        self.thumbnailSize = thumbnailSize
        self.allowNetwork = allowNetwork
        self.maximumPages = max(1, min(3, maximumPages))

        var built: [SectionSpan] = []
        var running = 0
        for sectionIndex in index.sections.indices {
            let count = max(0, index.sections[sectionIndex].limit)
            built.append(SectionSpan(sectionIndex: sectionIndex, start: running, count: count))
            let sum = running.addingReportingOverflow(count)
            running = sum.overflow ? Int.max : sum.partialValue
        }
        spans = built
        totalCount = running
        let safeSection = min(max(0, seed.sectionIndex), max(0, index.sections.count - 1))
        let span = built.indices.contains(safeSection) ? built[safeSection] : SectionSpan(sectionIndex: 0, start: 0, count: 0)
        let safeOffset = min(max(0, seed.pageOffset), max(0, span.count - 1))
        desired = PhotoViewerLocation(sectionIndex: safeSection, pageOffset: safeOffset,
                                      ordinal: span.start + safeOffset)
        currentItem = seed.item
        currentIdentity = Self.identity(of: seed.item)
        metadataVerified = seed.pageVerified
        metadataStatus = seed.pageVerified ? .ready(verified: true, validationFailure: nil) : .loading
        if let page = seed.page {
            pages[safeSection] = PageEntry(items: Array(page.prefix(max(1, span.count))),
                                           verified: seed.pageVerified)
        }
    }

    public func states() -> AsyncStream<PhotoViewerState> {
        let id = UUID()
        let stream = AsyncStream<PhotoViewerState>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.yield(makeState())
            if closed {
                continuation.finish()
            } else {
                continuation.onTermination = { @Sendable _ in
                    Task { await self.removeObserver(id) }
                }
            }
        }
        startIfNeeded()
        return stream
    }

    public func state() -> PhotoViewerState {
        startIfNeeded()
        return makeState()
    }

    public func navigatePrevious() { navigate(by: -1) }
    public func navigateNext() { navigate(by: 1) }

    public func toggleFavorite() async {
        guard !closed, allowNetwork, metadataVerified, !favoriteUpdating,
              let item = currentItem else { return }
        favoriteUpdating = true
        favoriteFailure = nil
        publish()
        let itemID = item.id
        let section = index.sections[desired.sectionIndex]
        let target = !item.isFavorite
        applyFavorite(itemID: itemID, value: target)
        do {
            try await repository.setFavorite(itemID: itemID, item: item, in: section,
                                              collection: collection, to: target)
        } catch {
            applyFavorite(itemID: itemID, value: item.isFavorite)
            if currentItem?.id == itemID { favoriteFailure = error.localizedDescription }
        }
        favoriteUpdating = false
        publish()
    }

    public func navigate(by delta: Int) {
        guard !closed, totalCount > 0, delta != 0 else { return }
        startIfNeeded()
        let sum = desired.ordinal.addingReportingOverflow(delta)
        let candidate: Int
        if sum.overflow { candidate = delta > 0 ? totalCount - 1 : 0 }
        else { candidate = min(totalCount - 1, max(0, sum.partialValue)) }
        guard candidate != desired.ordinal, let location = location(for: candidate) else { return }
        select(location)
    }

    public func updateAllowNetwork(_ enabled: Bool) {
        guard !closed, allowNetwork != enabled else { return }
        allowNetwork = enabled
        retryRevision &+= 1
        for job in pageJobs.values { job.task.cancel() }
        pageJobs.removeAll()
        if !enabled {
            metadataVerified = pages[desired.sectionIndex]?.verified == true
        }
        restartCurrentAssets()
        ensurePage(desired.sectionIndex, visible: true)
        scheduleThumbnailNeighbors()
        publish()
    }

    public func retry() {
        guard !closed else { return }
        retryRevision &+= 1
        pageJobs.removeValue(forKey: desired.sectionIndex)?.task.cancel()
        restartCurrentAssets()
        ensurePage(desired.sectionIndex, visible: true)
        scheduleThumbnailNeighbors()
        publish()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        thumbnailTask?.cancel()
        for job in thumbnailPrefetchJobs.values { job.task.cancel() }
        fullTask?.cancel()
        for job in pageJobs.values { job.task.cancel() }
        for job in fullJobs.values { job.task.cancel() }
        thumbnailTask = nil
        thumbnailPrefetchJobs.removeAll()
        fullTask = nil
        pageJobs.removeAll()
        fullJobs.removeAll()
        favoriteTask?.cancel()
        publish()
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    func retainedPageCount() -> Int { pages.count }
    func speculativeFullImageCount() -> Int { fullJobs.count }

    private func startIfNeeded() {
        guard !started, !closed else { return }
        started = true
        let repository = repository
        favoriteTask = Task { [weak self] in
            for await change in await repository.favoriteChanges() {
                guard !Task.isCancelled else { return }
                await self?.applyFavorite(itemID: change.itemID, value: change.favorite)
            }
        }
        startAssetsForCurrentMetadata()
        ensurePage(desired.sectionIndex, visible: true)
        scheduleThumbnailNeighbors()
        publish()
    }

    private func select(_ location: PhotoViewerLocation) {
        let targetResource = pages[location.sectionIndex]
            .flatMap { $0.items.indices.contains(location.pageOffset) ? $0.items[location.pageOffset] : nil }?
            .fullImageResource
        generation &+= 1
        desired = location
        favoriteFailure = nil
        currentItem = nil
        currentIdentity = nil
        metadataVerified = false
        thumbnailData = nil
        fullImageData = nil
        metadataStatus = .loading
        thumbnailStatus = .idle
        fullImageStatus = .idle
        prefetchEnabledGeneration = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        thumbnailAttempt = nil
        thumbnailTaskAllowsNetwork = false
        fullTask?.cancel()
        fullTask = nil
        fullAttempt = nil
        fullTaskAllowsNetwork = false
        cancelFullJobsExcept(resource: targetResource)
        trimPages(around: location)
        if let page = pages[location.sectionIndex] {
            applyCurrentPage(page, at: location)
        }
        ensurePage(location.sectionIndex, visible: true)
        scheduleThumbnailNeighbors()
        trimPageJobs(around: location)
        publish()
    }

    private func ensurePage(_ sectionIndex: Int, visible: Bool) {
        guard !closed, index.sections.indices.contains(sectionIndex) else { return }
        if let page = pages[sectionIndex], page.verified || !allowNetwork {
            if sectionIndex == desired.sectionIndex { applyCurrentPage(page, at: desired) }
            if prefetchEnabledGeneration == generation { scheduleLoadedNeighbors() }
            return
        }
        if let job = pageJobs[sectionIndex], job.allowNetwork == allowNetwork {
            if visible { Task { await repository.promotePage(index.sections[sectionIndex], collection: collection) } }
            return
        }
        pageJobs.removeValue(forKey: sectionIndex)?.task.cancel()
        let id = UUID()
        let descriptor = index.sections[sectionIndex]
        let network = allowNetwork
        let collection = collection
        let revision = retryRevision
        let repository = repository
        let priority: RequestPriority = visible ? .visible : .prefetch
        let task = Task { [weak self] in
            for await event in await repository.page(descriptor, collection: collection,
                                                      allowNetwork: network, priority: priority) {
                guard !Task.isCancelled else { break }
                await self?.receivePage(event, sectionIndex: sectionIndex, id: id, retryRevision: revision)
            }
            await self?.finishPage(sectionIndex: sectionIndex, id: id)
        }
        pageJobs[sectionIndex] = PageJob(id: id, allowNetwork: network, task: task)
    }

    private func receivePage(_ event: ResourceEvent<[PhotoItem]>, sectionIndex: Int,
                             id: UUID, retryRevision: Int) {
        guard !closed, self.retryRevision == retryRevision, pageJobs[sectionIndex]?.id == id else { return }
        switch event {
        case .value(let items, let verified):
            if pages[sectionIndex]?.verified == true && !verified { return }
            if sectionIndex == desired.sectionIndex && metadataVerified && !verified { return }
            let items = applyingFavorites(items)
            pages[sectionIndex] = PageEntry(items: items, verified: verified)
            trimPages(around: desired)
            if sectionIndex == desired.sectionIndex {
                applyCurrentPage(PageEntry(items: items, verified: verified), at: desired)
            }
            if prefetchEnabledGeneration == generation { scheduleLoadedNeighbors() }
            scheduleThumbnailNeighbors()
        case .failure(let message):
            if sectionIndex == desired.sectionIndex {
                if currentItem == nil { metadataStatus = .failure(message) }
                else { metadataStatus = .ready(verified: metadataVerified, validationFailure: message) }
                publish()
            }
        }
    }

    private func finishPage(sectionIndex: Int, id: UUID) {
        if pageJobs[sectionIndex]?.id == id { pageJobs.removeValue(forKey: sectionIndex) }
    }

    private func applyCurrentPage(_ page: PageEntry, at location: PhotoViewerLocation) {
        guard desired == location else { return }
        var item: PhotoItem
        if let selected = currentItem, page.verified {
            if let shiftedOffset = page.items.firstIndex(where: { $0.id == selected.id }) {
                let spanStart = spans[location.sectionIndex].start
                desired = PhotoViewerLocation(sectionIndex: location.sectionIndex,
                                              pageOffset: shiftedOffset,
                                              ordinal: spanStart + shiftedOffset)
                item = page.items[shiftedOffset]
            } else {
                clearCurrentForMissingItem("The selected item is no longer in this page.")
                return
            }
        } else {
            guard page.items.indices.contains(location.pageOffset) else {
                if page.verified {
                    clearCurrentForMissingItem("The selected item is no longer in this page.")
                }
                return
            }
            item = page.items[location.pageOffset]
            if let selected = currentItem, item.id != selected.id {
                // A stale cached page must not replace the exact item supplied by the grid.
                return
            }
        }
        item = applyingFavorite(item)
        let identity = Self.identity(of: item)
        if currentIdentity != identity {
            generation &+= 1
            currentItem = item
            currentIdentity = identity
            thumbnailData = nil
            fullImageData = nil
            thumbnailTask?.cancel()
            fullTask?.cancel()
            thumbnailTask = nil
            fullTask = nil
            thumbnailAttempt = nil
            fullAttempt = nil
            thumbnailTaskAllowsNetwork = false
            fullTaskAllowsNetwork = false
            prefetchEnabledGeneration = nil
            cancelFullJobsExcept(resource: item.fullImageResource)
        } else {
            currentItem = item
        }
        metadataVerified = page.verified
        metadataStatus = .ready(verified: page.verified, validationFailure: nil)
        startAssetsForCurrentMetadata()
        publish()
    }

    private func clearCurrentForMissingItem(_ message: String) {
        if currentItem != nil || currentIdentity != nil { generation &+= 1 }
        currentItem = nil
        currentIdentity = nil
        metadataVerified = true
        thumbnailData = nil
        fullImageData = nil
        metadataStatus = .failure(message)
        thumbnailStatus = .idle
        fullImageStatus = .failure(message)
        thumbnailTask?.cancel()
        fullTask?.cancel()
        thumbnailTask = nil
        fullTask = nil
        thumbnailAttempt = nil
        fullAttempt = nil
        thumbnailTaskAllowsNetwork = false
        fullTaskAllowsNetwork = false
        prefetchEnabledGeneration = nil
        cancelFullJobsExcept(resource: nil)
        publish()
    }

    private func restartCurrentAssets() {
        thumbnailTask?.cancel()
        fullTask?.cancel()
        thumbnailTask = nil
        fullTask = nil
        thumbnailAttempt = nil
        fullAttempt = nil
        thumbnailTaskAllowsNetwork = false
        fullTaskAllowsNetwork = false
        prefetchEnabledGeneration = nil
        cancelFullJobsExceptCurrentCandidate()
        startAssetsForCurrentMetadata()
    }

    private func startAssetsForCurrentMetadata() {
        guard !closed, let item = currentItem else { return }
        let network = allowNetwork && metadataVerified
        startThumbnail(item: item, allowNetwork: network)
        if item.isVideo {
            fullImageStatus = .unsupported("Video playback is not supported.")
            return
        }
        guard let resource = item.fullImageResource else {
            fullImageStatus = .unsupported("A full-size image is unavailable for this item.")
            return
        }
        startFullImage(resource: resource, allowNetwork: network)
    }

    private func startThumbnail(item: PhotoItem, allowNetwork: Bool) {
        if let task = thumbnailTask, allowNetwork && !thumbnailTaskAllowsNetwork {
            task.cancel()
            thumbnailTask = nil
            thumbnailAttempt = nil
        }
        guard thumbnailTask == nil, let descriptor = item.additional?.thumbnail else {
            if item.additional?.thumbnail == nil { thumbnailStatus = .unsupported("A preview is unavailable for this item.") }
            return
        }
        let attempt = UUID()
        let expectedGeneration = generation
        let expectedID = item.id
        let repository = repository
        let size = thumbnailSize
        thumbnailAttempt = attempt
        thumbnailTaskAllowsNetwork = allowNetwork
        if thumbnailData == nil { thumbnailStatus = .loading }
        thumbnailTask = Task { [weak self] in
            for await event in await repository.thumbnail(descriptor, size: size,
                                                           allowNetwork: allowNetwork, priority: .visible) {
                guard !Task.isCancelled else { break }
                await self?.receiveThumbnail(event, attempt: attempt,
                                             generation: expectedGeneration, itemID: expectedID)
            }
            await self?.finishThumbnail(attempt)
        }
    }

    private func receiveThumbnail(_ event: ResourceEvent<Data>, attempt: UUID,
                                  generation expectedGeneration: UInt64, itemID: Int64) {
        guard !closed, thumbnailAttempt == attempt, generation == expectedGeneration,
              currentItem?.id == itemID else { return }
        switch event {
        case .value(let data, let verified):
            thumbnailData = data
            thumbnailStatus = .ready(verified: verified, validationFailure: nil)
        case .failure(let message):
            if thumbnailData != nil {
                thumbnailStatus = .ready(verified: false, validationFailure: message)
            } else {
                thumbnailStatus = .failure(message)
            }
        }
        publish()
    }

    private func finishThumbnail(_ attempt: UUID) {
        if thumbnailAttempt == attempt {
            if thumbnailData == nil, thumbnailStatus == .loading {
                thumbnailStatus = .failure("The preview is not cached.")
                publish()
            }
            thumbnailAttempt = nil
            thumbnailTask = nil
            thumbnailTaskAllowsNetwork = false
        }
    }

    private func startFullImage(resource: FullImageResource, allowNetwork: Bool) {
        let key = Self.resourceKey(resource)
        if let prefetched = fullJobs.removeValue(forKey: key) {
            fullTask?.cancel()
            if let data = prefetched.data {
                fullImageData = data
                fullImageStatus = .ready(verified: prefetched.verified,
                                         validationFailure: prefetched.failure)
                enablePrefetchAfterCurrentSuccess()
            } else {
                fullImageStatus = .loading
            }
            if prefetched.completed {
                fullTask = nil
                fullAttempt = nil
                fullTaskAllowsNetwork = false
                if allowNetwork && !prefetched.allowNetwork {
                    startFullImage(resource: resource, allowNetwork: true)
                }
            } else {
                fullTask = prefetched.task
                fullAttempt = prefetched.id
                fullTaskAllowsNetwork = prefetched.allowNetwork
                // The existing subscriber and transfer survive; the gate changes its admission class.
                Task { await repository.promoteFullImage(resource) }
            }
            return
        }
        if let task = fullTask, allowNetwork && !fullTaskAllowsNetwork {
            task.cancel()
            fullTask = nil
            fullAttempt = nil
        }
        guard fullTask == nil else { return }
        let attempt = UUID()
        let expectedGeneration = generation
        let expectedID = currentItem?.id
        let repository = repository
        fullAttempt = attempt
        fullTaskAllowsNetwork = allowNetwork
        if fullImageData == nil { fullImageStatus = .loading }
        fullTask = Task { [weak self] in
            for await event in await repository.fullImage(resource, allowNetwork: allowNetwork,
                                                           priority: .visible) {
                guard !Task.isCancelled else { break }
                await self?.receiveCurrentFull(event, attempt: attempt,
                                               generation: expectedGeneration, itemID: expectedID,
                                               resource: resource)
            }
            await self?.finishCurrentFull(attempt)
        }
    }

    private func receiveCurrentFull(_ event: ResourceEvent<Data>, attempt: UUID,
                                    generation expectedGeneration: UInt64, itemID: Int64?,
                                    resource: FullImageResource) {
        guard !closed, fullAttempt == attempt, generation == expectedGeneration,
              currentItem?.id == itemID,
              currentItem?.fullImageResource.map(Self.resourceKey) == Self.resourceKey(resource) else { return }
        switch event {
        case .value(let data, let verified):
            fullImageData = data
            fullImageStatus = .ready(verified: verified, validationFailure: nil)
            enablePrefetchAfterCurrentSuccess()
        case .failure(let message):
            if fullImageData != nil {
                fullImageStatus = .ready(verified: false, validationFailure: message)
            } else {
                fullImageStatus = .failure(message)
            }
        }
        publish()
    }

    private func finishCurrentFull(_ attempt: UUID) {
        if fullAttempt == attempt {
            if fullImageData == nil, fullImageStatus == .loading {
                fullImageStatus = .failure("The full-size image is not cached.")
                publish()
            }
            fullAttempt = nil
            fullTask = nil
            let needsNetworkValidation = allowNetwork && metadataVerified && !fullTaskAllowsNetwork
            fullTaskAllowsNetwork = false
            if needsNetworkValidation, let resource = currentItem?.fullImageResource {
                startFullImage(resource: resource, allowNetwork: true)
            }
        }
    }

    private func enablePrefetchAfterCurrentSuccess() {
        guard prefetchEnabledGeneration != generation else { return }
        prefetchEnabledGeneration = generation
        scheduleLoadedNeighbors()
    }

    /// Preview fetching is intentionally independent of original-image prefetch. It
    /// gives arrow navigation a low-resolution image while the next original loads.
    private func scheduleThumbnailNeighbors() {
        guard !closed else { return }
        let locations = [-1, 1].compactMap { location(for: desired.ordinal + $0) }
        let wantedSections = Set(locations.map(\.sectionIndex))
        for section in wantedSections where pages[section] == nil || (allowNetwork && pages[section]?.verified == false) {
            ensurePage(section, visible: false)
        }

        var wantedKeys: Set<String> = []
        for location in locations {
            guard let page = pages[location.sectionIndex],
                  page.items.indices.contains(location.pageOffset),
                  let descriptor = page.items[location.pageOffset].additional?.thumbnail else { continue }
            let key = Self.thumbnailKey(descriptor, size: thumbnailSize)
            wantedKeys.insert(key)
            let network = allowNetwork && page.verified
            if let job = thumbnailPrefetchJobs[key], network && !job.allowNetwork {
                job.task.cancel()
                thumbnailPrefetchJobs.removeValue(forKey: key)
                startThumbnailPrefetch(descriptor, key: key, allowNetwork: true)
            } else if thumbnailPrefetchJobs[key] == nil {
                startThumbnailPrefetch(descriptor, key: key, allowNetwork: network)
            }
        }
        for (key, job) in thumbnailPrefetchJobs where !wantedKeys.contains(key) {
            job.task.cancel()
            thumbnailPrefetchJobs.removeValue(forKey: key)
        }
    }

    private func startThumbnailPrefetch(_ descriptor: ThumbnailInfo, key: String, allowNetwork: Bool) {
        let id = UUID()
        let repository = repository
        let size = thumbnailSize
        let task = Task { [weak self] in
            for await _ in await repository.thumbnail(descriptor, size: size,
                                                       allowNetwork: allowNetwork, priority: .prefetch) {
                guard !Task.isCancelled else { break }
            }
            await self?.finishThumbnailPrefetch(key: key, id: id)
        }
        thumbnailPrefetchJobs[key] = ThumbnailPrefetchJob(id: id, allowNetwork: allowNetwork, task: task)
    }

    private func finishThumbnailPrefetch(key: String, id: UUID) {
        guard thumbnailPrefetchJobs[key]?.id == id else { return }
        thumbnailPrefetchJobs.removeValue(forKey: key)
    }

    private func scheduleLoadedNeighbors() {
        guard !closed, prefetchEnabledGeneration == generation else { return }
        let locations = [-1, 1].compactMap { location(for: desired.ordinal + $0) }
        let desiredSections = Set(locations.map(\.sectionIndex) + [desired.sectionIndex])
        for section in desiredSections where pages[section] == nil || (allowNetwork && pages[section]?.verified == false) {
            ensurePage(section, visible: false)
        }
        trimPageJobs(around: desired)

        var wantedKeys: Set<String> = []
        for location in locations {
            guard let page = pages[location.sectionIndex], page.items.indices.contains(location.pageOffset) else { continue }
            let item = page.items[location.pageOffset]
            guard let resource = item.fullImageResource else { continue }
            let key = Self.resourceKey(resource)
            wantedKeys.insert(key)
            let network = allowNetwork && page.verified
            if let job = fullJobs[key], network && !job.allowNetwork {
                job.task.cancel()
                fullJobs.removeValue(forKey: key)
                startPrefetch(resource: resource, location: location, allowNetwork: true)
            } else if fullJobs[key] == nil {
                startPrefetch(resource: resource, location: location, allowNetwork: network)
            }
        }
        for (key, job) in fullJobs where !wantedKeys.contains(key) {
            job.task.cancel()
            fullJobs.removeValue(forKey: key)
        }
    }

    private func startPrefetch(resource: FullImageResource, location: PhotoViewerLocation,
                               allowNetwork: Bool) {
        let key = Self.resourceKey(resource)
        let id = UUID()
        let repository = repository
        let task = Task { [weak self] in
            for await event in await repository.fullImage(resource, allowNetwork: allowNetwork,
                                                           priority: .prefetch) {
                guard !Task.isCancelled else { break }
                await self?.receivePrefetch(event, key: key, id: id)
            }
            await self?.finishPrefetch(key: key, id: id)
        }
        fullJobs[key] = FullJob(id: id, location: location, resource: resource,
                                allowNetwork: allowNetwork, task: task)
    }

    private func receivePrefetch(_ event: ResourceEvent<Data>, key: String, id: UUID) {
        if fullAttempt == id {
            receiveCurrentFull(event, attempt: id, generation: generation,
                               itemID: currentItem?.id,
                               resource: currentItem?.fullImageResource ?? FullImageResource(unitID: -1, cacheKey: ""))
            return
        }
        guard var job = fullJobs[key], job.id == id else { return }
        switch event {
        case .value(let data, let verified):
            job.data = data
            job.verified = verified
            job.failure = nil
        case .failure(let message):
            job.failure = message
        }
        fullJobs[key] = job
    }

    private func finishPrefetch(key: String, id: UUID) {
        if fullAttempt == id {
            finishCurrentFull(id)
        } else if var job = fullJobs[key], job.id == id {
            if job.data == nil {
                fullJobs.removeValue(forKey: key)
            } else {
                job.completed = true
                fullJobs[key] = job
            }
        }
    }

    private func cancelFullJobsExceptCurrentCandidate() {
        cancelFullJobsExcept(resource: currentItem?.fullImageResource)
    }

    private func cancelFullJobsExcept(resource: FullImageResource?) {
        let keep = resource.map(Self.resourceKey)
        for (key, job) in fullJobs where key != keep {
            job.task.cancel()
            fullJobs.removeValue(forKey: key)
        }
    }

    private func trimPages(around location: PhotoViewerLocation) {
        var desiredSections = [location.sectionIndex]
        if let previous = self.location(for: location.ordinal - 1), !desiredSections.contains(previous.sectionIndex) {
            desiredSections.append(previous.sectionIndex)
        }
        if let next = self.location(for: location.ordinal + 1), !desiredSections.contains(next.sectionIndex) {
            desiredSections.append(next.sectionIndex)
        }
        let retained = Set(desiredSections.prefix(maximumPages))
        pages = pages.filter { retained.contains($0.key) }
    }

    private func trimPageJobs(around location: PhotoViewerLocation) {
        var retained: Set<Int> = [location.sectionIndex]
        // Neighbor metadata is needed for the always-on thumbnail buffer. Original-image
        // prefetch remains separately gated on the current original succeeding.
        if let previous = self.location(for: location.ordinal - 1) { retained.insert(previous.sectionIndex) }
        if let next = self.location(for: location.ordinal + 1) { retained.insert(next.sectionIndex) }
        for (section, job) in pageJobs where !retained.contains(section) {
            job.task.cancel()
            pageJobs.removeValue(forKey: section)
        }
    }

    private func location(for ordinal: Int) -> PhotoViewerLocation? {
        guard ordinal >= 0, ordinal < totalCount else { return nil }
        // The section count is compact (one record per server page); no item array is built.
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            let span = spans[mid]
            if ordinal < span.start { high = mid }
            else if ordinal >= span.start + span.count { low = mid + 1 }
            else {
                return PhotoViewerLocation(sectionIndex: span.sectionIndex,
                                           pageOffset: ordinal - span.start, ordinal: ordinal)
            }
        }
        return nil
    }

    private func makeState() -> PhotoViewerState {
        PhotoViewerState(
            selection: PhotoViewerSelection(generation: generation, itemID: currentItem?.id),
            desiredLocation: desired,
            item: currentItem,
            metadataVerified: metadataVerified,
            thumbnailData: thumbnailData,
            fullImageData: fullImageData,
            metadataStatus: metadataStatus,
            thumbnailStatus: thumbnailStatus,
            fullImageStatus: fullImageStatus,
            canNavigatePrevious: desired.ordinal > 0,
            canNavigateNext: desired.ordinal + 1 < totalCount,
            allowNetwork: allowNetwork,
            favoriteUpdating: favoriteUpdating,
            favoriteFailure: favoriteFailure,
            isClosed: closed
        )
    }

    private func publish() {
        let state = makeState()
        for observer in observers.values { observer.yield(state) }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func applyingFavorite(_ item: PhotoItem) -> PhotoItem {
        guard let value = favoriteValues[item.id] else { return item }
        return item.withFavorite(value)
    }

    private func applyingFavorites(_ items: [PhotoItem]) -> [PhotoItem] { items.map(applyingFavorite) }

    private func applyFavorite(itemID: Int64, value: Bool) {
        favoriteValues[itemID] = value
        for (section, page) in pages where page.items.contains(where: { $0.id == itemID }) {
            pages[section] = PageEntry(items: page.items.map { $0.id == itemID ? $0.withFavorite(value) : $0 },
                                       verified: page.verified)
        }
        if currentItem?.id == itemID {
            currentItem = currentItem?.withFavorite(value)
            favoriteFailure = nil
            publish()
        }
    }

    private static func identity(of item: PhotoItem) -> String {
        let thumbnail = item.additional?.thumbnail
        return "\(item.id)|\(item.type)|\(item.liveType ?? "")|\(thumbnail?.unitID ?? -1)|\(thumbnail?.cacheKey ?? "")"
    }

    private static func resourceKey(_ resource: FullImageResource) -> String {
        "\(resource.unitID)|\(resource.cacheKey)"
    }

    private static func thumbnailKey(_ descriptor: ThumbnailInfo, size: ThumbnailSize) -> String {
        "\(descriptor.unitID):\(descriptor.cacheKey):\(size.rawValue)"
    }
}
