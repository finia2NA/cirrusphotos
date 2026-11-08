import AppKit
import Charts
import PhotoCache
import SwiftUI

/// Cache use on this Mac as one bar against the shared maximum size: every account's
/// use, optionally split into the cache categories, then the space still allowed.
/// Reads every account's cache directory, including accounts that are not open.
struct CacheUsageView: View {
    let accounts: AccountController
    /// Changes when the open account's usage changes, so the chart is read again.
    let refreshKey: Int64
    @EnvironmentObject private var preferences: AppPreferences
    @AppStorage("settings.storage.showsCategories") private var showsCategories = true
    @State private var rows: [Row] = []

    struct Row: Identifiable {
        let id: String
        let name: String
        let usage: CacheUsageBreakdown
    }

    /// One stretch of the bar. `key` names its colour and legend entry.
    struct Segment: Identifiable, Equatable {
        let id: String
        let key: String
        let start: Int64
        let end: Int64
    }

    static let availableKey = "Available"

    /// Accounts in order, each split into categories when `showsCategories` is on, then
    /// the space left below `budget`.
    static func segments(rows: [Row], budget: Int64, showsCategories: Bool) -> [Segment] {
        var segments: [Segment] = []
        var offset: Int64 = 0
        for row in rows {
            if showsCategories {
                for category in CacheUsageCategory.allCases {
                    guard let value = row.usage.bytes[category], value > 0 else { continue }
                    segments.append(Segment(id: "\(row.id)/\(category.rawValue)", key: category.title,
                                            start: offset, end: offset + value))
                    offset += value
                }
            } else if row.usage.total > 0 {
                segments.append(Segment(id: row.id, key: row.name, start: offset, end: offset + row.usage.total))
                offset += row.usage.total
            }
        }
        if offset < budget {
            segments.append(Segment(id: availableKey, key: availableKey, start: offset, end: budget))
        }
        return segments
    }

    /// Where one account's part of the bar ends and the next begins.
    static func accountBoundaries(rows: [Row]) -> [Int64] {
        var offset: Int64 = 0
        return rows.dropLast().map { row in
            offset += row.usage.total
            return offset
        }
    }

    var body: some View {
        Section {
            if rows.isEmpty {
                Text("Nothing is cached yet.").foregroundStyle(.secondary)
            } else {
                Toggle("Show categories", isOn: $showsCategories)
                chart
                ForEach(rows) { row in
                    LabeledContent(row.name, value: bytes(row.usage.total)).monospacedDigit()
                    if showsCategories {
                        ForEach(CacheUsageCategory.allCases) { category in
                            if let value = row.usage.bytes[category], value > 0 {
                                LabeledContent {
                                    Text(bytes(value)).monospacedDigit()
                                } label: {
                                    Label {
                                        Text(category.title)
                                    } icon: {
                                        RoundedRectangle(cornerRadius: 2).fill(Self.color(category)).frame(width: 10, height: 10)
                                    }
                                    .padding(.leading, 12)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Use by account")
        } footer: {
            Text("All accounts share the maximum size.")
        }
        .task(id: refreshKey) { await scan() }
    }

    private var chart: some View {
        let budget = preferences.budgetBytes
        let total = rows.reduce(0) { $0 + $1.usage.total }
        let segments = Self.segments(rows: rows, budget: budget, showsCategories: showsCategories)
        let keys: [String] = showsCategories
            ? CacheUsageCategory.allCases.map(\.title)
            : rows.map(\.name)
        let colors: [Color] = showsCategories
            ? CacheUsageCategory.allCases.map(Self.color)
            : rows.indices.map(Self.accountColor)
        return Chart {
            ForEach(segments) { segment in
                BarMark(xStart: .value("Start", segment.start), xEnd: .value("End", segment.end),
                        y: .value("Cache", "All"), height: .fixed(18))
                    .foregroundStyle(by: .value("Part", segment.key))
            }
            if showsCategories {
                ForEach(Self.accountBoundaries(rows: rows), id: \.self) { boundary in
                    RuleMark(x: .value("Account", boundary))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                }
            }
            if total > budget {
                RuleMark(x: .value("Maximum", budget))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(.red)
                    .annotation(position: .top, alignment: .center) {
                        Text("Maximum").font(.caption2).foregroundStyle(.red)
                    }
            }
        }
        .chartForegroundStyleScale(domain: keys + [Self.availableKey],
                                   range: colors + [Color(nsColor: .quaternaryLabelColor)])
        .chartXScale(domain: 0...max(budget, total))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) { Text(self.bytes(bytes)) }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 74)
        .accessibilityLabel("Cache use: \(bytes(total)) of \(bytes(budget))")
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    private func scan() async {
        let cached = await Task.detached(priority: .utility) { CacheInventory.scan() }.value
        let stored = accounts.store.accounts
        rows = cached.map { entry in
            let match = stored.first { AccountController.namespace(of: $0) == entry.namespace }
            let name = match?.displayName
                ?? entry.username.map { user in entry.server.map { "\(user) on \($0)" } ?? user }
                ?? "Unknown account"
            return Row(id: entry.namespace, name: name, usage: entry.usage)
        }
    }

    /// Account colours when categories are hidden: the category palette in order, repeating.
    static func accountColor(_ index: Int) -> Color {
        color(CacheUsageCategory.allCases[index % CacheUsageCategory.allCases.count])
    }

    /// The first five categorical slots of the validated reference palette, stepped for
    /// light and dark appearance.
    static func color(_ category: CacheUsageCategory) -> Color {
        let (light, dark): (UInt32, UInt32) = switch category {
        case .metadata: (0x2a78d6, 0x3987e5)
        case .thumbnails: (0xeb6834, 0xd95926)
        case .previews: (0x1baf7a, 0x199e70)
        case .fullImages: (0xeda100, 0xc98500)
        case .video: (0xe87ba4, 0xd55181)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}
