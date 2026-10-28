import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class FilterPageRebaserTests: XCTestCase {
    private func item(_ id: Int64) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":\(id),"filename":"\(id).jpg","time":1713571200,"type":"photo"}
        """.utf8))
    }

    func testInsertionRetainsKnownSlotsAndRequestsMissingDetails() throws {
        let old = LibraryPage(sectionIndex: 0, items: [try item(1), try item(2)], verified: true)
        let pages = FilterPageRebaser.rebase(pages: [0: old], membership: [[3, 1, 2]])
        let page = try XCTUnwrap(pages[0])
        XCTAssertEqual(page.slots.map(\.itemID), [3, 1, 2])
        XCTAssertNil(page.slots[0].item)
        XCTAssertEqual(page.slots[1].item?.id, 1)
        XCTAssertEqual(page.slots[2].item?.id, 2)
        XCTAssertFalse(page.verified)
        XCTAssertTrue(page.membershipVerified)
    }

    func testSameCountReplacementDoesNotReuseObsoleteMember() throws {
        let old = LibraryPage(sectionIndex: 0, items: [try item(1), try item(2)], verified: true)
        let pages = FilterPageRebaser.rebase(pages: [0: old], membership: [[1, 3]])
        let page = try XCTUnwrap(pages[0])
        XCTAssertEqual(page.slots.map(\.itemID), [1, 3])
        XCTAssertNil(page.slots[1].item)
        XCTAssertFalse(page.verified)
        XCTAssertFalse(page.slots[1].verified)
    }

    func testUnchangedIDsLoseAuthorityWhenSourceMembershipIsInvalidated() throws {
        let old = LibraryPage(sectionIndex: 0, items: [try item(1), try item(2)], verified: true)
        let pages = FilterPageRebaser.rebase(pages: [0: old], membership: [[1, 2]], sourceAuthority: [[false, false]])
        let page = try XCTUnwrap(pages[0])
        XCTAssertEqual(page.items.map(\.id), [1, 2])
        XCTAssertFalse(page.verified)
        XCTAssertFalse(page.membershipVerified)
        XCTAssertTrue(page.slots.allSatisfy { !$0.verified })
    }

    func testUnchangedPageMovesAndRemainsVerified() throws {
        let old = LibraryPage(sectionIndex: 0, items: [try item(1), try item(2)], verified: true)
        let pages = FilterPageRebaser.rebase(pages: [0: old], membership: [[99], [1, 2]])
        XCTAssertNil(pages[0])
        XCTAssertEqual(pages[1]?.slots.map(\.itemID), [1, 2])
        XCTAssertEqual(pages[1]?.verified, true)
    }
}
