import Foundation
import SynologyAPI
import TimelineCore

/// One geotagged library item retained for the map surface.
public struct PhotoLocationRecord: Codable, Sendable, Equatable {
    public let id: Int64
    public let time: Int64
    public let coordinate: PhotoCoordinate
    public let thumbnail: ThumbnailInfo?

    public init(id: Int64, time: Int64, coordinate: PhotoCoordinate, thumbnail: ThumbnailInfo?) {
        self.id = id
        self.time = time
        self.coordinate = coordinate
        self.thumbnail = thumbnail
    }
}

/// Opaque dependency identity for a published location record set. Consumers may
/// only return it when registering a derived Map collection.
public struct LocationIndexRevision: Sendable, Equatable, Hashable {
    let rawValue: UInt64

    init(_ rawValue: UInt64) { self.rawValue = rawValue }
}

public struct LocationIndexValue: Sendable, Equatable {
    public let records: [PhotoLocationRecord]
    public let revision: LocationIndexRevision
}

/// Progress and results of the shared whole-library location scan.
public enum LocationIndexEvent: Sendable {
    case cached(LocationIndexValue)
    case progress(scanned: Int, total: Int?)
    case completed(LocationIndexValue, verified: Bool)
    case failure(String)
}

/// The single persisted location-index payload.
struct LocationIndexPayload: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var sourceTimelineFingerprint: String
    var scannedItemCount: Int
    var records: [PhotoLocationRecord]
}

extension CachedPhotosRepository {
    static let locationScanPageLimit = 1000
    static let locationScanPageCap = 2048

