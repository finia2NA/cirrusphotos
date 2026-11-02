import Foundation
import SynologyAPI

/// One bounded response shared by concurrent readers. Bytes are retained only for
/// the life of this window, allowing a late reader to replay the received prefix.
actor VideoWindow {
    let range: ClosedRange<Int64>
    private var header: VideoRangeHeader?
    private var bytes = Data()
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var subscribers: Set<UUID> = []
    private var task: Task<Void, Never>?
    private var finishWithoutSubscribers = false
    private var cancelled = false

    init(range: ClosedRange<Int64>) { self.range = range }

    func start(_ operation: @escaping @Sendable (VideoWindow) async throws -> Void) {
        task = Task {
            do { try await operation(self); finish(.success(())) }
            catch { finish(.failure(error)) }
        }
        if cancelled || (subscribers.isEmpty && !finishWithoutSubscribers) { task?.cancel() }
    }

    @discardableResult
    func subscribe(_ id: UUID) -> Bool {
        guard result == nil, !cancelled, task?.isCancelled != true else { return false }
        subscribers.insert(id)
        return true
    }

    func unsubscribe(_ id: UUID) {
        subscribers.remove(id)
        if subscribers.isEmpty, result == nil, !finishWithoutSubscribers {
            cancelled = true
            task?.cancel()
        }
        wake()
    }

    func cancel() { cancelled = true; task?.cancel(); wake() }
    func retainUntilFinished() { finishWithoutSubscribers = true }

    func append(_ event: VideoRangeEvent) throws {
        switch event {
        case .header(let value):
            guard header == nil, value.range.lowerBound == range.lowerBound,
                  value.range.upperBound <= range.upperBound,
                  value.range.upperBound == range.upperBound || value.range.upperBound == value.totalLength - 1,
                  value.totalLength > value.range.upperBound,
                  value.contentType.hasPrefix("video/") || value.contentType.hasPrefix("application/octet-stream") else {
                throw SynologyAPIError.invalidResponse
            }
            header = value
        case .bytes(let offset, let data):
            guard let header, !data.isEmpty, offset == range.lowerBound + Int64(bytes.count),
                  Int64(data.count) <= header.range.upperBound - offset + 1 else {
                throw SynologyAPIError.invalidResponse
            }
            bytes.append(data)
        }
        wake()
    }

    func completedData() throws -> (VideoRangeHeader, Data) {
        guard let header, bytes.count == Int(header.range.upperBound - header.range.lowerBound + 1) else {
            throw SynologyAPIError.invalidResponse
        }
        return (header, bytes)
    }

    func read(from offset: Int64) async throws -> VideoPlaybackData? {
        while true {
            try Task.checkCancellation()
            if cancelled { throw CancellationError() }
            if let header, offset >= range.lowerBound {
                let relative = offset - range.lowerBound
                if relative < Int64(bytes.count) {
                    let data = Data(bytes[Int(relative)...])
                    return VideoPlaybackData(data: data, range: offset...(offset + Int64(data.count) - 1),
                                             totalLength: header.totalLength, contentType: header.contentType,
                                             etag: header.etag, lastModified: header.lastModified)
                }
            }
            if let result {
                try result.get()
                return nil
            }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func finish(_ value: Result<Void, Error>) { result = value; wake() }
    private func wake() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
