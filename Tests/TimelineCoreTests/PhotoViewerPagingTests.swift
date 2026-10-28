import CoreGraphics
import XCTest
@testable import TimelineCore

final class PhotoViewerPagingTests: XCTestCase {
    func testDirectionRequiresHorizontalDeadZoneAndDominance() {
        XCTAssertNil(PhotoViewerPaging.direction(translation: .zero))
        XCTAssertNil(PhotoViewerPaging.direction(translation: CGSize(width: 4, height: -3)))
        XCTAssertNil(PhotoViewerPaging.direction(translation: CGSize(width: 30, height: 30)))
        XCTAssertNil(PhotoViewerPaging.direction(translation: CGSize(width: 5, height: -40)))
        XCTAssertEqual(PhotoViewerPaging.direction(translation: CGSize(width: -40, height: -5)),
                       .next)
        XCTAssertEqual(PhotoViewerPaging.direction(translation: CGSize(width: 40, height: -5)),
                       .previous)
        XCTAssertEqual(PhotoViewerPaging.direction(translation: CGSize(width: -40, height: -30)),
                       .next)
        XCTAssertNil(PhotoViewerPaging.direction(
            translation: CGSize(width: CGFloat(Double.nan), height: -40)))
    }

    func testHorizontalSensitivityScalesDistanceAndVelocityWithoutChangingVerticalInput() {
        let scaled = PhotoViewerPaging.scaledHorizontal(CGSize(width: -100, height: -20))
        XCTAssertEqual(scaled.width, -135, accuracy: 0.001)
        XCTAssertEqual(scaled.height, -20)
    }

    func testPageDistanceKeepsTheNeighborBeyondTheViewportEdge() {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let neighbor = CGRect(x: 300, y: 250, width: 200, height: 100)
        XCTAssertEqual(PhotoViewerPaging.pageDistance(viewport: viewport,
                                                      neighborFrame: neighbor), 524)
        XCTAssertEqual(PhotoViewerPaging.pageDistance(
            viewport: viewport,
            neighborFrame: CGRect(x: 0, y: 0, width: CGFloat(Double.nan), height: 100)), 424)
    }

    func testExitDistanceClearsTheViewportWithGap() {
        XCTAssertEqual(PhotoViewerPaging.exitDistance(
            currentFrame: CGRect(x: 300, y: 150, width: 200, height: 300),
            viewport: CGRect(x: 0, y: 0, width: 800, height: 600)), 524)
    }

    func testMetricsFollowTheLockedDirectionAndClampOvershoot() {
        let rest = PhotoViewerPaging.metrics(translation: .zero, direction: .next,
                                             distance: 800)
        XCTAssertEqual(rest.translation, .zero)
        XCTAssertEqual(rest.progress, 0)

        let half = PhotoViewerPaging.metrics(translation: CGSize(width: -400, height: 50),
                                             direction: .next, distance: 800)
        XCTAssertEqual(half.translation.width, -400)
        XCTAssertEqual(half.translation.height, 0)
        XCTAssertEqual(half.progress, 0.5)

        let wrongDirection = PhotoViewerPaging.metrics(
            translation: CGSize(width: 200, height: 0), direction: .next, distance: 800)
        XCTAssertEqual(wrongDirection.translation.width, 0)
        XCTAssertEqual(wrongDirection.progress, 0)

        let previous = PhotoViewerPaging.metrics(translation: CGSize(width: 400, height: 0),
                                                 direction: .previous, distance: 800)
        XCTAssertEqual(previous.translation.width, 400)
        XCTAssertEqual(previous.progress, 0.5)

        let past = PhotoViewerPaging.metrics(translation: CGSize(width: -2_000, height: 0),
                                             direction: .next, distance: 800)
        XCTAssertEqual(past.translation.width, -800)
        XCTAssertEqual(past.progress, 1)

        let nonFinite = PhotoViewerPaging.metrics(
            translation: CGSize(width: CGFloat(Double.nan), height: CGFloat(Double.infinity)),
            direction: .next, distance: 800)
        XCTAssertEqual(nonFinite.translation.width, 0)
        XCTAssertEqual(nonFinite.progress, 0)
    }

    func testCommitRequiresDisplacementOrDirectionalVelocity() {
        XCTAssertFalse(PhotoViewerPaging.shouldCommit(
            direction: .next, translation: CGSize(width: -100, height: 0),
            velocity: .zero, distance: 800))
        XCTAssertTrue(PhotoViewerPaging.shouldCommit(
            direction: .next, translation: CGSize(width: -300, height: 0),
            velocity: .zero, distance: 800))
        XCTAssertTrue(PhotoViewerPaging.shouldCommit(
            direction: .next, translation: CGSize(width: -40, height: 0),
            velocity: CGSize(width: -1_500, height: 0), distance: 800))
        XCTAssertTrue(PhotoViewerPaging.shouldCommit(
            direction: .previous, translation: CGSize(width: 40, height: 0),
            velocity: CGSize(width: 1_500, height: 0), distance: 800))
        XCTAssertFalse(PhotoViewerPaging.shouldCommit(
            direction: .next, translation: CGSize(width: -40, height: 0),
            velocity: CGSize(width: 1_500, height: 0), distance: 800))
        XCTAssertFalse(PhotoViewerPaging.shouldCommit(
            direction: .next, translation: CGSize(width: 100, height: 0),
            velocity: CGSize(width: -1_500, height: 0), distance: 800))
        XCTAssertFalse(PhotoViewerPaging.shouldCommit(
            direction: .next, translation: CGSize(width: -40, height: 0),
            velocity: CGSize(width: CGFloat(Double.nan), height: 0), distance: 800))
    }
}
