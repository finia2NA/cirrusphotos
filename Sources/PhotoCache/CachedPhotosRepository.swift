import Foundation
import SynologyAPI

public enum ResourceEvent<Value: Sendable>: Sendable {
    case value(Value, verified: Bool)
    case failure(String)
}

private struct SharedJob<Value: Sendable> {
    let id: UUID
    let task: Task<Value, Error>
    var subscribers: Set<UUID>
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
    private var loginTask: Task<Void, Error>?
    private var connected = false
    private var timelineJob: SharedJob<TimelineSnapshot>?
    private var initialSubscribers: Set<UUID> = []
    private var pageJobs: [String: SharedJob<[PhotoItem]>] = [:]
    private var imageJobs: [String: SharedJob<Data>] = [:]
    private var pendingPagePromotions: [String] = []

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

    public func timeline() -> AsyncStream<ResourceEvent<TimelineSnapshot>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let key = CacheKey.timeline(namespace: namespace)
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                let snapshot = cached.flatMap { try? JSONDecoder().decode(TimelineSnapshot.self, from: $0.data) }
                if let snapshot { continuation.yield(.value(snapshot, verified: cached?.validatedRun == runID)) }
                if cached?.validatedRun == runID, snapshot != nil { continuation.finish(); return }
                var phase = "Signing in"
                do {
                    if snapshot == nil {
                        let initial = try await initialTimeline(id: subscriber)
                        guard !Task.isCancelled else { continuation.finish(); return }
                        continuation.yield(.value(initial, verified: false))
                    }
                    phase = "Full timeline"
                    let task = registerTimeline(subscriber)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.value(current, verified: true))
                } catch {
                    if !Task.isCancelled && !(error is CancellationError) {
                        continuation.yield(.failure("\(phase): \(error.localizedDescription)"))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.releaseTimeline(subscriber) }
            }
        }
    }

    public func page(_ section: TimelineSection, allowNetwork: Bool = true,
                     priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<[PhotoItem]>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                guard let key = CacheKey.page(namespace: namespace, section: section) else {
                    continuation.yield(.failure("The section has no date bounds.")); continuation.finish(); return
                }
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                let items = cached.flatMap { try? JSONDecoder().decode([PhotoItem].self, from: $0.data) }
                if let items { continuation.yield(.value(items, verified: cached?.validatedRun == runID)) }
                guard allowNetwork && !(cached?.validatedRun == runID && items != nil) else {
                    continuation.finish(); return
                }
                do {
                    let task = registerPage(section, key: key, subscriber: subscriber, priority: priority)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.value(current, verified: true))
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
                Task { await self.releasePage(key: CacheKey.page(namespace: self.namespace, section: section), subscriber: subscriber) }
            }
        }
    }

    /// Provisional metadata can request cached bytes with allowNetwork=false.
    public func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, allowNetwork: Bool,
                          priority: RequestPriority = .visible) -> AsyncStream<ResourceEvent<Data>> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            producer.task = Task {
                let key = CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: size)
                let cached = try? await store.get(key)
                guard !Task.isCancelled else { continuation.finish(); return }
                if let cached { continuation.yield(.value(cached.data, verified: cached.validatedRun == runID)) }
                guard allowNetwork && cached?.validatedRun != runID else { continuation.finish(); return }
                do {
                    let task = registerImage(descriptor, size: size, key: key,
                                             subscriber: subscriber, priority: priority)
                    let current = try await task.value
                    guard !Task.isCancelled else { continuation.finish(); return }
                    continuation.yield(.value(current, verified: true))
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

    public func setBudget(_ bytes: Int64) async throws { try await store.setBudget(bytes) }
    public func usage() async throws -> Int64 { try await store.usage() }
    public func clearCache() async throws { try await store.clear() }

    public func promotePage(_ section: TimelineSection) async {
        guard let key = CacheKey.page(namespace: namespace, section: section) else { return }
        if let job = pageJobs[key] {
            await gate.promote(job.id)
        } else if !pendingPagePromotions.contains(key) {
            pendingPagePromotions.append(key)
            if pendingPagePromotions.count > 64 { pendingPagePromotions.removeFirst() }
        }
    }

    private func connect() async throws {
        if loginTask == nil { loginTask = Task { try await client.login(credentials: credentials) } }
        do {
            try await loginTask!.value
            try Task.checkCancellation()
            connected = true
        } catch {
            if !(error is CancellationError) { loginTask = nil }
            throw error
        }
    }

    private func initialTimeline(id: UUID) async throws -> TimelineSnapshot {
        initialSubscribers.insert(id)
        defer { initialSubscribers.remove(id); cancelIdleLogin() }
        try await gate.acquire(.metadata, priority: .visible, id: id)
        defer { Task { await gate.release(.metadata) } }
        try Task.checkCancellation()
        try await connect()
        return try await client.timeline(initial: true)
    }

    private func registerTimeline(_ subscriber: UUID) -> Task<TimelineSnapshot, Error> {
        if var job = timelineJob {
            job.subscribers.insert(subscriber)
            timelineJob = job
            return job.task
        }
        let id = UUID()
        let task = Task<TimelineSnapshot, Error> {
            let generation = await store.currentGeneration()
            try await gate.acquire(.metadata, priority: .visible, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            let snapshot = try await client.timeline(initial: false)
            try Task.checkCancellation()
            if let bytes = try? JSONEncoder().encode(snapshot) {
                try? await store.put(CacheKey.timeline(namespace: namespace), kind: .timeline,
                                     data: bytes, validatedRun: runID, expectedGeneration: generation)
            }
            return snapshot
        }
        timelineJob = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func registerPage(_ section: TimelineSection, key: String, subscriber: UUID,
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
        let task = Task<[PhotoItem], Error> {
            let generation = await store.currentGeneration()
            try await gate.acquire(.metadata, priority: effectivePriority, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            let items = try await client.items(in: section)
            try Task.checkCancellation()
            if let bytes = try? JSONEncoder().encode(items) {
                try? await store.put(key, kind: .page, data: bytes, validatedRun: runID,
                                     expectedGeneration: generation)
            }
            return items
        }
        pageJobs[key] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func registerImage(_ descriptor: ThumbnailInfo, size: ThumbnailSize, key: String,
                               subscriber: UUID, priority: RequestPriority) -> Task<Data, Error> {
        if var job = imageJobs[key] {
            job.subscribers.insert(subscriber)
            imageJobs[key] = job
            if priority == .visible { Task { await gate.promote(job.id) } }
            return job.task
        }
        let id = UUID()
        let task = Task<Data, Error> {
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
                try? await store.markValidated(key, run: runID, expectedGeneration: generation)
                return prior.data
            }
            guard let data = response.data else { throw SynologyAPIError.invalidResponse }
            try? await store.put(key, kind: .thumbnail, data: data, validatedRun: runID,
                                 etag: response.etag, lastModified: response.lastModified,
                                 expectedGeneration: generation)
            return data
        }
        imageJobs[key] = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func releaseTimeline(_ subscriber: UUID) {
        initialSubscribers.remove(subscriber)
        guard var job = timelineJob else { cancelIdleLogin(); return }
        job.subscribers.remove(subscriber)
        if job.subscribers.isEmpty { job.task.cancel(); timelineJob = nil; cancelIdleLogin() }
        else { timelineJob = job }
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
    private func cancelIdleLogin() {
        if !connected && initialSubscribers.isEmpty && timelineJob == nil &&
            pageJobs.isEmpty && imageJobs.isEmpty {
            loginTask?.cancel()
            loginTask = nil
        }
    }
}
