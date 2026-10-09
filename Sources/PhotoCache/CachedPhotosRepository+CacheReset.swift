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

    public func clearCache() async throws {
        _ = try await resetCache(scope: .all)
    }

    private func resetCache(scope: MetadataResetScope) async throws -> UInt64 {
        if let existing = metadata.resetJob {
            let revision = try await existing.task.value
            if scope == .metadata || existing.scope == .all { return revision }
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

        if scope == .metadata {
            // Existing transfers have already been admitted. Let them finish even
            // when UI invalidation removes their last subscriber.
            imageWork.thumbnailFinishWithoutSubscribers.formUnion(imageWork.thumbnailJobs.keys)
            imageWork.fullImageFinishWithoutSubscribers.formUnion(imageWork.fullImageJobs.keys)
        } else {
            for job in imageWork.thumbnailJobs.values { job.task.cancel() }
            for job in imageWork.fullImageJobs.values {
                job.task.cancel()
                Task { await fullImageGate.release(job.id) }
            }
            imageWork.thumbnailJobs.removeAll()
            imageWork.fullImageJobs.removeAll()
            for job in imageWork.videoSegmentJobs.values { job.task.cancel() }
            imageWork.videoSegmentJobs.removeAll()
            imageWork.thumbnailFinishWithoutSubscribers.removeAll()
            imageWork.fullImageFinishWithoutSubscribers.removeAll()
        }

        cancelMetadataJobsForReset()

        do {
            let diskRevision: Int
            switch scope {
            case .metadata:
                diskRevision = try await store.clearMetadata()
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

    private func cancelMetadataJobsForReset() {
        for job in metadata.timelineJobs.values { job.task.cancel() }
        for job in metadata.pageJobs.values { job.task.cancel() }
        metadata.albumListJob?.task.cancel()
        metadata.locationIndexWork?.task.cancel()
        favorites.refreshTask?.cancel()
        favorites.refreshTask = nil
        metadata.timelineJobs.removeAll()
        metadata.pageJobs.removeAll()
        metadata.pageJobEpochs.removeAll()
        metadata.albumListJob = nil
        metadata.locationIndexWork = nil
        metadata.initialSubscribers.removeAll()
    }

    private func clearMetadataStateAfterReset() {
        metadata.latestTimelines.removeAll()
        metadata.albumListLatest = nil
        metadata.pendingPagePromotions.removeAll()
        metadata.locationRecords.removeAll()
        metadata.locationRevision &+= 1
        metadata.mapFilters.removeAll()
        metadata.mapFilterPages.removeAll()
        metadata.mapFilterPageOrder.removeAll()
        // Mutation epochs and favorite overrides remain monotonic/live. Already
        // submitted NAS writes are not duplicated or canceled by a local reset.
    }

    private func removeMetadataResetObserver(_ id: UUID) {
        metadata.resetObservers.removeValue(forKey: id)
    }
}
