import Foundation
import SynologyAPI

// Actor-isolated prefetch coordination; task identities remain owned by the session.
extension PhotoViewerSession {
    func enablePrefetchAfterCurrentSuccess() {
        guard images.prefetchEnabledGeneration != generation,
              !allowNetwork || images.enhancementsReleasedGeneration == generation else { return }
        images.prefetchEnabledGeneration = generation
        scheduleLoadedNeighbors()
    }

    /// Thumbnail fetching is independent of original prefetch, so adjacent previews
    /// can warm while the current original is still loading.
    func scheduleThumbnailNeighbors() {
        guard !closed else { return }
        let locations = [-1, 1].compactMap { metadata.location(for: desired.ordinal + $0) }
        let wantedSections = Set(locations.map(\.sectionIndex))
        for section in wantedSections where metadata.pages[section] == nil || (allowNetwork && metadata.pages[section]?.verified == false) {
            ensurePage(section, visible: false)
        }

        var wantedKeys: Set<String> = []
        // Keep adjacent prefetch subscribers alive until the newly selected visible
        // subscribers have joined the shared repository jobs. Cancelling them here can
        // race task startup and needlessly restart the same transfers.
        if let descriptor = currentItem?.additional?.thumbnail {
            for request in currentThumbnailRequests(for: descriptor) {
                let currentKey = Self.thumbnailKey(descriptor, size: request.size)
                if images.thumbnailPrefetchJobs[currentKey] != nil { wantedKeys.insert(currentKey) }
            }
        }
        for location in locations {
            guard let page = metadata.pages[location.sectionIndex],
                  page.items.indices.contains(location.pageOffset),
                  let descriptor = page.items[location.pageOffset].additional?.thumbnail else { continue }
            for request in neighborThumbnailRequests(for: descriptor) {
                let key = Self.thumbnailKey(descriptor, size: request.size)
                wantedKeys.insert(key)
                let network = allowNetwork && page.verified
                if let job = images.thumbnailPrefetchJobs[key], network && !job.allowNetwork {
                    job.task.cancel()
                    images.thumbnailPrefetchJobs.removeValue(forKey: key)
                    startThumbnailPrefetch(descriptor, request: request, key: key, allowNetwork: true)
                } else if images.thumbnailPrefetchJobs[key] == nil {
                    startThumbnailPrefetch(descriptor, request: request, key: key, allowNetwork: network)
                }
            }
        }
        for (key, job) in images.thumbnailPrefetchJobs where !wantedKeys.contains(key) {
            job.task.cancel()
            images.thumbnailPrefetchJobs.removeValue(forKey: key)
        }
    }

    func startThumbnailPrefetch(_ descriptor: ThumbnailInfo,
                                        request: ViewerImageWork.ThumbnailRequest,
                                        key: String, allowNetwork: Bool) {
        let id = UUID()
        let repository = repository
        let task = Task { [weak self] in
            for await _ in await repository.thumbnail(descriptor, size: request.size,
                                                       allowNetwork: allowNetwork, priority: .prefetch,
                                                       cachePurpose: request.purpose) {
                guard !Task.isCancelled else { break }
            }
            await self?.finishThumbnailPrefetch(key: key, id: id)
        }
        images.thumbnailPrefetchJobs[key] = ViewerImageWork.ThumbnailJob(id: id, allowNetwork: allowNetwork, task: task)
    }

    func finishThumbnailPrefetch(key: String, id: UUID) {
        guard images.thumbnailPrefetchJobs[key]?.id == id else { return }
        images.thumbnailPrefetchJobs.removeValue(forKey: key)
    }

    func configuredThumbnailRequest() -> ViewerImageWork.ThumbnailRequest {
        ViewerImageWork.ThumbnailRequest(tier: .configured, size: thumbnailSize, purpose: .library)
    }

    func expensiveThumbnailRequest(for descriptor: ThumbnailInfo) -> ViewerImageWork.ThumbnailRequest? {
        if thumbnailSize == .xl { return configuredThumbnailRequest() }
        if loadsLargePreviews, thumbnailSize != .xl, descriptor.isReady(.xl) {
            return ViewerImageWork.ThumbnailRequest(tier: .largePreview, size: .xl, purpose: .viewerPreview)
        }
        return nil
    }

