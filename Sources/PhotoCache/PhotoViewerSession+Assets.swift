import Foundation
import SynologyAPI

// Actor-isolated assets coordination; task identities remain owned by the session.
extension PhotoViewerSession {
    func restartCurrentAssets() {
        images.restartCurrent(keeping: currentItem?.fullImageResource)
        startAssetsForCurrentMetadata()
    }

    func startAssetsForCurrentMetadata() {
        guard !closed, let item = currentItem else { return }
        let network = allowNetwork && metadataVerified
        let descriptor = item.additional?.thumbnail
        if let descriptor {
            if thumbnailSize != .xl {
                startThumbnail(descriptor: descriptor, itemID: item.id,
                               request: configuredThumbnailRequest(), allowNetwork: network)
            }
            if let expensive = expensiveThumbnailRequest(for: descriptor) {
                // Cached XL data is cheap and useful immediately. Only its network
                // validation/download waits for the selection to stabilize.
                startThumbnail(descriptor: descriptor, itemID: item.id,
                               request: expensive, allowNetwork: false)
            }
        } else {
            SynologyDiagnostics.viewer.error(
                "Preview unavailable before request item_id=\(item.id, privacy: .public) type=\(item.type, privacy: .public) live_type=\(item.liveType ?? "nil", privacy: .public) has_additional=\(item.additional != nil, privacy: .public)"
            )
            images.thumbnailStatus = .unsupported("A preview is unavailable for this item.")
        }

        let resource: FullImageResource?
        if item.isVideo {
            images.fullImageStatus = .idle
            resource = nil
            let requestedPreference = videoQuality
            let isMetadataVerified = metadataVerified
            let knownQualities = (item.additional?.videoConvert ?? [])
                .compactMap(\.knownQuality)
                .sorted { $0.rank < $1.rank }
                .map(\.rawValue)
                .joined(separator: ",")
            if let playback = item.videoPlaybackResource(preference: requestedPreference) {
                let target = requestedPreference.targetQuality?.rawValue ?? "original"
                let chosen = playback.variant.cacheComponent
                let reason: String
                switch playback.variant {
                case .original:
                    reason = requestedPreference == .original
                        ? "explicit_original"
                        : "no_converted_rendition_available"
                case .converted(let quality):
                    if quality == requestedPreference.targetQuality {
                        reason = "exact_match"
                    } else if let targetQuality = requestedPreference.targetQuality,
                              quality.rank < targetQuality.rank {
                        reason = "requested_not_available_closest_lower"
                    } else {
                        reason = "requested_not_available_closest_higher"
                    }
                }
                SynologyDiagnostics.videoPlayer.info(
                    "Video quality selected item_id=\(item.id, privacy: .public) unit_id=\(playback.unitID, privacy: .public) settings=\(requestedPreference.rawValue, privacy: .public) target=\(target, privacy: .public) chosen=\(chosen, privacy: .public) reason=\(reason, privacy: .public) advertised=\(knownQualities, privacy: .public) metadata_verified=\(isMetadataVerified, privacy: .public) network_allowed=\(network, privacy: .public)"
                )
            } else {
                SynologyDiagnostics.videoPlayer.error(
                    "Video quality unavailable item_id=\(item.id, privacy: .public) settings=\(requestedPreference.rawValue, privacy: .public) target=\(requestedPreference.targetQuality?.rawValue ?? "original", privacy: .public) chosen=none reason=missing_playback_identity advertised=\(knownQualities, privacy: .public) has_thumbnail=\(descriptor != nil, privacy: .public)"
                )
            }
        } else if let available = item.fullImageResource {
            resource = available
            SynologyDiagnostics.viewer.debug(
                "Full-size resource admitted item_id=\(item.id, privacy: .public) unit_id=\(available.unitID, privacy: .public) network_allowed=\(network, privacy: .public)"
            )
            // Read a cached original immediately without authorizing a network transfer.
            startFullImage(resource: available, allowNetwork: false)
        } else {
            SynologyDiagnostics.viewer.error(
                "Full-size image unavailable before request item_id=\(item.id, privacy: .public) type=\(item.type, privacy: .public) live_type=\(item.liveType ?? "nil", privacy: .public) has_additional=\(item.additional != nil, privacy: .public) has_thumbnail=\(item.additional?.thumbnail != nil, privacy: .public)"
            )
            images.fullImageStatus = .unsupported("A full-size image is unavailable for this item.")
            resource = nil
        }
        scheduleEnhancements(itemID: item.id, descriptor: descriptor,
                             resource: resource, allowNetwork: network)
    }

    func scheduleEnhancements(itemID: Int64, descriptor: ThumbnailInfo?,
                                      resource: FullImageResource?, allowNetwork: Bool) {
        guard allowNetwork, images.enhancementTask == nil,
              descriptor.flatMap(expensiveThumbnailRequest) != nil || resource != nil else { return }
        let attempt = UUID()
        let expectedGeneration = generation
        images.enhancementAttempt = attempt
        images.enhancementTask = Task { [weak self] in
            do { try await Task.sleep(for: ViewerImageWork.enhancementDelay) }
            catch { return }
            await self?.releaseEnhancements(attempt: attempt, generation: expectedGeneration,
                                            itemID: itemID, descriptor: descriptor,
                                            resource: resource)
        }
    }

