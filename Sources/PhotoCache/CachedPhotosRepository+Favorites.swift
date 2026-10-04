import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    public func favoriteChanges() -> AsyncStream<FavoriteChange> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            favorites.observers[id] = continuation
            for change in favorites.latestChanges.values { continuation.yield(change) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeFavoriteObserver(id) }
            }
        }
    }

    /// The independent task survives a viewer closing after the request starts. Writes
    /// are serialized; membership/order is reconciled from the NAS after successful writes.
    public func setFavorite(itemID: Int64, item: PhotoItem? = nil,
                            in section: TimelineSection,
                            collection: PhotoCollectionDescriptor = .personalLibrary,
                            to favorite: Bool) async throws {
        guard favorites.pendingIDs.insert(itemID).inserted else {
            throw SynologyAPIError.unsupported("A favorite change is already in progress.")
        }
        let previous = favorites.writeTail
        let operation = Task<Void, Error> {
            defer { favorites.pendingIDs.remove(itemID) }
            await previous?.value
            favorites.refreshTask?.cancel()
            let generation = await store.currentGeneration()
            var transaction = FavoriteMutationTransaction(
                previousFavorite: favorites.overrides[itemID] ?? item?.isFavorite ?? !favorite)
            metadata.mutationEpochs[.favorites, default: 0] &+= 1
            favorites.publish(itemID: itemID, section: section, favorite: favorite)
            let resolvedItem: PhotoItem?
            if let item {
                resolvedItem = item
            } else {
                resolvedItem = await cachedItem(itemID: itemID, section: section,
                                                collection: collection)
            }
            await patchPersonalPages(itemID: itemID, item: resolvedItem, sourceSection: section,
                                     sourceCollection: collection, favorite: favorite,
                                     generation: generation, transaction: &transaction)
            do {
                try await connect()
                try await client.setFavorite(itemIDs: [itemID], favorite: favorite)
            } catch {
                metadata.mutationEpochs[.favorites, default: 0] &+= 1
                await rollbackFavoriteCaches(transaction, generation: generation)
                favorites.publish(itemID: itemID, section: section,
                                favorite: transaction.previousFavorite)
                if favorites.metadataDirty { scheduleFavoritesRefresh() }
                throw error
            }
            favorites.metadataDirty = true
            scheduleFavoritesRefresh()
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

    private func patchPersonalPages(itemID: Int64, item: PhotoItem?,
                                    sourceSection: TimelineSection,
                                    sourceCollection: PhotoCollectionDescriptor,
                                    favorite: Bool, generation: Int,
                                    transaction: inout FavoriteMutationTransaction) async {
        var candidates: [TimelineSection] = []
        if sourceCollection == .personalLibrary { candidates.append(sourceSection) }
        if let snapshot = metadata.latestTimelines[.personalLibrary] {
            if let item, let day = utcDay(for: item) {
                candidates.append(contentsOf: snapshot.sections.filter { section in
                    section.list.contains(where: { sameDay($0, day) })
                })
            } else if sourceCollection != .personalLibrary {
                candidates.append(contentsOf: snapshot.sections)
            }
        }
        var seen: Set<String> = []
        for section in candidates {
            guard let key = CacheKey.page(namespace: namespace, section: section,
                                          collection: .personalLibrary),
                  seen.insert(key).inserted,
                  let cached = try? await store.get(key),
                  let items = try? JSONDecoder().decode([PhotoItem].self, from: cached.data),
                  items.contains(where: { $0.id == itemID }) else { continue }
            await recordBackup(key: key, kind: .page, knownEntry: cached, transaction: &transaction)
            guard let bytes = try? JSONEncoder().encode(items.map {
                $0.id == itemID ? $0.withFavorite(favorite) : $0
            }) else { continue }
            try? await store.put(key, kind: .page, data: bytes,
                                 validatedRun: cached.validatedRun,
                                 etag: cached.etag, lastModified: cached.lastModified,
                                 expectedGeneration: generation)
        }
    }

    private func recordBackup(key: String, kind: CacheKind, knownEntry: CacheEntry? = nil,
                              transaction: inout FavoriteMutationTransaction) async {
        guard transaction.cacheBackups[key] == nil else { return }
        let entry: CacheEntry?
        if let knownEntry {
            entry = knownEntry
        } else {
            entry = try? await store.get(key)
        }
        transaction.cacheBackups[key] = FavoriteCacheBackup(kind: kind, entry: entry)
    }

    private func rollbackFavoriteCaches(_ transaction: FavoriteMutationTransaction,
                                        generation: Int) async {
        guard await store.currentGeneration() == generation else { return }
        for (key, backup) in transaction.cacheBackups {
            if let entry = backup.entry {
                try? await store.put(key, kind: backup.kind, data: entry.data,
                                     validatedRun: entry.validatedRun,
                                     etag: entry.etag, lastModified: entry.lastModified,
                                     expectedGeneration: generation)
            } else {
                try? await store.remove(key, expectedGeneration: generation)
            }
        }
    }

    private func scheduleFavoritesRefresh() {
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

    private func utcDay(for item: PhotoItem) -> TimelineDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day],
                                                  from: Date(timeIntervalSince1970: TimeInterval(item.time)))
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return TimelineDay(year: year, month: month, day: day, itemCount: 0)
    }

    private func sameDay(_ lhs: TimelineDay, _ rhs: TimelineDay) -> Bool {
        lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day
    }

    private func removeFavoriteObserver(_ id: UUID) { favorites.observers.removeValue(forKey: id) }
}

private struct FavoriteCacheBackup: Sendable {
    let kind: CacheKind
    let entry: CacheEntry?
}

private struct FavoriteMutationTransaction: Sendable {
    let previousFavorite: Bool
    var cacheBackups: [String: FavoriteCacheBackup] = [:]
}
