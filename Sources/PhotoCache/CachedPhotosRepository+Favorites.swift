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
        guard mediaCollection(for: action.collection) == .personalLibrary else {
            throw SynologyAPIError.unsupported("Favorites are unavailable for shared album photos.")
        }
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
            // Advance the Favorites mutation epoch once before the action
            self.metadata.mutationEpochs[.favorites, default: 0] &+= 1
            let metadataToken = try await self.captureMetadataWorkToken(
                resource: .mutation, jobID: UUID()
            )

            if self.metadata.initialized, let admission = try? await self.store.metadataAdmission(self.metadataNamespace) {
                try? await self.store.invalidateMetadataCollection(CollectionKey(namespace: self.metadataNamespace, collection: .favorites), admission: admission)
            }

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
                        if await self.metadataTokenIsCurrent(metadataToken), self.metadata.initialized,
                           let admission = try? await self.store.metadataAdmission(self.metadataNamespace) {
                            try? await self.store.applyMetadataFavoriteValues(Dictionary(uniqueKeysWithValues: chunk.map { ($0, target) }),
                                                                             namespace: self.metadataNamespace, currentRun: self.runID, admission: admission)
                        }
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
        guard metadata.initialized,
              let details = try? await store.metadataDetails(metadataNamespace, ids: [itemID], currentRun: runID) else { return nil }
        return details[itemID]?.item
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
            let token = try await captureMetadataWorkToken(
                resource: .transient(collection), jobID: id, collection: collection
            )
            try await initializeMetadataEngine()
            try await connect()
            try await reconcileMetadataSource()
            let admission = try await store.metadataAdmission(metadataNamespace)
            let catalog = try await acquireCollectionCatalog(collection).catalog
            guard epoch == metadata.mutationEpochs[collection, default: 0], await metadataTokenIsCurrent(token) else { return }
            try await store.storeMetadataCatalog(catalog, key: CollectionKey(namespace: metadataNamespace, collection: collection),
                                                 validatedRun: runID, admission: admission, invalidateMembership: true)
            guard epoch == metadata.mutationEpochs[collection, default: 0], await metadataTokenIsCurrent(token) else { return }
            let snapshot = try CollectionDayPager.snapshot(catalog: catalog)
            metadata.latestTimelines[collection] = snapshot
            publishTimelineProjection(snapshot, collection: collection)
            publishMetadataInvalidation(collection: collection)
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

    func publishTimelineProjection(_ snapshot: TimelineSnapshot,
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
