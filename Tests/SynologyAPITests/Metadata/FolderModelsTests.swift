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

    func testUnreadableCoverAndPermissionAreLeftOutAndListed() throws {
        let json = #"""
        {"id":7,"parent":2,"name":"/Trips","additional":{
          "thumbnail":[{"unit_id":1,"cache_key":"1_1","m":"ready"},{"unit_id":null,"cache_key":"2_1"},{"cache_key":"3_1"},"x",{"unit_id":4,"cache_key":"4_1"}],
          "access_permission":{"view":1,"download":true}}}
        """#
        let folder = try JSONDecoder().decode(FolderSummary.self, from: Data(json.utf8))
        XCTAssertEqual(folder.additional?.thumbnail?.map(\.unitID), [1, 4])
        XCTAssertNil(folder.additional?.accessPermission)
        XCTAssertEqual(folder.unreadableFields.count, 4)
        XCTAssertTrue(folder.unreadableFields[0].hasPrefix("additional.thumbnail[1]: null at"))
        XCTAssertTrue(folder.unreadableFields[1].hasPrefix("additional.thumbnail[2]: missing key"))
        XCTAssertTrue(folder.unreadableFields[1].hasSuffix("unit_id"))
        XCTAssertTrue(folder.unreadableFields[2].hasPrefix("additional.thumbnail[3]: type mismatch"))
        XCTAssertTrue(folder.unreadableFields[3].hasPrefix("additional.access_permission: type mismatch"))

        let stored = try JSONDecoder().decode(FolderSummary.self, from: JSONEncoder().encode(folder))
        XCTAssertEqual(stored, folder)
        XCTAssertEqual(stored.unreadableFields, [])
    }

    func testFolderWithoutNameStillFails() {
        let json = #"{"id":7,"parent":2,"additional":{"thumbnail":[]}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(FolderSummary.self, from: Data(json.utf8)))
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
