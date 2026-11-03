import AppKit
import PhotoCache
import SwiftUI
import TimelineCore

struct ViewerFilmstrip: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    let height: CGFloat
    let cropsToSquare: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = max(40, height - 16)
            let available = min(21, max(1, Int(geometry.size.width / (side + 6))))
            let count = available.isMultiple(of: 2) ? available - 1 : available
            let center = viewer.state?.desiredLocation.ordinal ?? 0
            let items = (viewer.state?.filmstrip ?? []).filter { abs($0.ordinal - center) <= count / 2 }
            HStack(spacing: 6) {
                ForEach(items, id: \.ordinal) { slot in
                    let frame = FixedPhotoGrid.visibleFrame(in: CGRect(x: 0, y: 0, width: side, height: side),
                        aspectRatio: slot.item?.displayAspectRatio ?? 1, cropsToSquare: cropsToSquare)
                    Button { viewer.navigateToOrdinal(slot.ordinal) } label: {
                        Group {
                            if slot.ordinal == center, let image = viewer.image {
                                thumbnail(image)
                            } else if let identity = slot.neighbor?.thumbnailIdentity,
                                      let image = viewer.decodedThumbnails[identity] {
                                thumbnail(image)
                            } else {
                                Rectangle().fill(.secondary.opacity(0.2))
                            }
                        }
                        .frame(width: frame.width, height: frame.height).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay { if let item = slot.item { ThumbnailBadgeOverlay(item: item) } }
                        .overlay { if slot.ordinal == center { RoundedRectangle(cornerRadius: 4).stroke(.primary, lineWidth: 2) } }
                        .frame(width: side, height: side)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(slot.ordinal == center ? "Current photo" : "Photo \(slot.ordinal + 1)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private func thumbnail(_ image: NSImage) -> some View {
        if cropsToSquare { Image(nsImage: image).resizable().scaledToFill() }
        else { Image(nsImage: image).resizable().scaledToFit() }
    }
}

/// AppKit owns the resize drag so the adjacent compositor-backed canvas cannot intercept it.
struct FilmstripDivider: NSViewRepresentable {
    @Binding var height: CGFloat
    func makeNSView(context: Context) -> DividerView { DividerView() }
    func updateNSView(_ view: DividerView, context: Context) {
        view.height = height
        view.onChange = { height = $0 }
    }
    final class DividerView: NSView {
        var height: CGFloat = 100
        var onChange: ((CGFloat) -> Void)?
        private var startY: CGFloat = 0
        private var startHeight: CGFloat = 0
        override var isFlipped: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
        }
        override func mouseDown(with event: NSEvent) {
            startY = event.locationInWindow.y
            startHeight = height
        }
        override func mouseDragged(with event: NSEvent) {
            onChange?(min(220, max(56, startHeight + event.locationInWindow.y - startY)))
        }
    }
}

struct HistogramBins: Sendable {
    let luminance: [Int]
    let red: [Int]
    let green: [Int]
    let blue: [Int]
}

struct ViewerHistogram: View {
    let image: NSImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bins: HistogramBins?
    @State private var corner: Alignment = .bottomTrailing
    @State private var drag: CGSize = .zero
    @AppStorage(AppPreferences.Key.viewerHistogramShowsColor) private var showsColor = false

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(width: max(0, geometry.size.width - 180),
                                   height: max(0, geometry.size.height - 80))
            let origin = HistogramSnap.origin(for: corner, available: available)
            Canvas { context, size in
                guard let bins else { return }
                let channels = showsColor ? [bins.red, bins.green, bins.blue] : [bins.luminance]
                guard let peak = channels.flatMap({ $0 }).max(), peak > 0 else { return }
                for (channel, values) in channels.enumerated() {
                    var path = Path()
                    for (index, value) in values.enumerated() {
                        let x = CGFloat(index) * size.width / CGFloat(values.count)
                        let h = CGFloat(value) / CGFloat(peak) * size.height
                        path.addRect(CGRect(x: x, y: size.height - h, width: max(1, size.width / CGFloat(values.count)), height: h))
                    }
                    let color: Color = showsColor ? [Color(red: 1, green: 0, blue: 0),
                                                     Color(red: 0, green: 1, blue: 0),
                                                     Color(red: 0, green: 0, blue: 1)][channel] : .primary
                    context.blendMode = showsColor ? .plusLighter : .normal
                    context.fill(path, with: .color(color))
                }
            }
            .padding(8)
            .frame(width: 180, height: 80)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { showsColor.toggle() }
            .gesture(DragGesture(coordinateSpace: .named("histogramContainer")).onChanged { value in
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    drag = CGSize(width: min(available.width - origin.x, max(-origin.x, value.translation.width)),
                                  height: min(available.height - origin.y, max(-origin.y, value.translation.height)))
                }
            }.onEnded { value in
                let target = HistogramSnap.target(origin: origin, drag: drag, translation: value.translation,
                                                  predicted: value.predictedEndTranslation, available: available)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                    corner = target
                    drag = .zero
                }
            })
            .position(x: origin.x + drag.width + 90, y: origin.y + drag.height + 40)
        }
        .coordinateSpace(name: "histogramContainer")
        .accessibilityLabel(showsColor ? "Color histogram" : "Luminance histogram")
        .accessibilityHint("Click to switch histogram mode. Drag to move.")
        .task(id: ObjectIdentifier(image)) {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { bins = nil; return }
            let result = await ViewerInspectionEngine.shared.histogram(cgImage)
            guard !Task.isCancelled else { return }
            bins = result
        }
    }

    nonisolated static func histogram(_ image: CGImage) -> HistogramBins? {
        let width = 256, height = 256
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var luminance = [Int](repeating: 0, count: 64)
        var red = luminance, green = luminance, blue = luminance
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            luminance[min(63, ((r * 54 + g * 183 + b * 19) >> 8) / 4)] += 1
            red[r / 4] += 1; green[g / 4] += 1; blue[b / 4] += 1
        }
        return HistogramBins(luminance: luminance, red: red, green: green, blue: blue)
    }
}

enum HistogramSnap {
    static func origin(for corner: Alignment, available: CGSize) -> CGPoint {
        CGPoint(x: corner == .topLeading || corner == .bottomLeading ? 0 : available.width,
                y: corner == .topLeading || corner == .topTrailing ? 0 : available.height)
    }

    static func target(origin: CGPoint, drag: CGSize, translation: CGSize,
                       predicted: CGSize, available: CGSize) -> Alignment {
        let x = origin.x + drag.width + 1.5 * (predicted.width - translation.width)
        let y = origin.y + drag.height + 1.5 * (predicted.height - translation.height)
        let left = x < available.width / 2
        let top = y < available.height / 2
        return top ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)
    }
}
