import Foundation
import Security

/// A single-response data task whose delegate exposes every delivered body chunk.
/// It is intentionally separate from the authenticated shared session because the
/// completion-handler conveniences buffer the body and do not reliably expose
/// incremental delivery to a per-task delegate.
final class ProgressiveDataTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let allowedHost: String
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (TransferProgress) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var received = Data()
    private var cancelled = false

    init(
        allowedHost: String,
        configuration: URLSessionConfiguration,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) {
        self.allowedHost = allowedHost
        self.configuration = configuration
        self.progress = progress
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(
                    configuration: configuration, delegate: self, delegateQueue: queue
                )
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == allowedHost,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        if response.expectedContentLength > 0,
           response.expectedContentLength <= Int64(Int.max) {
            received.reserveCapacity(Int(response.expectedContentLength))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received.append(data)
        progress(TransferProgress(
            completedBytes: Int64(received.count),
            totalBytes: response?.expectedContentLength
        ))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        let response = response
        let data = received
        lock.unlock()

        session.finishTasksAndInvalidate()
        guard let continuation else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
        } else if let response {
            continuation.resume(returning: (data, response))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
