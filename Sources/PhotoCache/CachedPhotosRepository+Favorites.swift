import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    public func favoriteChanges() -> AsyncStream<FavoriteChange> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            favorites.observers[id] = continuation
            if !favorites.overrides.isEmpty {
                continuation.yield(FavoriteChange(values: favorites.overrides))
            }
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeFavoriteObserver(id) }
            }
        }
    }

    /// Single-item convenience wrapper over setFavoritesBatch so viewer behavior
    /// does not fork into a separate pipeline.
    public func setFavorite(itemID: Int64, item: PhotoItem? = nil,
                            in section: TimelineSection,
                            collection: PhotoCollectionDescriptor = .personalLibrary,
                            to favorite: Bool) async throws {
        var itemsByID: [Int64: PhotoItem] = [:]
        if let item {
            itemsByID[itemID] = item
        } else if let cached = await cachedItem(itemID: itemID, section: section, collection: collection) {
            itemsByID[itemID] = cached
        }
        let action = SelectionFavoriteAction(
            affectedIDs: [itemID],
            targetFavorite: favorite,
            sectionsByID: [itemID: section],
            collection: collection,
            itemsByID: itemsByID
        )
        try await setFavoritesBatch(action: action)
    }

    /// Executes an already-prepared batch favorite mutation with chunking, optimistic publication,
    /// rollback on failure, and an authoritative Favorites refresh.
    public func setFavoritesBatch(action: SelectionFavoriteAction) async throws {
        let allIDs = action.affectedIDs
        guard !allIDs.isEmpty else { return }
        let target = action.targetFavorite

        // 1. Atomically reject or claim every affected ID against pendingIDs
        for id in allIDs {
            guard !favorites.pendingIDs.contains(id) else {
                throw SynologyAPIError.unsupported("A favorite change is already in progress.")
            }
        }
        for id in allIDs {
            favorites.pendingIDs.insert(id)
        }

        let previous = favorites.writeTail
        let operation = Task<Void, Error> {
            defer {
                for id in allIDs {
                    self.favorites.pendingIDs.remove(id)
                }
            }
            await previous?.value
            self.favorites.refreshTask?.cancel()
            if let expectedFingerprint = action.expectedTimelineFingerprint {
                guard let currentSnapshot = self.metadata.latestTimelines[action.collection],
                      LibraryIndex(snapshot: currentSnapshot).fingerprint == expectedFingerprint else {
                    throw SynologyAPIError.unsupported(
                        "The collection changed before the favorite update. Try again."
                    )
                }
            }
            let generation = await self.store.currentGeneration()

            // Advance the Favorites mutation epoch once before the action
            self.metadata.mutationEpochs[.favorites, default: 0] &+= 1

            // Record previous values for all affected IDs
            var previousValues: [Int64: Bool] = [:]
            for id in allIDs {
                let prev = self.favorites.overrides[id] ?? action.itemsByID[id]?.isFavorite ?? !target
                previousValues[id] = prev
            }

            // Apply one uniform target value to affected IDs in favorites.overrides
            // and publish one batched favorite change
            var targetMap: [Int64: Bool] = [:]
            for id in allIDs {
                targetMap[id] = target
            }
            self.favorites.publish(
                values: targetMap,
                section: action.sectionsByID.values.first,
                collection: action.collection
            )

            // Patch cached Personal Library pages by grouping changes per cache key
            // and decoding/encoding each affected page once
            var transaction = BatchFavoriteMutationTransaction()
            await self.patchPersonalPagesBatch(
                action: action,
                target: target,
                generation: generation,
                transaction: &transaction
            )

            // Connect once, then call transport sequentially in fixed-size chunks
            let chunkSize = 100
            let chunks = stride(from: 0, to: allIDs.count, by: chunkSize).map {
                Array(allIDs[$0..<min($0 + chunkSize, allIDs.count)])
            }

            var successfulIDs: [Int64] = []
            var failedOrUnsubmittedIDs: [Int64] = []
            var writeError: (any Error)? = nil
            var attemptedWrite = false

            do {
                try await self.connect()
                for (chunkIndex, chunk) in chunks.enumerated() {
                    do {
                        attemptedWrite = true
                        try await self.client.setFavorite(itemIDs: chunk, favorite: target)
                        successfulIDs.append(contentsOf: chunk)
                    } catch {
                        writeError = error
                        let failedStart = chunkIndex * chunkSize
                        failedOrUnsubmittedIDs = Array(allIDs[failedStart...])
                        break
                    }
                }
            } catch {
                writeError = error
                failedOrUnsubmittedIDs = allIDs
            }

            if !failedOrUnsubmittedIDs.isEmpty {
                // Advance mutation epoch to reject older in-flight Favorites metadata
                self.metadata.mutationEpochs[.favorites, default: 0] &+= 1

                // Roll back failed and unsubmitted IDs only
                var rollbackMap: [Int64: Bool] = [:]
                for id in failedOrUnsubmittedIDs {
                    rollbackMap[id] = previousValues[id] ?? !target
                }
                self.favorites.publish(
                    values: rollbackMap,
                    section: action.sectionsByID.values.first,
                    collection: action.collection
                )

                // Reapply previous values to affected cached page entries
                await self.rollbackBatchFavoriteCaches(
                    transaction: transaction,
                    failedIDs: Set(failedOrUnsubmittedIDs),
                    previousValues: previousValues,
                    generation: generation
                )

                // Refresh authoritative Favorites timeline after any success or ambiguous state
                if self.favorites.metadataDirty || !successfulIDs.isEmpty || attemptedWrite {
                    self.scheduleFavoritesRefresh()
                }

                let outcome = BatchFavoriteOutcome(
                    successfulCount: successfulIDs.count,
                    failedCount: failedOrUnsubmittedIDs.count
                )
                throw BatchFavoriteError(
                    outcome: outcome,
                    underlyingError: writeError ?? SynologyAPIError.unsupported("Write failed")
                )
            }

            self.favorites.metadataDirty = true
            self.scheduleFavoritesRefresh()
        }

        favorites.writeTail = Task { _ = try? await operation.value }
        try await operation.value
    }

    private func cachedItem(itemID: Int64, section: TimelineSection,
                            collection: PhotoCollectionDescriptor) async -> PhotoItem? {
        guard let key = CacheKey.page(namespace: namespace, section: section, collection: collection),
              let cached = try? await store.get(key),
              let items = try? JSONDecoder().decode([PhotoItem].self, from: cached.data) else { return nil }
        return items.first(where: { $0.id == itemID })
    }

    private func patchPersonalPagesBatch(
        action: SelectionFavoriteAction,
        target: Bool,
        generation: Int,
        transaction: inout BatchFavoriteMutationTransaction
    ) async {
        let itemIDSet = Set(action.affectedIDs)
        var candidateSections: [TimelineSection] = []

        if action.collection == .personalLibrary {
            var seenSections: Set<TimelineSection> = []
            for id in action.affectedIDs {
                if let sec = action.sectionsByID[id], seenSections.insert(sec).inserted {
                    candidateSections.append(sec)
                }
            }
        } else if let snapshot = metadata.latestTimelines[.personalLibrary] {
            // For favorites collection, find personal library sections by item dates
            var targetDays: Set<TimelineDay> = []
            var hadUnknownDay = false
            for id in action.affectedIDs {
                if let item = action.itemsByID[id], let day = utcDay(for: item) {
                    targetDays.insert(day)
                } else {
                    hadUnknownDay = true
                }
            }
            if hadUnknownDay {
                candidateSections = snapshot.sections
            } else {
                candidateSections = snapshot.sections.filter { section in
                    section.list.contains(where: { day in targetDays.contains(where: { sameDay($0, day) }) })
                }
            }
        }

        var seenKeys: Set<String> = []
        for section in candidateSections {
            guard let key = CacheKey.page(namespace: namespace, section: section, collection: .personalLibrary),
                  seenKeys.insert(key).inserted,
                  let cached = try? await store.get(key),
                  let items = try? JSONDecoder().decode([PhotoItem].self, from: cached.data) else { continue }

            let hasAffectedItems = items.contains { itemIDSet.contains($0.id) }
            guard hasAffectedItems else { continue }

            transaction.cacheBackups[key] = BatchFavoriteCacheBackup(kind: .page, entry: cached)
            let updatedItems = items.map { item -> PhotoItem in
                if itemIDSet.contains(item.id) {
                    return item.withFavorite(target)
                }
                return item
            }
            guard let bytes = try? JSONEncoder().encode(updatedItems) else { continue }
            try? await store.put(key, kind: .page, data: bytes,
                                 validatedRun: cached.validatedRun,
                                 etag: cached.etag, lastModified: cached.lastModified,
                                 expectedGeneration: generation)
        }
    }

    private func rollbackBatchFavoriteCaches(
        transaction: BatchFavoriteMutationTransaction,
        failedIDs: Set<Int64>,
        previousValues: [Int64: Bool],
        generation: Int
    ) async {
        guard await store.currentGeneration() == generation else { return }
        for (key, backup) in transaction.cacheBackups {
            guard let originalEntry = backup.entry,
                  let items = try? JSONDecoder().decode([PhotoItem].self, from: originalEntry.data) else { continue }
            let hasFailedItems = items.contains { failedIDs.contains($0.id) }
            guard hasFailedItems else { continue }

            let currentStored = (try? await store.get(key))?.data
            let currentItems = (currentStored.flatMap { try? JSONDecoder().decode([PhotoItem].self, from: $0) }) ?? items

            let rolledBackItems = currentItems.map { item -> PhotoItem in
                if failedIDs.contains(item.id) {
                    let prev = previousValues[item.id] ?? item.isFavorite
                    return item.withFavorite(prev)
                }
                return item
            }
            guard let bytes = try? JSONEncoder().encode(rolledBackItems) else { continue }
            try? await store.put(key, kind: backup.kind, data: bytes,
                                 validatedRun: originalEntry.validatedRun,
                                 etag: originalEntry.etag, lastModified: originalEntry.lastModified,
                                 expectedGeneration: generation)
        }
    }

    func scheduleFavoritesRefresh() {
        favorites.refreshTask?.cancel()
        let epoch = metadata.mutationEpochs[.favorites, default: 0]
        favorites.refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
            await self?.refreshFavoritesAfterMutation(epoch: epoch)
        }
    }

    private func refreshFavoritesAfterMutation(epoch: UInt64) async {
        let collection = PhotoCollectionDescriptor.favorites
        metadata.timelineJobs.removeValue(forKey: collection)?.task.cancel()
        let id = UUID()
        do {
            try await gate.acquire(.metadata, priority: .visible, id: id)
            defer { Task { await gate.release(.metadata) } }
            try await connect()
            let snapshot = try await client.timeline(collection: collection, initial: false)
            guard epoch == metadata.mutationEpochs[collection, default: 0] else { return }
            let generation = await store.currentGeneration()
            metadata.latestTimelines[collection] = snapshot
            if let bytes = try? JSONEncoder().encode(snapshot) {
                try? await store.put(CacheKey.timeline(namespace: namespace, collection: collection),
                                     kind: .timeline, data: bytes,
                                     validatedRun: validationRun(for: collection),
                                     expectedGeneration: generation)
            }
            publishTimelineProjection(snapshot, collection: collection)
            favorites.metadataDirty = false
            favorites.refreshTask = nil
        } catch {
            guard epoch == metadata.mutationEpochs[collection, default: 0],
                  !(error is CancellationError) else { return }
            for observer in metadata.refreshObservers[collection]?.values ?? [:].values {
                observer.yield(.failure("Favorites refresh: \(error.localizedDescription)"))
            }
            favorites.refreshTask = nil
        }
    }

    private func publishTimelineProjection(_ snapshot: TimelineSnapshot,
                                           collection: PhotoCollectionDescriptor,
                                           verified: Bool = true) {
        for observer in metadata.refreshObservers[collection]?.values ?? [:].values {
            observer.yield(.value(snapshot, verified: verified))
        }
    }

    func utcDay(for item: PhotoItem) -> TimelineDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day],
                                                  from: Date(timeIntervalSince1970: TimeInterval(item.time)))
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return TimelineDay(year: year, month: month, day: day, itemCount: 0)
    }

    func sameDay(_ lhs: TimelineDay, _ rhs: TimelineDay) -> Bool {
        lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day
    }

    private func removeFavoriteObserver(_ id: UUID) { favorites.observers.removeValue(forKey: id) }
}

private struct BatchFavoriteCacheBackup: Sendable {
    let kind: CacheKind
    let entry: CacheEntry?
}

private struct BatchFavoriteMutationTransaction: Sendable {
    var cacheBackups: [String: BatchFavoriteCacheBackup] = [:]
}
