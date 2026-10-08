import AppKit
import SwiftUI

enum InfoPanelScene {
    static let id = "photo-info"
}

struct InfoPanelView: View {
    @EnvironmentObject private var infoPanel: InfoPanelModel

    var body: some View {
        content
            .padding(14)
            .frame(width: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(InfoPanelWindowConfigurator())
            .onAppear { infoPanel.setVisible(true) }
            .onDisappear { infoPanel.setVisible(false) }
    }

    @ViewBuilder
    private var content: some View {
        switch infoPanel.content.kind {
        case .empty:
            Text("Select photos to view info.")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Info")
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Info unavailable")
        case .multiple:
            multipleContent
        case .single:
            singleContent
        }
    }

    private var multipleContent: some View {
        let content = infoPanel.content
        return VStack(alignment: .leading, spacing: 6) {
            Text(content.countText)
                .font(.title3.weight(.semibold))
            if !content.dateRangeText.isEmpty {
                Text(content.dateRangeText)
                    .foregroundStyle(.secondary)
            }
            sizeRow(content)
            if !content.pins.isEmpty {
                InfoPanelMapView(pins: content.pins)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(multipleAccessibilityLabel(content))
    }

    @ViewBuilder
    private func sizeRow(_ content: InfoPanelContent) -> some View {
        HStack(spacing: 6) {
            if content.isResolvingSize {
                ProgressView()
                    .controlSize(.small)
            } else if let sizeText = content.sizeText {
                Text(sizeText)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var singleContent: some View {
        let content = infoPanel.content
        return VStack(alignment: .leading, spacing: 8) {
            if let filename = content.filename {
                Text(filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if content.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading info…")
                        .foregroundStyle(.secondary)
                }
            } else {
                if let dateTimeText = content.dateTimeText {
                    Text(dateTimeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                if let camera = content.camera {
                    Text(camera)
                }
                if let lens = content.lens {
                    Text(lens)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                metricsRow(content)
                if !content.exposure.isEmpty {
                    Divider()
                    Text(content.exposure.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !content.pins.isEmpty {
                    Divider()
                    InfoPanelMapView(pins: content.pins)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(singleAccessibilityLabel(content))
    }

    private func metricsRow(_ content: InfoPanelContent) -> some View {
        var parts: [String] = []
        if let durationText = content.durationText { parts.append(durationText) }
        parts.append(contentsOf: content.metrics)
        return HStack(spacing: 8) {
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let formatBadge = content.formatBadge {
                Text(formatBadge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
        }
    }

    private func multipleAccessibilityLabel(_ content: InfoPanelContent) -> String {
        var parts = ["Info", content.countText]
        if !content.dateRangeText.isEmpty { parts.append(content.dateRangeText) }
        if let sizeText = content.sizeText { parts.append(sizeText) }
        return parts.joined(separator: ", ")
    }

    private func singleAccessibilityLabel(_ content: InfoPanelContent) -> String {
        var parts = ["Info"]
        if let filename = content.filename { parts.append(filename) }
        if let dateTimeText = content.dateTimeText { parts.append(dateTimeText) }
        return parts.joined(separator: ", ")
    }
}

struct InfoPanelWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowConfiguratorView {
        WindowConfiguratorView()
    }

    func updateNSView(_ nsView: WindowConfiguratorView, context: Context) {}

    final class WindowConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            configure()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }

        private func configure() {
            guard let window else { return }
            window.collectionBehavior.formUnion([.transient, .ignoresCycle, .fullScreenAuxiliary])
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        }
    }
}
