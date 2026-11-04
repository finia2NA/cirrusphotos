import AppKit
import PhotoCache
import SwiftUI

/// The Activity panel: connection and Refresh, current work and failures, and session History.
struct ActivityPanelView: View {
    @Environment(LibraryModel.self) private var library
    @Bindable var activity: ActivityCenter
    @State private var contentHeight: CGFloat = 0

    private static let minListHeight: CGFloat = 160
    private static let maxListHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("View", selection: $activity.selectedTab) {
                Text("Activity").tag(ActivityTab.activity)
                Text("History").tag(ActivityTab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            list
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { markSeenIfVisible() }
        .onChange(of: activity.selectedTab) { _, _ in markSeenIfVisible() }
        .onChange(of: activity.unseenFailureIDs) { _, _ in markSeenIfVisible() }
    }

    private func markSeenIfVisible() {
        if activity.selectedTab == .activity { activity.markFailuresSeen() }
    }

    // MARK: Header

    private var header: some View {
        let state = library.connectionState
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.symbol)
                .font(.system(size: 15))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.label).font(.headline)
                if let detail = state.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if library.isRefreshing || library.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await library.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh from NAS (⌘R)")
                .accessibilityLabel("Refresh")
            }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch activity.selectedTab {
                    case .activity: activitySections
                    case .history: historyRows
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                contentHeight = height
            }
            // Grows with its content between the bounds, then scrolls.
            .frame(height: min(max(contentHeight, Self.minListHeight), Self.maxListHeight))
            .onChange(of: activity.highlightedEntryID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
            .onAppear {
                if let id = activity.highlightedEntryID { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    @ViewBuilder private var activitySections: some View {
        let attention = activity.attention
        let transfers = activity.transfers
        let inProgress = activity.inProgress
        let notices = activity.notices
        if attention.isEmpty && transfers.isEmpty && inProgress.isEmpty && notices.isEmpty {
            Text("No current activity").foregroundStyle(.secondary)
        }
        section("Needs Attention", attention)
        section("Transfers", transfers)
        section("In Progress", inProgress)
        section("Notices", notices)
    }

    @ViewBuilder private func section(_ title: String, _ entries: [ActivityEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    ActivityEntryRow(entry: entry, activity: activity,
                                     highlighted: activity.highlightedEntryID == entry.id)
                        .id(entry.id)
                }
            }
        }
    }

    @ViewBuilder private var historyRows: some View {
        if activity.history.isEmpty {
            Text("No changes in this session").foregroundStyle(.secondary)
        }
        ForEach(activity.history) { record in
            HistoryRow(record: record, activity: activity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()
            switch activity.selectedTab {
            case .activity:
                if activity.hasRetryableFailures {
                    Button("Retry All Failed") { activity.retryAllFailed() }
                }
                Button("Clear") { activity.clearActivity() }
                    .disabled(!activity.hasSettledEntries)
            case .history:
                Button("Clear History") { activity.clearHistory() }
                    .disabled(activity.history.isEmpty)
            }
        }
        .controlSize(.small)
    }
}

/// One Activity entry: title, progress or error, controls, and its failed items.
private struct ActivityEntryRow: View {
    let entry: ActivityEntry
    let activity: ActivityCenter
    let highlighted: Bool
    @Environment(LibraryModel.self) private var library
    @State private var expanded = false

    private var expandable: Bool { entry.phase.needsAttention && !entry.failedItems.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if expandable {
                    DisclosureChevron(expanded: $expanded)
                }
                Text(entry.title)
                    .lineLimit(2)
                    .foregroundStyle(entry.phase == .cancelled ? .secondary : .primary)
                Spacer(minLength: 6)
                controls
            }
            if !entry.phase.isSettled && entry.kind.isTransfer {
                ProgressView(value: entry.fraction).controlSize(.small)
            }
            if let detail = entry.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(entry.phase.needsAttention ? Color.red : Color.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if expandable && expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.failedItems) { item in
                        ActivityItemRow(item: item, activity: activity, retry: entry.retry == nil ? nil : {
                            activity.retry(entry.id, itemIDs: [item.id])
                        }, dismiss: {
                            activity.dismiss(itemID: item.id, from: entry.id)
                        })
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(highlighted ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.4), value: highlighted)
        .contextMenu {
            if let failure = entry.failure {
                Button("Copy Details") {
                    ActivityReport.copy(ActivityReport.text(title: entry.title, failure: failure,
                                                            items: entry.failedItems.isEmpty ? entry.items : entry.failedItems,
                                                            connection: library.connectionState.label))
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if !entry.phase.isSettled, let cancel = entry.cancel {
            Button("Cancel", action: cancel).controlSize(.small)
        }
        if entry.phase == .succeeded, let url = entry.savedURL {
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show in Finder")
        }
        if entry.phase.needsAttention, entry.retry != nil {
            Button(entry.failedItems.count > 1 ? "Retry All" : "Retry") { activity.retry(entry.id) }
                .controlSize(.small)
        }
        if entry.phase.isSettled {
            DismissButton { activity.dismiss(entry.id) }
        }
    }
}

/// A failed photo or file inside an entry.
private struct ActivityItemRow: View {
    let item: ActivityItem
    let activity: ActivityCenter
    let retry: (() -> Void)?
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            label
            Spacer(minLength: 6)
            if let retry {
                Button(action: retry) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Retry")
                    .accessibilityLabel("Retry \(item.name)")
            }
            if let dismiss { DismissButton(action: dismiss) }
        }
    }

    /// The thumbnail and name; a button that shows the photo when the browser displays its
    /// collection.
    @ViewBuilder private var label: some View {
        let content = HStack(spacing: 8) {
            ActivityThumbnail(item: item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if let message = item.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        if activity.canReveal(item) {
            Button { activity.reveal(item) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Show in Library")
        } else if item.photoID != nil {
            content.help("Open the photo's collection to show it here")
        } else {
            content
        }
    }
}

/// A History record, expandable to the photos it covers.
private struct HistoryRow: View {
    let record: HistoryRecord
    let activity: ActivityCenter
    @Environment(LibraryModel.self) private var library
    @State private var expanded = false
    private static let shownItemLimit = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !record.items.isEmpty {
                    DisclosureChevron(expanded: $expanded)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title).lineLimit(2)
                    Text(record.finishedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                DismissButton { activity.dismissHistory(record.id) }
            }
            if let detail = record.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(record.items.prefix(Self.shownItemLimit)) { item in
                        ActivityItemRow(item: item, activity: activity, retry: nil, dismiss: nil)
                    }
                    if record.items.count > Self.shownItemLimit {
                        Text("and \(record.items.count - Self.shownItemLimit) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            if let failure = record.failure {
                Button("Copy Details") {
                    ActivityReport.copy(ActivityReport.text(title: record.title, failure: failure, items: record.items,
                                                            connection: library.connectionState.label))
                }
            }
        }
    }
}

private struct DisclosureChevron: View {
    @Binding var expanded: Bool

    var body: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(expanded ? "Collapse" : "Expand")
    }
}

private struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

/// A cached small thumbnail for a photo item; never downloads.
private struct ActivityThumbnail: View {
    let item: ActivityItem
    @Environment(LibraryModel.self) private var library
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.fileURL == nil ? "photo" : "doc")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: item.id) { await load() }
    }

    private func load() async {
        guard case .photo(let photo, let collection) = item.reference, let descriptor = photo.additional?.thumbnail,
              let repository = library.repository else { return }
        for await event in await repository.thumbnail(descriptor, size: .sm, allowNetwork: false, collection: collection) {
            if case .value(let data, _) = event { image = NSImage(data: data) }
            break
        }
    }
}
