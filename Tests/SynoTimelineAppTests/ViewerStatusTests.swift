import PhotoCache
import SynologyAPI
import XCTest
@testable import SynoTimelineApp

final class ViewerStatusTests: XCTestCase {
    private func photo(_ displayed: ViewerImageTier?, _ full: PhotoViewerResourceStatus,
                       transfer: TransferProgress? = nil, stalled: Bool = false,
                       decoding: Bool = false, allowNetwork: Bool = true) -> ViewerStatus {
        ViewerStatus.make(ViewerStatus.Inputs(displayed: displayed, fullStatus: full, isDecoding: decoding,
                                              transfer: transfer, stalled: stalled, allowNetwork: allowNetwork))
    }

    func testPhotoStepsNameTheShownSizeThenTheWork() {
        XCTAssertEqual(photo(nil, .loading).short, "Loading")
        XCTAssertEqual(photo(.thumbnail(.m), .loading).short, "Medium · Loading")
        // Nothing has arrived from the NAS yet, so no bar: a cached original would already be done.
        XCTAssertNil(photo(.thumbnail(.m), .loading).progress)
        XCTAssertEqual(photo(.thumbnail(.xl), .loading).short, "Large · Loading")
        XCTAssertEqual(photo(.thumbnail(.xl), .ready(verified: true, validationFailure: nil), decoding: true).short,
                       "Large · Decoding")
        let full = photo(.full, .ready(verified: true, validationFailure: nil))
        XCTAssertEqual(full.short, "Full")
        XCTAssertEqual(full.help, "Showing full resolution")
        XCTAssertNil(full.progress)
        XCTAssertTrue(full.isComplete)
    }

    func testDecodingKeepsAFullBarOnlyAfterANetworkLoad() {
        func decoding(networkLoaded: Bool) -> ViewerStatus {
            ViewerStatus.make(ViewerStatus.Inputs(displayed: .thumbnail(.xl), fullStatus: .ready(verified: true, validationFailure: nil),
                                                  isDecoding: true, networkLoaded: networkLoaded))
        }
        XCTAssertEqual(decoding(networkLoaded: true).progress, .determinate(1))
        XCTAssertNil(decoding(networkLoaded: false).progress)
    }

    func testKnownTransferSizeShowsPercentAndDeterminateProgress() {
        let status = photo(.thumbnail(.xl), .loading,
                           transfer: TransferProgress(completedBytes: 4_300_000, totalBytes: 10_000_000))
        XCTAssertEqual(status.short, "Large · Loading 43%")
        XCTAssertEqual(status.progress, .determinate(0.43))
        XCTAssertTrue(status.help.hasPrefix("Showing the large preview; loading full resolution: "))
    }

    func testLargePreviewFillsTheFirstFifthAndFullResolutionTheRest() {
        func status(_ displayed: ViewerImageTier?, previewLoading: Bool, transfer: TransferProgress? = nil) -> ViewerStatus {
            ViewerStatus.make(ViewerStatus.Inputs(displayed: displayed, fullStatus: .loading,
                                                  isLoadingLargePreview: previewLoading, largePreviews: true,
                                                  transfer: transfer))
        }
        let half = TransferProgress(completedBytes: 50, totalBytes: 100)
        // Preview still loading: full resolution counts for its 80%.
        guard case .determinate(let early) = status(.thumbnail(.m), previewLoading: true, transfer: half).progress else {
            return XCTFail("Expected determinate progress")
        }
        XCTAssertEqual(early, 0.4, accuracy: 0.0001)
        // Preview arrived, nothing of full resolution from the NAS yet: no bar until bytes arrive.
        XCTAssertNil(status(.thumbnail(.xl), previewLoading: false).progress)
        let both = status(.thumbnail(.xl), previewLoading: false, transfer: half)
        guard case .determinate(let late) = both.progress else { return XCTFail("Expected determinate progress") }
        XCTAssertEqual(late, 0.6, accuracy: 0.0001)
        XCTAssertEqual(both.short, "Large · Loading 60%")
        // No large preview for this item: full resolution is the whole bar.
        XCTAssertEqual(status(.thumbnail(.m), previewLoading: false, transfer: half).progress, .determinate(0.5))
    }

