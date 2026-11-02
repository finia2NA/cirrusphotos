import Foundation
import XCTest
@testable import SynologyAPI

final class FolderModelsTests: XCTestCase {
    func testFolderThumbnailsAndPathDecode() throws {
        let json = #"{"id":7,"parent":2,"name":"/Camera/Trips","additional":{"thumbnail":[]}}"#
        let folder = try JSONDecoder().decode(FolderSummary.self, from: Data(json.utf8))
        XCTAssertEqual(folder.displayName, "Trips")
        XCTAssertNil(folder.thumbnail)
        XCTAssertEqual(folder.parent, 2)
        XCTAssertEqual(try JSONDecoder().decode(FolderSummary.self, from: JSONEncoder().encode(folder)), folder)
    }

    func testFolderCollectionIdentityAndOrdering() throws {
        let collection = PhotoCollectionDescriptor.folder(42, space: .personal)
        XCTAssertEqual(PhotoCollectionDescriptor(rawValue: collection.rawValue), collection)
        XCTAssertEqual(try JSONDecoder().decode(PhotoCollectionDescriptor.self, from: JSONEncoder().encode(collection)), collection)
        XCTAssertTrue(collection.usesItemCatalog)
        XCTAssertNil(collection.albumID)
        XCTAssertEqual(collection.folderID, 42)
    }
}
