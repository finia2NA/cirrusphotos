import Foundation
import SynologyAPI

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
            throw RepositoryError.unavailable("Rotation is unavailable for shared album photos.")
        }
        let space = try await itemActionSpace(itemIDs: action.itemIDs, collection: source)
        guard !action.itemIDs.isEmpty else { return }
        if let expected = action.expectedTimelineFingerprint {
            guard let snapshot = metadata.latestTimelines[action.collection], LibraryIndex(snapshot: snapshot).fingerprint == expected else {
                throw RepositoryError.stale("The collection changed before the rotation. Try again.")
            }
        }
        let mutationCacheEpoch = metadata.admissionEpoch
        guard action.itemIDs.allSatisfy({ action.itemsByID[$0]?.hasDisplayableStillImage == true }) else {
            throw RepositoryError.unavailable("Only photos and Live Photo still images can be rotated.")
        }
        for id in action.itemIDs {
            guard !itemMutations.pendingIDs.contains(PhotoItemIdentity(scope: .space(space), itemID: id)) else {
                throw RepositoryError.busy("A rotation is already in progress for one of these photos.")
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
            await publishRotationReplacements(replacements, action: action, space: space, epoch: mutationCacheEpoch)
        } catch {
            var recovery = originals
            if attemptedWrite, let refreshed = try? await lookupAllRotationItems(action.itemIDs, space: space) {
                for item in refreshed { recovery[item.id] = item }
            }
            await publishRotationReplacements(recovery, action: action, space: space, epoch: mutationCacheEpoch)
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
        var reporter = ThumbnailRotationReporter(continuation: continuation, total: action.itemIDs.count)
        let space: PhotoSpace
        let operationItems: [Int64: PhotoItem]
        do {
            let source = mediaCollection(for: action.collection)
            guard source.incomingAlbumIdentity == nil, !source.isSessionDerived else { throw RepositoryError.unavailable("Thumbnail rotation is unavailable for this collection.") }
            space = try await itemActionSpace(itemIDs: action.itemIDs, collection: source)
            reporter.report(.preparing, itemID: nil)
            do { try await connect() }
            catch {
                SynologyDiagnostics.rotations.error(
                    "Thumbnail rotation could not connect items=\(reporter.total, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                throw ThumbnailRotationStartFailure(message: "Could not start: \(error.localizedDescription)", underlying: error)
            }
            operationItems = source.albumID != nil
                ? Dictionary(uniqueKeysWithValues: try await lookupAllRotationItems(action.itemIDs, space: space).map { ($0.id, $0) })
                : action.itemsByID
        } catch {
            reporter.finishWithoutStarting(error)
            return
        }
        let mutationCacheEpoch = metadata.admissionEpoch
        for id in action.itemIDs {
            if Task.isCancelled {
                SynologyDiagnostics.rotations.info(
                    "Thumbnail rotation cancelled before item item_id=\(id, privacy: .public) completed=\(reporter.completed, privacy: .public) total=\(reporter.total, privacy: .public)"
                )
                reporter.record(failure: "Cancelled before photo \(id).", activity: "Photo \(id): cancelled before processing.")
                break
            }
            let identity = PhotoItemIdentity(scope: .space(space), itemID: id)
            guard !itemMutations.pendingIDs.contains(identity) else {
                SynologyDiagnostics.rotations.error("Thumbnail rotation rejected pending item item_id=\(id, privacy: .public)")
                reporter.record(failure: "Photo \(id) already has a rotation in progress.",
                                activity: "Photo \(id): failed — another rotation is already in progress.")
                reporter.completed += 1
                continue
            }
            guard let item = operationItems[id], let descriptor = item.additional?.thumbnail, item.hasDisplayableStillImage else {
                SynologyDiagnostics.rotations.error("Thumbnail rotation missing eligible descriptor item_id=\(id, privacy: .public)")
                reporter.record(failure: "Photo \(id) does not have three replaceable thumbnails.",
                                activity: "Photo \(id): failed — replaceable thumbnails are unavailable.")
                reporter.completed += 1
                continue
            }
            itemMutations.pendingIDs.insert(identity)
            defer { itemMutations.pendingIDs.remove(identity) }
            do {
                let turns = try await rotateThumbnails(of: item, descriptor: descriptor, operation: operation, space: space,
                                                       action: action, mutationCacheEpoch: mutationCacheEpoch, reporter: reporter)
                reporter.activity.append(turns == 0 ? "Photo \(id): already correct."
                                                    : "Photo \(id): applied \(ThumbnailRotationReporter.rotationDescription(turns)).")
            } catch is CancellationError {
                SynologyDiagnostics.rotations.info("Thumbnail rotation cancellation handled item_id=\(id, privacy: .public)")
                reporter.record(failure: "Thumbnail rotation was cancelled.", activity: "Photo \(id): cancelled.")
                break
            } catch {
                Self.logRotationFailure("item", itemID: id, unitID: descriptor.unitID, error: error)
                reporter.record(failure: "Photo \(id): \(error.localizedDescription)",
                                activity: "Photo \(id): failed — \(error.localizedDescription)")
            }
            reporter.completed += 1
        }
        reporter.report(.finished, itemID: nil, progress: 1)
        SynologyDiagnostics.rotations.info(
            "Thumbnail rotation run finished operation=\(operation.logDescription, privacy: .public) completed=\(reporter.completed, privacy: .public) total=\(reporter.total, privacy: .public) failures=\(reporter.failures.count, privacy: .public)"
        )
        continuation.finish()
    }

    /// Replaces one photo's three thumbnails. Returns the applied clockwise quarter
    /// turns; zero means the thumbnails were already correct and nothing was written.
    private func rotateThumbnails(of item: PhotoItem, descriptor: ThumbnailInfo, operation: ThumbnailRotationOperation,
                                  space: PhotoSpace, action: SelectionRotationAction, mutationCacheEpoch: UInt64,
                                  reporter: ThumbnailRotationReporter) async throws -> Int {
        let id = item.id
        var estimate = ThumbnailRotationDownloadEstimate(item: item, includesOriginal: operation.isAutomatic)
        let downloaded = try await downloadRotationThumbnails(descriptor, itemID: id, space: space,
                                                             estimate: &estimate, reporter: reporter)
        try Task.checkCancellation()
        let turns: Int
        switch operation {
        case .manual(let direction):
            turns = direction == .clockwise ? 1 : -1
        case .automatic:
            turns = try await matchThumbnailOrientation(item, thumbnails: downloaded, space: space,
                                                        estimate: estimate, reporter: reporter)
            SynologyDiagnostics.rotations.info(
                "Matched thumbnail orientation item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) clockwise_quarter_turns=\(turns, privacy: .public)"
            )
        }
        if turns == 0 {
            SynologyDiagnostics.rotations.info(
                "Thumbnail orientation already correct item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public)"
            )
            return 0
        }
        reporter.report(.rotating, itemID: id, progress: operation.isAutomatic ? 0.6 : 0.5)
        let files = try ThumbnailOrientationMatcher.rotatedFiles(downloaded, clockwiseQuarterTurns: turns)
        reporter.report(.rotating, itemID: id, progress: 2.0 / 3.0)
        SynologyDiagnostics.rotations.info(
            "Rotated thumbnails locally item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) clockwise_quarter_turns=\(turns, privacy: .public) sm_bytes=\(files.sm.count, privacy: .public) m_bytes=\(files.m.count, privacy: .public) xl_bytes=\(files.xl.count, privacy: .public)"
        )
        try await replaceThumbnails(itemID: id, descriptor: descriptor, files: files, space: space,
                                    action: action, mutationCacheEpoch: mutationCacheEpoch, reporter: reporter)
        return turns
    }

    private func downloadRotationThumbnails(_ descriptor: ThumbnailInfo, itemID id: Int64, space: PhotoSpace,
                                            estimate: inout ThumbnailRotationDownloadEstimate,
                                            reporter: ThumbnailRotationReporter) async throws -> [ThumbnailSize: Data] {
        var downloaded: [ThumbnailSize: Data] = [:]
        for size in ThumbnailSize.allCases {
            let detail = "Downloading \(ThumbnailRotationDownloadEstimate.name(for: size)) thumbnail"
            reporter.report(.downloading, itemID: id, progress: estimate.thumbnailProgress, detail: detail)
            SynologyDiagnostics.rotations.info(
                "Downloading thumbnail for rotation item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) size=\(size.rawValue, privacy: .public) ready=\(descriptor.isReady(size), privacy: .public)"
            )
            guard descriptor.isReady(size) else {
                throw RepositoryError.unavailable("The \(size.rawValue) thumbnail is not ready.")
            }
            let response = try await client.thumbnail(descriptor, size: size, space: space, etag: nil, lastModified: nil)
            guard let data = response.data else { throw SynologyAPIError.invalidResponse }
            downloaded[size] = data
            estimate.completeThumbnail(size)
            reporter.report(.downloading, itemID: id, progress: estimate.thumbnailProgress, detail: detail)
            SynologyDiagnostics.rotations.info(
                "Downloaded thumbnail for rotation item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) size=\(size.rawValue, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
        }
        return downloaded
    }

    /// Compares the thumbnails with the original; all three must agree on one turn.
    private func matchThumbnailOrientation(_ item: PhotoItem, thumbnails: [ThumbnailSize: Data], space: PhotoSpace,
                                           estimate: ThumbnailRotationDownloadEstimate,
                                           reporter: ThumbnailRotationReporter) async throws -> Int {
        guard let resource = item.fullImageResource(in: .space(space)) else {
            throw RepositoryError.unavailable("A full-size image is unavailable.")
        }
        reporter.report(.downloading, itemID: item.id, progress: estimate.thumbnailProgress, detail: "Downloading full photo")
        let original = try await comparisonOriginal(resource) { transfer in
            reporter.report(.downloading, itemID: item.id, progress: estimate.originalProgress(transfer),
                            detail: "Downloading full photo")
        }
        try Task.checkCancellation()
        reporter.report(.analyzing, itemID: item.id, progress: 0.5)
        let match = try await ThumbnailOrientationAnalyzer.shared.match(originalData: original, item: item, thumbnails: thumbnails)
        try Task.checkCancellation()
        reporter.report(.analyzing, itemID: item.id, progress: 0.6)
        return match.clockwiseQuarterTurns
    }

    /// Leases the unit for regeneration, uploads the rotated files and waits for the
    /// new cache key. Any ambiguous failure restores the lease and rereads the item.
    private func replaceThumbnails(itemID id: Int64, descriptor: ThumbnailInfo, files: ConvertedThumbnailFiles,
                                   space: PhotoSpace, action: SelectionRotationAction, mutationCacheEpoch: UInt64,
                                   reporter: ThumbnailRotationReporter) async throws {
        func recover(_ unitID: Int64) async {
            await recoverThumbnailAfterAmbiguousFailure(action: action, itemID: id, descriptor: descriptor,
                                                        unitIDs: [unitID], space: space, mutationCacheEpoch: mutationCacheEpoch)
        }
        let units: [RegeneratingThumbnailUnit]
        do {
            units = try await client.setRegenerating(itemIDs: [id], space: space)
        } catch {
            Self.logRotationFailure("set_regenerating", itemID: id, unitID: descriptor.unitID, error: error)
            await recover(descriptor.unitID)
            throw error
        }
        guard let unit = units.first, units.count == 1, unit.unitID == descriptor.unitID,
              unit.itemID == nil || unit.itemID == id else {
            SynologyDiagnostics.rotations.error(
                "Unexpected set_regenerating result item_id=\(id, privacy: .public) descriptor_unit_id=\(descriptor.unitID, privacy: .public) returned_units=\(units.count, privacy: .public)"
            )
            await recover(descriptor.unitID)
            throw SynologyAPIError.invalidResponse
        }
        do {
            try Task.checkCancellation()
            SynologyDiagnostics.rotations.info(
                "Uploading rotated thumbnails item_id=\(id, privacy: .public) unit_id=\(unit.unitID, privacy: .public)"
            )
            reporter.report(.uploading, itemID: id, progress: 2.0 / 3.0)
            try await client.uploadConvertedThumbnails(unitID: unit.unitID, files: files, space: space) { transfer in
                reporter.report(.uploading, itemID: id, progress: 2.0 / 3.0 + (transfer.fractionCompleted ?? 0) / 3.0)
            }
            try Task.checkCancellation()
            reporter.report(.refreshing, itemID: id, progress: 1)
            let refreshed = try await waitForThumbnailRevision(itemID: id, oldCacheKey: descriptor.cacheKey, space: space)
            await publishRotationReplacements([id: refreshed], action: action, space: space, epoch: mutationCacheEpoch)
            SynologyDiagnostics.rotations.info(
                "Thumbnail rotation completed item_id=\(id, privacy: .public) unit_id=\(unit.unitID, privacy: .public)"
            )
        } catch {
            Self.logRotationFailure("upload_or_refresh", itemID: id, unitID: unit.unitID, error: error)
            await recover(unit.unitID)
            throw error
        }
    }

    /// Applies item replacements to the displayed collection, the item's space and observers.
    private func publishRotationReplacements(_ items: [Int64: PhotoItem], action: SelectionRotationAction,
                                             space: PhotoSpace, epoch: UInt64) async {
        await patchRotationPages(action: action, replacements: items, metadataEpoch: epoch)
        itemMutations.publish(PhotoItemChange(items: items, scope: .space(space)))
        let source = mediaCollection(for: action.collection)
        if source.albumID != nil {
            await patchRotationSpace(items, space: space, epoch: epoch)
            itemMutations.publish(PhotoItemChange(items: items, scope: source.contentScope))
        }
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
                failure = message.localizedDescription
            }
        }
        if let cached { return cached }
        throw SynologyAPIError.transport(failure ?? "The full-size image is unavailable.")
    }

    private func lookupAllRotationItems(_ ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
        var result: [PhotoItem] = []
        for start in stride(from: 0, to: ids.count, by: 1_000) {
            let requested = Array(ids[start..<min(start + 1_000, ids.count)])
            let items = try await client.items(ids: requested, space: space)
            guard items.count == requested.count, Set(items.map(\.id)) == Set(requested) else { throw SynologyAPIError.invalidResponse }
            result.append(contentsOf: items)
        }
        return result
    }

    private func waitForThumbnailRevision(itemID: Int64, oldCacheKey: String, space: PhotoSpace) async throws -> PhotoItem {
        for attempt in 0..<8 {
            try Task.checkCancellation()
            if let item = try await lookupAllRotationItems([itemID], space: space).first {
                let changed = item.additional?.thumbnail.map { $0.cacheKey != oldCacheKey } ?? false
                SynologyDiagnostics.rotations.debug(
                    "Polled thumbnail revision item_id=\(itemID, privacy: .public) attempt=\(attempt + 1, privacy: .public) changed=\(changed, privacy: .public)"
                )
                if changed { return item }
            }
            if attempt < 7 { try await Task.sleep(for: .milliseconds(250)) }
        }
        throw SynologyAPIError.invalidResponse
    }

    private func restoreRegeneratingUnits(_ unitIDs: [Int64], space: PhotoSpace) async {
        let client = client
        SynologyDiagnostics.rotations.info(
            "Restoring regenerating thumbnail units count=\(unitIDs.count, privacy: .public) first_unit_id=\(unitIDs.first ?? -1, privacy: .public)"
        )
        await Task.detached(priority: .utility) {
            do {
                try await client.restoreFromRegenerating(unitIDs: unitIDs, space: space)
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
        space: PhotoSpace,
        mutationCacheEpoch: UInt64
    ) async {
        await restoreRegeneratingUnits(unitIDs, space: space)
        let client = client
        let refreshed = await Task.detached(priority: .utility) { () -> PhotoItem? in
            for attempt in 0..<8 {
                if let item = try? await client.items(ids: [itemID], space: space).first,
                   item.additional?.thumbnail.map({ $0.cacheKey != descriptor.cacheKey }) == true {
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
        await publishRotationReplacements([itemID: refreshed], action: action, space: space, epoch: mutationCacheEpoch)
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
        guard isAdmitted(epoch) else { return }
        let scoped = MetadataNamespace(account: namespace, scope: .space(space))
        guard let admission = try? await store.metadataAdmission(scoped), epoch == metadata.admissionEpoch else { return }
        try? await store.applyMetadataRotationValues(items, namespace: scoped, admission: admission)
    }

    private func patchRotationPages(action: SelectionRotationAction,
                                    replacements: [Int64: PhotoItem], metadataEpoch: UInt64) async {
        guard isAdmitted(metadataEpoch) else { return }
        let scopedNamespace = metadataNamespace(for: action.collection)
        if metadata.initialized,
           replacements.values.allSatisfy({ $0.pendingRotationQuarterTurns == 0 }),
           let admission = try? await store.metadataAdmission(scopedNamespace) {
            guard isAdmitted(metadataEpoch) else { return }
            try? await store.applyMetadataRotationValues(replacements, namespace: scopedNamespace, admission: admission)
            guard isAdmitted(metadataEpoch) else { return }
            let canonical = try? await store.metadataDetails(scopedNamespace, ids: Array(replacements.keys), currentRun: runID)
            guard metadataEpoch == metadata.admissionEpoch else { return }
            if scopedNamespace.scope == .space(.personal) { publishLocationItemChanges(canonical?.values.compactMap(\.item) ?? []) }
            else if scopedNamespace.scope == .space(.shared) { await publishSharedLocationItemChanges(canonical?.values.compactMap(\.item) ?? []) }
        }

    }

    private func removeItemMutationObserver(_ id: UUID) { itemMutations.observers.removeValue(forKey: id) }
}
