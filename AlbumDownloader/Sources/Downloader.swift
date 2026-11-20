import Foundation

/// Downloads an album's originals one at a time and keeps going through outages.
///
/// - A failure while the server is unreachable is an outage: the item is not charged and the
///   downloader waits, without limit, until the server answers again.
/// - A failure while the server is reachable counts against the item (`RetryQueue`), except a
///   dropped transfer that still added bytes to the partial file while the server resumes.
/// - An expired session is renewed and the item retried.
final class Downloader {
    struct Summary {
        let downloaded: Int
        let givenUp: [(item: AlbumItem, reason: String)]
    }

    private let api: Synology
    private let reference: String
    private let state: DownloadState
    private let items: [AlbumItem]
    /// Set once the server answers a range request with a full `200`; partial progress then
    /// no longer excuses a failed attempt, because the next attempt starts over.
    private var serverIgnoresRanges = false

    init(api: Synology, reference: String, state: DownloadState, items: [AlbumItem]) {
        self.api = api
        self.reference = reference
        self.state = state
        self.items = items
    }

    func run() -> Summary {
        let remaining = items.filter { !state.isComplete($0.id) }
        let totalBytes = items.reduce(Int64(0)) { $0 + $1.filesize }
        var doneBytes = items.filter { state.isComplete($0.id) }.reduce(Int64(0)) { $0 + $1.filesize }
        var doneCount = items.count - remaining.count
        var downloaded = 0
        var renewals = 0
        var queue = RetryQueue(remaining)
        let width = String(items.count).count

        while let entry = queue.current {
            let item = entry.item
            let position = String(repeating: " ", count: width - String(doneCount + 1).count) + "\(doneCount + 1)"
            let counter = "[\(position)/\(items.count)]"
            let label = "\(counter) \(item.filename)"
            guard let partial = try? state.partialFile(for: item.id) else {
                Console.say("Can't write to \(state.folder.path). Check the disk and run this again.")
                break
            }
            let sizeBefore = Self.size(of: partial)
            let started = Date()

            do {
                let name = try fetch(item, into: partial) { size, total in
                    let fileTotal = total ?? item.filesize
                    let elapsed = max(Date().timeIntervalSince(started), 0.001)
                    let speed = Double(max(0, size - sizeBefore)) / elapsed
                    let overall = totalBytes > 0 ? Int(Double(doneBytes + size) / Double(totalBytes) * 100) : 0
                    Console.status("\(counter) \(Console.bytes(size)) of \(Console.bytes(fileTotal))  ·  "
                                   + "\(overall)% of album  ·  \(Console.bytes(Int64(speed)))/s  ·  \(item.filename)")
                }
                queue.succeeded()
                renewals = 0
                downloaded += 1
                doneCount += 1
                doneBytes += item.filesize
                Console.say("\(label)  \(Console.bytes(Self.size(of: state.folder.appendingPathComponent(name))))"
                            + (name == item.filename ? "" : "  → \(name)"))
                noteRangeSupport(resumedFrom: sizeBefore)
            } catch let error as TransferError where error.isSessionExpired && renewals < 3 {
                renewals += 1
                renewSession()
            } catch {
                let failure = error as? TransferError ?? .invalid(error.localizedDescription)
                renewals = 0
                noteRangeSupport(resumedFrom: sizeBefore)
                if case .network = failure {
                    if !api.isReachable() {
                        waitForServer(after: failure)
                        continue
                    }
                    if !serverIgnoresRanges, Self.size(of: partial) > sizeBefore {
                        // Progress was kept; the next attempt continues from there.
                        Console.say("\(label)  interrupted (\(failure.message)); resuming")
                        pause(2, "Resuming", item.filename)
                        continue
                    }
                }
                let attempt = entry.failures + 1
                switch queue.failed(reason: failure.message) {
                case .retry(let delay):
                    Console.say("\(label)  failed (\(failure.message)), attempt \(attempt) of \(RetryQueue<AlbumItem>.attemptsPerRound)")
                    pause(delay, "Retrying", item.filename)
                case .deferred(let delay):
                    Console.say("\(label)  failed \(RetryQueue<AlbumItem>.attemptsPerRound) times; trying it again after the others")
                    if delay > 0 { pause(delay, "Trying again", item.filename) }
                case .gaveUp:
                    Console.say("\(label)  failed \(RetryQueue<AlbumItem>.attemptsPerRound * RetryQueue<AlbumItem>.maximumRounds) times; skipped for now")
                }
            }
        }
        state.cleanUp()
        return Summary(downloaded: downloaded,
                       givenUp: queue.givenUp.map { ($0.item, $0.lastError) })
    }

