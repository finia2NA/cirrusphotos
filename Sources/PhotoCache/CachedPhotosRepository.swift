import Foundation
import SynologyAPI

public enum ResourceEvent<Value: Sendable>: Sendable {
    case value(Value, verified: Bool)
    case failure(String)
}

public actor CachedPhotosRepository {
    public let store: DiskCache
    private let client: SynologyClient
    private let credentials: SynologyCredentials
    private let namespace: String
    private let runID = UUID().uuidString
    private var loginTask: Task<Void, Error>?
    private var fullTask: Task<TimelineSnapshot, Error>?
    private var pageTasks: [String: Task<[PhotoItem], Error>] = [:]
    private var imageTasks: [String: Task<Data, Error>] = [:]
    private let transfers = TransferLimiter(limit: 6)

    public init(credentials: SynologyCredentials, baseURL: URL = SynologyClient.defaultBaseURL,
                budget: Int64 = CacheBudget.bytes(at: 0.5), cacheRoot: URL? = nil) throws {
        self.credentials = credentials
        namespace = CacheKey.namespace(server: baseURL, account: credentials.username)
        client = SynologyClient(baseURL: baseURL)
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
        AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            Task {
                let key = CacheKey.timeline(namespace: namespace)
                let cached = try? await store.get(key)
                let snapshot = cached.flatMap { try? JSONDecoder().decode(TimelineSnapshot.self, from: $0.data) }
                if let snapshot { continuation.yield(.value(snapshot, verified: cached?.validatedRun == runID)) }
                if cached?.validatedRun == runID, snapshot != nil { continuation.finish(); return }
                var phase = "Signing in"
                do {
                    if snapshot == nil {
                        try await connect()
                        phase = "Initial timeline"
                        let initial = try await client.timeline(initial: true)
                        continuation.yield(.value(initial, verified: false))
                    }
                    phase = "Full timeline"
                    let current = try await currentTimeline()
                    continuation.yield(.value(current, verified: true))
                } catch {
                    continuation.yield(.failure("\(phase): \(error.localizedDescription)"))
                }
                continuation.finish()
            }
        }
    }

    public func page(_ section: TimelineSection, allowNetwork: Bool = true) -> AsyncStream<ResourceEvent<[PhotoItem]>> {
        AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            Task {
                guard let key = CacheKey.page(namespace: namespace, section: section) else {
                    continuation.yield(.failure("The section has no date bounds.")); continuation.finish(); return
                }
                let cached = try? await store.get(key)
                let items = cached.flatMap { try? JSONDecoder().decode([PhotoItem].self, from: $0.data) }
                if let items { continuation.yield(.value(items, verified: cached?.validatedRun == runID)) }
                guard allowNetwork else { continuation.finish(); return }
                if cached?.validatedRun == runID, items != nil { continuation.finish(); return }
                do {
                    let current = try await currentPage(section, key: key)
                    continuation.yield(.value(current, verified: true))
                } catch {
                    continuation.yield(.failure(error.localizedDescription))
                }
                continuation.finish()
            }
        }
    }

    /// Call with allowNetwork=false for provisional item metadata. Cached bytes can still paint immediately.
    public func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, allowNetwork: Bool)
        -> AsyncStream<ResourceEvent<Data>> {
        AsyncStream(bufferingPolicy: .bufferingNewest(3)) { continuation in
            Task {
                let key = CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: size)
                let cached = try? await store.get(key)
                if let cached { continuation.yield(.value(cached.data, verified: cached.validatedRun == runID)) }
                guard allowNetwork, cached?.validatedRun != runID else {
                    continuation.finish(); return
                }
                do {
                    let current = try await currentThumbnail(descriptor, size: size, key: key)
                    continuation.yield(.value(current, verified: true))
                } catch {
                    continuation.yield(.failure(error.localizedDescription))
                }
                continuation.finish()
            }
        }
    }

    public func setBudget(_ bytes: Int64) async throws { try await store.setBudget(bytes) }
    public func usage() async throws -> Int64 { try await store.usage() }
    public func clearCache() async throws {
        try await store.clear()
    }

    private func connect() async throws {
        if loginTask == nil {
            loginTask = Task { try await client.login(credentials: credentials) }
        }
        do { try await loginTask!.value }
        catch { loginTask = nil; throw error }
    }

    private func currentTimeline() async throws -> TimelineSnapshot {
        if let fullTask { return try await fullTask.value }
        let generation = await store.currentGeneration()
        let task = Task<TimelineSnapshot, Error> {
            try await connect()
            let snapshot = try await client.timeline(initial: false)
            let data = try JSONEncoder().encode(snapshot)
            try await store.put(CacheKey.timeline(namespace: namespace), kind: .timeline,
                                data: data, validatedRun: runID, expectedGeneration: generation)
            return snapshot
        }
        fullTask = task
        do { let result = try await task.value; fullTask = nil; return result }
        catch { fullTask = nil; throw error }
    }

    private func currentPage(_ section: TimelineSection, key: String) async throws -> [PhotoItem] {
        if let task = pageTasks[key] { return try await task.value }
        let generation = await store.currentGeneration()
        let task = Task<[PhotoItem], Error> {
            try await connect()
            let items = try await client.items(in: section)
            let data = try JSONEncoder().encode(items)
            try await store.put(key, kind: .page, data: data, validatedRun: runID,
                                expectedGeneration: generation)
            return items
        }
        pageTasks[key] = task
        do { let result = try await task.value; pageTasks[key] = nil; return result }
        catch { pageTasks[key] = nil; throw error }
    }

    private func currentThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, key: String) async throws -> Data {
        if let task = imageTasks[key] { return try await task.value }
        let generation = await store.currentGeneration()
        let task = Task<Data, Error> {
            await transfers.acquire()
            defer { Task { await transfers.release() } }
            try Task.checkCancellation()
            try await connect()
            let prior = try await store.get(key)
            var response = try await client.thumbnail(descriptor, size: size,
                                                      etag: prior?.etag, lastModified: prior?.lastModified)
            if response.notModified && prior == nil {
                response = try await client.thumbnail(descriptor, size: size)
            }
            if response.notModified, let prior {
                try await store.markValidated(key, run: runID, expectedGeneration: generation)
                return prior.data
            }
            guard let data = response.data else { throw SynologyAPIError.invalidResponse }
            try await store.put(key, kind: .thumbnail, data: data, validatedRun: runID,
                                etag: response.etag, lastModified: response.lastModified,
                                expectedGeneration: generation)
            return data
        }
        imageTasks[key] = task
        do { let result = try await task.value; imageTasks[key] = nil; return result }
        catch { imageTasks[key] = nil; throw error }
    }
}

private actor TransferLimiter {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { available = limit }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { available += 1 }
        else { waiting.removeFirst().resume() }
    }
}
