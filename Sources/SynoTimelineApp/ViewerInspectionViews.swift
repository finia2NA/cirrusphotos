import AppKit
import SwiftUI

struct ViewerFilmstrip: View {
    @ObservedObject var viewer: PhotoViewerPresentation
    let height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let side = max(40, height - 16)
            let available = min(21, max(1, Int(geometry.size.width / (side + 6))))
            let count = available.isMultiple(of: 2) ? available - 1 : available
            let center = viewer.state?.desiredLocation.ordinal ?? 0
            let items = (viewer.state?.filmstrip ?? []).filter { abs($0.ordinal - center) <= count / 2 }
            HStack(spacing: 6) {
                ForEach(items, id: \.ordinal) { item in
                    Button { viewer.navigateToOrdinal(item.ordinal) } label: {
                        Group {
                            if item.ordinal == center, let image = viewer.image {
                                Image(nsImage: image).resizable().scaledToFill()
                            } else if let identity = item.neighbor?.thumbnailIdentity,
                                      let image = viewer.decodedThumbnails[identity] {
                                Image(nsImage: image).resizable().scaledToFill()
                            } else {
                                Rectangle().fill(.secondary.opacity(0.2))
                            }
                        }
                        .frame(width: side, height: side).clipped()
                        .overlay { if item.ordinal == center { Rectangle().stroke(.primary, lineWidth: 2) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.ordinal == center ? "Current photo" : "Photo \(item.ordinal + 1)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
    }
}

struct ViewerHistogram: View {
    let image: NSImage
    @State private var bins: [Int] = []
    @State private var corner: Alignment = .bottomTrailing
    @State private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let peak = bins.max(), peak > 0 else { return }
                var path = Path()
                for (index, value) in bins.enumerated() {
                    let x = CGFloat(index) * size.width / CGFloat(bins.count)
                    let h = CGFloat(value) / CGFloat(peak) * size.height
                    path.addRect(CGRect(x: x, y: size.height - h, width: max(1, size.width / CGFloat(bins.count)), height: h))
                }
                context.fill(path, with: .color(.primary))
            }
            .padding(8)
            .frame(width: 180, height: 80)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .offset(drag)
            .gesture(DragGesture().onChanged { drag = $0.translation }.onEnded { value in
                let initialX: CGFloat = corner == .topLeading || corner == .bottomLeading ? 0 : geometry.size.width
                let initialY: CGFloat = corner == .topLeading || corner == .topTrailing ? 0 : geometry.size.height
                let left = initialX + value.translation.width < geometry.size.width / 2
                let top = initialY + value.translation.height < geometry.size.height / 2
                corner = top ? (left ? .topLeading : .topTrailing) : (left ? .bottomLeading : .bottomTrailing)
                drag = .zero
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
        }
        .accessibilityLabel("Luminance histogram")
        .task(id: ObjectIdentifier(image)) {
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { bins = []; return }
            let result = await ViewerInspectionEngine.shared.histogram(cgImage)
            guard !Task.isCancelled else { return }
            bins = result
        }
    }

    nonisolated static func histogram(_ image: CGImage) -> [Int] {
        let width = 256, height = 256
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var result = [Int](repeating: 0, count: 64)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let luminance = (Int(pixels[offset]) * 54 + Int(pixels[offset + 1]) * 183 + Int(pixels[offset + 2]) * 19) >> 8
            result[min(63, luminance / 4)] += 1
        }
        return result
    }
}
