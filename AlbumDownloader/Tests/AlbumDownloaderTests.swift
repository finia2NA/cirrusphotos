import XCTest

final class ShareLinkTests: XCTestCase {
    func testSharingPath() {
        let link = ShareLink("https://nas.example.com:5001/mo/sharing/AbCd1234")
        XCTAssertEqual(link?.server.absoluteString, "https://nas.example.com:5001")
        XCTAssertEqual(link?.reference, "AbCd1234")
    }

    func testPortalAliasAndTrailingParts() {
        let link = ShareLink("  http://cirrus.tail1234.ts.net/photo/mo/sharing/xY_9-z/item/5?x=1 ")
        XCTAssertEqual(link?.server.absoluteString, "http://cirrus.tail1234.ts.net")
        XCTAssertEqual(link?.reference, "xY_9-z")
    }

    func testPassphraseQueryAndMissingScheme() {
        let link = ShareLink("nas.local:5001/?launchApp=SYNO.Foto.AppInstance&passphrase=Ref123")
        XCTAssertEqual(link?.server.absoluteString, "https://nas.local:5001")
        XCTAssertEqual(link?.reference, "Ref123")
    }

    func testRejectsLinksWithoutReference() {
        XCTAssertNil(ShareLink("https://nas.example.com:5001/"))
        XCTAssertNil(ShareLink("https://nas.example.com/mo/sharing/"))
        XCTAssertNil(ShareLink("ftp://nas.example.com/mo/sharing/abc"))
        XCTAssertNil(ShareLink(""))
    }
}

final class RetryQueueTests: XCTestCase {
    func testRetriesThenDefersToEnd() {
        var queue = RetryQueue(["a", "b"])
        for failure in 1..<RetryQueue<String>.attemptsPerRound {
            XCTAssertEqual(queue.failed(reason: "x"), .retry(after: RetryQueue<String>.backoff(afterFailures: failure)))
            XCTAssertEqual(queue.current?.item, "a")
        }
        XCTAssertEqual(queue.failed(reason: "x"), .deferred(pause: 0))
        XCTAssertEqual(queue.pending.map(\.item), ["b", "a"])
        queue.succeeded()
        XCTAssertEqual(queue.current?.item, "a")
        XCTAssertEqual(queue.current?.failures, 0)
    }

    func testGivesUpAfterMaximumRounds() {
        var queue = RetryQueue(["a"])
        var decisions: [RetryQueue<String>.Decision] = []
        for _ in 0..<(RetryQueue<String>.attemptsPerRound * RetryQueue<String>.maximumRounds) {
            decisions.append(queue.failed(reason: "broken"))
        }
        XCTAssertEqual(decisions.filter { $0 == .deferred(pause: RetryQueue<String>.lonePause) }.count,
                       RetryQueue<String>.maximumRounds - 1)
        XCTAssertEqual(decisions.last, .gaveUp)
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.givenUp.map(\.item), ["a"])
        XCTAssertEqual(queue.givenUp.first?.lastError, "broken")
    }

    func testBackoffIsCapped() {
        XCTAssertEqual(RetryQueue<Int>.backoff(afterFailures: 1), 2)
        XCTAssertEqual(RetryQueue<Int>.backoff(afterFailures: 5), 32)
        XCTAssertEqual(RetryQueue<Int>.backoff(afterFailures: 9), 60)
    }
}

final class ContentRangeTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(ContentRange("bytes 100-199/200"), ContentRange("bytes 100-199/200"))
        XCTAssertEqual(ContentRange("bytes 100-199/200")?.start, 100)
        XCTAssertEqual(ContentRange("bytes 100-199/200")?.total, 200)
        XCTAssertNil(ContentRange("bytes 100-199/*")?.total)
        XCTAssertNil(ContentRange("items 1-2/3"))
        XCTAssertNil(ContentRange(nil))
    }
}

final class FileNameTests: XCTestCase {
    func testSafeAndAvailableNames() throws {
        XCTAssertEqual(DownloadState.safeName("../a:b.jpg", fallback: "x"), "a-b.jpg")
        XCTAssertEqual(DownloadState.safeName("...", fallback: "x"), "x")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(DownloadState.availableName(for: "IMG.HEIC", in: folder), "IMG.HEIC")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("IMG.HEIC").path, contents: Data())
        XCTAssertEqual(DownloadState.availableName(for: "IMG.HEIC", in: folder), "IMG (2).HEIC")
    }
}
