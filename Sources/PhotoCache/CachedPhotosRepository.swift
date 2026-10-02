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

public enum ThumbnailCacheOutcome: Sendable, Equatable {
    case fetched
    case reused
    case cacheWriteFailed
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
    private var timelineJob: SharedJob<TimelineSnapshot>?
    private var initialSubscribers: Set<UUID> = []
    private var pageJobs: [String: SharedJob<[PhotoItem]>] = [:]
    private var imageJobs: [String: SharedJob<ImageResolution>] = [:]
    private var fullImageJobs: [String: SharedJob<FullImageResolution>] = [:]
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
                var phase = "Initial timeline"
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

    /// Resolves one thumbnail through the normal shared cache pipeline without retaining bytes.
    /// Bulk callers must use `.prefetch` so visible browsing can move ahead in the gate.
    public func cacheThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                               priority: RequestPriority = .prefetch) async throws -> ThumbnailCacheOutcome {
        try Task.checkCancellation()
        let key = CacheKey.thumbnail(namespace: namespace, descriptor: descriptor, size: size)
        if let cached = try? await store.get(key), cached.validatedRun == runID { return .reused }
        try Task.checkCancellation()
        let subscriber = UUID()
        let task = registerImage(descriptor, size: size, key: key,
                                 subscriber: subscriber, priority: priority)
        return try await withTaskCancellationHandler {
            do {
                let resolution = try await task.value
                try Task.checkCancellation()
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

    public func promotePage(_ section: TimelineSection) async {
        guard let key = CacheKey.page(namespace: namespace, section: section) else { return }
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
                               subscriber: UUID, priority: RequestPriority) -> Task<ImageResolution, Error> {
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
                try await store.put(key, kind: .thumbnail, data: data, validatedRun: runID,
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
        if !connected && initialSubscribers.isEmpty && timelineJob == nil &&
            pageJobs.isEmpty && imageJobs.isEmpty && fullImageJobs.isEmpty {
            loginTask?.cancel()
            loginTask = nil
            loginAttempt = nil
            if case .loggingIn = authenticationStatus { setAuthenticationStatus(.notStarted) }
        }
    }
}

private enum AuthenticationAttemptError: LocalizedError {
    case previousFailure(String)
    var errorDescription: String? {
        if case .previousFailure(let message) = self { return message }
        return nil
    }
}
