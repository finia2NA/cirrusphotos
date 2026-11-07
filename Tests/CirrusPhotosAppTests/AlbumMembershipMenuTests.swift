import XCTest
import SynologyAPI
@testable import CirrusPhotosApp

final class AlbumMembershipMenuTests: XCTestCase {
    func testEligiblePinsAreFirstAndDuplicatesAreRemoved() {
        let albums = [AlbumSummary(id: 1, name: "A", itemCount: 0),
                      AlbumSummary(id: 2, name: "B", itemCount: 0),
                      AlbumSummary(id: 3, name: "C", itemCount: 0),
                      AlbumSummary(id: 2, name: "Duplicate", itemCount: 0)]
        let result = orderedAddableAlbums(albums, pinnedIDs: [3, 9, 1, 3])
        XCTAssertEqual(result.pinned.map(\.id), [3, 1])
        XCTAssertEqual(result.remaining.map(\.id), [2])
    }

    func testRemovalRequiresKnownNormalAlbum() {
        let albums = [AlbumSummary(id: 1, name: "Normal", itemCount: 0, type: "normal"),
                      AlbumSummary(id: 2, name: "Generated", itemCount: 0, type: "condition"),
                      AlbumSummary(id: 3, name: "Unknown", itemCount: 0)]
        XCTAssertTrue(isKnownNormalAlbum(1, in: albums))
        XCTAssertFalse(isKnownNormalAlbum(2, in: albums))
        XCTAssertFalse(isKnownNormalAlbum(3, in: albums))
        XCTAssertFalse(isKnownNormalAlbum(4, in: albums))
        XCTAssertFalse(isKnownNormalAlbum(nil, in: albums))
    }
}
