import Foundation
import XCTest
@testable import SynologyAPI

final class ScopedCollectionDescriptorTests: XCTestCase {
    func testCollectionKindsRetainScopeThroughIdentityAndCoding() throws {
        for space in PhotoSpace.allCases {
            let collections: [PhotoCollectionDescriptor] = [.library(space), .favorites(space),
                .folder(7, space: space), .person(7, space: space), .subject(7, space: space), .tag(7, space: space),
                .mapFilter(UUID(), space: space), .libraryFilter(UUID(), scope: .space(space))]
            for collection in collections {
                XCTAssertEqual(collection.space, space)
                XCTAssertEqual(collection.contentScope, .space(space))
                XCTAssertEqual(PhotoCollectionDescriptor(rawValue: collection.rawValue), collection)
                XCTAssertEqual(try JSONDecoder().decode(PhotoCollectionDescriptor.self, from: JSONEncoder().encode(collection)), collection)
            }
        }
        XCTAssertNotEqual(PhotoCollectionDescriptor.person(7, space: .personal), .person(7, space: .shared))
    }

    func testAlbumAuthorityHasNoImpliedOriginAndUnsupportedSharedRoutesCannotDecode() throws {
        for collection in [PhotoCollectionDescriptor.album(7), .incomingAlbum(ownerID: 3, albumID: 7)] {
            XCTAssertNil(collection.space)
            let filtered = PhotoCollectionDescriptor.libraryFilter(UUID(), scope: collection.contentScope)
            XCTAssertNil(filtered.space)
            XCTAssertEqual(PhotoCollectionDescriptor(rawValue: filtered.rawValue), filtered)
        }
        XCTAssertNil(PhotoCollectionDescriptor(rawValue: "shared:recently-added"))
        XCTAssertNil(PhotoCollectionDescriptor(rawValue: "shared:album:7"))
        XCTAssertNil(PhotoCollectionDescriptor(rawValue: "shared:shared:person:7"))
    }
}
