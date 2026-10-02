import Foundation
import SynologyAPI

public enum ResourceEvent<Value: Sendable>: Sendable {
    case value(Value, verified: Bool)
    case failure(String)
}

public enum AuthenticationStatus: Sendable, Equatable {
    case notStarted
    case loggingIn
    case signedIn
    case failed(String)
}

public struct FavoriteChange: Sendable {
    public let itemID: Int64
    public let section: TimelineSection
    public let favorite: Bool
}

private struct SharedJob<Value: Sendable> {
    let id: UUID
    let task: Task<Value, Error>
    var subscribers: Set<UUID>
}

private struct ImageResolution: Sendable {
    let data: Data
    let outcome: ThumbnailCacheOutcome
}

private struct FullImageResolution: Sendable {
    let data: Data
}

private struct FavoriteCacheBackup: Sendable {
    let kind: CacheKind
    let entry: CacheEntry?
}

private struct FavoriteMutationTransaction: Sendable {
    let previousFavorite: Bool
    let previousLocalSections: [Int64: TimelineSection]
    var cacheBackups: [String: FavoriteCacheBackup] = [:]
    var previousFavoritesSnapshot: TimelineSnapshot?
}

public enum ThumbnailCacheOutcome: Sendable, Equatable {
    case fetched
    case reused
    case cacheWriteFailed
}

public enum ThumbnailCachePurpose: Sendable, Equatable {
    case library
    case viewerPreview

    fileprivate var kind: CacheKind {
        switch self {
        case .library: .thumbnail
        case .viewerPreview: .previewThumbnail
        }
    }
}

private final class StreamProducer: @unchecked Sendable {
    var task: Task<Void, Never>?
}

