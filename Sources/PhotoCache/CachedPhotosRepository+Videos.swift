import Foundation
import SynologyAPI

extension CachedPhotosRepository {
    public func livePhotoMotion(itemID: Int64, space: PhotoSpace = .personal) async throws -> VideoPlaybackResource? {
        try await connect()
        defer { cancelIdleLogin() }
        return try await client.livePhotoMotion(itemID: itemID, space: space)
    }

    public static let videoSegmentSize: Int64 = 64 * 1_024
    public static let videoWindowSize: Int64 = 1 * 1_024 * 1_024

    /// Deliver cached segments and network chunks in order without waiting for the
    /// entire player request. Each network window is bounded and staged for cache.
    public func streamVideoData(_ resource: VideoPlaybackResource, offset: Int64, length: Int,
                                allowNetwork: Bool = true,
                                receive: @escaping @Sendable (VideoPlaybackData) async throws -> Void) async throws {
        guard offset >= 0, length > 0, length <= 8 * 1_024 * 1_024,
              offset <= Int64.max - Int64(length) - Self.videoWindowSize else { throw SynologyAPIError.invalidResponse }
        let end = offset + Int64(length)
        let consistency = VideoStreamConsistency()
        let deliver: @Sendable (VideoPlaybackData) async throws -> Void = { value in
            try await consistency.check(value)
            try await receive(value)
        }
        var cursor = offset
        var expectedTotal: Int64?
        var expectedType: String?
        while cursor < end {
            try Task.checkCancellation()
            let index = cursor / Self.videoSegmentSize
            if let segment = await cachedVideoSegment(resource, index: index) {
                guard expectedTotal == nil || expectedTotal == segment.header.totalLength,
                      expectedType == nil || expectedType == segment.header.contentType else { throw SynologyAPIError.invalidResponse }
                expectedTotal = segment.header.totalLength
                expectedType = segment.header.contentType
                if cursor >= segment.header.totalLength { return }
                let upper = min(end - 1, segment.header.rangeUpper)
                guard upper >= cursor else { throw SynologyAPIError.invalidResponse }
                let lowerIndex = Int(cursor - segment.header.rangeLower)
                let upperIndex = Int(upper - segment.header.rangeLower)
                let value = VideoPlaybackData(data: Data(segment.data[lowerIndex...upperIndex]), range: cursor...upper,
                                              totalLength: segment.header.totalLength, contentType: segment.header.contentType,
                                              etag: segment.etag, lastModified: segment.lastModified)
                try await deliver(value)
                cursor = upper + 1
                if cursor >= segment.header.totalLength { return }
                continue
            }
            guard allowNetwork else { throw SynologyAPIError.unsupported("This part of the video is not cached.") }
            let lower = index * Self.videoSegmentSize
            let demandEnd = min(end, lower + Self.videoWindowSize)
            var windowEnd = lower + Self.videoSegmentSize
            while windowEnd < demandEnd {
                if await cachedVideoSegment(resource, index: windowEnd / Self.videoSegmentSize) != nil { break }
                windowEnd += Self.videoSegmentSize
            }
            let range = lower...(windowEnd - 1)
            let resourceKey = CacheKey.videoSegment(namespace: namespace, resource: resource, index: 0)
            let key = CacheKey.videoSegment(namespace: namespace, resource: resource, index: index) + ":window:\(range.upperBound)"
            let subscriber = UUID()
            let window: VideoWindow
            if let existing = imageWork.videoWindowJobs.values.first(where: { $0.resourceKey == resourceKey && $0.range.contains(cursor) }),
               await existing.window.subscribe(subscriber) {
                window = existing.window
            } else {
                window = VideoWindow(range: range)
                let jobID = UUID()
                imageWork.videoWindowJobs[key] = VideoWindowJob(id: jobID, resourceKey: resourceKey, range: range, window: window)
                await window.subscribe(subscriber)
                await window.start { [self] window in
                    do {
                        try await downloadVideoWindow(resource, range: range, window: window)
                        await finishVideoWindow(key: key, id: jobID)
                    } catch {
                        await finishVideoWindow(key: key, id: jobID)
                        throw error
                    }
                }
            }
            let current = cursor
            let totalBefore = expectedTotal
            let typeBefore = expectedType
            let result = try await withTaskCancellationHandler {
                try await consumeVideoWindow(window, subscriber: subscriber, offset: current, end: end,
                                             expectedTotal: totalBefore, expectedType: typeBefore, receive: deliver)
            } onCancel: { Task { await window.unsubscribe(subscriber) } }
            cursor = result.offset
            expectedTotal = result.total
            expectedType = result.type
            if let total = expectedTotal, cursor >= total { return }
            guard cursor > current else { throw SynologyAPIError.invalidResponse }
        }
    }

