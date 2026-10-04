import Foundation
import SynologyAPI

public struct LibraryPage: Sendable {
    public let sectionIndex: Int
    public let items: [PhotoItem]
    public let verified: Bool
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
    private var pages: [Int: LibraryPage] = [:]
    private var requests: [Int: Request] = [:]
    private var completed: [Int: Completion] = [:]
    private var failedSections: Set<Int> = []
    private var retryRevision = 0
    private var observers: [UUID: AsyncStream<LibraryPageEvent>.Continuation] = [:]
    private var favoriteTask: Task<Void, Never>?
    private var favoriteValues: [Int64: Bool] = [:]

    public init(repository: CachedPhotosRepository,
                collection: PhotoCollectionDescriptor = .personalLibrary,
                maximumPages: Int = 8) {
        self.repository = repository
        self.collection = collection
        self.maximumPages = max(1, maximumPages)
    }

    public func events() -> AsyncStream<LibraryPageEvent> {
        observeFavoritesIfNeeded()
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
        if self.retryRevision != retryRevision {
            self.retryRevision = retryRevision
            for section in failedSections {
                completed.removeValue(forKey: section)
                requests.removeValue(forKey: section)?.task.cancel()
            }
            failedSections.removeAll()
        }
        if fingerprint != index.fingerprint {
            for request in requests.values { request.task.cancel() }
            requests.removeAll()
            completed.removeAll()
            failedSections.removeAll()
            for section in pages.keys { publish(.removed(sectionIndex: section)) }
            pages.removeAll()
            fingerprint = index.fingerprint
        }
        var desired: [Int] = []
        var visibleSet: Set<Int> = []
        for section in visible where index.sections.indices.contains(section) {
            if visibleSet.insert(section).inserted { desired.append(section) }
            if desired.count == maximumPages { break }
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

    public func cancelAll() {
        for request in requests.values { request.task.cancel() }
        requests.removeAll()
        completed.removeAll()
        failedSections.removeAll()
        for section in pages.keys { publish(.removed(sectionIndex: section)) }
        pages.removeAll()
        favoriteTask?.cancel()
        favoriteTask = nil
    }

    private func receive(_ event: ResourceEvent<[PhotoItem]>, section: Int,
                         fingerprint identity: String, id: UUID) {
        guard fingerprint == identity, requests[section]?.id == id else { return }
        switch event {
        case .value(let items, let verified):
            failedSections.remove(section)
            let page = LibraryPage(sectionIndex: section,
                                   items: items.map { item in
                                       guard let value = favoriteValues[item.id] else { return item }
                                       return item.withFavorite(value)
                                   }, verified: verified)
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
        favoriteTask = Task { [weak self] in
            for await change in await repository.favoriteChanges() {
                guard !Task.isCancelled else { return }
                await self?.receiveFavorite(change)
            }
        }
    }

    private func receiveFavorite(_ change: FavoriteChange) {
        favoriteValues[change.itemID] = change.favorite
        guard let fingerprint else { return }
        for (section, page) in pages where page.items.contains(where: { $0.id == change.itemID }) {
            let items: [PhotoItem]
            items = page.items.map { $0.id == change.itemID ? $0.withFavorite(change.favorite) : $0 }
            let updated = LibraryPage(sectionIndex: section,
                                      items: items, verified: page.verified)
            pages[section] = updated
            publish(.page(updated, fingerprint: fingerprint))
        }
    }
    private func publish(_ event: LibraryPageEvent) {
        for observer in observers.values { observer.yield(event) }
    }
}