    /// Downloads one item and moves it into the folder; returns its file name there.
    private func fetch(_ item: AlbumItem, into partial: URL,
                       progress: @escaping (Int64, Int64?) -> Void) throws -> String {
        var outcome = try api.download(item: item, reference: reference, into: partial, progress: progress)
        if case .rangeMismatch = outcome {
            try? FileManager.default.removeItem(at: partial)
            outcome = try api.download(item: item, reference: reference, into: partial, progress: progress)
        }
        switch outcome {
        case .rangeMismatch:
            throw TransferError.invalid("The server did not continue the interrupted download.")
        case .body(let response, let data):
            if let code = Synology.apiErrorCode(in: data) { throw TransferError.api(code) }
            if response.statusCode != 200, response.statusCode != 206 { throw TransferError.http(response.statusCode) }
            throw TransferError.invalid("The server sent no file.")
        case .file(let response, let size, _):
            guard size > 0 else {
                try? FileManager.default.removeItem(at: partial)
                throw TransferError.invalid("The server sent an empty file.")
            }
            if size <= 4_096, let data = try? Data(contentsOf: partial), let code = Synology.apiErrorCode(in: data) {
                try? FileManager.default.removeItem(at: partial)
                throw TransferError.api(code)
            }
            let disposition = response.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            let suggested = disposition.contains("filename") ? response.suggestedFilename : nil
            let filename = DownloadState.safeName(suggested ?? item.filename,
                                                  fallback: DownloadState.safeName(item.filename, fallback: "item-\(item.id)"))
            do {
                return try state.complete(item.id, partial: partial, filename: filename)
            } catch {
                throw TransferError.invalid("Could not save the file: \(error.localizedDescription)")
            }
        }
    }

    private func noteRangeSupport(resumedFrom offset: Int64) {
        if offset > 0, api.http.lastStreamStatus == 200 { serverIgnoresRanges = true }
    }

    /// Waits until the server answers again, however long that takes.
    private func waitForServer(after failure: TransferError) {
        let since = Date()
        Console.say("Lost the connection to the server (\(failure.message)). Waiting for it to come back.")
        var delay: TimeInterval = 5
        while true {
            pause(delay, "Checking again", "server unreachable for \(Console.duration(Date().timeIntervalSince(since)))")
            Console.status("Checking the connection…")
            if api.isReachable() {
                Console.say("Connection is back after \(Console.duration(Date().timeIntervalSince(since))).")
                return
            }
            delay = min(delay * 2, 60)
        }
    }

    /// Signs in again after DSM expired the session; asks for input only when DSM requires it.
    private func renewSession() {
        var password: String?
        var code: String?
        while true {
            do {
                try api.renewSession(password: password, code: code)
                return
            } catch SignInError.codeRequired, SignInError.wrongCode {
                Console.bell()
                code = Console.ask("The session expired. Two-factor code: ")
            } catch SignInError.rejected(let message) {
                Console.bell()
                Console.say("Signing in again failed: \(message)")
                password = Console.secret(api.isGuest ? "Link password: " : "Password: ")
                code = nil
            } catch let error as TransferError {
                if case .network = error, !api.isReachable() {
                    waitForServer(after: error)
                } else {
                    Console.say("Signing in again failed (\(error.message)).")
                    pause(30, "Signing in again", "the session expired")
                }
            } catch {
                pause(30, "Signing in again", "the session expired")
            }
        }
    }

    private func pause(_ seconds: TimeInterval, _ action: String, _ subject: String) {
        let end = Date().addingTimeInterval(seconds)
        while true {
            let left = end.timeIntervalSinceNow
            if left <= 0 { break }
            Console.status("\(action) in \(Int(left.rounded(.up))) s  ·  \(subject)")
            Thread.sleep(forTimeInterval: min(1, left))
        }
        Console.clearStatus()
    }

    private static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
