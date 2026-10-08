import AppKit
import SwiftUI

/// Click target for map pin content.
///
/// A SwiftUI `Button` hosted in a map annotation can activate from gestures that are
/// part of a zoom or pan (or from a click whose release lands on a rebuilt
/// annotation). This view reports only a complete, stationary single click, and it
/// forwards scroll and magnification so the map keeps zooming normally.
struct MapPinClickCatcher: NSViewRepresentable {
    let isCircular: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.action = action
        view.isCircular = isCircular
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.action = action
        view.isCircular = isCircular
    }

    final class ClickView: NSView {
        var action: (() -> Void)?
        var isCircular = false
        private var mouseDownLocation: NSPoint?
        private var lastZoomGestureTimestamp: TimeInterval = 0

        override var acceptsFirstResponder: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

        override func mouseDown(with event: NSEvent) {
            mouseDownLocation = event.timestamp - lastZoomGestureTimestamp > 0.2
                ? convert(event.locationInWindow, from: nil)
                : nil
        }

        override func mouseDragged(with event: NSEvent) {
            // Panning across a pin must not become a click.
            mouseDownLocation = nil
        }

        override func mouseUp(with event: NSEvent) {
            guard let start = mouseDownLocation else { return }
            mouseDownLocation = nil
            guard event.clickCount == 1 else { return }
            let end = convert(event.locationInWindow, from: nil)
            guard hitRegion.contains(end) else { return }
            guard hypot(end.x - start.x, end.y - start.y) <= 3 else { return }
            action?()
        }

        override func scrollWheel(with event: NSEvent) {
            lastZoomGestureTimestamp = event.timestamp
            nextResponder?.scrollWheel(with: event)
        }

        override func magnify(with event: NSEvent) {
            lastZoomGestureTimestamp = event.timestamp
            nextResponder?.magnify(with: event)
        }

        override func rotate(with event: NSEvent) {
            lastZoomGestureTimestamp = event.timestamp
            nextResponder?.rotate(with: event)
        }

        override func smartMagnify(with event: NSEvent) {
            lastZoomGestureTimestamp = event.timestamp
            nextResponder?.smartMagnify(with: event)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard hitRegion.contains(local) else { return nil }
            return super.hitTest(point)
        }

        private var hitRegion: NSBezierPath {
            isCircular
                ? NSBezierPath(ovalIn: bounds)
                : NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        }
    }
}