    private func consumeVideoWindow(_ window: VideoWindow, subscriber: UUID, offset: Int64, end: Int64,
                                    expectedTotal: Int64?, expectedType: String?,
                                    receive: @escaping @Sendable (VideoPlaybackData) async throws -> Void)
        async throws -> (offset: Int64, total: Int64?, type: String?) {
        var cursor = offset
        var readOffset = offset
        var total = expectedTotal
        var type = expectedType
        do {
            while let value = try await window.read(from: readOffset) {
                try Task.checkCancellation()
                guard total == nil || total == value.totalLength,
                      type == nil || type == value.contentType else { throw SynologyAPIError.invalidResponse }
                total = value.totalLength
                type = value.contentType
                let count = min(value.data.count, Int(end - cursor))
                if count > 0 {
                    let data = Data(value.data.prefix(count))
                    try await receive(VideoPlaybackData(data: data, range: cursor...(cursor + Int64(count) - 1),
                                                        totalLength: value.totalLength, contentType: value.contentType,
                                                        etag: value.etag, lastModified: value.lastModified))
                    cursor += Int64(count)
                }
                readOffset += Int64(value.data.count)
                // Continue waiting for the bounded window to complete, even if the
                // caller's requested bytes were a partial final cache segment.
            }
            await window.unsubscribe(subscriber)
            return (cursor, total, type)
        } catch {
            await window.unsubscribe(subscriber)
            throw error
        }
    }

    private func cachedVideoSegment(_ resource: VideoPlaybackResource, index: Int64) async -> CachedVideoSegment? {
        let key = CacheKey.videoSegment(namespace: namespace, resource: resource, index: index)
        guard let entry = try? await store.get(key), let segment = try? CachedVideoSegment(encoded: entry.data, etag: entry.etag, lastModified: entry.lastModified),
              segment.header.rangeLower == index * Self.videoSegmentSize,
              segment.header.rangeUpper == min(segment.header.rangeLower + Self.videoSegmentSize - 1, segment.header.totalLength - 1) else { return nil }
        return segment
    }

    private func finishVideoWindow(key: String, id: UUID) {
        if imageWork.videoWindowJobs[key]?.id == id { imageWork.videoWindowJobs[key] = nil }
        cancelIdleLogin()
    }

    private func downloadVideoWindow(_ resource: VideoPlaybackResource, range: ClosedRange<Int64>,
                                     window: VideoWindow) async throws {
        try Task.checkCancellation()
        let generation = await store.currentGeneration()
        try await connect()
        let gateID = UUID()
        do {
            try await videoTransferGate.acquire(gateID)
            try Task.checkCancellation()
            try await client.streamVideoRange(resource, range: range) { event in
                try Task.checkCancellation()
                try await window.append(event)
            }
            let (header, data) = try await window.completedData()
            try Task.checkCancellation()
            var position = 0
            while position < data.count {
                try Task.checkCancellation()
                let count = min(Int(Self.videoSegmentSize), data.count - position)
                let lower = range.lowerBound + Int64(position)
                let response = VideoRangeResponse(data: Data(data[position..<(position + count)]),
                    range: lower...(lower + Int64(count) - 1), totalLength: header.totalLength,
                    contentType: header.contentType, etag: header.etag, lastModified: header.lastModified)
                let segment = CachedVideoSegment(response: response)
                let key = CacheKey.videoSegment(namespace: namespace, resource: resource, index: lower / Self.videoSegmentSize)
                try? await store.put(key, kind: .videoSegment, data: segment.encoded(), validatedRun: runID,
                                     etag: header.etag, lastModified: header.lastModified, expectedGeneration: generation)
                position += count
            }
            await videoTransferGate.release(gateID)
        } catch {
            await videoTransferGate.release(gateID)
            throw error
        }
    }
}

private actor VideoStreamConsistency {
    private var etag: String?
    private var lastModified: String?

    func check(_ value: VideoPlaybackData) throws {
        if let etag, let incoming = value.etag, etag != incoming { throw SynologyAPIError.invalidResponse }
        if let lastModified, let incoming = value.lastModified, lastModified != incoming { throw SynologyAPIError.invalidResponse }
        if etag == nil { etag = value.etag }
        if lastModified == nil { lastModified = value.lastModified }
    }
}
