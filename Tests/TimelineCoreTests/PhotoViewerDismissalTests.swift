import CoreGraphics
import XCTest
@testable import TimelineCore

final class PhotoViewerDismissalTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)

    func testDownwardBeginRequiresDeadZoneAndVerticalDominance() {
        XCTAssertFalse(PhotoViewerDismissal.beginsInteractiveDismissal(
            translation: CGSize(width: 0, height: -4)))
        XCTAssertFalse(PhotoViewerDismissal.beginsInteractiveDismissal(
            translation: CGSize(width: 200, height: -30)))
        XCTAssertFalse(PhotoViewerDismissal.beginsInteractiveDismissal(
            translation: CGSize(width: 0, height: 40)))
        XCTAssertTrue(PhotoViewerDismissal.beginsInteractiveDismissal(
            translation: CGSize(width: 5, height: -40)))
        XCTAssertFalse(PhotoViewerDismissal.beginsInteractiveDismissal(
            translation: CGSize(width: CGFloat.nan, height: -40)))
    }

    func testScrollIntentLocksDirectionAfterDeadZone() {
        XCTAssertEqual(PhotoViewerDismissal.scrollIntent(translation: .zero), .undecided)
        XCTAssertEqual(PhotoViewerDismissal.scrollIntent(translation: CGSize(width: 3, height: -4)),
                       .undecided)
        XCTAssertEqual(PhotoViewerDismissal.scrollIntent(translation: CGSize(width: 0, height: -40)),
                       .dismiss)
        XCTAssertEqual(PhotoViewerDismissal.scrollIntent(translation: CGSize(width: 40, height: -5)),
                       .scroll)
        XCTAssertEqual(PhotoViewerDismissal.scrollIntent(translation: CGSize(width: 0, height: 40)),
                       .scroll)
        XCTAssertEqual(PhotoViewerDismissal.scrollIntent(translation: CGSize(width: 60, height: -20)),
                       .scroll)
        XCTAssertEqual(PhotoViewerDismissal.scrollIntent(
            translation: CGSize(width: CGFloat.nan, height: -40)), .scroll)
    }

    func testMetricsAtRestAreIdentity() {
        let metrics = PhotoViewerDismissal.metrics(translation: .zero, viewport: viewport)
        XCTAssertEqual(metrics.translation, .zero)
        XCTAssertEqual(metrics.scale, 1)
        XCTAssertEqual(metrics.backdropOpacity, 1)
    }

    func testMetricsFollowDownwardTravelAndClampOvershoot() {
        let half = PhotoViewerDismissal.metrics(translation: CGSize(width: 0, height: -300),
                                                viewport: viewport)
        XCTAssertEqual(half.translation.height, -300)
        XCTAssertLessThan(half.scale, 1)
        XCTAssertGreaterThanOrEqual(half.scale, PhotoViewerDismissal.minimumScale)
        XCTAssertLessThan(half.backdropOpacity, 1)

        let upward = PhotoViewerDismissal.metrics(translation: CGSize(width: 0, height: 120),
                                                  viewport: viewport)
        XCTAssertEqual(upward.translation.height, 0)
        XCTAssertEqual(upward.scale, 1)
        XCTAssertEqual(upward.backdropOpacity, 1)

        let past = PhotoViewerDismissal.metrics(translation: CGSize(width: 0, height: -5_000),
                                                viewport: viewport)
        XCTAssertEqual(past.translation.height, -600)
        XCTAssertEqual(past.scale, PhotoViewerDismissal.minimumScale, accuracy: 0.0001)
        XCTAssertEqual(past.backdropOpacity, 0, accuracy: 0.0001)
    }

    func testMetricsClampHorizontalAndHandleNonFiniteInput() {
        let metrics = PhotoViewerDismissal.metrics(
            translation: CGSize(width: 5_000, height: -.infinity), viewport: viewport)
        XCTAssertEqual(metrics.translation.width, 800)
        XCTAssertEqual(metrics.translation.height, 0)
        XCTAssertTrue(metrics.scale.isFinite)
        XCTAssertTrue(metrics.backdropOpacity.isFinite)
    }

    func testDismissalRequiresDisplacementOrVelocityBeyondThreshold() {
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Below the displacement threshold and slow: spring back.
        XCTAssertFalse(PhotoViewerDismissal.shouldDismiss(
            translation: CGSize(width: 0, height: -40), velocity: .zero, viewport: viewport))
        // A long, slow drag passes the displacement threshold.
        XCTAssertTrue(PhotoViewerDismissal.shouldDismiss(
            translation: CGSize(width: 0, height: -200), velocity: .zero, viewport: viewport))
        // A short, fast fling passes the velocity threshold.
        XCTAssertTrue(PhotoViewerDismissal.shouldDismiss(
            translation: CGSize(width: 0, height: -40),
            velocity: CGSize(width: 0, height: -1_500), viewport: viewport))
        // Upward velocity never dismisses.
        XCTAssertFalse(PhotoViewerDismissal.shouldDismiss(
            translation: CGSize(width: 0, height: -40),
            velocity: CGSize(width: 0, height: 2_000), viewport: viewport))
        // Non-finite velocity is treated as no velocity.
        XCTAssertFalse(PhotoViewerDismissal.shouldDismiss(
            translation: CGSize(width: 0, height: -40),
            velocity: CGSize(width: CGFloat.nan, height: CGFloat.nan), viewport: viewport))
    }
}
