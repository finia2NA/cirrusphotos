import AppKit
import SwiftUI

struct WindowChromeMetrics: Equatable {
    var top: CGFloat = 0
}

struct WindowChromeMetricsReader: NSViewRepresentable {
    let onChange: (WindowChromeMetrics) -> Void

    func makeNSView(context: Context) -> MetricsView {
        let view = MetricsView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: MetricsView, context: Context) {
        view.onChange = onChange
        view.reportSoon()
    }

    final class MetricsView: NSView {
        var onChange: ((WindowChromeMetrics) -> Void)?
        private var last = WindowChromeMetrics(top: -1)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            // Keep the native toolbar material across the whole window. The content
            // still extends behind it through fullSizeContentView.
            window.titlebarAppearsTransparent = false
            reportSoon()
        }

        override func layout() {
            super.layout()
            reportSoon()
        }

        func reportSoon() {
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window, let content = window.contentView else { return }
            let layout = convert(window.contentLayoutRect, from: nil)
            let contentBounds = convert(content.bounds, from: content)
            let top = isFlipped
                ? max(0, layout.minY - contentBounds.minY)
                : max(0, contentBounds.maxY - layout.maxY)
            let metrics = WindowChromeMetrics(top: top)
            guard abs(metrics.top - last.top) > 0.5 else { return }
            last = metrics
            onChange?(metrics)
        }
    }
}