    func releaseEnhancements(attempt: UUID, generation expectedGeneration: UInt64,
                                     itemID: Int64, descriptor: ThumbnailInfo?,
                                     resource: FullImageResource?) {
        guard !closed, images.enhancementAttempt == attempt, generation == expectedGeneration,
              currentItem?.id == itemID else { return }
        images.enhancementTask = nil
        images.enhancementAttempt = nil
        images.enhancementsReleasedGeneration = generation
        if let descriptor, let request = expensiveThumbnailRequest(for: descriptor) {
            startThumbnail(descriptor: descriptor, itemID: itemID,
                           request: request, allowNetwork: true)
        }
        if let resource { startFullImage(resource: resource, allowNetwork: true) }
        scheduleThumbnailNeighbors()
        if images.fullImageData != nil { enablePrefetchAfterCurrentSuccess() }
        publish()
    }

    func startThumbnail(descriptor: ThumbnailInfo, itemID: Int64,
                                request: ViewerImageWork.ThumbnailRequest, allowNetwork: Bool) {
        if let job = images.thumbnailJobs[request.tier], allowNetwork && !job.allowNetwork {
            job.task.cancel()
            images.thumbnailJobs.removeValue(forKey: request.tier)
        }
        guard images.thumbnailJobs[request.tier] == nil else { return }
        let attempt = UUID()
        let expectedGeneration = generation
        let repository = repository
        let key = Self.thumbnailKey(descriptor, size: request.size)
        let identity = Self.viewerThumbnailIdentity(descriptor)
        if images.thumbnailData == nil { images.thumbnailStatus = .loading }
        let task = Task { [weak self] in
            if request.purpose == .library {
                for await event in await repository.thumbnailWithFallback(
                    descriptor, size: request.size, allowNetwork: allowNetwork, priority: .visible
                ) {
                    guard !Task.isCancelled else { break }
                    let mapped: ResourceEvent<Data>
                    switch event {
                    case .value(let value, let verified): mapped = .value(value.data, verified: verified)
                    case .failure(let message): mapped = .failure(message)
                    }
                    await self?.receiveThumbnail(mapped, attempt: attempt,
                                                 tier: request.tier,
                                                 generation: expectedGeneration, itemID: itemID)
                }
            } else {
                for await event in await repository.thumbnail(
                    descriptor, size: request.size, allowNetwork: allowNetwork, priority: .visible,
                    cachePurpose: request.purpose
                ) {
                    guard !Task.isCancelled else { break }
                    await self?.receiveThumbnail(event, attempt: attempt,
                                                 tier: request.tier,
                                                 generation: expectedGeneration, itemID: itemID)
                }
            }
            await self?.finishThumbnail(attempt, tier: request.tier, key: key)
        }
        images.thumbnailJobs[request.tier] = ViewerImageWork.ThumbnailJob(
            id: attempt, identity: identity, allowNetwork: allowNetwork, task: task
        )
    }

    func receiveThumbnail(_ event: ResourceEvent<Data>, attempt: UUID,
                                  tier: ViewerImageWork.ThumbnailTier,
                                  generation expectedGeneration: UInt64, itemID: Int64) {
        guard !closed, let job = images.thumbnailJobs[tier], job.id == attempt,
              generation == expectedGeneration, currentItem?.id == itemID else { return }
        switch event {
        case .value(let data, let verified):
            images.thumbnailFailures.removeValue(forKey: tier)
            if tier == .configured {
                images.thumbnailDataByIdentity[job.identity] = data
            } else {
                images.largePreviewDataByIdentity[job.identity] = data
            }
            if images.bestThumbnailTier == nil || tier.rawValue >= images.bestThumbnailTier!.rawValue {
                images.bestThumbnailTier = tier
                images.thumbnailData = data
                images.thumbnailStatus = .ready(verified: verified, validationFailure: nil)
            }
        case .failure(let message):
            images.thumbnailFailures[tier] = message
            if images.thumbnailData != nil {
                images.thumbnailStatus = .ready(verified: false, validationFailure: message)
            } else if images.thumbnailJobs.count == 1 {
                images.thumbnailStatus = .failure(message)
            }
        }
        publish()
    }

    func finishThumbnail(_ attempt: UUID, tier: ViewerImageWork.ThumbnailTier, key: String) {
        guard images.thumbnailJobs[tier]?.id == attempt else { return }
        images.thumbnailJobs.removeValue(forKey: tier)
        images.thumbnailPrefetchJobs.removeValue(forKey: key)?.task.cancel()
        if images.thumbnailData == nil, images.thumbnailJobs.isEmpty {
            images.thumbnailStatus = .failure(images.thumbnailFailures[tier] ?? "The preview is not cached.")
        }
        publish()
    }

