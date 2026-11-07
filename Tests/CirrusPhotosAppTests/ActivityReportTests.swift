import Foundation
import PhotoCache
import SynologyAPI
import XCTest
@testable import CirrusPhotosApp

final class ActivityReportTests: XCTestCase {
    func testFailureChainNamesWrappedErrorsWithoutServerText() {
        let batch = BatchFavoriteError(outcome: BatchFavoriteOutcome(successfulCount: 100, failedIDs: [101, 102]),
                                       underlyingError: SynologyAPIError.api(1003))
        XCTAssertEqual(ActivityFailure(error: batch, operation: "Favorites").underlying,
                       ["BatchFavoriteError(succeeded: 100, failed: 2)", "SynologyAPIError.api(1003)"])

        let transport = RepositoryError.server(.transport("host nas.example _sid=secret"))
        XCTAssertEqual(ActivityFailure(error: transport, operation: "Refresh").underlying,
                       ["RepositoryError.server", "SynologyAPIError.transport"])

        let nested = NSError(domain: "Outer", code: 2, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        let lines = ActivityFailure(error: nested, operation: "Download").underlying
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("Outer(2)"))
        XCTAssertEqual(lines[1], "URLError(\(URLError.Code.timedOut.rawValue))")
    }

    func testUnconfirmedFailureIsFlagged() {
        let failure = ActivityFailure(error: RepositoryError.unconfirmed("Unknown"), operation: "Deletion")
        XCTAssertTrue(failure.unconfirmed)
        XCTAssertEqual(failure.errorKind, "unconfirmed")
    }

    func testScrubRemovesSessionAndCredentialValues() {
        XCTAssertEqual(ActivityReport.scrub("GET /webapi/entry.cgi?api=x&_sid=abc123&SynoToken=tok passwd=hunter2 done"),
                       "GET /webapi/entry.cgi?api=x&_sid=<removed>&SynoToken=<removed> passwd=<removed> done")
    }

    func testReportListsContextAndItems() throws {
        let photo = try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":7,\"filename\":\"a.jpg\",\"time\":1,\"type\":\"photo\"}".utf8))
        var file = ActivityItem(file: URL(fileURLWithPath: "/tmp/b.heic"))
        file.message = "Upload rejected"
        let failure = ActivityFailure(error: SynologyAPIError.http(502), operation: "Favorites",
                                      date: Date(timeIntervalSince1970: 0))
        let text = ActivityReport.text(title: "Favoriting failed for 2 photos", failure: failure,
                                       items: [ActivityItem(photo: photo, collection: .library(.personal)), file],
                                       connection: "Connected", osVersion: "27.0")
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("Cirrus Photos "))
        XCTAssertTrue(lines[0].hasSuffix("macOS 27.0"))
        XCTAssertEqual(lines[1], "1970-01-01T00:00:00Z · Favorites · server")
        XCTAssertTrue(lines.contains("Action: Favoriting failed for 2 photos"))
        XCTAssertTrue(lines.contains("Message: The NAS returned HTTP 502."))
        XCTAssertTrue(lines.contains("Underlying: SynologyAPIError.http(502)"))
        XCTAssertTrue(lines.contains("Connection: Connected"))
        XCTAssertTrue(lines.contains("Collection: \(PhotoCollectionDescriptor.library(.personal).rawValue)"))
        XCTAssertTrue(lines.contains("Items (2): 7 a.jpg, b.heic"))
        XCTAssertTrue(lines.contains("Item b.heic: Upload rejected"))
    }
}
