import PhotoCache
import SynologyAPI
import XCTest
@testable import CirrusPhotosApp

final class ViewerProblemsTests: XCTestCase {
    private func problems(filesize: Int64? = 1000, thumbnail: ThumbnailInfo? = nil,
                          thumbnailStatus: PhotoViewerResourceStatus = .ready(verified: true, validationFailure: nil),
                          full: PhotoViewerResourceStatus = .loading, limit: FullImageLimit? = nil,
                          decodeFailure: String? = nil, hasImage: Bool = true, allowNetwork: Bool = true,
                          isVideo: Bool = false) -> [String] {
        ViewerProblems.make(ViewerProblems.Inputs(
            filesize: filesize, thumbnail: thumbnail, thumbnailStatus: thumbnailStatus, fullStatus: full,
            fullImageLimit: limit, decodeFailure: decodeFailure, hasImage: hasImage, allowNetwork: allowNetwork,
            isVideo: isVideo))
    }

    private func thumbnail(sm: String = "ready", m: String = "ready", xl: String = "ready") -> ThumbnailInfo {
        ThumbnailInfo(unitID: 1, cacheKey: "1_1", sm: sm, m: m, xl: xl)
    }

    func testAHealthyLoadingPhotoHasNoProblems() {
        XCTAssertEqual(problems(thumbnail: thumbnail()), [])
        XCTAssertEqual(problems(filesize: nil), [])
    }

    func testAnEmptyFileWithBrokenPreviewsAndAFailedOriginalListsAllThree() {
        let result = problems(filesize: 0, thumbnail: thumbnail(sm: "broken", m: "broken", xl: "broken"),
                              thumbnailStatus: .failure("The preview is not cached."),
                              full: .failure("The NAS returned an unexpected response."), hasImage: false)
        XCTAssertEqual(result, [
            "The file on the NAS is empty.",
            "The NAS couldn't create previews of this photo.",
            "Original unavailable: The NAS returned an unexpected response."
        ])
    }

    func testSomeBrokenPreviewsAreNamed() {
        XCTAssertEqual(problems(thumbnail: thumbnail(xl: "broken")), ["The NAS couldn't create the large preview."])
        XCTAssertEqual(problems(thumbnail: thumbnail(sm: "broken", xl: "broken")),
                       ["The NAS couldn't create the small and large previews."])
    }

    func testAnyStatusButReadyOrConvertingIsAPreviewTheNASCouldNotCreate() {
        XCTAssertEqual(problems(thumbnail: thumbnail(m: "ame_defect")), ["The NAS couldn't create the medium preview."])
        XCTAssertEqual(problems(thumbnail: thumbnail(m: "converting")), [])
    }

    func testVideosListOnlyWhatTheMetadataReports() {
        XCTAssertEqual(problems(filesize: 0, thumbnail: thumbnail(sm: "broken", m: "broken", xl: "broken"),
                                full: .failure("Not cached."), hasImage: false, isVideo: true),
                       ["The file on the NAS is empty.", "The NAS couldn't create previews of this video."])
        XCTAssertEqual(problems(thumbnail: thumbnail(m: "ame_defect"), thumbnailStatus: .failure("Timed out."), isVideo: true),
                       ["The NAS couldn't create the medium preview."])
    }

    func testAPreviewFailureShowsWhileConnectedOrWithoutAnImage() {
        XCTAssertEqual(problems(thumbnailStatus: .failure("Timed out."), hasImage: true),
                       ["Preview unavailable: Timed out."])
        XCTAssertEqual(problems(thumbnailStatus: .failure("Not cached."), hasImage: false, allowNetwork: false),
                       ["Preview unavailable: Not cached."])
        XCTAssertEqual(problems(thumbnailStatus: .failure("Not cached."), hasImage: true, allowNetwork: false), [])
        XCTAssertEqual(problems(thumbnail: thumbnail(sm: "broken", m: "broken", xl: "broken"),
                                thumbnailStatus: .failure("Not cached."), hasImage: false),
                       ["The NAS couldn't create previews of this photo."])
    }

    func testAnOfflineOriginalFailureBehindAPreviewIsNotAProblem() {
        XCTAssertEqual(problems(full: .failure("Not cached."), allowNetwork: false), [])
        XCTAssertEqual(problems(full: .failure("Not cached."), hasImage: false, allowNetwork: false),
                       ["Original unavailable offline: Not cached."])
    }

    func testDecodeFailuresAndUnsupportedOriginals() {
        XCTAssertEqual(problems(full: .ready(verified: true, validationFailure: nil), decodeFailure: "Bad data."),
                       ["The original couldn't be decoded: Bad data."])
        XCTAssertEqual(problems(full: .unsupported("No original."), hasImage: false), ["No original."])
        XCTAssertEqual(problems(full: .unsupported("Large only."), limit: .qualitySetting, hasImage: false), [])
        XCTAssertEqual(problems(full: .unsupported("No original."), hasImage: true), [])
    }
}