    func startFullImage(resource: FullImageResource, allowNetwork: Bool) {
        SynologyDiagnostics.viewer.debug(
            "Starting full-size subscription item_id=\(self.currentItem?.id ?? -1, privacy: .public) unit_id=\(resource.unitID, privacy: .public) network_allowed=\(allowNetwork, privacy: .public)"
        )
        let key = Self.resourceKey(resource)
        if let prefetched = images.fullJobs.removeValue(forKey: key) {
            images.fullTask?.cancel()
            if let data = prefetched.data {
                images.fullImageData = data
                images.fullImageStatus = .ready(verified: prefetched.verified,
                                         validationFailure: prefetched.failure)
                enablePrefetchAfterCurrentSuccess()
            } else {
                images.fullImageStatus = .loading
            }
            if prefetched.completed {
                images.fullTask = nil
                images.fullAttempt = nil
                images.fullTaskAllowsNetwork = false
                if allowNetwork && !prefetched.allowNetwork {
                    startFullImage(resource: resource, allowNetwork: true)
                }
            } else {
                images.fullTask = prefetched.task
                images.fullAttempt = prefetched.id
                images.fullTaskAllowsNetwork = prefetched.allowNetwork
                // The existing subscriber and transfer survive; the gate changes its admission class.
                Task { await repository.promoteFullImage(resource) }
            }
            return
        }
        if let task = images.fullTask, allowNetwork && !images.fullTaskAllowsNetwork {
            task.cancel()
            images.fullTask = nil
            images.fullAttempt = nil
        }
        guard images.fullTask == nil else { return }
        let attempt = UUID()
        let expectedGeneration = generation
        let expectedID = currentItem?.id
        let repository = repository
        images.fullAttempt = attempt
        images.fullTaskAllowsNetwork = allowNetwork
        if images.fullImageData == nil { images.fullImageStatus = .loading }
        images.fullTask = Task { [weak self] in
            for await event in await repository.fullImage(resource, allowNetwork: allowNetwork,
                                                           priority: .visible) {
                guard !Task.isCancelled else { break }
                await self?.receiveCurrentFull(event, attempt: attempt,
                                               generation: expectedGeneration, itemID: expectedID,
                                               resource: resource)
            }
            await self?.finishCurrentFull(attempt)
        }
    }

    func receiveCurrentFull(_ event: ResourceEvent<Data>, attempt: UUID,
                                    generation expectedGeneration: UInt64, itemID: Int64?,
                                    resource: FullImageResource) {
        guard !closed, images.fullAttempt == attempt, generation == expectedGeneration,
              currentItem?.id == itemID,
              currentItem?.fullImageResource.map(Self.resourceKey) == Self.resourceKey(resource) else { return }
        switch event {
        case .value(let data, let verified):
            SynologyDiagnostics.viewer.info(
                "Full-size bytes received item_id=\(itemID ?? -1, privacy: .public) unit_id=\(resource.unitID, privacy: .public) bytes=\(data.count, privacy: .public) verified=\(verified, privacy: .public)"
            )
            images.fullImageData = data
            images.fullImageStatus = .ready(verified: verified, validationFailure: nil)
            enablePrefetchAfterCurrentSuccess()
        case .failure(let message):
            SynologyDiagnostics.viewer.error(
                "Full-size subscription failed item_id=\(itemID ?? -1, privacy: .public) unit_id=\(resource.unitID, privacy: .public) error=\(message, privacy: .public)"
            )
            if images.fullImageData != nil {
                images.fullImageStatus = .ready(verified: false, validationFailure: message)
            } else {
                images.fullImageStatus = .failure(message)
            }
        }
        publish()
    }

    func finishCurrentFull(_ attempt: UUID) {
        if images.fullAttempt == attempt {
            let waitingForEnhancements = allowNetwork && metadataVerified &&
                images.enhancementsReleasedGeneration != generation
            if images.fullImageData == nil, images.fullImageStatus == .loading, !waitingForEnhancements {
                images.fullImageStatus = .failure("The full-size image is not cached.")
                publish()
            }
            images.fullAttempt = nil
            images.fullTask = nil
            let needsNetworkValidation = allowNetwork && metadataVerified &&
                !images.fullTaskAllowsNetwork && !waitingForEnhancements
            images.fullTaskAllowsNetwork = false
            if needsNetworkValidation, let resource = currentItem?.fullImageResource {
                startFullImage(resource: resource, allowNetwork: true)
            }
        }
    }

    func isLargePreviewLoading() -> Bool {
        guard let descriptor = currentItem?.additional?.thumbnail,
              let request = expensiveThumbnailRequest(for: descriptor),
              request.tier == .largePreview,
              images.bestThumbnailTier != request.tier else { return false }
        return images.enhancementTask != nil || images.thumbnailJobs[request.tier] != nil
    }
}
