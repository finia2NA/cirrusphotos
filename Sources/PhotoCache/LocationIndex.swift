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
    let space: PhotoSpace

    init(_ rawValue: UInt64, space: PhotoSpace) { self.rawValue = rawValue; self.space = space }
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

    public func locationIndexChanges(space: PhotoSpace) -> AsyncStream<LocationIndexEvent> {
        if space == .shared { return sharedLocationIndexChanges() }
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            metadata.locations.projectionObservers[id] = continuation
            Task { await self.publishStoredLocationProjection() }
            continuation.onTermination = { @Sendable _ in Task { await self.removeLocationProjectionObserver(id) } }
        }
    }
    private func removeLocationProjectionObserver(_ id: UUID) { metadata.locations.projectionObservers.removeValue(forKey: id) }

    func publishStoredLocationProjection() async {
        guard metadata.initialized, !metadata.resetInProgress,
              !metadata.sessions.mapFilters.isEmpty || !metadata.locations.projectionObservers.isEmpty else {
            metadata.locations.projectionLoaded = false
            return
        }
        let epoch = metadata.admissionEpoch
        let revision = metadata.locations.revision
        guard let projection = try? await store.metadataLocationProjection(personalMetadataNamespace),
              isAdmitted(epoch) else { return }
        guard revision == metadata.locations.revision else {
            metadata.locations.projectionLoaded = false
            scheduleLocationProjectionPublication()
            return
        }
        let state = projection.state, records = projection.records
        let verified = state.inventoryComplete && (metadata.inventoryCurrent || metadataSourceCurrent(.personal))
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        metadata.locations.projectionLoaded = true
        guard metadata.locations.records != byID || metadata.locations.lastPublishedInventoryVerified != verified else { return }
        metadata.locations.lastPublishedInventoryVerified = verified
        let value = acceptLocationRecords(records, space: .personal)
        for observer in metadata.locations.projectionObservers.values { observer.yield(.completed(value, verified: verified)) }
    }

    /// Full rows are already available from the bounded read that changed them.
    /// Keep dependency updates O(changed IDs), and coalesce Map presentation arrays.
    func publishLocationItemChanges(_ items: [PhotoItem], deletedIDs: [Int64] = [], coverageChanged: Bool = false) {
        guard !metadata.sessions.mapFilters.isEmpty || !metadata.locations.projectionObservers.isEmpty else {
            metadata.locations.projectionLoaded = false
            return
        }
        guard metadata.locations.projectionLoaded else { scheduleLocationProjectionPublication(); return }
        var changed = false
        for id in deletedIDs { if metadata.locations.records.removeValue(forKey: id) != nil { changed = true } }
        for item in items {
            let record = item.coordinate.map { PhotoLocationRecord(id: item.id, time: item.time, coordinate: $0, thumbnail: item.additional?.thumbnail) }
            if metadata.locations.records[item.id] != record {
                metadata.locations.records[item.id] = record
                changed = true
            }
        }
        if changed {
            metadata.locations.revision &+= 1
            invalidateMapFiltersForLocationChange(space: .personal)
        }
        if changed || coverageChanged { scheduleLocationProjectionPublication() }
    }
    private func scheduleLocationProjectionPublication() {
        guard metadata.locations.publicationTask == nil else { return }
        let id = UUID()
        metadata.locations.publicationID = id
        metadata.locations.publicationTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, metadata.locations.publicationID == id else { return }
            metadata.locations.publicationTask = nil
            metadata.locations.publicationID = nil
            if !metadata.locations.projectionLoaded { await publishStoredLocationProjection(); return }
            let epoch = metadata.admissionEpoch
            guard !metadata.locations.projectionObservers.isEmpty,
                  let state = try? await store.metadataState(personalMetadataNamespace),
                  isAdmitted(epoch) else { return }
            let records = metadata.locations.records.values.sorted { $0.time > $1.time || ($0.time == $1.time && $0.id < $1.id) }
            let verified = state.inventoryComplete && (metadata.inventoryCurrent || metadataSourceCurrent(.personal))
            metadata.locations.lastPublishedInventoryVerified = verified
            let value = LocationIndexValue(records: records, revision: LocationIndexRevision(metadata.locations.revision, space: .personal))
            for observer in metadata.locations.projectionObservers.values { observer.yield(.completed(value, verified: verified)) }
        }
    }

    /// Map is a projection of the common all-item inventory. It owns no source cursor.
    public func locationIndex(space: PhotoSpace) -> AsyncStream<LocationIndexEvent> {
        if space == .shared { return sharedLocationIndex() }
        let subscriber = UUID()
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            producer.task = Task {
                metadata.locations.indexObservers[subscriber] = continuation
                do {
                    try await initializeMetadataEngine()
                    let epoch = metadata.admissionEpoch
                    let cached = try await store.metadataCachedLocations(personalMetadataNamespace)
                    guard isAdmitted(epoch), !Task.isCancelled else { throw CancellationError() }
                    if !cached.isEmpty { continuation.yield(.cached(acceptLocationRecords(cached, space: .personal))) }
                    try await connect()
                    try await reconcileMetadataSource()
                    let projection = try await store.metadataLocationProjection(personalMetadataNamespace, currentOnly: true)
                    let state = projection.state
                    if (metadata.inventoryCurrent && state.inventoryComplete) || (metadataSourceCurrent(.personal) && state.inventoryComplete) {
                        let records = projection.records
                        guard isAdmitted(epoch), !Task.isCancelled else { throw CancellationError() }
                        continuation.yield(.completed(acceptLocationRecords(records, space: .personal), verified: true))
                    } else {
                        _ = try await verifiedTimelineSnapshot(collection: .library(.personal))
                        let task = registerLocationIndexScan(subscriber: subscriber)
                        let records = try await task.value
                        guard isAdmitted(epoch), !Task.isCancelled else { throw CancellationError() }
                        continuation.yield(.completed(acceptLocationRecords(records, space: .personal), verified: true))
                    }
                } catch {
                    if !Task.isCancelled { continuation.yield(.failure(RepositoryError.record(error, operation: "Location index").localizedDescription)) }
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
        if var job = metadata.locations.work {
            job.subscribers.insert(subscriber); metadata.locations.work = job; return job.task
        }
        let id = UUID()
        let task = Task<[PhotoLocationRecord], Error> {
            defer { finishLocationIndexScan(id: id) }
            let token = try await captureMetadataWorkToken(resource: .locationIndex, jobID: id)
            return try await buildMetadataInventory(token: token, id: id)

        }
        metadata.locations.work = SharedJob(id: id, task: task, subscribers: [subscriber])
        return task
    }

    func publishLocationIndexProgress(scanned: Int, total: Int?) {
        let event = LocationIndexEvent.progress(scanned: scanned, total: total)
        for observer in metadata.locations.indexObservers.values { observer.yield(event) }
    }

    private func finishLocationIndexScan(id: UUID) {
        guard metadata.locations.work?.id == id else { return }
        metadata.locations.work = nil
        cancelIdleLogin()
    }

    private func removeLocationIndexSubscriber(_ id: UUID) {
        metadata.locations.indexObservers.removeValue(forKey: id)
        metadata.locations.work?.subscribers.remove(id)
    }

    func acceptLocationRecords(_ records: [PhotoLocationRecord], space: PhotoSpace) -> LocationIndexValue {
        if space == .personal { metadata.locations.projectionLoaded = true }
        let previous = space == .shared ? metadata.sharedLocations.records : metadata.locations.records
        let next = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let semanticChanged = previous.count != next.count || next.contains { id, record in
            guard let old = previous[id] else { return true }
            return old.time != record.time || old.coordinate != record.coordinate
        }
        if space == .shared {
            metadata.sharedLocations.records = next
            if semanticChanged { metadata.sharedLocations.revision &+= 1 }
        } else {
            metadata.locations.records = next
            if semanticChanged { metadata.locations.revision &+= 1 }
        }
        if semanticChanged { invalidateMapFiltersForLocationChange(space: space) }
        let revision = space == .shared ? metadata.sharedLocations.revision : metadata.locations.revision
        return LocationIndexValue(records: records, revision: LocationIndexRevision(revision, space: space))
    }
}