public actor CachedPhotosRepository {
    public let store: DiskCache
    private let client: any PhotosTransport
    private let credentials: SynologyCredentials
    private let namespace: String
    private let runID = UUID().uuidString
    private let gate = NetworkGate()
    private let fullImageGate = FullImageGate()
    private var loginTask: Task<Void, Error>?
    private var loginAttempt: UUID?
    private var connected = false
    private var authenticationStatus: AuthenticationStatus = .notStarted
    private var authenticationObservers: [UUID: AsyncStream<AuthenticationStatus>.Continuation] = [:]
    private var timelineJobs: [PhotoCollectionDescriptor: SharedJob<TimelineSnapshot>] = [:]
    private var latestTimelines: [PhotoCollectionDescriptor: TimelineSnapshot] = [:]
    private var initialSubscribers: Set<UUID> = []
    private var collectionMutationEpochs: [PhotoCollectionDescriptor: UInt64] = [:]
    private var timelineRefreshObservers: [PhotoCollectionDescriptor: [UUID: AsyncStream<ResourceEvent<TimelineSnapshot>>.Continuation]] = [:]
    private var pageJobs: [String: SharedJob<[PhotoItem]>] = [:]
    private var imageJobs: [String: SharedJob<ImageResolution>] = [:]
    private var fullImageJobs: [String: SharedJob<FullImageResolution>] = [:]
    private var pendingPagePromotions: [String] = []
    private var favoriteObservers: [UUID: AsyncStream<FavoriteChange>.Continuation] = [:]
    private var favoriteOverrides: [Int64: Bool] = [:]
    private var latestFavoriteChanges: [Int64: FavoriteChange] = [:]
    private var localFavoriteSections: [Int64: TimelineSection] = [:]
    private var pendingFavoriteIDs: Set<Int64> = []
    private var favoriteWriteTail: Task<Void, Never>?

    public init(credentials: SynologyCredentials, baseURL: URL = SynologyClient.defaultBaseURL,
                budget: Int64 = CacheBudget.bytes(at: 0.5), cacheRoot: URL? = nil,
                transport: (any PhotosTransport)? = nil) throws {
        self.credentials = credentials
        namespace = CacheKey.namespace(server: baseURL, account: credentials.username)
        client = transport ?? SynologyClient(baseURL: baseURL)
        let root: URL
        if let cacheRoot {
            root = cacheRoot
        } else {
            root = CacheLocation.defaultRoot().appendingPathComponent(namespace, isDirectory: true)
            let legacyRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CirrusTimeline", isDirectory: true)
                .appendingPathComponent(namespace, isDirectory: true)
            CacheLocation.migrateDirectory(from: legacyRoot, to: root)
        }
        store = try DiskCache(root: root, budget: budget,
                              protectedTimelineKey: CacheKey.timeline(namespace: namespace))
    }

    public func timeline(collection: PhotoCollectionDescriptor = .personalLibrary) -> AsyncStream<ResourceEvent<TimelineSnapshot>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let key = CacheKey.timeline(namespace: namespace, collection: collection)
                let validation = validationRun(for: collection)
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                let snapshot = cached.flatMap { try? JSONDecoder().decode(TimelineSnapshot.self, from: $0.data) }
                if let snapshot {
                    latestTimelines[collection] = snapshot
                    continuation.yield(.value(snapshot, verified: cached?.validatedRun == validation))
                }
                if cached?.validatedRun == validation, snapshot != nil { continuation.finish(); return }
                var phase = "Initial timeline"
                do {
                    if snapshot == nil, collection.supportsInitialTimeline {
                        let initial = try await initialTimeline(id: subscriber, collection: collection)
                        guard !Task.isCancelled else { continuation.finish(); return }
                        latestTimelines[collection] = initial
                        continuation.yield(.value(initial, verified: false))
                    }
                    phase = "Full timeline"
                    let requestedValidation = validationRun(for: collection)
                    let task = registerTimeline(collection: collection, subscriber: subscriber)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    latestTimelines[collection] = current
                    continuation.yield(.value(current,
                                              verified: requestedValidation == validationRun(for: collection)))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) {
                        continuation.yield(.failure("\(phase): \(error.localizedDescription)"))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseTimeline(collection: collection, subscriber: subscriber) }
            }
        }
    }

    public func page(_ section: TimelineSection, collection: PhotoCollectionDescriptor = .personalLibrary,
                     allowNetwork: Bool = true,
                     priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<[PhotoItem]>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                guard let key = CacheKey.page(namespace: namespace, section: section, collection: collection) else {
                    continuation.yield(.failure("The section has no date bounds.")); continuation.finish(); return
                }
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                let items = cached.flatMap { try? JSONDecoder().decode([PhotoItem].self, from: $0.data) }
                    .map { applyingFavoriteOverrides($0, collection: collection) }
                let validation = validationRun(for: collection)
                if let items { continuation.yield(.value(items, verified: cached?.validatedRun == validation)) }
                guard allowNetwork && !(cached?.validatedRun == validation && items != nil) else {
                    continuation.finish(); return
                }
                do {
                    let requestedValidation = validationRun(for: collection)
                    let task = registerPage(section, collection: collection, key: key,
                                            subscriber: subscriber, priority: priority)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.value(applyingFavoriteOverrides(current, collection: collection),
                                              verified: requestedValidation == validationRun(for: collection)))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) &&
                        !(error is NetworkGateError && priority == .prefetch) {
                        continuation.yield(.failure(error.localizedDescription))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releasePage(key: CacheKey.page(namespace: self.namespace, section: section,
                                                                 collection: collection), subscriber: subscriber) }
            }
        }
    }

    /// Provisional metadata can request cached bytes with allowNetwork=false.
    public func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, allowNetwork: Bool,
                          priority: RequestPriority = .visible,
                          cachePurpose: ThumbnailCachePurpose = .library) -> AsyncStream<ResourceEvent<Data>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let key = CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: size)
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                if cached != nil, cachePurpose == .library {
                    try? await store.promotePreviewThumbnail(key)
                }
                if let cached { continuation.yield(.value(cached.data, verified: cached.validatedRun == runID)) }
                guard allowNetwork && cached?.validatedRun != runID else { continuation.finish(); return }
                do {
                    let task = registerImage(descriptor, size: size, key: key,
                                             subscriber: subscriber, priority: priority,
                                             cachePurpose: cachePurpose)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    if cachePurpose == .library {
                        try? await store.promotePreviewThumbnail(key)
                    }
                    continuation.yield(.value(current.data, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) &&
                        !(error is NetworkGateError && priority == .prefetch) {
                        continuation.yield(.failure(error.localizedDescription))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseImage(key: CacheKey.thumbnail(namespace: self.namespace, descriptor: descriptor, size: size), subscriber: subscriber) }
            }
        }
    }

    /// Returns compressed original-image bytes. Cached bytes arrive first and are then
    /// validated at most once per app run when network access is allowed.
    public func fullImage(_ resource: FullImageResource, allowNetwork: Bool = true,
                          priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<Data>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let key = CacheKey.fullImage(namespace: namespace, resource: resource)
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                if let cached { continuation.yield(.value(cached.data, verified: cached.validatedRun == runID)) }
                guard allowNetwork && cached?.validatedRun != runID else { continuation.finish(); return }
                do {
                    let task = registerFullImage(resource, key: key, subscriber: subscriber,
                                                 priority: priority)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.value(current.data, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) &&
                        !(error is NetworkGateError && priority == .prefetch) {
                        continuation.yield(.failure(error.localizedDescription))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task {
                    await self.releaseFullImage(
                        key: CacheKey.fullImage(namespace: self.namespace, resource: resource),
                        subscriber: subscriber
                    )
                }
            }
        }
    }

    public func setBudget(_ bytes: Int64) async throws { try await store.setBudget(bytes) }
    public func usage() async throws -> Int64 { try await store.usage() }
    public func clearCache() async throws { try await store.clear() }

    public func favoriteChanges() -> AsyncStream<FavoriteChange> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            favoriteObservers[id] = continuation
            for change in latestFavoriteChanges.values { continuation.yield(change) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeFavoriteObserver(id) }
            }
        }
    }

    /// Emits cached projection changes caused by local mutations. Normal startup reads
    /// use `timeline(collection:)`; this stream keeps views current without polling.
    public func timelineRefreshes(collection: PhotoCollectionDescriptor) -> AsyncStream<ResourceEvent<TimelineSnapshot>> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            timelineRefreshObservers[collection, default: [:]][id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeTimelineRefreshObserver(collection: collection, id: id) }
            }
        }
    }

    /// The independent task survives a viewer closing after the request starts. Writes
    /// are serialized so rollback can restore one exact optimistic cache transaction.
    public func setFavorite(itemID: Int64, item: PhotoItem? = nil,
                            in section: TimelineSection,
                            collection: PhotoCollectionDescriptor = .personalLibrary,
                            to favorite: Bool) async throws {
        guard pendingFavoriteIDs.insert(itemID).inserted else {
            throw SynologyAPIError.unsupported("A favorite change is already in progress.")
        }
        let previous = favoriteWriteTail
        let operation = Task<Void, Error> {
            defer { pendingFavoriteIDs.remove(itemID) }
            await previous?.value
            let generation = await store.currentGeneration()
            var transaction = FavoriteMutationTransaction(
                previousFavorite: favoriteOverrides[itemID] ?? item?.isFavorite ?? !favorite,
                previousLocalSections: localFavoriteSections
            )
            collectionMutationEpochs[.favorites, default: 0] &+= 1
            publishFavorite(itemID: itemID, section: section, favorite: favorite)
            await updateFavoriteCaches(itemID: itemID, item: item, sourceSection: section,
                                       sourceCollection: collection, favorite: favorite,
                                       generation: generation, transaction: &transaction)
            do {
                try await connect()
                try await client.setFavorite(itemIDs: [itemID], favorite: favorite)
            } catch {
                collectionMutationEpochs[.favorites, default: 0] &+= 1
                await rollbackFavoriteCaches(transaction, generation: generation)
                localFavoriteSections = transaction.previousLocalSections
                publishFavorite(itemID: itemID, section: section,
                                favorite: transaction.previousFavorite)
                throw error
            }
        }
        favoriteWriteTail = Task { _ = try? await operation.value }
        try await operation.value
    }

    private func applyingFavoriteOverrides(_ items: [PhotoItem],
                                            collection: PhotoCollectionDescriptor = .personalLibrary) -> [PhotoItem] {
        items.compactMap { item in
            guard let favorite = favoriteOverrides[item.id] else { return item }
            if collection == .favorites, !favorite { return nil }
            return item.withFavorite(favorite)
        }
    }

    private func publishFavorite(itemID: Int64, section: TimelineSection, favorite: Bool) {
        favoriteOverrides[itemID] = favorite
        let change = FavoriteChange(itemID: itemID, section: section, favorite: favorite)
        latestFavoriteChanges[itemID] = change
        for observer in favoriteObservers.values { observer.yield(change) }
    }

    private func updateFavoriteCaches(itemID: Int64, item suppliedItem: PhotoItem?,
                                      sourceSection: TimelineSection,
                                      sourceCollection: PhotoCollectionDescriptor,
                                      favorite: Bool, generation: Int,
                                      transaction: inout FavoriteMutationTransaction) async {
        let item: PhotoItem?
        if let suppliedItem {
            item = suppliedItem
        } else {
            item = await cachedItem(itemID: itemID, section: sourceSection,
                                    collection: sourceCollection)
        }
        await patchPersonalPages(itemID: itemID, item: item, sourceSection: sourceSection,
                                 sourceCollection: sourceCollection, favorite: favorite,
                                 generation: generation, transaction: &transaction)

        let timelineKey = CacheKey.timeline(namespace: namespace, collection: .favorites)
        let cachedTimeline = try? await store.get(timelineKey)
        let oldSnapshot = latestTimelines[.favorites] ?? cachedTimeline.flatMap {
            try? JSONDecoder().decode(TimelineSnapshot.self, from: $0.data)
        }
        transaction.previousFavoritesSnapshot = oldSnapshot
        await recordBackup(key: timelineKey, kind: .timeline,
                           knownEntry: cachedTimeline, transaction: &transaction)

        guard let item else { return }
        let original = oldSnapshot ?? TimelineSnapshot(sections: [])
        guard let projection = await favoriteProjection(from: original, item: item,
                                                        favorite: favorite,
                                                        generation: generation,
                                                        transaction: &transaction) else { return }
        latestTimelines[.favorites] = projection
        if let bytes = try? JSONEncoder().encode(projection) {
            try? await store.put(timelineKey, kind: .timeline, data: bytes,
                                 validatedRun: validationRun(for: .favorites),
                                 expectedGeneration: generation)
        }
        publishTimelineProjection(projection, collection: .favorites)
    }

    private func cachedItem(itemID: Int64, section: TimelineSection,
                            collection: PhotoCollectionDescriptor) async -> PhotoItem? {
        guard let key = CacheKey.page(namespace: namespace, section: section, collection: collection),
              let cached = try? await store.get(key),
              let items = try? JSONDecoder().decode([PhotoItem].self, from: cached.data) else { return nil }
        return items.first(where: { $0.id == itemID })
    }

    private func patchPersonalPages(itemID: Int64, item: PhotoItem?,
                                    sourceSection: TimelineSection,
                                    sourceCollection: PhotoCollectionDescriptor,
                                    favorite: Bool, generation: Int,
                                    transaction: inout FavoriteMutationTransaction) async {
        var candidates: [TimelineSection] = []
        if sourceCollection == .personalLibrary { candidates.append(sourceSection) }
        if let snapshot = latestTimelines[.personalLibrary] {
            if let item, let day = utcDay(for: item) {
                candidates.append(contentsOf: snapshot.sections.filter { section in
                    section.list.contains(where: { sameDay($0, day) })
                })
            } else if sourceCollection != .personalLibrary {
                candidates.append(contentsOf: snapshot.sections)
            }
        }
        var seen: Set<String> = []
        for section in candidates {
            guard let key = CacheKey.page(namespace: namespace, section: section,
                                          collection: .personalLibrary),
                  seen.insert(key).inserted,
                  let cached = try? await store.get(key),
                  let items = try? JSONDecoder().decode([PhotoItem].self, from: cached.data),
                  items.contains(where: { $0.id == itemID }) else { continue }
            await recordBackup(key: key, kind: .page, knownEntry: cached, transaction: &transaction)
            guard let bytes = try? JSONEncoder().encode(items.map {
                $0.id == itemID ? $0.withFavorite(favorite) : $0
            }) else { continue }
            try? await store.put(key, kind: .page, data: bytes,
                                 validatedRun: cached.validatedRun,
                                 etag: cached.etag, lastModified: cached.lastModified,
                                 expectedGeneration: generation)
        }
    }

    private func favoriteProjection(from snapshot: TimelineSnapshot, item: PhotoItem,
                                    favorite: Bool, generation: Int,
                                    transaction: inout FavoriteMutationTransaction) async -> TimelineSnapshot? {
        guard let day = utcDay(for: item) else { return nil }
        var sections = snapshot.sections
        let dayIndices = sections.indices.filter { index in
            sections[index].list.contains(where: { sameDay($0, day) })
        }

        if favorite {
            let oldCount = dayIndices.compactMap { index in
                sections[index].list.first(where: { sameDay($0, day) })?.itemCount
            }.max().map { max(0, $0) } ?? 0
            let localSection = TimelineSection(offset: oldCount, limit: 1,
                list: [TimelineDay(year: day.year, month: day.month, day: day.day,
                                   itemCount: oldCount + 1)])
            let insertion = dayIndices.last.map { $0 + 1 } ?? sections.firstIndex { section in
                guard let first = section.list.first else { return false }
                return dayID(first) < dayID(day)
            } ?? sections.endIndex
            sections.insert(localSection, at: insertion)
            localFavoriteSections[item.id] = localSection
            if let key = CacheKey.page(namespace: namespace, section: localSection, collection: .favorites) {
                await recordBackup(key: key, kind: .page, transaction: &transaction)
                if let bytes = try? JSONEncoder().encode([item.withFavorite(true)]) {
                    try? await store.put(key, kind: .page, data: bytes,
                                         validatedRun: validationRun(for: .favorites),
                                         expectedGeneration: generation)
                }
            }
            return TimelineSnapshot(sections: sections)
        }

        if let localSection = localFavoriteSections[item.id],
           let localIndex = sections.firstIndex(of: localSection) {
            if let key = CacheKey.page(namespace: namespace, section: localSection, collection: .favorites) {
                await recordBackup(key: key, kind: .page, transaction: &transaction)
                try? await store.remove(key, expectedGeneration: generation)
            }
            let shiftedSections = localFavoriteSections.compactMap { otherID, otherSection in
                otherID != item.id && otherSection.offset > localSection.offset &&
                    otherSection.list.contains(where: { sameDay($0, day) })
                    ? (otherID, otherSection) : nil
            }
            for (otherID, otherSection) in shiftedSections {
                guard let index = sections.firstIndex(of: otherSection) else { continue }
                let adjusted = TimelineSection(offset: otherSection.offset - 1,
                    limit: otherSection.limit,
                    list: otherSection.list.map { value in
                        sameDay(value, day) ? TimelineDay(year: value.year, month: value.month,
                                                          day: value.day,
                                                          itemCount: max(0, value.itemCount - 1)) : value
                    })
                let oldKey = CacheKey.page(namespace: namespace, section: otherSection,
                                           collection: .favorites)
                let newKey = CacheKey.page(namespace: namespace, section: adjusted,
                                           collection: .favorites)
                let cached: CacheEntry?
                if let oldKey {
                    cached = try? await store.get(oldKey)
                } else {
                    cached = nil
                }
                if let oldKey {
                    await recordBackup(key: oldKey, kind: .page, knownEntry: cached,
                                       transaction: &transaction)
                }
                if let newKey {
                    await recordBackup(key: newKey, kind: .page, transaction: &transaction)
                    if let cached {
                        try? await store.put(newKey, kind: .page, data: cached.data,
                                             validatedRun: validationRun(for: .favorites),
                                             etag: cached.etag, lastModified: cached.lastModified,
                                             expectedGeneration: generation)
                    }
                }
                if let oldKey, oldKey != newKey {
                    try? await store.remove(oldKey, expectedGeneration: generation)
                }
                sections[index] = adjusted
                localFavoriteSections[otherID] = adjusted
            }
            sections.remove(at: localIndex)
            localFavoriteSections.removeValue(forKey: item.id)
            return TimelineSnapshot(sections: sections)
        }

        guard !dayIndices.isEmpty else { return snapshot }
        var cachedPages: [Int: CacheEntry] = [:]
        var target = dayIndices.last!
        for index in dayIndices {
            guard let key = CacheKey.page(namespace: namespace, section: sections[index], collection: .favorites),
                  let cached = try? await store.get(key),
                  let items = try? JSONDecoder().decode([PhotoItem].self, from: cached.data) else { continue }
            cachedPages[index] = cached
            if items.contains(where: { $0.id == item.id }) { target = index }
        }

        let oldSections = sections
        let targetSection = oldSections[target]
        for index in dayIndices {
            let section = oldSections[index]
            let adjustedOffset = index != target && section.offset >= targetSection.offset + targetSection.limit
                ? max(0, section.offset - 1) : section.offset
            let adjustedLimit = index == target ? max(0, section.limit - 1) : section.limit
            let adjustedList = section.list.compactMap { value -> TimelineDay? in
                guard sameDay(value, day) else { return value }
                let count = max(0, value.itemCount - 1)
                return count == 0 ? nil : TimelineDay(year: value.year, month: value.month,
                                                       day: value.day, itemCount: count)
            }
            sections[index] = TimelineSection(offset: adjustedOffset, limit: adjustedLimit,
                                               list: adjustedList)
        }

        var removals = Set<Int>()
        for index in dayIndices where sections[index].limit == 0 || sections[index].list.isEmpty {
            removals.insert(index)
        }
        let survivingKeys = Set(sections.indices.compactMap { index -> String? in
            guard !removals.contains(index) else { return nil }
            return CacheKey.page(namespace: namespace, section: sections[index], collection: .favorites)
        })
        for index in dayIndices {
            let oldSection = oldSections[index]
            guard let oldKey = CacheKey.page(namespace: namespace, section: oldSection, collection: .favorites) else {
                continue
            }
            let cached: CacheEntry?
            if let known = cachedPages[index] {
                cached = known
            } else {
                cached = try? await store.get(oldKey)
            }
            await recordBackup(key: oldKey, kind: .page, knownEntry: cached, transaction: &transaction)
            if !removals.contains(index),
               let newKey = CacheKey.page(namespace: namespace, section: sections[index], collection: .favorites),
               let cached,
               let items = try? JSONDecoder().decode([PhotoItem].self, from: cached.data) {
                await recordBackup(key: newKey, kind: .page, transaction: &transaction)
                let updated = items.filter { $0.id != item.id }.map { $0.withFavorite(true) }
                if let bytes = try? JSONEncoder().encode(updated) {
                    try? await store.put(newKey, kind: .page, data: bytes,
                                         validatedRun: validationRun(for: .favorites),
                                         etag: cached.etag, lastModified: cached.lastModified,
                                         expectedGeneration: generation)
                }
            }
            if !survivingKeys.contains(oldKey) {
                try? await store.remove(oldKey, expectedGeneration: generation)
            }
        }
        for index in removals.sorted(by: >) { sections.remove(at: index) }
        localFavoriteSections.removeValue(forKey: item.id)
        return TimelineSnapshot(sections: sections)
    }

    private func recordBackup(key: String, kind: CacheKind, knownEntry: CacheEntry? = nil,
                              transaction: inout FavoriteMutationTransaction) async {
        guard transaction.cacheBackups[key] == nil else { return }
        let entry: CacheEntry?
        if let knownEntry {
            entry = knownEntry
        } else {
            entry = try? await store.get(key)
        }
        transaction.cacheBackups[key] = FavoriteCacheBackup(kind: kind, entry: entry)
    }

    private func rollbackFavoriteCaches(_ transaction: FavoriteMutationTransaction,
                                        generation: Int) async {
        guard await store.currentGeneration() == generation else { return }
        for (key, backup) in transaction.cacheBackups {
            if let entry = backup.entry {
                try? await store.put(key, kind: backup.kind, data: entry.data,
                                     validatedRun: entry.validatedRun,
                                     etag: entry.etag, lastModified: entry.lastModified,
                                     expectedGeneration: generation)
            } else {
                try? await store.remove(key, expectedGeneration: generation)
            }
        }
        if let snapshot = transaction.previousFavoritesSnapshot {
            latestTimelines[.favorites] = snapshot
            let timelineKey = CacheKey.timeline(namespace: namespace, collection: .favorites)
            let verified = transaction.cacheBackups[timelineKey]?.entry?.validatedRun == validationRun(for: .favorites)
            publishTimelineProjection(snapshot, collection: .favorites, verified: verified)
        } else {
            latestTimelines.removeValue(forKey: .favorites)
        }
    }

    private func publishTimelineProjection(_ snapshot: TimelineSnapshot,
                                           collection: PhotoCollectionDescriptor,
                                           verified: Bool = true) {
        for observer in timelineRefreshObservers[collection]?.values ?? [:].values {
            observer.yield(.value(snapshot, verified: verified))
        }
    }

    private func utcDay(for item: PhotoItem) -> TimelineDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day],
                                                  from: Date(timeIntervalSince1970: TimeInterval(item.time)))
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return TimelineDay(year: year, month: month, day: day, itemCount: 0)
    }

    private func sameDay(_ lhs: TimelineDay, _ rhs: TimelineDay) -> Bool {
        lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day
    }

    private func dayID(_ day: TimelineDay) -> String {
        String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    private func removeFavoriteObserver(_ id: UUID) { favoriteObservers.removeValue(forKey: id) }

    /// Resolves one thumbnail through the normal shared cache pipeline without retaining bytes.
    /// Bulk callers must use `.prefetch` so visible browsing can move ahead in the gate.
    public func cacheThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                               priority: RequestPriority = .prefetch) async throws -> ThumbnailCacheOutcome {
        try Task.checkCancellation()
        let key = CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: size)
        if let cached = try? await store.get(key), cached.validatedRun == runID {
            try? await store.promotePreviewThumbnail(key)
            return .reused
        }
        try Task.checkCancellation()
        let subscriber = UUID()
        let task = registerImage(descriptor, size: size, key: key,
                                 subscriber: subscriber, priority: priority,
                                 cachePurpose: .library)
        return try await withTaskCancellationHandler {
            do {
                let resolution = try await task.value
                try Task.checkCancellation()
                try? await store.promotePreviewThumbnail(key)
                releaseImage(key: key, subscriber: subscriber)
                return resolution.outcome
            } catch {
                releaseImage(key: key, subscriber: subscriber)
                throw error
            }
        } onCancel: {
            Task { await self.releaseImage(key: key, subscriber: subscriber) }
        }
    }

    /// Each observer receives the latest status immediately, including a previous failure.
    public func authentication() -> AsyncStream<AuthenticationStatus> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            authenticationObservers[id] = continuation
            continuation.yield(authenticationStatus)
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeAuthenticationObserver(id) }
            }
        }
    }

    /// A failed sign-in is sticky until the user explicitly retries it.
    public func retryAuthentication() {
        guard case .failed = authenticationStatus else { return }
        loginTask = nil
        loginAttempt = nil
        setAuthenticationStatus(.notStarted)
    }

    private func removeAuthenticationObserver(_ id: UUID) {
        authenticationObservers.removeValue(forKey: id)
    }

    private func setAuthenticationStatus(_ status: AuthenticationStatus) {
        guard authenticationStatus != status else { return }
        authenticationStatus = status
        for observer in authenticationObservers.values { observer.yield(status) }
    }

    public func promotePage(_ section: TimelineSection,
                            collection: PhotoCollectionDescriptor = .personalLibrary) async {
        guard let key = CacheKey.page(namespace: namespace, section: section, collection: collection) else { return }
        if let job = pageJobs[key] {
            await gate.promote(job.id)
        } else if !pendingPagePromotions.contains(key) {
            pendingPagePromotions.append(key)
            if pendingPagePromotions.count > 64 { pendingPagePromotions.removeFirst() }
        }
    }

    public func promoteFullImage(_ resource: FullImageResource) async {
        let key = CacheKey.fullImage(namespace: namespace, resource: resource)
        if let job = fullImageJobs[key] { await fullImageGate.promote(job.id) }
    }

    private func connect() async throws {
        try Task.checkCancellation()
        if connected { return }
        if case .failed(let message) = authenticationStatus {
            throw AuthenticationAttemptError.previousFailure(message)
        }
        if loginTask == nil {
            setAuthenticationStatus(.loggingIn)
            loginAttempt = UUID()
            loginTask = Task { try await client.login(credentials: credentials) }
        }
        guard let loginTask, let attempt = loginAttempt else { throw CancellationError() }
        do {
            try await loginTask.value
            try Task.checkCancellation()
            guard loginAttempt == attempt else { throw CancellationError() }
            connected = true
            setAuthenticationStatus(.signedIn)
        } catch {
            if !Task.isCancelled && !(error is CancellationError) && loginAttempt == attempt && !connected {
                self.loginTask = nil
                loginAttempt = nil
                setAuthenticationStatus(.failed(error.localizedDescription))
            }
            throw error
        }
    }

    private func initialTimeline(id: UUID, collection: PhotoCollectionDescriptor) async throws -> TimelineSnapshot {
        initialSubscribers.insert(id)
        defer { initialSubscribers.remove(id); cancelIdleLogin() }
        try await gate.acquire(.metadata, priority: .visible, id: id)
        defer { Task { await gate.release(.metadata) } }
        try Task.checkCancellation()
        try await connect()
        return try await client.timeline(collection: collection, initial: true)
    }

    private func registerTimeline(collection: PhotoCollectionDescriptor,
                                  subscriber: UUID) -> Task<TimelineSnapshot, Error> {
        if var job = timelineJobs[collection] {
            job.subscribers.insert(subscriber)
            timelineJobs[collection] = job
            return job.task
        }
        let id = UUID()
        let validation = validationRun(for: collection)
        let mutationEpoch = collectionMutationEpochs[collection, default: 0]
        let task = Task<TimelineSnapshot, Error> {
            let generation = await store.currentGeneration()
            try await gate.acquire(.metadata, priority: .visible, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            let snapshot = try await client.timeline(collection: collection, initial: false)
            try Task.checkCancellation()
            guard validation == validationRun(for: collection),
                  mutationEpoch == collectionMutationEpochs[collection, default: 0] else {
                throw CancellationError()
            }
            if let bytes = try? JSONEncoder().encode(snapshot) {
                try? await store.put(CacheKey.timeline(namespace: namespace, collection: collection), kind: .timeline,
                                     data: bytes, validatedRun: validation,
                                     expectedGeneration: generation)
            }
            return snapshot
        }
        timelineJobs[collection] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func registerPage(_ section: TimelineSection, collection: PhotoCollectionDescriptor,
                              key: String, subscriber: UUID,
                              priority: RequestPriority) -> Task<[PhotoItem], Error> {
        let promoted = pendingPagePromotions.contains(key)
        pendingPagePromotions.removeAll(where: { $0 == key })
        let effectivePriority: RequestPriority = promoted ? .visible : priority
        if var job = pageJobs[key] {
            job.subscribers.insert(subscriber)
            pageJobs[key] = job
            if effectivePriority == .visible { Task { await gate.promote(job.id) } }
            return job.task
        }
        let id = UUID()
        let validation = validationRun(for: collection)
        let mutationEpoch = collectionMutationEpochs[collection, default: 0]
        let task = Task<[PhotoItem], Error> {
            let generation = await store.currentGeneration()
            try await gate.acquire(.metadata, priority: effectivePriority, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            let items = try await client.items(in: section, collection: collection)
            try Task.checkCancellation()
            guard validation == validationRun(for: collection),
                  mutationEpoch == collectionMutationEpochs[collection, default: 0] else {
                throw CancellationError()
            }
            let current = applyingFavoriteOverrides(items, collection: collection)
            if let bytes = try? JSONEncoder().encode(current) {
                try? await store.put(key, kind: .page, data: bytes,
                                     validatedRun: validation,
                                     expectedGeneration: generation)
            }
            return applyingFavoriteOverrides(current, collection: collection)
        }
        pageJobs[key] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func registerImage(_ descriptor: ThumbnailInfo, size: ThumbnailSize, key: String,
                               subscriber: UUID, priority: RequestPriority,
                               cachePurpose: ThumbnailCachePurpose) -> Task<ImageResolution, Error> {
        if var job = imageJobs[key] {
            job.subscribers.insert(subscriber)
            imageJobs[key] = job
            if priority == .visible { Task { await gate.promote(job.id) } }
            return job.task
        }
        let id = UUID()
        let task = Task<ImageResolution, Error> {
            let generation = await store.currentGeneration()
            try await gate.acquire(.thumbnail, priority: priority, id: id)
            defer { Task { await gate.release(.thumbnail) } }
            try Task.checkCancellation()
            try await connect()
            let prior = try? await store.get(key)
            var response = try await client.thumbnail(descriptor, size: size,
                                                      etag: prior?.etag, lastModified: prior?.lastModified)
            if response.notModified && prior == nil {
                response = try await client.thumbnail(descriptor, size: size, etag: nil, lastModified: nil)
            }
            try Task.checkCancellation()
            if response.notModified, let prior {
                do {
                    try await store.markValidated(key, run: runID, expectedGeneration: generation)
                    return ImageResolution(data: prior.data, outcome: .reused)
                } catch {
                    return ImageResolution(data: prior.data, outcome: .cacheWriteFailed)
                }
            }
            guard let data = response.data else { throw SynologyAPIError.invalidResponse }
            do {
                try await store.put(key, kind: cachePurpose.kind, data: data, validatedRun: runID,
                                    etag: response.etag, lastModified: response.lastModified,
                                    expectedGeneration: generation)
                return ImageResolution(data: data, outcome: .fetched)
            } catch {
                return ImageResolution(data: data, outcome: .cacheWriteFailed)
            }
        }
        imageJobs[key] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func registerFullImage(_ resource: FullImageResource, key: String, subscriber: UUID,
                                   priority: RequestPriority) -> Task<FullImageResolution, Error> {
        if var job = fullImageJobs[key] {
            job.subscribers.insert(subscriber)
            fullImageJobs[key] = job
            if priority == .visible { Task { await fullImageGate.promote(job.id) } }
            return job.task
        }
        let id = UUID()
        let task = Task<FullImageResolution, Error> {
            let generation = await store.currentGeneration()
            try await fullImageGate.acquire(priority: priority, id: id)
            do {
                try Task.checkCancellation()
                try await connect()
                let prior = try? await store.get(key)
                var response = try await client.fullImage(resource, etag: prior?.etag,
                                                          lastModified: prior?.lastModified)
                if response.notModified && prior == nil {
                    response = try await client.fullImage(resource, etag: nil, lastModified: nil)
                }
                try Task.checkCancellation()
                let result: FullImageResolution
                if response.notModified, let prior {
                    try? await store.markValidated(key, run: runID, expectedGeneration: generation)
                    result = FullImageResolution(data: prior.data)
                } else {
                    guard let data = response.data else { throw SynologyAPIError.invalidResponse }
                    try? await store.put(key, kind: .fullImage, data: data, validatedRun: runID,
                                         etag: response.etag, lastModified: response.lastModified,
                                         expectedGeneration: generation)
                    result = FullImageResolution(data: data)
                }
                await fullImageGate.release(id)
                return result
            } catch {
                await fullImageGate.release(id)
                throw error
            }
        }
        fullImageJobs[key] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func releaseTimeline(collection: PhotoCollectionDescriptor, subscriber: UUID) {
        initialSubscribers.remove(subscriber)
        guard var job = timelineJobs[collection] else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); timelineJobs.removeValue(forKey: collection); cancelIdleLogin() }
        else { timelineJobs[collection] = job }
    }
    private func releasePage(key: String?, subscriber: UUID) {
        guard let key, var job = pageJobs[key] else { return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); pageJobs.removeValue(forKey: key); cancelIdleLogin() }
        else { pageJobs[key] = job }
    }
    private func releaseImage(key: String, subscriber: UUID) {
        guard var job = imageJobs[key] else { return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); imageJobs.removeValue(forKey: key); cancelIdleLogin() }
        else { imageJobs[key] = job }
    }
    private func releaseFullImage(key: String, subscriber: UUID) {
        guard var job = fullImageJobs[key] else { return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty {
            job.task.cancel()
            fullImageJobs.removeValue(forKey: key)
            Task { await fullImageGate.release(job.id) }
            cancelIdleLogin()
        } else {
            fullImageJobs[key] = job
        }
    }
    private func cancelIdleLogin() {
        if !connected && initialSubscribers.isEmpty && timelineJobs.isEmpty &&
            pageJobs.isEmpty && imageJobs.isEmpty && fullImageJobs.isEmpty {
            loginTask?.cancel()
            loginTask = nil
            loginAttempt = nil
            if case .loggingIn = authenticationStatus { setAuthenticationStatus(.notStarted) }
        }
    }

    private func validationRun(for collection: PhotoCollectionDescriptor) -> String {
        "\(runID):\(collection.rawValue)"
    }

    private func removeTimelineRefreshObserver(collection: PhotoCollectionDescriptor, id: UUID) {
        timelineRefreshObservers[collection]?.removeValue(forKey: id)
    }

}

private enum AuthenticationAttemptError: LocalizedError {
    case previousFailure(String)
    var errorDescription: String? {
        if case .previousFailure(let message) = self { return message }
        return nil
    }
}
