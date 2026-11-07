import AppKit
import Charts
import PhotoCache
import SwiftUI

/// Cache use on this Mac by account, optionally split into the cache categories.
/// Reads every account's cache directory, including accounts that are not open.
struct CacheUsageView: View {
    let accounts: AccountController
    /// Changes when the open account's usage changes, so the chart is read again.
    let refreshKey: Int64
    @AppStorage("settings.storage.showsCategories") private var showsCategories = true
    @State private var rows: [Row] = []

    struct Row: Identifiable {
        let id: String
        let name: String
        let usage: CacheUsageBreakdown
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
            Text("Each account can use up to the maximum size.")
        }
        .task(id: refreshKey) { await scan() }
    }

    private var chart: some View {
        Chart {
            ForEach(rows) { row in
                if showsCategories {
                    ForEach(CacheUsageCategory.allCases) { category in
                        if let value = row.usage.bytes[category], value > 0 {
                            BarMark(x: .value("Size", value), y: .value("Account", row.name), height: .fixed(14))
                                .foregroundStyle(by: .value("Category", category.title))
                        }
                    }
                } else {
                    BarMark(x: .value("Size", row.usage.total), y: .value("Account", row.name), height: .fixed(14))
                        .foregroundStyle(Self.color(.metadata))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .chartForegroundStyleScale(domain: CacheUsageCategory.allCases.map(\.title),
                                   range: CacheUsageCategory.allCases.map(Self.color))
        .chartLegend(showsCategories ? .visible : .hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) { Text(self.bytes(bytes)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel() }
        }
        .frame(height: CGFloat(rows.count) * 30 + (showsCategories ? 56 : 30))
        .accessibilityLabel("Cache use by account")
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
