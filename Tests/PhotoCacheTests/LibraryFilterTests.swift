import Foundation
import XCTest
@testable import PhotoCache
import SynologyAPI

final class LibraryFilterTests: XCTestCase {
    private func item(filename: String = "IMG.HIF", camera: String = "Fujifilm X-T5",
                      lens: String = "XF 23mm", iso: String = "ISO 400", exposure: String = "1/250 s",
                      type: String = "photo") throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"filename":"\(filename)","time":1,"type":"\(type)","filesize":2000000,
         "additional":{"resolution":{"width":4000,"height":3000},
         "exif":{"camera":"\(camera)","lens":"\(lens)","iso":"\(iso)","focal_length":"23 mm","aperture":"F2.8","exposure_time":"\(exposure)"}}}
        """.utf8))
    }

    func testFacetSemanticsAndInclusiveRanges() throws {
        let value = try item()
        var filter = LibraryFilter(cameras: [" fujifilm x-t5 "], extensions: ["hif"],
                                   megapixels: .init(minimum: 12, maximum: 12),
                                   iso: .init(minimum: 400, maximum: 400))
        XCTAssertTrue(filter.matches(value))
        filter.cameras = ["Other", "FUJIFILM X-T5"]
        XCTAssertTrue(filter.matches(value), "values within a facet are ORed")
        filter.extensions = ["HEIC"]
        XCTAssertFalse(filter.matches(value), "facets are ANDed and extensions remain literal")
    }

    func testMissingValueFailsOnlyWhenRangeIsActive() throws {
        let value = try item(iso: "unknown")
        XCTAssertTrue(LibraryFilter().matches(value))
        XCTAssertFalse(LibraryFilter(iso: .init(minimum: 100)).matches(value))
    }

    func testVideoOnlyMediaFilterRejectsPhotosAndAcceptsVideos() throws {
        let photo = try item(type: "photo")
        let video = try item(filename: "clip.MOV", type: "video")
        let filter = LibraryFilter(mediaKinds: [.video])
        XCTAssertFalse(filter.matches(photo))
        XCTAssertTrue(filter.matches(video))
    }

    func testFilenameTextSearchIgnoresCaseAndDiacritics() throws {
        let value = try item(filename: "Café_DSCF4417.JPG")
        XCTAssertTrue(LibraryFilter(filename: .init("dscf44")).matches(value))
        XCTAssertTrue(LibraryFilter(filename: .init(" cafe ")).matches(value))
        XCTAssertFalse(LibraryFilter(filename: .init("dscf45")).matches(value))
        XCTAssertTrue(LibraryFilter(filename: .init("   ")).isEmpty, "whitespace-only text is no criterion")
        XCTAssertEqual(LibraryFilter(filename: .init("x")).activeCriterionCount, 1)
    }

    func testFilenameRegularExpressionMatchesAnywhereWithoutCase() throws {
        let value = try item(filename: "DSCF4417.JPG")
        XCTAssertTrue(LibraryFilter(filename: .init(#"^dscf\d{4}\.jpg$"#, mode: .regularExpression)).matches(value))
        XCTAssertTrue(LibraryFilter(filename: .init("44", mode: .regularExpression)).matches(value))
        XCTAssertFalse(LibraryFilter(filename: .init(#"^IMG_"#, mode: .regularExpression)).matches(value))
        XCTAssertFalse(LibraryFilter(filename: .init("(?-i)dscf", mode: .regularExpression)).matches(value))
        let invalid = FilenameSearch("[", mode: .regularExpression)
        XCTAssertFalse(invalid.isValid)
        XCTAssertFalse(LibraryFilter(filename: invalid).matches(value))
        XCTAssertNotEqual(FilenameSearch("a"), FilenameSearch("a", mode: .regularExpression))
    }

    func testPureParsersRejectMalformedAndNonPositiveValues() {
        XCTAssertEqual(LibraryFilterParsing.firstPositiveNumber("ISO 1250"), 1250)
        XCTAssertEqual(LibraryFilterParsing.firstPositiveNumber("9.0 mm"), 9)
        XCTAssertEqual(LibraryFilterParsing.aperture("f/2.8"), 2.8)
        XCTAssertEqual(LibraryFilterParsing.exposureSeconds("1/250 s")!, 0.004, accuracy: 0.000001)
        XCTAssertEqual(LibraryFilterParsing.exposureSeconds("0.004s")!, 0.004, accuracy: 0.000001)
        XCTAssertNil(LibraryFilterParsing.exposureSeconds("1/0"))
        XCTAssertNil(LibraryFilterParsing.firstPositiveNumber("-4"))
        XCTAssertNil(LibraryFilterParsing.firstPositiveNumber("nan"))
        XCTAssertEqual(LibraryFilterParsing.fileExtension("edited.heic"), "HEIC")
        XCTAssertNil(LibraryFilterParsing.fileExtension("no-extension"))
    }
}