    /// Cached-first, shared, cancellable-on-clear location index stream.
    ///
    /// Emits the cached payload immediately when present, then either verifies it
    /// against the currently loaded personal-timeline fingerprint (skipping the
    /// network entirely) or joins the single shared background scan. The scan keeps
    /// running after its last subscriber leaves so the next open is fast; it is
    /// abandoned when the cache generation changes.
    public func locationIndex() -> AsyncStream<LocationIndexEvent> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            producer.task = Task {
                metadata.locationIndexObservers[subscriber] = continuation
                let key = CacheKey.locationIndex(namespace: namespace)
                let cached = try? await readCachedMetadata(LocationIndexPayload.self, key: key)
                let cachedPayload = cached?.value.schemaVersion == LocationIndexPayload.currentSchemaVersion
                    ? cached?.value : nil
                if let cachedPayload {
                    continuation.yield(.cached(acceptLocationRecords(cachedPayload.records)))
                }
                // A cached timeline from an earlier run is useful for immediate UI,
                // but it cannot validate the location index until this run has checked
                // that timeline with the server. Join the ordinary timeline pipeline so
                // opening Map during startup cannot bless a stale index and then miss a
                // later authoritative timeline replacement.
                let fingerprint: String
                do {
                    fingerprint = try await verifiedPersonalTimelineFingerprint()
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.failure("Location index validation: \(error.localizedDescription)"))
                    }
                    removeLocationIndexSubscriber(subscriber)
                    continuation.finish()
                    return
                }
                if fingerprint == cachedPayload?.sourceTimelineFingerprint {
                    let value = acceptLocationRecords(cachedPayload?.records ?? [])
                    continuation.yield(.completed(value, verified: true))
                    removeLocationIndexSubscriber(subscriber)
                    continuation.finish()
                    return
                }
                let task = registerLocationIndexScan(fingerprint: fingerprint, subscriber: subscriber)
                do {
                    let records = try await task.value
                    continuation.yield(.completed(acceptLocationRecords(records), verified: true))
                } catch {
                    if !Task.isCancelled {
                        let message = error is CancellationError
                            ? "The location scan was canceled. Retry to rebuild the map index."
                            : error.localizedDescription
                        continuation.yield(.failure(message))
                    }
                }
                removeLocationIndexSubscriber(subscriber)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                producer.task?.cancel()
                Task { await self.removeLocationIndexSubscriber(subscriber) }
            }
        }
    }

    /// Returns only a fingerprint validated in this repository run. Calling
    /// `timeline(collection:)` joins any eager Personal Library request already in
    /// flight, and returns immediately when that resource has already been validated.
    private func verifiedPersonalTimelineFingerprint() async throws -> String {
        LibraryIndex(snapshot: try await verifiedTimelineSnapshot(collection: .personalLibrary)).fingerprint
    }

    private func registerLocationIndexScan(fingerprint: String,
                                           subscriber: UUID) -> Task<[PhotoLocationRecord], Error> {
        if var job = metadata.locationIndexWork {
            job.subscribers.insert(subscriber)
            metadata.locationIndexWork = job
            return job.task
        }
        let id = UUID()
        let task = Task<[PhotoLocationRecord], Error> {
            defer { finishLocationIndexScan(id: id) }
            let token = try await captureMetadataWorkToken(resource: .locationIndex, jobID: id)
            let key = CacheKey.locationIndex(namespace: namespace)
            let prior = try? await store.get(key)
            return try await runLocationIndexScan(sourceFingerprint: fingerprint,
                                                  token: token,
                                                  replacing: rowExpectation(for: prior))
        }
        metadata.locationIndexWork = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    private func runLocationIndexScan(sourceFingerprint: String,
                                      token: MetadataWorkToken,
                                      replacing expectation: MetadataRowExpectation) async throws -> [PhotoLocationRecord] {
        let total = metadata.latestTimelines[.personalLibrary].map {
            $0.sections.reduce(0) { $0 + max(0, $1.limit) }
        }
        var records: [PhotoLocationRecord] = []
        var scanned = 0
        var pages = 0
        var offset = 0
        var current: Task<[PhotoItem], Error>? = locationScanPageTask(offset: 0)
        var next: Task<[PhotoItem], Error>? = locationScanPageTask(offset: Self.locationScanPageLimit)
        // These page tasks are deliberately unstructured so two offsets can overlap.
        // Cancel either outstanding sibling on every exit, including a thrown page.
        defer {
            current?.cancel()
            next?.cancel()
        }
        while let pageTask = current {
            let items = try await pageTask.value
            pages += 1
            guard await metadataTokenIsCurrent(token) else {
                next?.cancel()
                throw CancellationError()
            }
            for item in items {
                guard let coordinate = item.coordinate else { continue }
                records.append(PhotoLocationRecord(id: item.id, time: item.time,
                                                   coordinate: coordinate,
                                                   thumbnail: item.additional?.thumbnail))
            }
            scanned += items.count
            publishLocationIndexProgress(scanned: scanned, total: total)
            guard !items.isEmpty, items.count == Self.locationScanPageLimit else {
                next?.cancel()
                break
            }
            guard pages < Self.locationScanPageCap else {
                next?.cancel()
                throw SynologyAPIError.unsupported(
                    "The location scan exceeds the \(Self.locationScanPageCap)-page safety cap."
                )
            }
            offset += Self.locationScanPageLimit
            current = next
            next = locationScanPageTask(offset: offset + Self.locationScanPageLimit)
        }
        let payload = LocationIndexPayload(sourceTimelineFingerprint: sourceFingerprint,
                                           scannedItemCount: scanned,
                                           records: records)
        let commit = try? await commitMetadata(
            payload,
            key: CacheKey.locationIndex(namespace: namespace),
            kind: .locationIndex,
            validatedRun: nil,
            token: token,
            replacing: expectation
        )
        if commit == .superseded || commit == .generationChanged {
            throw CancellationError()
        }
        return records
    }

    private func locationScanPageTask(offset: Int) -> Task<[PhotoItem], Error> {
        let id = UUID()
        return Task<[PhotoItem], Error> {
            try await gate.acquire(.metadata, priority: .prefetch, id: id)
            defer { Task { await gate.release(.metadata) } }
            try Task.checkCancellation()
            try await connect()
            try Task.checkCancellation()
            return try await client.locationScanPage(offset: offset, limit: Self.locationScanPageLimit)
        }
    }

    private func publishLocationIndexProgress(scanned: Int, total: Int?) {
        let event = LocationIndexEvent.progress(scanned: scanned, total: total)
        for observer in metadata.locationIndexObservers.values { observer.yield(event) }
    }

    private func finishLocationIndexScan(id: UUID) {
        guard metadata.locationIndexWork?.id == id else { return }
        metadata.locationIndexWork = nil
        cancelIdleLogin()
    }

    private func removeLocationIndexSubscriber(_ id: UUID) {
        metadata.locationIndexObservers.removeValue(forKey: id)
        metadata.locationIndexWork?.subscribers.remove(id)
    }

    private func acceptLocationRecords(_ records: [PhotoLocationRecord]) -> LocationIndexValue {
        let previous = metadata.locationRecords
        let next = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let semanticChanged = previous.count != next.count || next.contains { id, record in
            guard let old = previous[id] else { return true }
            return old.time != record.time || old.coordinate != record.coordinate
        }
        metadata.locationRecords = next
        if semanticChanged {
            metadata.locationRevision &+= 1
            invalidateMapFiltersForLocationChange()
        }
        return LocationIndexValue(records: records,
                                  revision: LocationIndexRevision(metadata.locationRevision))
    }
}
