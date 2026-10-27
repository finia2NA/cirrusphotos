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

extension CachedPhotosRepository {
    static let locationScanPageLimit = 1000
    static let locationScanPageCap = 2048

    public func locationIndexChanges() -> AsyncStream<LocationIndexEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            metadata.locationProjectionObservers[id] = continuation
            Task { await self.publishStoredLocationProjection() }
            continuation.onTermination = { @Sendable _ in Task { await self.removeLocationProjectionObserver(id) } }
        }
    }
    private func removeLocationProjectionObserver(_ id: UUID) { metadata.locationProjectionObservers.removeValue(forKey: id) }

    func publishStoredLocationProjection() async {
        guard metadata.initialized, !metadata.resetInProgress,
              !metadata.mapFilters.isEmpty || !metadata.locationProjectionObservers.isEmpty else {
            metadata.locationProjectionLoaded = false
            return
        }
        let epoch = metadata.admissionEpoch
        let revision = metadata.locationRevision
        guard let projection = try? await store.metadataLocationProjection(metadataNamespace),
              epoch == metadata.admissionEpoch, !metadata.resetInProgress else { return }
        guard revision == metadata.locationRevision else {
            metadata.locationProjectionLoaded = false
            scheduleLocationProjectionPublication()
            return
        }
        let state = projection.state, records = projection.records
        let verified = state.inventoryComplete && (metadata.inventoryCurrent || (metadata.reconciled && !metadata.sourceUnavailable))
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        metadata.locationProjectionLoaded = true
        guard metadata.locationRecords != byID || metadata.lastPublishedInventoryVerified != verified else { return }
        metadata.lastPublishedInventoryVerified = verified
        let value = acceptLocationRecords(records)
        for observer in metadata.locationProjectionObservers.values { observer.yield(.completed(value, verified: verified)) }
    }

    /// Full rows are already available from the bounded read that changed them.
    /// Keep dependency updates O(changed IDs), and coalesce Map presentation arrays.
    func publishLocationItemChanges(_ items: [PhotoItem], deletedIDs: [Int64] = [], coverageChanged: Bool = false) {
        guard !metadata.mapFilters.isEmpty || !metadata.locationProjectionObservers.isEmpty else {
            metadata.locationProjectionLoaded = false
            return
        }
        guard metadata.locationProjectionLoaded else { scheduleLocationProjectionPublication(); return }
        var changed = false
        for id in deletedIDs { if metadata.locationRecords.removeValue(forKey: id) != nil { changed = true } }
        for item in items {
            let record = item.coordinate.map { PhotoLocationRecord(id: item.id, time: item.time, coordinate: $0, thumbnail: item.additional?.thumbnail) }
            if metadata.locationRecords[item.id] != record {
                metadata.locationRecords[item.id] = record
                changed = true
            }
        }
        if changed {
            metadata.locationRevision &+= 1
            invalidateMapFiltersForLocationChange()
        }
        if changed || coverageChanged { scheduleLocationProjectionPublication() }
    }
    private func scheduleLocationProjectionPublication() {
        guard metadata.locationPublicationTask == nil else { return }
        let id = UUID()
        metadata.locationPublicationID = id
        metadata.locationPublicationTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, metadata.locationPublicationID == id else { return }
            metadata.locationPublicationTask = nil
            metadata.locationPublicationID = nil
            if !metadata.locationProjectionLoaded { await publishStoredLocationProjection(); return }
            let epoch = metadata.admissionEpoch
            guard !metadata.locationProjectionObservers.isEmpty,
                  let state = try? await store.metadataState(metadataNamespace),
                  epoch == metadata.admissionEpoch, !metadata.resetInProgress else { return }
            let records = metadata.locationRecords.values.sorted { $0.time > $1.time || ($0.time == $1.time && $0.id < $1.id) }
            let verified = state.inventoryComplete && (metadata.inventoryCurrent || (metadata.reconciled && !metadata.sourceUnavailable))
            metadata.lastPublishedInventoryVerified = verified
            let value = LocationIndexValue(records: records, revision: LocationIndexRevision(metadata.locationRevision))
            for observer in metadata.locationProjectionObservers.values { observer.yield(.completed(value, verified: verified)) }
        }
    }

    /// Map is a projection of the common all-item inventory. It owns no source cursor.
    public func locationIndex() -> AsyncStream<LocationIndexEvent> {
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            producer.task = Task {
                metadata.locationIndexObservers[subscriber] = continuation
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let cached = try await store.metadataCachedLocations(metadataNamespace)
                    guard epoch == metadata.admissionEpoch, !metadata.resetInProgress, !Task.isCancelled else { throw CancellationError() }
                    if !cached.isEmpty { continuation.yield(.cached(acceptLocationRecords(cached))) }
                    try await connect()
                    try await reconcileMetadataSource()
                    let projection = try await store.metadataLocationProjection(metadataNamespace, currentOnly: true)
                    let state = projection.state
                    if (metadata.inventoryCurrent && state.inventoryComplete) || (metadata.reconciled && !metadata.sourceUnavailable && state.inventoryComplete) {
                        let records = projection.records
                        guard epoch == metadata.admissionEpoch, !metadata.resetInProgress, !Task.isCancelled else { throw CancellationError() }
                        continuation.yield(.completed(acceptLocationRecords(records), verified: true))
                    } else {
                        _ = try await verifiedTimelineSnapshot(collection: .personalLibrary)
                        let task = registerLocationIndexScan(subscriber: subscriber)
                        let records = try await task.value
                        guard epoch == metadata.admissionEpoch, !metadata.resetInProgress, !Task.isCancelled else { throw CancellationError() }
                        continuation.yield(.completed(acceptLocationRecords(records), verified: true))
                    }
                } catch {
                    if !Task.isCancelled { continuation.yield(.failure(error.localizedDescription)) }
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

    private func registerLocationIndexScan(subscriber: UUID) -> Task<[PhotoLocationRecord], Error> {
        if var job = metadata.locationIndexWork {
            job.subscribers.insert(subscriber); metadata.locationIndexWork = job; return job.task
        }
        let id = UUID()
        let task = Task<[PhotoLocationRecord], Error> {
            defer { finishLocationIndexScan(id: id) }
            let token = try await captureMetadataWorkToken(resource: .locationIndex, jobID: id)
            return try await buildMetadataInventory(token: token, id: id)

        }
        metadata.locationIndexWork = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    func publishLocationIndexProgress(scanned: Int, total: Int?) {
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

    func acceptLocationRecords(_ records: [PhotoLocationRecord]) -> LocationIndexValue {
        metadata.locationProjectionLoaded = true
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
