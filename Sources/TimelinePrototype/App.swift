import AppKit
import SwiftUI
import TimelineCore

@main
struct TimelinePrototypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Cirrus · Timeline") {
            PrototypeView().frame(minWidth: 560, minHeight: 420)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 860, height: 820)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PrototypeView: View {
    private let timeline: Timeline?
    @State private var selected = 0

    init() {
        if let url = Bundle.module.url(forResource: "days", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let rows = try? JSONDecoder().decode([[Int]].self, from: data),
           rows.allSatisfy({ $0.count == 5 }) {
            timeline = Timeline(days: rows.map {
                LibraryDay(year: $0[0], month: $0[1], day: $0[2], count: $0[3], section: $0[4])
            })
        } else { timeline = nil }
    }

    var body: some View {
        Group {
            if let timeline, !timeline.days.isEmpty {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 20) {
                        Label("Cirrus", systemImage: "photo.stack").font(.title2.weight(.semibold))
                        Text("Personal Space").foregroundStyle(.secondary)
                        Spacer()
                        Text("SELECTED DATE").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(timeline.days[selected].id).font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("\(timeline.days[selected].count) items · Section \(timeline.days[selected].section)")
                            .foregroundStyle(.secondary)
                        Text("Day \(selected + 1) of \(timeline.days.count)").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Text("Move over the timeline to explore. Click or drag to select a date.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Recorded library · \(timeline.days.count) populated days\nEach day occupies the same amount of space.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(36).frame(maxWidth: .infinity, alignment: .leading)
                    TimelineNavigator(timeline: timeline, selected: $selected)
                        .frame(width: 190).padding(.vertical, 24).padding(.trailing, 16)
                }
            } else {
                ContentUnavailableView("Timeline unavailable", systemImage: "calendar.badge.exclamationmark",
                                       description: Text("The recorded timeline could not be loaded."))
            }
        }.background(Color(red: 0.065, green: 0.065, blue: 0.07))
    }
}

struct TimelineNavigator: View {
    let timeline: Timeline
    @Binding var selected: Int
    @State private var hovered: Int?
    @FocusState private var focused: Bool
    private let inset: CGFloat = 14

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
                context.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: 1)

                // Paint marks in one canvas; dates never create individual hit targets.
                for index in timeline.monthStarts {
                    let dot = CGRect(x: rail - 1.5, y: y(index) - 1.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.25)))
                }
                var lastLabelY: CGFloat = -.infinity
                for index in timeline.yearStarts {
                    let position = y(index)
                    guard position - lastLabelY >= 25 else { continue }
                    context.draw(Text(String(timeline.days[index].year)).font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.8)),
                        at: CGPoint(x: rail - 13, y: position), anchor: .trailing)
                    lastLabelY = position
                }
                var selection = Path()
                selection.move(to: CGPoint(x: rail - 7, y: y(selected)))
                selection.addLine(to: CGPoint(x: rail + 6, y: y(selected)))
                context.stroke(selection, with: .color(.pink), lineWidth: 2)
            }
            .allowsHitTesting(false)

            if let hovered {
                let markerY = y(hovered)
                Rectangle().fill(.pink.opacity(0.7)).frame(width: width - 8, height: 1)
                    .position(x: width / 2, y: markerY).allowsHitTesting(false)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeline.days[hovered].monthLabel).font(.system(size: 15, weight: .semibold))
                    Text(timeline.days[hovered].id).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .monospacedDigit().padding(.horizontal, 9).padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .position(x: width / 2 - 10, y: min(max(markerY - 29, 25), geometry.size.height - 25))
                .allowsHitTesting(false)
            }

            Color.clear.contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = timeline.index(at: (point.y - inset) / height)
                    case .ended: hovered = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    focused = true
                    if let index = timeline.index(at: (value.location.y - inset) / height) {
                        selected = index; hovered = index
                    }
                })
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.upArrow) { selected = max(0, selected - 1); hovered = selected; return .handled }
                .onKeyPress(.downArrow) { selected = min(timeline.days.count - 1, selected + 1); hovered = selected; return .handled }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Library timeline")
                .accessibilityValue(timeline.days[selected].id)
                .accessibilityHint("Use up and down arrows to select adjacent populated days.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: selected = min(timeline.days.count - 1, selected + 1)
                    case .decrement: selected = max(0, selected - 1)
                    @unknown default: break
                    }
                }
        }
    }
}
