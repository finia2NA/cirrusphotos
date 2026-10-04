import SwiftUI
import TimelineCore

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct TimelineNavigator: View {
    let timeline: Timeline
    @Binding var selected: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Int?
    @State private var pointerIsNear = false
    @State private var dragging = false
    @State private var keyboardActive = false
    @State private var lastDragIndex: Int?
    @FocusState private var focused: Bool
    private let inset: CGFloat = 14

    private var isRevealed: Bool { pointerIsNear || dragging || (focused && keyboardActive) }

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - inset * 2)
            let width = geometry.size.width
            let y: (Int) -> CGFloat = { inset + height * timeline.fraction(at: $0) }

            Canvas { context, size in
                let rail = size.width - 10
                var line = Path()
                line.move(to: CGPoint(x: rail, y: inset))
                line.addLine(to: CGPoint(x: rail, y: size.height - inset))
                context.stroke(line, with: .color(.primary.opacity(0.12)), lineWidth: 1)

                // Paint marks in one canvas; dates never create individual hit targets.
                for index in timeline.monthStarts {
                    let dot = CGRect(x: rail - 1.5, y: y(index) - 1.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dot), with: .color(.primary.opacity(0.32)))
                }
                var lastLabelY: CGFloat = -.infinity
                for index in timeline.yearStarts {
                    let position = y(index)
                    guard position - lastLabelY >= 25 else { continue }
                    context.draw(Text(String(timeline.days[index].year)).font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary.opacity(0.82)),
                        at: CGPoint(x: rail - 11, y: position), anchor: .trailing)
                    lastLabelY = position
                }
                var selection = Path()
                if !timeline.days.isEmpty {
                    let safeSelection = min(max(0, selected), timeline.days.count - 1)
                    selection.move(to: CGPoint(x: rail - 7, y: y(safeSelection)))
                    selection.addLine(to: CGPoint(x: rail + 6, y: y(safeSelection)))
                }
                context.stroke(selection, with: .color(.pink), lineWidth: 2)
            }
            .opacity(isRevealed ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isRevealed)
            .allowsHitTesting(false)

            if isRevealed, let hovered, timeline.days.indices.contains(hovered) {
                let markerY = y(hovered)
                Rectangle().fill(.pink.opacity(0.7)).frame(width: width - 8, height: 1)
                    .position(x: width / 2, y: markerY).allowsHitTesting(false)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeline.days[hovered].monthLabel).font(.system(size: 15, weight: .semibold))
                    Text(timeline.days[hovered].id).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .monospacedDigit().padding(.horizontal, 9).padding(.vertical, 6)
                .frame(width: 126, alignment: .trailing)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .position(x: width - 63,
                          y: min(max(markerY - 29, 25), geometry.size.height - 25))
                .allowsHitTesting(false)
            }

            Color.clear.contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        pointerIsNear = true
                        hovered = timeline.index(at: (point.y - inset) / height)
                    case .ended:
                        pointerIsNear = false
                        hovered = focused && keyboardActive || dragging ?
                            (timeline.days.indices.contains(selected) ? selected : nil) : nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    keyboardActive = false
                    dragging = true
                    focused = true
                    if let index = timeline.index(at: (value.location.y - inset) / height) {
                        if lastDragIndex != index { selected = index; lastDragIndex = index }
                        hovered = index
                    }
                }.onEnded { _ in
                    dragging = false
                    lastDragIndex = nil
                    if !pointerIsNear && !(focused && keyboardActive) { hovered = nil }
                })
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.upArrow) {
                    guard !timeline.days.isEmpty else { return .handled }
                    keyboardActive = true
                    selected = max(0, min(selected, timeline.days.count - 1) - 1); hovered = selected; return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !timeline.days.isEmpty else { return .handled }
                    keyboardActive = true
                    selected = min(timeline.days.count - 1, max(0, selected) + 1); hovered = selected; return .handled
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Library timeline")
                .accessibilityValue(timeline.days[safe: selected]?.id ?? "No dates")
                .accessibilityHint("Use up and down arrows to select adjacent populated days.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if !timeline.days.isEmpty { selected = min(timeline.days.count - 1, max(0, selected) + 1) }
                    case .decrement: if !timeline.days.isEmpty { selected = max(0, min(selected, timeline.days.count - 1) - 1) }
                    @unknown default: break
                    }
                    keyboardActive = true
                    focused = true
                    hovered = timeline.days.indices.contains(selected) ? selected : nil
                }
                .onChange(of: focused) { _, isFocused in
                    if isFocused, !pointerIsNear, !dragging, !timeline.days.isEmpty {
                        keyboardActive = true
                        hovered = min(max(0, selected), timeline.days.count - 1)
                    } else if !isFocused {
                        keyboardActive = false
                        if !pointerIsNear && !dragging { hovered = nil }
                    }
                }
                .onChange(of: selected) { _, newSelection in
                    if focused && keyboardActive, !pointerIsNear, !dragging,
                       timeline.days.indices.contains(newSelection) {
                        hovered = newSelection
                    } else if !pointerIsNear && !dragging && !(focused && keyboardActive) {
                        hovered = nil
                    }
                }
        }
    }
}
