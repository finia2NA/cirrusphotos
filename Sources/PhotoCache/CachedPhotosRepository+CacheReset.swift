import Foundation

extension CachedPhotosRepository {
    /// Replaying stream of successful metadata invalidations. Internal transaction
    /// phases and failed attempts are deliberately not exposed to consumers.
    public func metadataCacheResets() -> AsyncStream<UInt64> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            metadata.resetObservers[id] = continuation
            continuation.yield(metadata.successfulResetRevision)
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeMetadataResetObserver(id) }
            }
        }
    }

    public func clearMetadataCache() async throws {
        _ = try await resetCache(scope: .metadata)
    }

    /// Keeps cached metadata visible while treating all of it as unverified, so it is
    /// read again on demand and by the background sync. An escape hatch for stale data.
    public func revalidateAllMetadata() async throws {
        try await initializeMetadataEngine()
        try await store.withdrawMetadataValidation()
        try await supersedeMetadataState()
    }

    public func clearCache() async throws {
        _ = try await resetCache(scope: .all)
    }

    /// Publishes a cache-reset revision for in-memory state without deleting
    /// stored metadata. Callers invalidate the affected stored rows first.
    func supersedeMetadataState() async throws {
        _ = try await resetCache(scope: .invalidation)
    }

    private func resetCache(scope: MetadataResetScope) async throws -> UInt64 {
        if let existing = metadata.resetJob {
            let revision = try await existing.task.value
            if scope != .all || existing.scope == .all { return revision }
            // A whole-cache reset requested during a metadata-only reset runs after it.
        }

        let id = UUID()
        let task = Task<UInt64, Error> { try await executeCacheReset(scope: scope) }
        metadata.resetJob = MetadataResetJob(id: id, scope: scope, task: task)
        do {
            let revision = try await task.value
            if metadata.resetJob?.id == id { metadata.resetJob = nil }
            return revision
        } catch {
            if metadata.resetJob?.id == id { metadata.resetJob = nil }
            throw error
        }
    }

    private func executeCacheReset(scope: MetadataResetScope) async throws -> UInt64 {
        metadata.resetInProgress = true
        metadata.admissionEpoch &+= 1

        if scope != .all {
            // Existing transfers have already been admitted. Let them finish even
            // when UI invalidation removes their last subscriber.
            imageWork.thumbnailFinishWithoutSubscribers.formUnion(imageWork.thumbnailJobs.keys)
            imageWork.fullImageFinishWithoutSubscribers.formUnion(imageWork.fullImageJobs.keys)
            for job in imageWork.videoWindowJobs.values { await job.window.retainUntilFinished() }
        } else {
            await cancelAllImageWork()
        }

        cancelMetadataJobsForReset()

        do {
            let diskRevision: Int
            switch scope {
            case .metadata:
                diskRevision = try await store.clearMetadata()
            case .invalidation:
                diskRevision = await store.advanceMetadataGeneration()
            case .all:
                try await store.clear()
                diskRevision = await store.currentMetadataGeneration()
            }
            clearMetadataStateAfterReset()
            let revision = UInt64(max(0, diskRevision))
            metadata.successfulResetRevision = revision
            metadata.resetInProgress = false
            for observer in metadata.resetObservers.values { observer.yield(revision) }
            return revision
        } catch {
            // The admission epoch and disk metadata generation remain advanced.
            // Published values are retained provisionally and old work stays obsolete.
            metadata.resetInProgress = false
            throw error
        }
    }

    /// Supersedes and cancels everything in flight, for `shutdown()`.
    func stopAllWork() async {
        metadata.admissionEpoch &+= 1
        await cancelAllImageWork()
        cancelMetadataJobsForReset()
        for observer in metadata.resetObservers.values { observer.finish() }
        metadata.resetObservers.removeAll()
    }

    private func cancelAllImageWork() async {
        for job in imageWork.thumbnailJobs.values { job.task.cancel() }
        for job in imageWork.fullImageJobs.values {
            job.task.cancel()
            Task { await fullImageGate.release(job.id) }
        }
        imageWork.thumbnailJobs.removeAll()
        imageWork.fullImageJobs.removeAll()
        for job in imageWork.videoWindowJobs.values { await job.window.cancel() }
        imageWork.videoWindowJobs.removeAll()
        imageWork.thumbnailFinishWithoutSubscribers.removeAll()
        imageWork.fullImageFinishWithoutSubscribers.removeAll()
    }

    private func cancelMetadataJobsForReset() {
        cancelNormalizedMetadataWork()
        for recovery in metadata.collectionRecoveries.values { recovery.task.cancel() }
        for job in metadata.detailJobs.values { job.task.cancel() }
        metadata.detailJobs.removeAll()
        metadata.detailJobByID.removeAll()
        for source in metadata.sources.values { source.reconciliation?.cancel() }
        metadata.locations.publicationTask?.cancel()
        metadata.clearSourceWork()
        for observer in metadata.collectionPageObservers.values { observer.continuation.finish() }
        metadata.collectionPageObservers.removeAll()
        for job in metadata.timelineJobs.values { job.task.cancel() }
        for job in metadata.pageJobs.values { job.task.cancel() }
        metadata.collectionIndexJobs.values.forEach { $0.task.cancel() }
        metadata.collectionIndexJobs.removeAll()
        metadata.folderJobs.values.forEach { $0.task.cancel() }
        metadata.folderJobs.removeAll()
        metadata.albums.listJob?.task.cancel()
        metadata.locations.work?.task.cancel()
        metadata.sharedLocations.job?.task.cancel()
        metadata.sharedLocations.job = nil
        metadata.sharedLocations.current = false
        for favorites in favoriteStates.values {
            favorites.refreshTask?.cancel()
            favorites.refreshTask = nil
        }
        metadata.timelineJobs.removeAll()
        metadata.pageJobs.removeAll()
        metadata.pageJobEpochs.removeAll()
        metadata.pageJobSourceRevisions.removeAll()
        metadata.forcedMembershipJobs.removeAll()
        metadata.albums.listJob = nil
        metadata.locations.work = nil
        metadata.initialSubscribers.removeAll()
    }

    private func clearMetadataStateAfterReset() {
        metadata.latestTimelines.removeAll()
        metadata.albums.listLatest = nil
        metadata.pendingPagePromotions.removeAll()
        metadata.locations.records.removeAll()
        metadata.sharedLocations.records.removeAll()
        metadata.sharedLocations.revision &+= 1
        metadata.locations.revision &+= 1
        metadata.sessions.selectionRetentions.removeAll()
        metadata.sessions.deferredUnregisters.removeAll()
        metadata.sessions.mapFilters.removeAll()
        metadata.sessions.libraryFilters.removeAll()
        metadata.sessions.filterCatalogs.removeAll()
        // Mutation epochs and favorite overrides remain monotonic/live. Already
        // submitted NAS writes are not duplicated or canceled by a local reset.
    }

    private func removeMetadataResetObserver(_ id: UUID) {
        metadata.resetObservers.removeValue(forKey: id)
    }
}