    func testUnknownTransferSizeStaysIndeterminate() {
        let status = photo(.thumbnail(.m), .loading, transfer: TransferProgress(completedBytes: 2_000_000, totalBytes: nil))
        XCTAssertEqual(status.short, "Medium · Loading")
        XCTAssertEqual(status.progress, .indeterminate)
        XCTAssertTrue(status.help.hasSuffix(" received"))
    }

    func testStalledLoadSaysSoAndKeepsTheReachedProgress() {
        let status = photo(.thumbnail(.xl), .loading,
                           transfer: TransferProgress(completedBytes: 5, totalBytes: 10), stalled: true)
        XCTAssertEqual(status.short, "Large · Stalled")
        XCTAssertEqual(status.progress, .determinate(0.5))
        XCTAssertTrue(status.help.contains("no data has arrived for 8 seconds"))
    }

    func testCachedFullResolutionReadsFullWithDetailOnHover() {
        let cached = photo(.full, .ready(verified: false, validationFailure: nil))
        XCTAssertEqual(cached.short, "Full")
        XCTAssertEqual(cached.help, "Showing full resolution from the cache; not yet checked against the NAS")
        let unchecked = photo(.full, .ready(verified: false, validationFailure: "Timed out"))
        XCTAssertEqual(unchecked.short, "Full")
        XCTAssertTrue(unchecked.help.hasSuffix("checking it against the NAS failed: Timed out"))
    }

    func testFullResolutionFailureNamesOfflineCase() {
        XCTAssertEqual(photo(.thumbnail(.xl), .failure("The full-size image is not cached."), allowNetwork: false).short,
                       "Large · Full unavailable offline")
        let online = photo(.thumbnail(.m), .failure("Server error"))
        XCTAssertEqual(online.short, "Medium · Full unavailable")
        XCTAssertEqual(online.help, "Showing the medium preview; Server error")
    }

    private func video(_ variant: VideoPlaybackVariant, _ preference: VideoQualityPreference = .automatic,
                       playing playback: VideoPlaybackStatus?) -> ViewerStatus {
        ViewerStatus.make(ViewerStatus.Inputs(displayed: nil, fullStatus: .idle,
            video: ViewerStatus.Video(variant: variant, preference: preference, playback: playback)))
    }

    func testVideoNamesQualityThenPlaybackState() {
        XCTAssertEqual(video(.converted(.high), playing: nil).short, "High · Loading")
        XCTAssertEqual(video(.converted(.high), playing: .buffering).short, "High · Buffering")
        XCTAssertEqual(video(.converted(.high), playing: .buffering).progress, .indeterminate)
        XCTAssertEqual(video(.converted(.high), playing: .stalled).short, "High · Stalled")
        XCTAssertNil(video(.converted(.high), playing: .stalled).progress)
        XCTAssertEqual(video(.converted(.high), playing: .playing).short, "High")
        XCTAssertNil(video(.converted(.high), playing: .playing).progress)
        let failed = video(.original, .original, playing: .failed("Cannot Open"))
        XCTAssertEqual(failed.short, "Original · Can't play")
        XCTAssertTrue(failed.help.hasSuffix("Cannot Open"))
    }

    func testVideoIsCompleteOncePlayingOrPaused() {
        XCTAssertFalse(video(.converted(.high), playing: .buffering).isComplete)
        XCTAssertTrue(video(.converted(.high), playing: .playing).isComplete)
        XCTAssertTrue(video(.converted(.high), playing: .paused).isComplete)
    }

    func testVideoFallbackNoteShowsWhilePlaying() {
        XCTAssertEqual(video(.converted(.medium), .automatic, playing: .playing).short, "Medium · High unavailable")
        XCTAssertEqual(video(.original, .automatic, playing: .paused).short, "Original · No converted quality available")
        XCTAssertEqual(video(.converted(.medium), .automatic, playing: .buffering).short, "Medium · Buffering")
    }
}