    func currentThumbnailRequests(for descriptor: ThumbnailInfo) -> [ViewerImageWork.ThumbnailRequest] {
        var requests: [ViewerImageWork.ThumbnailRequest] = thumbnailSize == .xl ? [] : [configuredThumbnailRequest()]
        if let expensive = expensiveThumbnailRequest(for: descriptor) { requests.append(expensive) }
        return requests
    }

    func neighborThumbnailRequests(for descriptor: ThumbnailInfo) -> [ViewerImageWork.ThumbnailRequest] {
        var requests: [ViewerImageWork.ThumbnailRequest] = thumbnailSize == .xl ? [] : [configuredThumbnailRequest()]
        if images.enhancementsReleasedGeneration == generation,
           let expensive = expensiveThumbnailRequest(for: descriptor) {
            requests.append(expensive)
        }
        return requests
    }

    func scheduleLoadedNeighbors() {
        guard !closed, images.prefetchEnabledGeneration == generation else { return }
        let locations = [-1, 1].compactMap { metadata.location(for: desired.ordinal + $0) }
        let desiredSections = Set(locations.map(\.sectionIndex) + [desired.sectionIndex])
        for section in desiredSections where metadata.pages[section] == nil || (allowNetwork && metadata.pages[section]?.verified == false) {
            ensurePage(section, visible: false)
        }
        metadata.trimPageJobs(around: desired)

        var wantedKeys: Set<String> = []
        for location in locations {
            guard let page = metadata.pages[location.sectionIndex], page.items.indices.contains(location.pageOffset) else { continue }
            let item = page.items[location.pageOffset]
            guard let resource = item.fullImageResource else { continue }
            let key = Self.resourceKey(resource)
            wantedKeys.insert(key)
            let network = allowNetwork && page.verified
            if let job = images.fullJobs[key], network && !job.allowNetwork {
                job.task.cancel()
                images.fullJobs.removeValue(forKey: key)
                startPrefetch(resource: resource, location: location, allowNetwork: true)
            } else if images.fullJobs[key] == nil {
                startPrefetch(resource: resource, location: location, allowNetwork: network)
            }
        }
        for (key, job) in images.fullJobs where !wantedKeys.contains(key) {
            job.task.cancel()
            images.fullJobs.removeValue(forKey: key)
        }
    }

    func startPrefetch(resource: FullImageResource, location: PhotoViewerLocation,
                               allowNetwork: Bool) {
        let key = Self.resourceKey(resource)
        let id = UUID()
        let repository = repository
        let task = Task { [weak self] in
            for await event in await repository.fullImage(resource, allowNetwork: allowNetwork,
                                                           priority: .prefetch) {
                guard !Task.isCancelled else { break }
                await self?.receivePrefetch(event, key: key, id: id)
            }
            await self?.finishPrefetch(key: key, id: id)
        }
        images.fullJobs[key] = ViewerImageWork.FullJob(id: id, location: location, resource: resource,
                                allowNetwork: allowNetwork, task: task)
    }

    func receivePrefetch(_ event: ResourceEvent<Data>, key: String, id: UUID) {
        if images.fullAttempt == id {
            receiveCurrentFull(event, attempt: id, generation: generation,
                               itemID: currentItem?.id,
                               resource: currentItem?.fullImageResource ?? FullImageResource(unitID: -1, cacheKey: ""))
            return
        }
        guard var job = images.fullJobs[key], job.id == id else { return }
        switch event {
        case .value(let data, let verified):
            job.data = data
            job.verified = verified
            job.failure = nil
        case .failure(let message):
            job.failure = message
        }
        images.fullJobs[key] = job
    }

    func finishPrefetch(key: String, id: UUID) {
        if images.fullAttempt == id {
            finishCurrentFull(id)
        } else if var job = images.fullJobs[key], job.id == id {
            if job.data == nil {
                images.fullJobs.removeValue(forKey: key)
            } else {
                job.completed = true
                images.fullJobs[key] = job
            }
        }
    }
}
