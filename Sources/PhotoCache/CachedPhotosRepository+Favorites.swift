import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    func favoriteState(for space: PhotoSpace) -> RepositoryFavoriteState { space == .shared ? sharedFavorites : favorites }

    public func favoriteChanges(space: PhotoSpace) -> AsyncStream<FavoriteChange> {
        let id = UUID()
        let favorites = favoriteState(for: space)
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            favorites.observers[id] = continuation
            if !favorites.overrides.isEmpty {
                continuation.yield(FavoriteChange(values: favorites.overrides, sourceCollection: space == .shared ? .library(.shared) : .library(.personal)))
            }
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeFavoriteObserver(id, space: space) }
            }
        }
    }

    /// Single-item convenience wrapper over setFavoritesBatch so viewer behavior
    /// does not fork into a separate pipeline.
    public func setFavorite(itemID: Int64, item: PhotoItem? = nil,
                            in section: TimelineSection,
                            collection: PhotoCollectionDescriptor,
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
        let source = mediaCollection(for: action.collection)
        guard source.incomingAlbumIdentity == nil, !source.isSessionDerived else {
            throw SynologyAPIError.unsupported("Favorites are unavailable for shared album photos.")
        }
        let space = try await itemActionSpace(itemIDs: action.affectedIDs, collection: source)
        let favorites = favoriteState(for: space)
        let favoriteCollection: PhotoCollectionDescriptor = space == .shared ? .favorites(.shared) : .favorites(.personal)
        let scopedNamespace = MetadataNamespace(account: namespace, scope: .space(space))
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
                    favorites.pendingIDs.remove(id)
                }
            }
            await previous?.value
            favorites.refreshTask?.cancel()
            if let expectedFingerprint = action.expectedTimelineFingerprint {
                guard let currentSnapshot = self.metadata.latestTimelines[action.collection],
                      LibraryIndex(snapshot: currentSnapshot).fingerprint == expectedFingerprint else {
                    throw SynologyAPIError.unsupported(
                        "The collection changed before the favorite update. Try again."
                    )
                }
            }
            // Advance the Favorites mutation epoch once before the action
            self.metadata.mutationEpochs[favoriteCollection, default: 0] &+= 1
            let metadataToken = try await self.captureMetadataWorkToken(
                resource: .mutation, jobID: UUID()
            )

            if self.metadata.initialized, let admission = try? await self.store.metadataAdmission(scopedNamespace) {
                try? await self.store.invalidateMetadataCollection(CollectionKey(namespace: scopedNamespace, collection: favoriteCollection), admission: admission)
            }

            // Record previous values for all affected IDs
            var previousValues: [Int64: Bool] = [:]
            for id in allIDs {
                let prev = favorites.overrides[id] ?? action.itemsByID[id]?.isFavorite ?? !target
                previousValues[id] = prev
            }

            // Apply one uniform target value to affected IDs in favorites.overrides
            // and publish one batched favorite change
            var targetMap: [Int64: Bool] = [:]
            for id in allIDs {
                targetMap[id] = target
            }
            favorites.publish(
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
                        try await self.client.setFavorite(itemIDs: chunk, favorite: target, space: space)
                        successfulIDs.append(contentsOf: chunk)
                        if await self.metadataTokenIsCurrent(metadataToken), self.metadata.initialized,
                           let admission = try? await self.store.metadataAdmission(scopedNamespace) {
                            try? await self.store.applyMetadataFavoriteValues(Dictionary(uniqueKeysWithValues: chunk.map { ($0, target) }),
                                                                             namespace: scopedNamespace, currentRun: self.runID, admission: admission)
                            if source.albumID != nil {
                                let albumNamespace = self.metadataNamespace(for: source)
                                if let albumAdmission = try? await self.store.metadataAdmission(albumNamespace) {
                                    try? await self.store.applyMetadataFavoriteValues(Dictionary(uniqueKeysWithValues: chunk.map { ($0, target) }), namespace: albumNamespace, currentRun: self.runID, admission: albumAdmission)
                                }
                                self.itemMutations.publish(PhotoItemChange(items: [:], favoriteValues: Dictionary(uniqueKeysWithValues: chunk.map { ($0, target) }), scope: source.contentScope))
                            }
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
                self.metadata.mutationEpochs[favoriteCollection, default: 0] &+= 1

                // Roll back failed and unsubmitted IDs only
                var rollbackMap: [Int64: Bool] = [:]
                for id in failedOrUnsubmittedIDs {
                    rollbackMap[id] = previousValues[id] ?? !target
                }
                favorites.publish(
                    values: rollbackMap,
                    section: action.sectionsByID.values.first,
                    collection: action.collection
                )

                // Reapply previous values to affected cached page entries

                // Refresh authoritative Favorites timeline after any success or ambiguous state
                if favorites.metadataDirty || !successfulIDs.isEmpty || attemptedWrite {
                    self.scheduleFavoritesRefresh(space: space)
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

            favorites.metadataDirty = true
            self.scheduleFavoritesRefresh(space: space)
        }

        favorites.writeTail = Task { _ = try? await operation.value }
        try await operation.value
    }

    private func cachedItem(itemID: Int64, section: TimelineSection,
                            collection: PhotoCollectionDescriptor) async -> PhotoItem? {
        guard metadata.initialized,
              let details = try? await store.metadataDetails(metadataNamespace(for: collection), ids: [itemID], currentRun: runID) else { return nil }
        return details[itemID]?.item
    }

    func scheduleFavoritesRefresh(space: PhotoSpace) {
        let favorites = favoriteState(for: space)
        let collection: PhotoCollectionDescriptor = space == .shared ? .favorites(.shared) : .favorites(.personal)
        favorites.refreshTask?.cancel()
        let epoch = metadata.mutationEpochs[collection, default: 0]
        favorites.refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
            await self?.refreshFavoritesAfterMutation(epoch: epoch, space: space)
        }
    }

    private func refreshFavoritesAfterMutation(epoch: UInt64, space: PhotoSpace) async {
        let collection: PhotoCollectionDescriptor = space == .shared ? .favorites(.shared) : .favorites(.personal)
        let favorites = favoriteState(for: space)
        let scopedNamespace = metadataNamespace(for: collection)
        metadata.timelineJobs.removeValue(forKey: collection)?.task.cancel()
        let id = UUID()
        do {
            let token = try await captureMetadataWorkToken(
                resource: .transient(collection), jobID: id, collection: collection
            )
            try await initializeMetadataEngine()
            try await connect()
            try await reconcileMetadataSource(for: collection)
            let admission = try await store.metadataAdmission(scopedNamespace)
            let catalog = try await acquireCollectionCatalog(collection).catalog
            guard epoch == metadata.mutationEpochs[collection, default: 0], await metadataTokenIsCurrent(token) else { return }
            try await store.storeMetadataCatalog(catalog, key: CollectionKey(namespace: scopedNamespace, collection: collection),
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

    private func removeFavoriteObserver(_ id: UUID, space: PhotoSpace) { favoriteState(for: space).observers.removeValue(forKey: id) }
}
