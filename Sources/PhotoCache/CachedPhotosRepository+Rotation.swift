import CoreGraphics
import Foundation
import ImageIO
import SynologyAPI
import UniformTypeIdentifiers

private enum ThumbnailRotationOperation: Sendable {
    case manual(PhotoRotationDirection)
    case automatic

    var logDescription: String {
        switch self {
        case .manual(let direction): direction.rawValue
        case .automatic: "automatic"
        }
    }

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }
}

extension CachedPhotosRepository {
    public func photoItemChanges() -> AsyncStream<PhotoItemChange> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            itemMutations.observers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeItemMutationObserver(id) }
            }
        }
    }

    /// Optimistically projects the quarter turn, then replaces it with authoritative
    /// `Browse.Item.get` records. Any transport or refresh failure restores the prior items.
    public func rotate(_ action: SelectionRotationAction,
                       direction: PhotoRotationDirection) async throws {
        let source = mediaCollection(for: action.collection)
        guard source.incomingAlbumIdentity == nil, !source.isSessionDerived else {
            throw SynologyAPIError.unsupported("Rotation is unavailable for shared album photos.")
        }
        let space = source.albumID != nil ? try await albumItemSpace(itemIDs: action.itemIDs, collection: source) : source.space
        guard !action.itemIDs.isEmpty else { return }
        if let expected = action.expectedTimelineFingerprint {
            guard let snapshot = metadata.latestTimelines[action.collection], LibraryIndex(snapshot: snapshot).fingerprint == expected else {
                throw SynologyAPIError.unsupported("The collection changed before the rotation. Try again.")
            }
        }
        let mutationCacheEpoch = metadata.admissionEpoch
        guard action.itemIDs.allSatisfy({ action.itemsByID[$0]?.hasDisplayableStillImage == true }) else {
            throw SynologyAPIError.unsupported("Only photos and Live Photo still images can be rotated.")
        }
        for id in action.itemIDs {
            guard !itemMutations.pendingIDs.contains(PhotoItemIdentity(scope: .space(space), itemID: id)) else {
                throw SynologyAPIError.unsupported("A rotation is already in progress for one of these photos.")
            }
        }
        for id in action.itemIDs { itemMutations.pendingIDs.insert(PhotoItemIdentity(scope: .space(space), itemID: id)) }
        defer { for id in action.itemIDs { itemMutations.pendingIDs.remove(PhotoItemIdentity(scope: .space(space), itemID: id)) } }

        let originals = action.itemsByID
        let optimistic = originals.mapValues { $0.rotated(direction) }
        itemMutations.publish(PhotoItemChange(
            items: optimistic,
            quarterTurns: Dictionary(uniqueKeysWithValues: action.itemIDs.map {
                ($0, direction == .clockwise ? 1 : -1)
            }), scope: .space(space)
        ))
        await patchRotationPages(action: action, replacements: optimistic, metadataEpoch: mutationCacheEpoch)
        if source.albumID != nil { itemMutations.publish(PhotoItemChange(items: optimistic, quarterTurns: Dictionary(uniqueKeysWithValues: action.itemIDs.map { ($0, direction == .clockwise ? 1 : -1) }), scope: source.contentScope)) }
        var attemptedWrite = false
        do {
            try await connect()
            for chunkStart in stride(from: 0, to: action.itemIDs.count, by: 100) {
                let chunk = Array(action.itemIDs[chunkStart..<min(chunkStart + 100, action.itemIDs.count)])
                attemptedWrite = true
                try await client.rotate(itemIDs: chunk, direction: direction, space: space)
            }
            let refreshed = try await lookupAllRotationItems(action.itemIDs, space: space)
            guard refreshed.count == action.itemIDs.count else { throw SynologyAPIError.invalidResponse }
            let replacements = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
            await patchRotationPages(action: action, replacements: replacements, metadataEpoch: mutationCacheEpoch)
            itemMutations.publish(PhotoItemChange(items: replacements, scope: .space(space)))
            if source.albumID != nil {
                await patchRotationSpace(replacements, space: space, epoch: mutationCacheEpoch)
                itemMutations.publish(PhotoItemChange(items: replacements, scope: source.contentScope))
            }
        } catch {
            var recovery = originals
            if attemptedWrite, let refreshed = try? await lookupAllRotationItems(action.itemIDs, space: space) {
                for item in refreshed { recovery[item.id] = item }
            }
            await patchRotationPages(action: action, replacements: recovery, metadataEpoch: mutationCacheEpoch)
            itemMutations.publish(PhotoItemChange(items: recovery, scope: .space(space)))
            if source.albumID != nil {
                await patchRotationSpace(recovery, space: space, epoch: mutationCacheEpoch)
                itemMutations.publish(PhotoItemChange(items: recovery, scope: source.contentScope))
            }
            throw error
        }
    }

    /// Runs the confirmed desktop-converter workflow. Processing is intentionally
    /// serialized: each item holds a server regeneration lease that must be restored
    /// independently on cancellation or failure.
    public func rotateThumbnails(_ action: SelectionRotationAction,
                                 direction: PhotoRotationDirection) -> AsyncStream<ThumbnailRotationProgress> {
        SynologyDiagnostics.rotations.info(
            "Thumbnail rotation requested items=\(action.itemIDs.count, privacy: .public) direction=\(direction.rawValue, privacy: .public)"
        )
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            producer.task = Task {
                await self.runThumbnailRotation(action, operation: .manual(direction),
                                                continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in producer.task?.cancel() }
        }
    }

    /// Detects the relative thumbnail orientation from the displayed original. All
    /// three renditions must independently agree before the server is mutated.
    public func fixThumbnailRotations(
        _ action: SelectionRotationAction
    ) -> AsyncStream<ThumbnailRotationProgress> {
        SynologyDiagnostics.rotations.info(
            "Automatic thumbnail rotation requested items=\(action.itemIDs.count, privacy: .public)"
        )
        let producer = StreamProducer()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            producer.task = Task {
                await self.runThumbnailRotation(action, operation: .automatic,
                                                continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in producer.task?.cancel() }
        }
    }

    private func runThumbnailRotation(
        _ action: SelectionRotationAction,
        operation: ThumbnailRotationOperation,
        continuation: AsyncStream<ThumbnailRotationProgress>.Continuation
    ) async {
        do {
            let source = mediaCollection(for: action.collection)
            let space = source.albumID != nil ? try await albumItemSpace(itemIDs: action.itemIDs, collection: source) : source.contentScope.space
            guard space == .personal else { throw SynologyAPIError.unsupported("Thumbnail rotation requires verified Personal Space items.") }
        } catch {
            let message = error.localizedDescription
            continuation.yield(.init(completedItems: 0, totalItems: action.itemIDs.count, itemID: nil,
                                     stage: .finished, failures: [message], activity: [message]))
            continuation.finish()
            return
        }
        let mutationCacheEpoch = metadata.admissionEpoch
        let total = action.itemIDs.count
        var completed = 0
        var failures: [String] = []
        var activity: [String] = []
        var claimedIDs: Set<Int64> = []
        defer {
            for id in claimedIDs { itemMutations.pendingIDs.remove(PhotoItemIdentity(scope: .space(.personal), itemID: id)) }
        }
        continuation.yield(.init(completedItems: 0, totalItems: total, itemID: nil,
                                 stage: .preparing, activity: activity))
        do { try await connect() }
        catch {
            SynologyDiagnostics.rotations.error(
                "Thumbnail rotation could not connect items=\(total, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            activity.append("Could not start: \(error.localizedDescription)")
            continuation.yield(.init(completedItems: 0, totalItems: total, itemID: nil,
                                     stage: .finished, failures: [error.localizedDescription],
                                     activity: activity))
            continuation.finish(); return
        }
        for id in action.itemIDs {
            if Task.isCancelled {
                SynologyDiagnostics.rotations.info(
                    "Thumbnail rotation cancelled before item item_id=\(id, privacy: .public) completed=\(completed, privacy: .public) total=\(total, privacy: .public)"
                )
                failures.append("Cancelled before photo \(id).")
                activity.append("Photo \(id): cancelled before processing.")
                break
            }
            guard !itemMutations.pendingIDs.contains(PhotoItemIdentity(scope: .space(.personal), itemID: id)) else {
                SynologyDiagnostics.rotations.error(
                    "Thumbnail rotation rejected pending item item_id=\(id, privacy: .public)"
                )
                failures.append("Photo \(id) already has a rotation in progress.")
                activity.append("Photo \(id): failed — another rotation is already in progress.")
                completed += 1
                continue
            }
            itemMutations.pendingIDs.insert(PhotoItemIdentity(scope: .space(.personal), itemID: id))
            claimedIDs.insert(id)
            guard let item = action.itemsByID[id], let descriptor = item.additional?.thumbnail,
                  item.hasDisplayableStillImage else {
                SynologyDiagnostics.rotations.error(
                    "Thumbnail rotation missing eligible descriptor item_id=\(id, privacy: .public)"
                )
                failures.append("Photo \(id) does not have three replaceable thumbnails.")
                activity.append("Photo \(id): failed — replaceable thumbnails are unavailable.")
                completed += 1
                itemMutations.pendingIDs.remove(PhotoItemIdentity(scope: .space(.personal), itemID: id))
                claimedIDs.remove(id)
                continue
            }
            do {
                var downloaded: [ThumbnailSize: Data] = [:]
                let thumbnailDownloadBytes = ThumbnailSize.allCases.reduce(Int64(0)) {
                    $0 + Self.estimatedDownloadBytes(for: $1)
                }
                let estimatedOriginalBytes = item.filesize.flatMap { $0 > 0 ? $0 : nil }
                    ?? Self.fallbackOriginalDownloadBytes
                let estimatedTotalDownloadBytes = thumbnailDownloadBytes
                    + (operation.isAutomatic ? estimatedOriginalBytes : 0)
                var completedThumbnailDownloadBytes: Int64 = 0
                for size in ThumbnailSize.allCases {
                    continuation.yield(.init(
                        completedItems: completed, totalItems: total, itemID: id,
                        stage: .downloading, failures: failures,
                        itemProgress: Self.downloadHalfProgress(
                            completedBytes: completedThumbnailDownloadBytes,
                            totalBytes: estimatedTotalDownloadBytes
                        ),
                        activity: activity,
                        detail: "Downloading \(Self.downloadName(for: size)) thumbnail"
                    ))
                    SynologyDiagnostics.rotations.info(
                        "Downloading thumbnail for rotation item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) size=\(size.rawValue, privacy: .public) ready=\(descriptor.isReady(size), privacy: .public)"
                    )
                    guard descriptor.isReady(size) else {
                        throw SynologyAPIError.unsupported("The \(size.rawValue) thumbnail is not ready.")
                    }
                    let response = try await client.thumbnail(descriptor, size: size,
                                                              etag: nil, lastModified: nil)
                    guard let data = response.data else { throw SynologyAPIError.invalidResponse }
                    downloaded[size] = data
                    completedThumbnailDownloadBytes += Self.estimatedDownloadBytes(for: size)
                    continuation.yield(.init(
                        completedItems: completed, totalItems: total, itemID: id,
                        stage: .downloading, failures: failures,
                        itemProgress: Self.downloadHalfProgress(
                            completedBytes: completedThumbnailDownloadBytes,
                            totalBytes: estimatedTotalDownloadBytes
                        ),
                        activity: activity,
                        detail: "Downloading \(Self.downloadName(for: size)) thumbnail"
                    ))
                    SynologyDiagnostics.rotations.info(
                        "Downloaded thumbnail for rotation item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) size=\(size.rawValue, privacy: .public) bytes=\(data.count, privacy: .public)"
                    )
                }
                try Task.checkCancellation()
                let clockwiseQuarterTurns: Int
                switch operation {
                case .manual(let direction):
                    clockwiseQuarterTurns = direction == .clockwise ? 1 : -1
                case .automatic:
                    guard let resource = item.fullImageResource(in: .space(.personal)) else {
                        throw SynologyAPIError.unsupported("A full-size image is unavailable.")
                    }
                    let downloadActivity = activity
                    let downloadFailures = failures
                    let downloadCompleted = completed
                    let completedEstimatedThumbnailBytes = completedThumbnailDownloadBytes
                    continuation.yield(.init(
                        completedItems: completed, totalItems: total, itemID: id,
                        stage: .downloading, failures: failures,
                        itemProgress: Self.downloadHalfProgress(
                            completedBytes: completedThumbnailDownloadBytes,
                            totalBytes: estimatedTotalDownloadBytes
                        ),
                        activity: activity, detail: "Downloading full photo"
                    ))
                    let original = try await comparisonOriginal(resource) { transfer in
                        let fullBytes = transfer.totalBytes ?? estimatedOriginalBytes
                        let aggregateDownloaded = completedEstimatedThumbnailBytes
                            + min(transfer.completedBytes, fullBytes)
                        let aggregateTotal = thumbnailDownloadBytes + fullBytes
                        continuation.yield(.init(
                            completedItems: downloadCompleted, totalItems: total, itemID: id,
                            stage: .downloading, failures: downloadFailures,
                            itemProgress: Self.downloadHalfProgress(
                                completedBytes: aggregateDownloaded, totalBytes: aggregateTotal
                            ),
                            activity: downloadActivity, detail: "Downloading full photo"
                        ))
                    }
                    try Task.checkCancellation()
                    continuation.yield(.init(completedItems: completed, totalItems: total,
                                             itemID: id, stage: .analyzing, failures: failures,
                                             itemProgress: 0.5, activity: activity))
                    let match = try await ThumbnailOrientationAnalyzer.shared.match(
                        originalData: original, item: item, thumbnails: downloaded
                    )
                    try Task.checkCancellation()
                    clockwiseQuarterTurns = match.clockwiseQuarterTurns
                    continuation.yield(.init(completedItems: completed, totalItems: total,
                                             itemID: id, stage: .analyzing, failures: failures,
                                             itemProgress: 0.6, activity: activity))
                    SynologyDiagnostics.rotations.info(
                        "Matched thumbnail orientation item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) clockwise_quarter_turns=\(clockwiseQuarterTurns, privacy: .public)"
                    )
                }
                if clockwiseQuarterTurns == 0 {
                    SynologyDiagnostics.rotations.info(
                        "Thumbnail orientation already correct item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public)"
                    )
                    activity.append("Photo \(id): already correct.")
                    completed += 1
                    itemMutations.pendingIDs.remove(PhotoItemIdentity(scope: .space(.personal), itemID: id))
                    claimedIDs.remove(id)
                    continue
                }
                continuation.yield(.init(completedItems: completed, totalItems: total,
                                         itemID: id, stage: .rotating, failures: failures,
                                         itemProgress: operation.isAutomatic ? 0.6 : 0.5,
                                         activity: activity))
                let files = try Self.rotatedFiles(
                    downloaded, clockwiseQuarterTurns: clockwiseQuarterTurns
                )
                continuation.yield(.init(completedItems: completed, totalItems: total,
                                         itemID: id, stage: .rotating, failures: failures,
                                         itemProgress: 2.0 / 3.0, activity: activity))
                SynologyDiagnostics.rotations.info(
                    "Rotated thumbnails locally item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) clockwise_quarter_turns=\(clockwiseQuarterTurns, privacy: .public) sm_bytes=\(files.sm.count, privacy: .public) m_bytes=\(files.m.count, privacy: .public) xl_bytes=\(files.xl.count, privacy: .public)"
                )
                let units: [RegeneratingThumbnailUnit]
                do {
                    units = try await client.setRegenerating(itemIDs: [id])
                } catch {
                    Self.logRotationFailure(
                        "set_regenerating", itemID: id, unitID: descriptor.unitID, error: error
                    )
                    await recoverThumbnailAfterAmbiguousFailure(
                        action: action, itemID: id, descriptor: descriptor,
                        unitIDs: [descriptor.unitID],
                        mutationCacheEpoch: mutationCacheEpoch
                    )
                    throw error
                }
                guard let unit = units.first, units.count == 1 else {
                    SynologyDiagnostics.rotations.error(
                        "Unexpected set_regenerating result item_id=\(id, privacy: .public) descriptor_unit_id=\(descriptor.unitID, privacy: .public) returned_units=\(units.count, privacy: .public)"
                    )
                    await recoverThumbnailAfterAmbiguousFailure(
                        action: action, itemID: id, descriptor: descriptor,
                        unitIDs: Array(Set(units.map(\.unitID) + [descriptor.unitID])),
                        mutationCacheEpoch: mutationCacheEpoch
                    )
                    throw SynologyAPIError.invalidResponse
                }
                do {
                    try Task.checkCancellation()
                    SynologyDiagnostics.rotations.info(
                        "Uploading rotated thumbnails item_id=\(id, privacy: .public) unit_id=\(unit.unitID, privacy: .public)"
                    )
                    continuation.yield(.init(completedItems: completed, totalItems: total,
                                             itemID: id, stage: .uploading, failures: failures,
                                             itemProgress: 2.0 / 3.0, activity: activity))
                    let uploadActivity = activity
                    let uploadFailures = failures
                    let uploadCompleted = completed
                    try await client.uploadConvertedThumbnails(
                        unitID: unit.unitID, files: files,
                        progress: { transfer in
                            continuation.yield(.init(
                                completedItems: uploadCompleted, totalItems: total, itemID: id,
                                stage: .uploading, failures: uploadFailures,
                                itemProgress: 2.0 / 3.0 + (transfer.fractionCompleted ?? 0) / 3.0,
                                activity: uploadActivity
                            ))
                        }
                    )
                    try Task.checkCancellation()
                    continuation.yield(.init(completedItems: completed, totalItems: total,
                                             itemID: id, stage: .refreshing, failures: failures,
                                             itemProgress: 1, activity: activity))
                    let refreshedItem = try await waitForThumbnailRevision(itemID: id,
                                                                           oldCacheKey: descriptor.cacheKey)
                    await patchRotationPages(action: action, replacements: [id: refreshedItem], metadataEpoch: mutationCacheEpoch)
                    itemMutations.publish(PhotoItemChange(items: [id: refreshedItem]))
                    let source = mediaCollection(for: action.collection)
                    if source.albumID != nil {
                        await patchRotationSpace([id: refreshedItem], space: .personal, epoch: mutationCacheEpoch)
                        itemMutations.publish(PhotoItemChange(items: [id: refreshedItem], scope: source.contentScope))
                    }
                    activity.append("Photo \(id): applied \(Self.rotationDescription(clockwiseQuarterTurns)).")
                    SynologyDiagnostics.rotations.info(
                        "Thumbnail rotation completed item_id=\(id, privacy: .public) unit_id=\(unit.unitID, privacy: .public)"
                    )
                } catch {
                    Self.logRotationFailure(
                        "upload_or_refresh", itemID: id, unitID: unit.unitID, error: error
                    )
                    await recoverThumbnailAfterAmbiguousFailure(
                        action: action, itemID: id, descriptor: descriptor,
                        unitIDs: [unit.unitID],
                        mutationCacheEpoch: mutationCacheEpoch
                    )
                    throw error
                }
            } catch is CancellationError {
                SynologyDiagnostics.rotations.info(
                    "Thumbnail rotation cancellation handled item_id=\(id, privacy: .public)"
                )
                failures.append("Thumbnail rotation was cancelled.")
                activity.append("Photo \(id): cancelled.")
                break
            } catch {
                Self.logRotationFailure(
                    "item", itemID: id, unitID: descriptor.unitID, error: error
                )
                failures.append("Photo \(id): \(error.localizedDescription)")
                activity.append("Photo \(id): failed — \(error.localizedDescription)")
            }
            completed += 1
            itemMutations.pendingIDs.remove(PhotoItemIdentity(scope: .space(.personal), itemID: id))
            claimedIDs.remove(id)
        }
        continuation.yield(.init(completedItems: completed, totalItems: total, itemID: nil,
                                 stage: .finished, failures: failures, itemProgress: 1,
                                 activity: activity))
        SynologyDiagnostics.rotations.info(
            "Thumbnail rotation run finished operation=\(operation.logDescription, privacy: .public) completed=\(completed, privacy: .public) total=\(total, privacy: .public) failures=\(failures.count, privacy: .public)"
        )
        continuation.finish()
    }

    private func comparisonOriginal(
        _ resource: FullImageResource,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> Data {
        var cached: Data?
        var failure: String?
        for await event in fullImage(resource, allowNetwork: true, priority: .visible,
                                     progress: progress) {
            try Task.checkCancellation()
            switch event {
            case .value(let data, let verified):
                if verified { return data }
                cached = data
            case .failure(let message):
                failure = message
            }
        }
        if let cached { return cached }
        throw SynologyAPIError.transport(failure ?? "The full-size image is unavailable.")
    }

    nonisolated private static func rotationDescription(_ turns: Int) -> String {
        switch (turns % 4 + 4) % 4 {
        case 0: "no rotation"
        case 1: "90° right"
        case 2: "180°"
        default: "90° left"
        }
    }

    nonisolated private static let fallbackOriginalDownloadBytes: Int64 = 5_000_000

    nonisolated private static func estimatedDownloadBytes(for size: ThumbnailSize) -> Int64 {
        switch size {
        case .sm: 60_000
        case .m: 150_000
        case .xl: 1_000_000
        }
    }

    nonisolated private static func downloadName(for size: ThumbnailSize) -> String {
        switch size {
        case .sm: "small"
        case .m: "medium"
        case .xl: "large"
        }
    }

    nonisolated private static func downloadHalfProgress(
        completedBytes: Int64, totalBytes: Int64
    ) -> Double {
        guard totalBytes > 0 else { return 0 }
        return 0.5 * min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    private func lookupAllRotationItems(_ ids: [Int64], space: PhotoSpace = .personal) async throws -> [PhotoItem] {
        var result: [PhotoItem] = []
        for start in stride(from: 0, to: ids.count, by: 1_000) {
            let requested = Array(ids[start..<min(start + 1_000, ids.count)])
            let items = try await client.items(ids: requested, space: space)
            guard items.count == requested.count, Set(items.map(\.id)) == Set(requested) else { throw SynologyAPIError.invalidResponse }
            result.append(contentsOf: items)
        }
        return result
    }

    private func waitForThumbnailRevision(itemID: Int64, oldCacheKey: String) async throws -> PhotoItem {
        for attempt in 0..<8 {
            try Task.checkCancellation()
            if let item = try await lookupAllRotationItems([itemID]).first {
                let changed = item.additional?.thumbnail?.cacheKey != oldCacheKey
                SynologyDiagnostics.rotations.debug(
                    "Polled thumbnail revision item_id=\(itemID, privacy: .public) attempt=\(attempt + 1, privacy: .public) changed=\(changed, privacy: .public)"
                )
                if changed { return item }
            }
            if attempt < 7 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw SynologyAPIError.invalidResponse
    }

    private func restoreRegeneratingUnits(_ unitIDs: [Int64]) async {
        let client = client
        SynologyDiagnostics.rotations.info(
            "Restoring regenerating thumbnail units count=\(unitIDs.count, privacy: .public) first_unit_id=\(unitIDs.first ?? -1, privacy: .public)"
        )
        await Task.detached(priority: .utility) {
            do {
                try await client.restoreFromRegenerating(unitIDs: unitIDs)
                SynologyDiagnostics.rotations.info(
                    "Restored regenerating thumbnail units count=\(unitIDs.count, privacy: .public) first_unit_id=\(unitIDs.first ?? -1, privacy: .public)"
                )
            } catch {
                Self.logRotationFailure(
                    "restore_from_regenerating", itemID: nil, unitID: unitIDs.first, error: error
                )
            }
        }.value
    }

    private func recoverThumbnailAfterAmbiguousFailure(
        action: SelectionRotationAction,
        itemID: Int64,
        descriptor: ThumbnailInfo,
        unitIDs: [Int64],
        mutationCacheEpoch: UInt64
    ) async {
        await restoreRegeneratingUnits(unitIDs)
        let client = client
        let refreshed = await Task.detached(priority: .utility) { () -> PhotoItem? in
            for attempt in 0..<8 {
                if let item = try? await client.items(ids: [itemID]).first,
                   item.additional?.thumbnail?.cacheKey != descriptor.cacheKey {
                    SynologyDiagnostics.rotations.info(
                        "Reconciled advanced thumbnail revision after failure item_id=\(itemID, privacy: .public) attempt=\(attempt + 1, privacy: .public)"
                    )
                    return item
                }
                if attempt < 7 { try? await Task.sleep(for: .milliseconds(250)) }
            }
            return nil
        }.value
        guard let refreshed else {
            SynologyDiagnostics.rotations.info(
                "No advanced thumbnail revision found after failure item_id=\(itemID, privacy: .public)"
            )
            return
        }
        await patchRotationPages(action: action, replacements: [itemID: refreshed], metadataEpoch: mutationCacheEpoch)
        itemMutations.publish(PhotoItemChange(items: [itemID: refreshed]))
        let source = mediaCollection(for: action.collection)
        if source.albumID != nil {
            await patchRotationSpace([itemID: refreshed], space: .personal, epoch: mutationCacheEpoch)
            itemMutations.publish(PhotoItemChange(items: [itemID: refreshed], scope: source.contentScope))
        }
    }

    nonisolated private static func logRotationFailure(
        _ stage: String, itemID: Int64?, unitID: Int64?, error: Error
    ) {
        if case SynologyAPIError.api(let code) = error {
            SynologyDiagnostics.rotations.error(
                "Thumbnail rotation failed stage=\(stage, privacy: .public) item_id=\(itemID ?? -1, privacy: .public) unit_id=\(unitID ?? -1, privacy: .public) api_code=\(code, privacy: .public)"
            )
        } else {
            SynologyDiagnostics.rotations.error(
                "Thumbnail rotation failed stage=\(stage, privacy: .public) item_id=\(itemID ?? -1, privacy: .public) unit_id=\(unitID ?? -1, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func patchRotationSpace(_ items: [Int64: PhotoItem], space: PhotoSpace, epoch: UInt64) async {
        guard epoch == metadata.admissionEpoch, !metadata.resetInProgress else { return }
        let scoped = MetadataNamespace(account: namespace, scope: .space(space))
        guard let admission = try? await store.metadataAdmission(scoped), epoch == metadata.admissionEpoch else { return }
        try? await store.applyMetadataRotationValues(items, namespace: scoped, admission: admission)
    }

    private func patchRotationPages(action: SelectionRotationAction,
                                    replacements: [Int64: PhotoItem], metadataEpoch: UInt64) async {
        guard metadataEpoch == metadata.admissionEpoch, !metadata.resetInProgress else { return }
        let metadataNamespace = metadataNamespace(for: action.collection)
        if metadata.initialized,
           replacements.values.allSatisfy({ $0.pendingRotationQuarterTurns == 0 }),
           let admission = try? await store.metadataAdmission(metadataNamespace) {
            guard metadataEpoch == metadata.admissionEpoch, !metadata.resetInProgress else { return }
            try? await store.applyMetadataRotationValues(replacements, namespace: metadataNamespace, admission: admission)
            guard metadataEpoch == metadata.admissionEpoch, !metadata.resetInProgress else { return }
            let canonical = try? await store.metadataDetails(metadataNamespace, ids: Array(replacements.keys), currentRun: runID)
            guard metadataEpoch == metadata.admissionEpoch else { return }
            if metadataNamespace.scope == .space(.personal) { publishLocationItemChanges(canonical?.values.compactMap(\.item) ?? []) }
            else if metadataNamespace.scope == .space(.shared) { await publishSharedLocationItemChanges(canonical?.values.compactMap(\.item) ?? []) }
        }

    }

    nonisolated private static func rotatedFiles(
        _ downloaded: [ThumbnailSize: Data], clockwiseQuarterTurns: Int
    ) throws -> ConvertedThumbnailFiles {
        ConvertedThumbnailFiles(
            sm: try rotateJPEG(downloaded[.sm], clockwiseQuarterTurns: clockwiseQuarterTurns),
            m: try rotateJPEG(downloaded[.m], clockwiseQuarterTurns: clockwiseQuarterTurns),
            xl: try rotateJPEG(downloaded[.xl], clockwiseQuarterTurns: clockwiseQuarterTurns)
        )
    }

    nonisolated private static func rotateJPEG(
        _ data: Data?, clockwiseQuarterTurns: Int
    ) throws -> Data {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0, pixelHeight > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
              ] as CFDictionary) else {
            throw SynologyAPIError.invalidResponse
        }
        let rotated = try ThumbnailOrientationMatcher.rotate(
            image, clockwiseQuarterTurns: clockwiseQuarterTurns
        )
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw SynologyAPIError.invalidResponse
        }
        CGImageDestinationAddImage(destination, rotated,
                                   [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SynologyAPIError.invalidResponse }
        return output as Data
    }

    private func removeItemMutationObserver(_ id: UUID) { itemMutations.observers.removeValue(forKey: id) }
}
