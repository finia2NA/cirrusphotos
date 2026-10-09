import CoreGraphics
import Foundation
import ImageIO
import SynologyAPI
import UniformTypeIdentifiers

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
        guard !action.itemIDs.isEmpty else { return }
        guard action.itemIDs.allSatisfy({ action.itemsByID[$0]?.hasDisplayableStillImage == true }) else {
            throw SynologyAPIError.unsupported("Only photos and Live Photo still images can be rotated.")
        }
        for id in action.itemIDs {
            guard !itemMutations.pendingIDs.contains(id) else {
                throw SynologyAPIError.unsupported("A rotation is already in progress for one of these photos.")
            }
        }
        for id in action.itemIDs { itemMutations.pendingIDs.insert(id) }
        defer { for id in action.itemIDs { itemMutations.pendingIDs.remove(id) } }

        let originals = action.itemsByID
        let optimistic = originals.mapValues { $0.rotated(direction) }
        itemMutations.publish(PhotoItemChange(
            items: optimistic,
            quarterTurns: Dictionary(uniqueKeysWithValues: action.itemIDs.map {
                ($0, direction == .clockwise ? 1 : -1)
            })
        ))
        await patchRotationPages(action: action, replacements: optimistic)
        var attemptedWrite = false
        do {
            try await connect()
            for chunkStart in stride(from: 0, to: action.itemIDs.count, by: 100) {
                let chunk = Array(action.itemIDs[chunkStart..<min(chunkStart + 100, action.itemIDs.count)])
                attemptedWrite = true
                try await client.rotate(itemIDs: chunk, direction: direction)
            }
            let refreshed = try await lookupAllRotationItems(action.itemIDs)
            guard refreshed.count == action.itemIDs.count else { throw SynologyAPIError.invalidResponse }
            let replacements = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
            await patchRotationPages(action: action, replacements: replacements)
            itemMutations.publish(PhotoItemChange(items: replacements))
        } catch {
            var recovery = originals
            if attemptedWrite, let refreshed = try? await lookupAllRotationItems(action.itemIDs) {
                for item in refreshed { recovery[item.id] = item }
            }
            await patchRotationPages(action: action, replacements: recovery)
            itemMutations.publish(PhotoItemChange(items: recovery))
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
                await self.runThumbnailRotation(action, direction: direction, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in producer.task?.cancel() }
        }
    }

    private func runThumbnailRotation(
        _ action: SelectionRotationAction,
        direction: PhotoRotationDirection,
        continuation: AsyncStream<ThumbnailRotationProgress>.Continuation
    ) async {
        let total = action.itemIDs.count
        var completed = 0
        var failures: [String] = []
        var claimedIDs: Set<Int64> = []
        defer {
            for id in claimedIDs { itemMutations.pendingIDs.remove(id) }
        }
        continuation.yield(.init(completedItems: 0, totalItems: total, itemID: nil, stage: .preparing))
        do { try await connect() }
        catch {
            SynologyDiagnostics.rotations.error(
                "Thumbnail rotation could not connect items=\(total, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            continuation.yield(.init(completedItems: 0, totalItems: total, itemID: nil,
                                     stage: .finished, failures: [error.localizedDescription]))
            continuation.finish(); return
        }
        for id in action.itemIDs {
            if Task.isCancelled {
                SynologyDiagnostics.rotations.info(
                    "Thumbnail rotation cancelled before item item_id=\(id, privacy: .public) completed=\(completed, privacy: .public) total=\(total, privacy: .public)"
                )
                failures.append("Cancelled before photo \(id).")
                break
            }
            guard !itemMutations.pendingIDs.contains(id) else {
                SynologyDiagnostics.rotations.error(
                    "Thumbnail rotation rejected pending item item_id=\(id, privacy: .public)"
                )
                failures.append("Photo \(id) already has a rotation in progress.")
                completed += 1
                continue
            }
            itemMutations.pendingIDs.insert(id)
            claimedIDs.insert(id)
            guard let item = action.itemsByID[id], let descriptor = item.additional?.thumbnail,
                  item.hasDisplayableStillImage else {
                SynologyDiagnostics.rotations.error(
                    "Thumbnail rotation missing eligible descriptor item_id=\(id, privacy: .public)"
                )
                failures.append("Photo \(id) does not have three replaceable thumbnails.")
                completed += 1
                itemMutations.pendingIDs.remove(id)
                claimedIDs.remove(id)
                continue
            }
            do {
                continuation.yield(.init(completedItems: completed, totalItems: total,
                                         itemID: id, stage: .downloading, failures: failures))
                var downloaded: [ThumbnailSize: Data] = [:]
                for size in ThumbnailSize.allCases {
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
                    SynologyDiagnostics.rotations.info(
                        "Downloaded thumbnail for rotation item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) size=\(size.rawValue, privacy: .public) bytes=\(data.count, privacy: .public)"
                    )
                }
                try Task.checkCancellation()
                continuation.yield(.init(completedItems: completed, totalItems: total,
                                         itemID: id, stage: .rotating, failures: failures))
                let files = try Self.rotatedFiles(downloaded, direction: direction)
                SynologyDiagnostics.rotations.info(
                    "Rotated thumbnails locally item_id=\(id, privacy: .public) unit_id=\(descriptor.unitID, privacy: .public) sm_bytes=\(files.sm.count, privacy: .public) m_bytes=\(files.m.count, privacy: .public) xl_bytes=\(files.xl.count, privacy: .public)"
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
                        unitIDs: [descriptor.unitID]
                    )
                    throw error
                }
                guard let unit = units.first, units.count == 1 else {
                    SynologyDiagnostics.rotations.error(
                        "Unexpected set_regenerating result item_id=\(id, privacy: .public) descriptor_unit_id=\(descriptor.unitID, privacy: .public) returned_units=\(units.count, privacy: .public)"
                    )
                    await recoverThumbnailAfterAmbiguousFailure(
                        action: action, itemID: id, descriptor: descriptor,
                        unitIDs: Array(Set(units.map(\.unitID) + [descriptor.unitID]))
                    )
                    throw SynologyAPIError.invalidResponse
                }
                do {
                    try Task.checkCancellation()
                    SynologyDiagnostics.rotations.info(
                        "Uploading rotated thumbnails item_id=\(id, privacy: .public) unit_id=\(unit.unitID, privacy: .public)"
                    )
                    continuation.yield(.init(completedItems: completed, totalItems: total,
                                             itemID: id, stage: .uploading, failures: failures))
                    try await client.uploadConvertedThumbnails(unitID: unit.unitID, files: files)
                    try Task.checkCancellation()
                    continuation.yield(.init(completedItems: completed, totalItems: total,
                                             itemID: id, stage: .refreshing, failures: failures))
                    let refreshedItem = try await waitForThumbnailRevision(itemID: id,
                                                                           oldCacheKey: descriptor.cacheKey)
                    await patchRotationPages(action: action, replacements: [id: refreshedItem])
                    itemMutations.publish(PhotoItemChange(items: [id: refreshedItem]))
                    SynologyDiagnostics.rotations.info(
                        "Thumbnail rotation completed item_id=\(id, privacy: .public) unit_id=\(unit.unitID, privacy: .public)"
                    )
                } catch {
                    Self.logRotationFailure(
                        "upload_or_refresh", itemID: id, unitID: unit.unitID, error: error
                    )
                    await recoverThumbnailAfterAmbiguousFailure(
                        action: action, itemID: id, descriptor: descriptor,
                        unitIDs: [unit.unitID]
                    )
                    throw error
                }
            } catch is CancellationError {
                SynologyDiagnostics.rotations.info(
                    "Thumbnail rotation cancellation handled item_id=\(id, privacy: .public)"
                )
                failures.append("Thumbnail rotation was cancelled.")
                break
            } catch {
                Self.logRotationFailure(
                    "item", itemID: id, unitID: descriptor.unitID, error: error
                )
                failures.append("Photo \(id): \(error.localizedDescription)")
            }
            completed += 1
            itemMutations.pendingIDs.remove(id)
            claimedIDs.remove(id)
        }
        continuation.yield(.init(completedItems: completed, totalItems: total, itemID: nil,
                                 stage: .finished, failures: failures))
        SynologyDiagnostics.rotations.info(
            "Thumbnail rotation run finished completed=\(completed, privacy: .public) total=\(total, privacy: .public) failures=\(failures.count, privacy: .public)"
        )
        continuation.finish()
    }

    private func lookupAllRotationItems(_ ids: [Int64]) async throws -> [PhotoItem] {
        var result: [PhotoItem] = []
        for start in stride(from: 0, to: ids.count, by: 1_000) {
            result.append(contentsOf: try await client.items(ids: Array(ids[start..<min(start + 1_000, ids.count)])))
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
        unitIDs: [Int64]
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
        await patchRotationPages(action: action, replacements: [itemID: refreshed])
        itemMutations.publish(PhotoItemChange(items: [itemID: refreshed]))
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

    private func patchRotationPages(action: SelectionRotationAction,
                                    replacements: [Int64: PhotoItem]) async {
        var sections: Set<TimelineSection> = []
        for id in replacements.keys {
            if let section = action.sectionsByID[id] { sections.insert(section) }
        }
        for section in sections {
            guard let key = CacheKey.page(namespace: namespace, section: section,
                                          collection: action.collection) else { continue }
            for _ in 0..<3 {
                guard let cached = try? await store.get(key),
                      let items = try? JSONDecoder().decode([PhotoItem].self, from: cached.data),
                      let data = try? JSONEncoder().encode(items.map { replacements[$0.id] ?? $0 }) else { break }
                let generation = await store.currentGeneration()
                let metadataGeneration = await store.currentMetadataGeneration()
                let result = try? await store.putMetadata(
                    key, kind: .page, data: data, validatedRun: cached.validatedRun,
                    etag: cached.etag, lastModified: cached.lastModified,
                    expectedGeneration: generation, expectedMetadataGeneration: metadataGeneration,
                    replacing: .revision(cached.revision)
                )
                if result == .superseded { continue }
                break
            }
        }
        if action.collection.isMapFilter {
            for (key, items) in metadata.mapFilterPages {
                metadata.mapFilterPages[key] = items.map { replacements[$0.id] ?? $0 }
            }
        }
    }

    nonisolated private static func rotatedFiles(
        _ downloaded: [ThumbnailSize: Data], direction: PhotoRotationDirection
    ) throws -> ConvertedThumbnailFiles {
        ConvertedThumbnailFiles(
            sm: try rotateJPEG(downloaded[.sm], direction: direction),
            m: try rotateJPEG(downloaded[.m], direction: direction),
            xl: try rotateJPEG(downloaded[.xl], direction: direction)
        )
    }

    nonisolated private static func rotateJPEG(_ data: Data?, direction: PhotoRotationDirection) throws -> Data {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SynologyAPIError.invalidResponse
        }
        let width = image.width, height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: height, height: width,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw SynologyAPIError.invalidResponse
        }
        context.translateBy(x: CGFloat(height) / 2, y: CGFloat(width) / 2)
        context.rotate(by: direction == .clockwise ? -.pi / 2 : .pi / 2)
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rotated = context.makeImage() else { throw SynologyAPIError.invalidResponse }
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
