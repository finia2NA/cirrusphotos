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

    private func annotated(rating: Int?, tags: [String]) throws -> PhotoItem {
        let tagJSON = tags.enumerated().map { #"{"id":\#($0.offset + 1),"name":"\#($0.element)"}"# }.joined(separator: ",")
        let ratingJSON = rating.map { #","rating":\#($0)"# } ?? ""
        return try JSONDecoder().decode(PhotoItem.self, from: Data(
            #"{"id":1,"filename":"a.jpg","time":1,"type":"photo","additional":{"tag":[\#(tagJSON)]\#(ratingJSON)}}"#.utf8))
    }

    func testTagFacetMatchesAnyTagByFoldedName() throws {
        let tagged = try annotated(rating: nil, tags: ["Holiday", "Family"])
        XCTAssertTrue(LibraryFilter(tags: ["family"]).matches(tagged))
        XCTAssertTrue(LibraryFilter(tags: ["Other", " HOLIDAY "]).matches(tagged), "tags within the facet are ORed")
        XCTAssertFalse(LibraryFilter(tags: ["Other"]).matches(tagged))
        XCTAssertFalse(LibraryFilter(tags: ["Holiday"]).matches(try annotated(rating: nil, tags: [])))
        XCTAssertTrue(LibraryFilter().matches(try annotated(rating: nil, tags: [])))
    }

    func testRatingRangesTreatMissingRatingAsUnrated() throws {
        let unrated = try annotated(rating: nil, tags: [])
        let three = try annotated(rating: 3, tags: [])
        let unratedOnly = LibraryFilter(rating: .init(minimum: 0, maximum: 0))
        XCTAssertTrue(unratedOnly.matches(unrated))
        XCTAssertFalse(unratedOnly.matches(three))
        let atLeastThree = LibraryFilter(rating: .init(minimum: 3))
        XCTAssertFalse(atLeastThree.matches(unrated))
        XCTAssertTrue(atLeastThree.matches(three))
        XCTAssertTrue(atLeastThree.matches(try annotated(rating: 5, tags: [])))
        XCTAssertFalse(LibraryFilter(rating: .init(minimum: 4)).matches(three))
    }

    func testTagAndRatingCountAsCriteria() {
        XCTAssertTrue(LibraryFilter().isEmpty)
        XCTAssertFalse(LibraryFilter(tags: ["a"]).isEmpty)
        XCTAssertFalse(LibraryFilter(rating: .init(minimum: 1)).isEmpty)
        XCTAssertEqual(LibraryFilter(tags: ["a"], rating: .init(minimum: 1)).activeCriterionCount, 2)
    }

    func testStoredFacetsRoundTripRatingAndTags() throws {
        let item = try annotated(rating: 4, tags: ["Holiday", "Family"])
        let values = ItemFacets(item).values
        XCTAssertEqual(values.rating, 4)
        XCTAssertEqual(values.tags, ["Holiday", "Family"])
        XCTAssertEqual(ItemFacets(try annotated(rating: nil, tags: [])).values.tags, [])
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
