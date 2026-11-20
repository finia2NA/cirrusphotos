import CryptoKit
import Foundation
import Security

enum TransferError: Error {
    /// The request did not complete at the transport level (no route, timeout, dropped connection).
    case network(String)
    case untrustedCertificate(fingerprint: String?)
    case http(Int)
    case api(Int)
    case invalid(String)

    var isSessionExpired: Bool {
        if case .api(let code) = self { return [106, 107, 119].contains(code) }
        return false
    }

    var message: String {
        switch self {
        case .network(let text): return text
        case .untrustedCertificate: return "The server's certificate is not trusted."
        case .http(let status): return "HTTP status \(status)"
        case .api(let code): return "Synology error \(code)"
        case .invalid(let text): return text
        }
    }
}

/// `bytes <start>-<end>/<total>`
struct ContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64?

    init?(_ header: String?) {
        guard let header = header?.trimmingCharacters(in: .whitespaces).lowercased(),
              header.hasPrefix("bytes ") else { return nil }
        let spec = header.dropFirst("bytes ".count)
        let halves = spec.split(separator: "/", maxSplits: 1).map(String.init)
        let bounds = halves.first?.split(separator: "-").map(String.init) ?? []
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        self.start = start
        self.end = end
        total = halves.count == 2 ? Int64(halves[1]) : nil
    }
}

/// The result of streaming one response into a partial file.
enum StreamOutcome {
    /// Media bytes are in the partial file, which now holds `size` bytes of `total`.
    case file(HTTPURLResponse, size: Int64, total: Int64?)
    /// A non-media response (an error page or a JSON envelope); nothing was written.
    case body(HTTPURLResponse, Data)
    /// The server answered a resume request with a different range.
    case rangeMismatch
}

/// A small synchronous HTTP client for one DSM host. One request runs at a time.
final class HTTPClient: NSObject, URLSessionDataDelegate {
    private var session: URLSession!
    private let host: String
    private let lock = NSLock()
    private var acceptedFingerprint: String?
    private var rejectedFingerprint: String?
    private var stream: Stream?
    /// The status of the last streamed response, also when its transfer failed afterwards.
    private(set) var lastStreamStatus: Int?

    init(server: URL) {
        host = server.host?.lowercased() ?? ""
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        // Inactivity timeout; it resets whenever data arrives.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Accepts a certificate that the system does not trust, identified by its SHA-256.
    func trust(fingerprint: String) {
        lock.lock(); acceptedFingerprint = fingerprint; lock.unlock()
    }

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<(Data, HTTPURLResponse), TransferError> = .failure(.invalid("No response"))
        session.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(self.classify(error))
            } else if let http = response as? HTTPURLResponse {
                outcome = .success((data ?? Data(), http))
            }
            done.signal()
        }.resume()
        done.wait()
        return try outcome.get()
    }

    /// Streams a response into `partial`. A `200` replaces the file; a `206` whose range starts at
    /// the file's current size appends to it.
    func stream(_ request: URLRequest, into partial: URL,
                progress: @escaping (_ size: Int64, _ total: Int64?) -> Void) throws -> StreamOutcome {
        let offset = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        let current = Stream(partial: partial, offset: offset, progress: progress)
        lock.lock(); stream = current; lock.unlock()
        session.dataTask(with: request).resume()
        current.done.wait()
        lock.lock(); stream = nil; lock.unlock()
        lastStreamStatus = current.response?.statusCode

        if current.rangeMismatch { return .rangeMismatch }
        if let error = current.error { throw error }
        guard let response = current.response else { throw TransferError.invalid("No response") }
        if current.writing {
            if let total = current.total, current.size != total {
                throw TransferError.network("The connection ended after \(current.size) of \(total) bytes.")
            }
            return .file(response, size: current.size, total: current.total)
        }
        return .body(response, current.body)
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        let fingerprint = Self.leafFingerprint(trust)
        lock.lock()
        let accepted = fingerprint != nil && fingerprint == acceptedFingerprint
        if !accepted { rejectedFingerprint = fingerprint }
        lock.unlock()
        if accepted {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let stream = currentStream(), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        stream.response = http
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isMedia = !type.contains("json") && !type.contains("text/html")
        do {
            if http.statusCode == 206, isMedia {
                guard let range = ContentRange(http.value(forHTTPHeaderField: "Content-Range")),
                      range.start == stream.offset else {
                    stream.rangeMismatch = true
                    completionHandler(.cancel)
                    return
                }
                try stream.open(truncatingTo: stream.offset)
                stream.total = range.total
            } else if http.statusCode == 200, isMedia {
                try stream.open(truncatingTo: 0)
                stream.total = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            }
        } catch {
            stream.error = .invalid("Could not write the file: \(error.localizedDescription)")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let stream = currentStream() else { return }
        if stream.writing {
            do {
                try stream.handle?.write(contentsOf: data)
                stream.size += Int64(data.count)
                stream.reportProgress()
            } catch {
                stream.error = .invalid("Could not write the file: \(error.localizedDescription)")
                dataTask.cancel()
            }
        } else if stream.body.count < 65_536 {
            stream.body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Completion-handler tasks also end here; only streamed ones have a current stream.
        guard let stream = currentStream() else { return }
        try? stream.handle?.close()
        stream.handle = nil
        if let error, stream.error == nil, !stream.rangeMismatch {
            stream.error = classify(error)
        }
        stream.done.signal()
    }

    // MARK: Helpers

    private func currentStream() -> Stream? {
        lock.lock(); defer { lock.unlock() }
        return stream
    }

    private func classify(_ error: Error) -> TransferError {
        lock.lock()
        let rejected = rejectedFingerprint
        rejectedFingerprint = nil
        lock.unlock()
        // A refused certificate surfaces as a cancellation or a TLS error, depending on the OS.
        if rejected != nil, error is URLError { return .untrustedCertificate(fingerprint: rejected) }
        return .network(error.localizedDescription)
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

private final class Stream {
    let partial: URL
    let offset: Int64
    let progress: (Int64, Int64?) -> Void
    let done = DispatchSemaphore(value: 0)
    var response: HTTPURLResponse?
    var handle: FileHandle?
    var writing = false
    var size: Int64 = 0
    var total: Int64?
    var body = Data()
    var error: TransferError?
    var rangeMismatch = false
    private var lastReport = Date.distantPast

    init(partial: URL, offset: Int64, progress: @escaping (Int64, Int64?) -> Void) {
        self.partial = partial
        self.offset = offset
        self.progress = progress
    }

    func open(truncatingTo length: Int64) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: partial.path) {
            guard manager.createFile(atPath: partial.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.truncate(atOffset: UInt64(length))
        try handle.seekToEnd()
        self.handle = handle
        size = length
        writing = true
    }

    func reportProgress() {
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.25 else { return }
        lastReport = now
        progress(size, total)
    }
}
