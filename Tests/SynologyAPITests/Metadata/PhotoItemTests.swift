import Foundation
import TimelineCore
import XCTest
@testable import SynologyAPI

final class PhotoItemTests: XCTestCase {
    func testLivePhotoUnitSelectsAdvertisedMotionMember() throws {
        let json = """
        {"list":[{"id_item":12,"type":"live","unit":[
          {"live_type":"photo","additional":{"thumbnail":{"unit_id":21,"cache_key":"still"}}},
          {"live_type":"video","filename":"motion.mov","additional":{"thumbnail":{"unit_id":22,"cache_key":"motion"},"video_convert":[{"quality":"high","metadata":{}}]}}
        ]}]}
        """
        let group = try XCTUnwrap(JSONDecoder().decode(LivePhotoUnitData.self, from: Data(json.utf8)).list.first)
        XCTAssertEqual(group.itemID, 12)
        XCTAssertNil(group.unit[0].playbackResource(scope: .space(.personal)))
        let motion = try XCTUnwrap(group.unit[1].playbackResource(scope: .space(.personal)))
        XCTAssertEqual(motion.unitID, 22)
        XCTAssertEqual(motion.cacheKey, "motion")
        XCTAssertEqual(motion.variant, .converted(.high))
    }

    func testRatingAndTagsDecodeFromObservedItemShape() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data(
            """
            {"id":284533,"filename":"IMG_4645.JPG","time":1,"type":"photo","additional":{"description":"","tag":[{"id":41,"name":"testtag"}],"rating":5,"favorite":true}}
            """.utf8))
        XCTAssertEqual(item.rating, 5)
        XCTAssertEqual(item.tags, [PhotoTag(id: 41, name: "testtag")])
        let bare = try JSONDecoder().decode(PhotoItem.self, from: Data(#"{"id":1,"time":1,"type":"photo"}"#.utf8))
        XCTAssertEqual(bare.rating, 0)
        XCTAssertEqual(bare.tags, [])
    }

    func testAnnotationEditsKeepOtherFieldsAndSurviveRotationAndFavoriteProjection() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data(
            """
            {"id":1,"time":1,"type":"photo","additional":{"orientation":1,"orientation_original":1,"favorite":true,"rating":2,"tag":[{"id":1,"name":"a"}]}}
            """.utf8))
        let edited = item.withAnnotations(PhotoAnnotations(rating: 4, tags: [PhotoTag(id: 2, name: "b")]))
        XCTAssertEqual(edited.rating, 4)
        XCTAssertEqual(edited.tags.map(\.name), ["b"])
        XCTAssertTrue(edited.isFavorite)
        XCTAssertEqual(edited.additional?.orientation, 1)
        XCTAssertEqual(item.rotated(.clockwise).rating, 2)
        XCTAssertEqual(item.rotated(.clockwise).tags.map(\.name), ["a"])
        XCTAssertEqual(item.withFavorite(false).tags.map(\.name), ["a"])
        // A rotation replacement carries rotation fields only, so it must not reset annotations.
        let replacement = try JSONDecoder().decode(PhotoItem.self, from: Data(
            #"{"id":1,"time":1,"type":"photo","additional":{"orientation":6,"orientation_original":1}}"#.utf8))
        XCTAssertEqual(item.withRotationMetadata(from: replacement).rating, 2)
        XCTAssertEqual(item.withRotationMetadata(from: replacement).additional?.orientation, 6)
        let bare = try JSONDecoder().decode(PhotoItem.self, from: Data(#"{"id":2,"time":1,"type":"photo"}"#.utf8))
        XCTAssertEqual(bare.withAnnotations(.init(rating: 3, tags: [])).rating, 3)
    }

    func testPageRequestsAskForTagAndRating() {
        XCTAssertTrue(PhotosRequestFields.pageAdditional.contains("tag"))
        XCTAssertTrue(PhotosRequestFields.pageAdditional.contains("rating"))
    }

    func testLivePhotoWithoutAdvertisedRenditionDoesNotInventVideoResource() throws {
        let member = try JSONDecoder().decode(LivePhotoUnitMember.self, from: Data(
            """
            {"live_type":"video","additional":{"thumbnail":{"unit_id":22,"cache_key":"motion"},"video_convert":[]}}
            """.utf8))
        XCTAssertNil(member.playbackResource(scope: .space(.personal)))
    }

    func testMediaKindPreservesUnknownAndRecognizesObservedLiveShapes() throws {
        func item(_ type: String, live: String? = nil) throws -> PhotoItem {
            let liveField = live.map { ",\"live_type\":\"\($0)\"" } ?? ""
            return try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":1,\"time\":1,\"type\":\"\(type)\"\(liveField)}".utf8))
        }
        XCTAssertEqual(try item("photo").mediaKind, .photo)
        XCTAssertEqual(try item("video").mediaKind, .video)
        XCTAssertEqual(try item("live", live: "photo").mediaKind, .livePhoto)
        XCTAssertEqual(try item("photo", live: "live").mediaKind, .livePhoto)
        XCTAssertEqual(try item("future").mediaKind, .unknown("future"))
    }

    func testObservedVideoConversionAndClosestQualitySelection() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":41,"filename":"clip.mov","time":1700000000,"type":"video","additional":{"thumbnail":{"unit_id":51,"cache_key":"revision"},"video_convert":[{"quality":"low","metadata":{"duration":5000,"container_type":"mp4","video_codec":"h264"}},{"quality":"high","metadata":{"duration":"5000","resolution_x":1920,"resolution_y":1080}}],"video_meta":{"duration":5000,"video_codec":"hevc"}}}
        """.utf8))
        XCTAssertEqual(item.additional?.videoConvert?.count, 2)
        XCTAssertEqual(item.additional?.videoConvert?.first?.metadata.duration, 5)
        XCTAssertEqual(item.videoPlaybackResource(scope: .space(.personal), preference: .medium)?.variant, .converted(.low))
        XCTAssertEqual(item.videoPlaybackResource(scope: .space(.personal), preference: .high)?.variant, .converted(.high))
        XCTAssertEqual(item.videoPlaybackResource(scope: .space(.personal), preference: .mobile)?.variant, .converted(.low))
        XCTAssertEqual(item.videoPlaybackResource(scope: .space(.personal), preference: .original)?.variant, .original)
        XCTAssertEqual(VideoQualityPreference(rawValue: "mobile"), .mobile)
    }

    func testClosestQualityPrefersDownOnTieAndMovesUpWhenNecessary() {
        XCTAssertEqual(VideoQuality.closest(to: .medium, in: [.low, .high]), .low)
        XCTAssertEqual(VideoQuality.closest(to: .high, in: [.medium, .originalH264]), .medium)
        XCTAssertEqual(VideoQuality.closest(to: .low, in: [.medium]), .medium)
        XCTAssertNil(VideoQuality.closest(to: .high, in: []))
    }

    func testVideoWithoutAdvertisedConversionFallsBackToOriginal() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":42,"time":1700000000,"type":"video","additional":{"thumbnail":{"unit_id":52,"cache_key":"revision"},"video_convert":[],"video_meta":{"duration":8000}}}
        """.utf8))
        XCTAssertEqual(item.videoPlaybackResource(scope: .space(.personal), preference: .automatic)?.variant, .original)
    }

    func testOptimisticQuarterTurnSwapsResolutionAndMapsOrientation() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"time":1700000000,"type":"photo","additional":{"resolution":{"width":400,"height":300},"orientation":1,"orientation_original":1}}
        """.utf8))
        let clockwise = item.rotated(.clockwise)
        XCTAssertEqual(clockwise.additional?.resolution?.width, 300)
        XCTAssertEqual(clockwise.additional?.resolution?.height, 400)
        XCTAssertEqual(clockwise.additional?.orientation, 6)
        XCTAssertEqual(clockwise.rotated(.counterClockwise), item)
    }

    func testOriginalDisplayQuarterTurnDeltaCoversNormalAndMirroredCycles() throws {
        func item(original: Int, current: Int) throws -> PhotoItem {
            try JSONDecoder().decode(PhotoItem.self, from: Data("""
            {"id":1,"time":1700000000,"type":"photo","additional":{"orientation":\(current),"orientation_original":\(original)}}
            """.utf8))
        }
        XCTAssertEqual(try item(original: 1, current: 1).displayQuarterTurns(fileOrientation: nil), 0)
        XCTAssertEqual(try item(original: 1, current: 6).displayQuarterTurns(fileOrientation: nil), 1)
        XCTAssertEqual(try item(original: 1, current: 3).displayQuarterTurns(fileOrientation: nil), 2)
        XCTAssertEqual(try item(original: 1, current: 8).displayQuarterTurns(fileOrientation: nil), -1)
        XCTAssertEqual(try item(original: 2, current: 7).displayQuarterTurns(fileOrientation: nil), 1)
        XCTAssertEqual(try item(original: 7, current: 5).displayQuarterTurns(fileOrientation: nil), 2)
        XCTAssertEqual(try item(original: 5, current: 4).displayQuarterTurns(fileOrientation: nil), -1)
        XCTAssertEqual(try item(original: 1, current: 2).displayQuarterTurns(fileOrientation: nil), 0)
        let rotated = try item(original: 1, current: 6)
        XCTAssertEqual(rotated.displayQuarterTurns(fileOrientation: 1), 1)
        XCTAssertEqual(rotated.displayQuarterTurns(fileOrientation: 6), 0)
        XCTAssertEqual(rotated.displayQuarterTurns(fileOrientation: nil), 1)
    }
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
        let resource = try XCTUnwrap(item.fullImageResource(in: .space(.personal)))
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
        let resource = try XCTUnwrap(item.fullImageResource(in: .space(.personal)))
        XCTAssertEqual(resource.unitID, 22)
        XCTAssertEqual(resource.filename, "IMG_0012.HEIC")

        let restored = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.liveType, "photo")
        XCTAssertTrue(restored.hasDisplayableStillImage)
    }

    func testLiveContainerProvidesFullImageResourceWhenLiveTypeIsLive() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":14,"filename":"IMG_0014.HEIC","time":1700000000,"type":"live","live_type":"live","additional":{"thumbnail":{"unit_id":24,"cache_key":"24_revision","sm":"ready"}}}
        """.utf8))

        XCTAssertEqual(item.liveType, "live")
        XCTAssertTrue(item.hasDisplayableStillImage)
        XCTAssertFalse(item.isVideo)
        let resource = try XCTUnwrap(item.fullImageResource(in: .space(.personal)))
        XCTAssertEqual(resource.unitID, 24)
        XCTAssertEqual(resource.cacheKey, "24_revision")
        XCTAssertEqual(resource.filename, "IMG_0014.HEIC")
    }

    func testStandaloneVideoDoesNotProvideFullImageResource() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":13,"filename":"clip.mov","time":1700000000,"type":"video","additional":{"thumbnail":{"unit_id":23,"cache_key":"23_revision","sm":"ready"}}}
        """.utf8))

        XCTAssertTrue(item.isVideo)
        XCTAssertFalse(item.hasDisplayableStillImage)
        XCTAssertNil(item.fullImageResource(in: .space(.personal)))
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

    func testGPSDecodesNumbersAndNumericStrings() throws {
        let numeric = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":1,"time":1700000000,"type":"photo","additional":{"gps":{"latitude":35.6585805555556,"longitude":139.745438888889}}}
        """.utf8))
        XCTAssertEqual(numeric.coordinate?.latitude ?? 0, 35.6585805555556, accuracy: 1e-9)
        XCTAssertEqual(numeric.coordinate?.longitude ?? 0, 139.745438888889, accuracy: 1e-9)

        let strings = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":2,"time":1700000000,"type":"photo","additional":{"gps":{"latitude":"35.5","longitude":"139.25"}}}
        """.utf8))
        XCTAssertEqual(strings.coordinate, PhotoCoordinate(latitude: 35.5, longitude: 139.25))
    }

    func testGPSAccessorRejectsInvalidAndMissingCoordinates() throws {
        let outOfRange = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":3,"time":1700000000,"type":"photo","additional":{"gps":{"latitude":120,"longitude":10}}}
        """.utf8))
        XCTAssertNil(outOfRange.coordinate)
        XCTAssertNotNil(outOfRange.additional?.gps)

        let missing = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":4,"time":1700000000,"type":"photo","additional":{"resolution":{"width":4,"height":2}}}
        """.utf8))
        XCTAssertNil(missing.coordinate)
        XCTAssertNil(missing.additional?.gps)
    }

    func testGPSSurvivesFavoriteMutationAndCacheRoundTrip() throws {
        let item = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":5,"time":1700000000,"type":"photo","additional":{"gps":{"latitude":48.8584,"longitude":2.2945},"favorite":false}}
        """.utf8))
        let updated = item.withFavorite(true)
        XCTAssertTrue(updated.isFavorite)
        let restored = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored.coordinate, PhotoCoordinate(latitude: 48.8584, longitude: 2.2945))
        XCTAssertTrue(restored.isFavorite)

        let withoutAdditional = try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":6,"time":1700000000,"type":"photo"}
        """.utf8))
        let updatedWithout = withoutAdditional.withFavorite(true)
        XCTAssertNil(updatedWithout.coordinate)
        XCTAssertTrue(updatedWithout.isFavorite)
    }

    private func decode(id: Int = 1, resolution: String, orientation: String) throws -> PhotoItem {
        let json = "{\"id\":\(id),\"time\":1700000000,\"type\":\"photo\",\"additional\":{\"resolution\":\(resolution)\(orientation)}}"
        return try JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }
}
