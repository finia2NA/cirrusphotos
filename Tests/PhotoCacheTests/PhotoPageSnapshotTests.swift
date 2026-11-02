import Foundation
import XCTest
import SynologyAPI
@testable import PhotoCache

final class PhotoPageSnapshotTests: XCTestCase {
    func testSparseSlotRetainsIdentityPositionAndIndividualAuthority() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data(#"{"id":2,"time":1704067200,"type":"photo"}"#.utf8))
        let page = PhotoPageSnapshot(address: try .init(collection: .library(.personal), day: CaptureDay(time: item.time), offset: 0), membershipRevision: 1,
                                     membershipVerified: true, slots: [.init(itemID: 1, item: nil, verified: true), .init(itemID: 2, item: item, verified: true)])
        XCTAssertEqual(page.slots.map(\.itemID), [1, 2])
        XCTAssertNil(page.slots[0].item)
        XCTAssertFalse(page.slots[0].verified)
        XCTAssertEqual(page.slots[1].item?.id, 2)
        XCTAssertTrue(page.slots[1].verified)
        XCTAssertFalse(page.verified)
    }
    func testViewerUsesFreshMembershipToRemapSelectedIDDespiteUnrelatedHole() async throws {
        let root = temporaryTestRoot("sparse-viewer"); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try JSONDecoder().decode(PhotoItem.self, from: Data(#"{"id":2,"time":1704067200,"type":"photo"}"#.utf8))
        let other = try JSONDecoder().decode(PhotoItem.self, from: Data(#"{"id":3,"time":1704067200,"type":"photo"}"#.utf8))
        let repository = try CachedPhotosRepository(credentials: .init(username: "sparse", password: "unused"), cacheRoot: root, transport: SparseNoNetworkTransport())
        let snapshot = TimelineSnapshot(sections: [.init(offset: 0, limit: 3, list: [.init(year: 2024, month: 1, day: 1, itemCount: 3)])])
        let session = PhotoViewerSession(repository: repository, index: LibraryIndex(snapshot: snapshot), seed: .init(sectionIndex: 0, pageOffset: 0, item: selected, pageVerified: true), allowNetwork: false)
        let page = ViewerMetadataWindow.PageEntry(slots: [.init(itemID: 1, item: nil, verified: false), .init(itemID: 3, item: other, verified: true), .init(itemID: 2, item: selected, verified: true)], verified: false, membershipVerified: true)
        await session.applyCurrentPage(page, at: .init(sectionIndex: 0, pageOffset: 0, ordinal: 0))
        let current = await session.state()
        XCTAssertEqual(current.item?.id, 2)
        XCTAssertEqual(current.desiredLocation.pageOffset, 2)
        XCTAssertTrue(current.metadataVerified)
        let missing = ViewerMetadataWindow.PageEntry(slots: [.init(itemID: 1, item: nil, verified: false), .init(itemID: 3, item: other, verified: true), .init(itemID: 2, item: nil, verified: false)], verified: false, membershipVerified: true)
        await session.applyCurrentPage(missing, at: current.desiredLocation)
        let retained = await session.state()
        XCTAssertEqual(retained.item?.id, 2)
        XCTAssertFalse(retained.metadataVerified)
        await session.close()
    }

}

private struct SparseNoNetworkTransport: PhotosTransport {}
