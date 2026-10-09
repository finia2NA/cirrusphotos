import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    /// Keep each buffered transport response below AVFoundation's resource-loader
    /// stall window on slow links. URLSession does not publish `data(for:)` bytes
    /// until the complete range response has arrived.
    public static let videoSegmentSize: Int64 = 64 * 1_024

    public func videoData(_ resource: VideoPlaybackResource, offset: Int64, length: Int,
                          allowNetwork: Bool = true) async throws -> VideoPlaybackData {
        guard offset >= 0, length > 0, length <= 8 * 1_024 * 1_024 else {
            SynologyDiagnostics.videoPlayback.error(
                "Video data request invalid unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) offset=\(offset, privacy: .public) length=\(length, privacy: .public)"
            )
            throw SynologyAPIError.invalidResponse
        }
        SynologyDiagnostics.videoPlayback.debug(
            "Video data requested unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) offset=\(offset, privacy: .public) length=\(length, privacy: .public) network_allowed=\(allowNetwork, privacy: .public)"
        )
        var cursor = offset
        let requestedUpper = offset + Int64(length) - 1
        var output = Data()
        var expectedTotal: Int64?
        var contentType: String?
        while cursor <= requestedUpper {
            try Task.checkCancellation()
            let index = cursor / Self.videoSegmentSize
            let segment = try await videoSegment(resource, index: index, allowNetwork: allowNetwork)
            if let expectedTotal, expectedTotal != segment.header.totalLength {
                throw SynologyAPIError.invalidResponse
            }
            expectedTotal = segment.header.totalLength
            contentType = segment.header.contentType
            guard cursor < segment.header.totalLength else { break }
            let upper = min(requestedUpper, segment.header.rangeUpper,
                            segment.header.totalLength - 1)
            guard cursor >= segment.header.rangeLower, upper >= cursor else {
                throw SynologyAPIError.invalidResponse
            }
            let localLower = Int(cursor - segment.header.rangeLower)
            let localUpper = Int(upper - segment.header.rangeLower)
            output.append(segment.data[localLower...localUpper])
            cursor = upper + 1
        }
        guard let total = expectedTotal, let contentType, !output.isEmpty else {
            SynologyDiagnostics.videoPlayback.error(
                "Video data unavailable unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) offset=\(offset, privacy: .public) length=\(length, privacy: .public) network_allowed=\(allowNetwork, privacy: .public)"
            )
            throw SynologyAPIError.unsupported("The requested video range is not cached.")
        }
        SynologyDiagnostics.videoPlayback.debug(
            "Video data ready unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) offset=\(offset, privacy: .public) bytes=\(output.count, privacy: .public) total=\(total, privacy: .public)"
        )
        return VideoPlaybackData(data: output, range: offset...(offset + Int64(output.count) - 1),
                                 totalLength: total, contentType: contentType)
    }

    private func videoSegment(_ resource: VideoPlaybackResource, index: Int64,
                              allowNetwork: Bool) async throws -> CachedVideoSegment {
        let key = CacheKey.videoSegment(namespace: namespace, resource: resource, index: index)
        if let entry = try? await store.get(key) {
            do {
                let cached = try CachedVideoSegment(encoded: entry.data)
                SynologyDiagnostics.videoPlayback.debug(
                    "Video segment cache hit unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) segment=\(index, privacy: .public) bytes=\(cached.data.count, privacy: .public)"
                )
                return cached
            } catch {
                SynologyDiagnostics.videoPlayback.error(
                    "Video segment cache invalid unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) segment=\(index, privacy: .public)"
                )
            }
        }
        guard allowNetwork else {
            SynologyDiagnostics.videoPlayback.error(
                "Video segment cache miss while offline unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) segment=\(index, privacy: .public)"
            )
            throw SynologyAPIError.unsupported("This part of the video is not cached.")
        }
        if let existing = imageWork.videoSegmentJobs[key] {
            SynologyDiagnostics.videoPlayback.debug(
                "Video segment joining transfer unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) segment=\(index, privacy: .public)"
            )
            return try await existing.task.value
        }
        let id = UUID()
        let task = Task<CachedVideoSegment, Error> {
            try await self.downloadVideoSegment(resource, index: index, key: key)
        }
        imageWork.videoSegmentJobs[key] = VideoSegmentJob(id: id, task: task)
        do {
            let value = try await task.value
            if imageWork.videoSegmentJobs[key]?.id == id { imageWork.videoSegmentJobs[key] = nil }
            cancelIdleLogin()
            return value
        } catch {
            if imageWork.videoSegmentJobs[key]?.id == id { imageWork.videoSegmentJobs[key] = nil }
            cancelIdleLogin()
            throw error
        }
    }

    private func downloadVideoSegment(_ resource: VideoPlaybackResource, index: Int64,
                                      key: String) async throws -> CachedVideoSegment {
        let generation = await store.currentGeneration()
        try await connect()
        let lower = index * Self.videoSegmentSize
        let upper = lower + Self.videoSegmentSize - 1
        let jobID = UUID()
        try await videoTransferGate.acquire(jobID)
        let started = Date()
        SynologyDiagnostics.videoPlayback.info(
            "Video segment download started unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) segment=\(index, privacy: .public) lower=\(lower, privacy: .public) upper=\(upper, privacy: .public)"
        )
        do {
            let response = try await client.videoRange(resource, range: lower...upper)
            await videoTransferGate.release(jobID)
            let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)
            SynologyDiagnostics.videoPlayback.info(
                "Video segment download finished unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) segment=\(index, privacy: .public) bytes=\(response.data.count, privacy: .public) total=\(response.totalLength, privacy: .public) elapsed_ms=\(elapsedMS, privacy: .public)"
            )
            let cached = CachedVideoSegment(response: response)
            do {
                try await store.put(key, kind: .videoSegment, data: cached.encoded(),
                                    validatedRun: runID, etag: response.etag,
                                    lastModified: response.lastModified,
                                    expectedGeneration: generation)
                SynologyDiagnostics.videoPlayback.debug(
                    "Video segment cached unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) segment=\(index, privacy: .public)"
                )
            } catch {
                SynologyDiagnostics.videoPlayback.error(
                    "Video segment cache write failed unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) segment=\(index, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
            return cached
        } catch {
            await videoTransferGate.release(jobID)
            let nsError = error as NSError
            SynologyDiagnostics.videoPlayback.error(
                "Video segment download failed unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) segment=\(index, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)"
            )
            throw error
        }
    }
}
