import Foundation
import XCTest
@testable import SynologyAPI

final class PhotoItemTests: XCTestCase {
    func testOrientationIsDecodedButDoesNotRotateServerResolutionAgain() throws {
        for orientation in [1, 3, 6, 8] {
            let item = try decode(resolution: "{\"width\":4000,\"height\":2000}",
                                  orientation: ",\"orientation\":\(orientation)")
            XCTAssertEqual(item.displayAspectRatio, 2)
            let restored = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(item))
            XCTAssertEqual(restored.additional?.orientation, orientation)
        }
    }

    func testObservedRotatedItemsMatchServedThumbnailGeometry() throws {
        let portrait = try decode(id: 183538,
                                  resolution: "{\"width\":3024,\"height\":4032}",
                                  orientation: ",\"orientation\":6")
        XCTAssertEqual(portrait.displayAspectRatio, 3024.0 / 4032.0)
        XCTAssertEqual(portrait.displayAspectRatio, 320.0 / 427.0, accuracy: 0.001)

        let landscape = try decode(id: 183471,
                                   resolution: "{\"width\":2208,\"height\":1242}",
                                   orientation: ",\"orientation\":8")
        XCTAssertEqual(landscape.displayAspectRatio, 2208.0 / 1242.0)
        XCTAssertEqual(landscape.displayAspectRatio, 569.0 / 320.0, accuracy: 0.001)
    }

    func testMinimalRecordAndInvalidResolution() throws {
        let minimal = try decode(resolution: "{\"width\":4000,\"height\":2000}", orientation: "")
        XCTAssertNil(minimal.filename)
        XCTAssertNil(minimal.additional?.orientation)
        XCTAssertEqual(minimal.displayAspectRatio, 2)
        XCTAssertEqual(try decode(resolution: "{\"width\":0,\"height\":2000}", orientation: "").displayAspectRatio, 1)
        XCTAssertEqual(try decode(resolution: "{\"width\":4000,\"height\":-1}", orientation: "").displayAspectRatio, 1)
    }

    func testFilenameAndFullImageResourceDecodeWithOptionalMetadata() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":7,"filename":"IMG_0007.HEIC","time":1700000000,"type":"photo","additional":{"thumbnail":{"unit_id":17,"cache_key":"17_revision","sm":"ready"}}}
        """.utf8))
        XCTAssertEqual(item.filename, "IMG_0007.HEIC")
        let resource = try XCTUnwrap(item.fullImageResource)
        XCTAssertEqual(resource.unitID, 17)
        XCTAssertEqual(resource.cacheKey, "17_revision")
        XCTAssertEqual(resource.filename, "IMG_0007.HEIC")
    }

    func testLivePhotoDecodesStillMemberAndProvidesFullImageResource() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":12,"filename":"IMG_0012.HEIC","time":1700000000,"type":"live","live_type":"photo","additional":{"thumbnail":{"unit_id":22,"cache_key":"22_revision","sm":"ready"}}}
        """.utf8))

        XCTAssertEqual(item.liveType, "photo")
        XCTAssertTrue(item.hasDisplayableStillImage)
        XCTAssertFalse(item.isVideo)
        let resource = try XCTUnwrap(item.fullImageResource)
        XCTAssertEqual(resource.unitID, 22)
        XCTAssertEqual(resource.filename, "IMG_0012.HEIC")

        let restored = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.liveType, "photo")
        XCTAssertTrue(restored.hasDisplayableStillImage)
    }

    func testStandaloneVideoDoesNotProvideFullImageResource() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":13,"filename":"clip.mov","time":1700000000,"type":"video","additional":{"thumbnail":{"unit_id":23,"cache_key":"23_revision","sm":"ready"}}}
        """.utf8))

        XCTAssertTrue(item.isVideo)
        XCTAssertFalse(item.hasDisplayableStillImage)
        XCTAssertNil(item.fullImageResource)
    }

    func testVideoDurationDecodesFromNumericAndStringMetadata() throws {
        let numeric = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":8,"time":1700000000,"type":"video","additional":{"video_meta":{"duration":125500.5}}}
        """.utf8))
        let string = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":9,"time":1700000000,"type":"video","additional":{"video_meta":{"duration":"61000"}}}
        """.utf8))
        XCTAssertEqual(numeric.additional?.videoMeta?.duration, 125.5005)
        XCTAssertEqual(string.additional?.videoMeta?.duration, 61)
        let restored = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(string))
        XCTAssertEqual(restored.additional?.videoMeta?.duration, 61)
    }

    func testObservedMillisecondDurationDoesNotBecomeHours() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":11,"time":1700000000,"type":"video","additional":{"video_meta":{"duration":49000}}}
        """.utf8))
        XCTAssertEqual(item.additional?.videoMeta?.duration, 49)
    }

    func testUnexpectedVideoMetadataShapeDoesNotDiscardItem() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":10,"time":1700000000,"type":"video","additional":{"video_meta":[]}}
        """.utf8))
        XCTAssertEqual(item.id, 10)
        XCTAssertNil(item.additional?.videoMeta?.duration)
    }

    func testDayIDUsesUTCBoundary() throws {
        let before = try JSONDecoder().decode(PhotoItem.self, from: Data(
            "{\"id\":1,\"time\":1704067199,\"type\":\"photo\"}".utf8))
        let after = try JSONDecoder().decode(PhotoItem.self, from: Data(
            "{\"id\":2,\"time\":1704067200,\"type\":\"photo\"}".utf8))
        XCTAssertEqual(before.utcDayID, "2023-12-31")
        XCTAssertEqual(after.utcDayID, "2024-01-01")
    }

    func testCaptureWallTimeDoesNotConvertThroughCurrentTimezone() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data(
            "{\"id\":3872,\"time\":1790803838,\"type\":\"photo\"}".utf8))
        let formatter = CaptureWallTimeFormatter.make(locale: Locale(identifier: "en_US_POSIX"))
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        XCTAssertEqual(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(item.time))),
                       "2026-09-30 21:30")
        XCTAssertEqual(item.utcDayID, "2026-09-30")
    }

    func testFavoriteDefaultsFalseWhenOptionalFieldIsAbsent() throws {
        let favored = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"time":1700000000,"type":"photo","additional":{"favorite":true}}
        """.utf8))
        let minimal = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":2,"time":1700000000,"type":"photo","additional":{"resolution":{"width":4,"height":2}}}
        """.utf8))
        XCTAssertTrue(favored.isFavorite)
        XCTAssertFalse(minimal.isFavorite)
        let updated = minimal.withFavorite(true)
        XCTAssertTrue(updated.isFavorite)
        XCTAssertEqual(updated.displayAspectRatio, 2)
        let roundTrip = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(updated))
        XCTAssertTrue(roundTrip.isFavorite)
        XCTAssertFalse(roundTrip.withFavorite(false).isFavorite)
    }

    func testFilesizeAndExifDecodeWithSnakeCaseMapping() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":239118,"filename":"IMG_3905.HEIC","filesize":1768222,"time":1790803838,"type":"photo","additional":{"exif":{"aperture":"F2.8","camera":"iPhone 13 Pro","exposure_time":"1/25 s","focal_length":"9.0 mm","iso":"1250","lens":"iPhone 13 Pro back triple camera 9mm f/2.8"}}}
        """.utf8))
        XCTAssertEqual(item.filesize, 1_768_222)
        let exif = try XCTUnwrap(item.additional?.exif)
        XCTAssertEqual(exif.aperture, "F2.8")
        XCTAssertEqual(exif.camera, "iPhone 13 Pro")
        XCTAssertEqual(exif.exposureTime, "1/25 s")
        XCTAssertEqual(exif.focalLength, "9.0 mm")
        XCTAssertEqual(exif.iso, "1250")
        XCTAssertEqual(exif.lens, "iPhone 13 Pro back triple camera 9mm f/2.8")
        XCTAssertTrue(exif.hasAnyValue)
    }

    func testEmptyExifStringsHideEveryRow() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"time":1700000000,"type":"photo","additional":{"exif":{"aperture":"","camera":"","exposure_time":"","focal_length":"","iso":"","lens":""}}}
        """.utf8))
        let exif = try XCTUnwrap(item.additional?.exif)
        XCTAssertNil(exif.aperture)
        XCTAssertNil(exif.camera)
        XCTAssertNil(exif.exposureTime)
        XCTAssertNil(exif.focalLength)
        XCTAssertNil(exif.iso)
        XCTAssertNil(exif.lens)
        XCTAssertFalse(exif.hasAnyValue)
    }

    func testExifKeepsUnknownKeysAndMixedValuesAcrossCacheRoundTrip() throws {
        let json = """
        {"id":1,"time":1700000000,"type":"photo","additional":{"exif":{"iso":1250,"has_geolocation":false,"aperture":"F2.8","focal_length":9.0,"empty":null,"unknown_object":{"a":1},"unknown_array":[1,2]}}}
        """
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
        let exif = try XCTUnwrap(item.additional?.exif)
        XCTAssertEqual(exif.iso, "1250")
        XCTAssertEqual(exif.aperture, "F2.8")
        XCTAssertEqual(exif.focalLength, "9")
        XCTAssertEqual(exif.raw["iso"], .number(1250))
        XCTAssertEqual(exif.raw["has_geolocation"], .bool(false))
        XCTAssertEqual(exif.raw["empty"], .null)
        XCTAssertEqual(exif.raw["unknown_object"], .null)
        XCTAssertEqual(exif.raw["unknown_array"], .null)

        let updated = item.withFavorite(true)
        XCTAssertTrue(updated.isFavorite)
        XCTAssertEqual(updated.additional?.exif, exif)

        let restored = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored.additional?.exif, exif)
        XCTAssertEqual(restored.filesize, nil)
    }

    func testFavoriteToggleKeepsFilesizeWhenAdditionalIsAbsent() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"filename":"IMG_0001.HEIC","filesize":42,"time":1700000000,"type":"photo"}
        """.utf8))
        let updated = item.withFavorite(true)
        XCTAssertTrue(updated.isFavorite)
        XCTAssertEqual(updated.filesize, 42)
        XCTAssertNil(updated.additional?.exif)
    }

    private func decode(id: Int = 1, resolution: String, orientation: String) throws -> PhotoItem {
        let json = "{\"id\":\(id),\"time\":1700000000,\"type\":\"photo\",\"additional\":{\"resolution\":\(resolution)\(orientation)}}"
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }
}
