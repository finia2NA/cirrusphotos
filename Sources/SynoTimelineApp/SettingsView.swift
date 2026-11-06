import PhotoCache
import SwiftUI
import SynologyAPI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general, viewing, storage, account

    var id: Self { self }
    var title: String {
        switch self { case .general: "General"; case .viewing: "Viewing"; case .storage: "Storage"; case .account: "Account" }
    }
    var symbol: String {
        switch self { case .general: "gearshape"; case .viewing: "eye"; case .storage: "internaldrive"; case .account: "person.crop.circle" }
    }
}

/// Settings with its own tab header. The system tab toolbar draws a strong selection
/// outline and shows the scroll-edge band only for some tabs and pointer positions;
/// this header has a quiet selection and one fixed divider on every tab.
struct SettingsView: View {
    let accounts: AccountController
    @AppStorage("settings.selectedTab") private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { item in
                    tabButton(item)
                }
            }
            .padding(.vertical, 8)
            Divider()
            content
                .scrollEdgeEffectHidden(true, for: .top)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(tab.title)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general:
            GeneralSettingsView()
        case .viewing:
            ViewingSettingsView()
        case .storage:
            AccountScoped(accounts: accounts) { context in
                StorageSettingsView().environment(context.model)
            }
        case .account:
            AccountSettingsView(accounts: accounts)
        }
    }

    private func tabButton(_ item: SettingsTab) -> some View {
        let selected = item == tab
        return Button { tab = item } label: {
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(item.title).font(.caption)
            }
            .frame(width: 72, height: 46)
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(selected ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppPreferences.Key.photoDownloadDirectory) private var downloadDirectory = ""

    private var path: String {
        let path = downloadDirectory.isEmpty ? PhotoDownloadManager.directory.path : downloadDirectory
        return (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Download folder") {
                    HStack {
                        Text(path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(path)
                        Button("Choose…") {
                            if let url = PhotoDownloadManager.chooseDirectory() { downloadDirectory = url.path }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

private struct ViewingSettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @AppStorage(AppPreferences.Key.viewerHighlightThreshold) private var highlightThreshold = 100.0
    @AppStorage(AppPreferences.Key.viewerFocusEdgeTolerance) private var focusEdgeTolerance = 1.5

    var body: some View {
        Form {
            Section {
                ThumbnailQualityPicker(size: $preferences.thumbnailSize)
            } header: {
                Text("Thumbnails")
            } footer: {
                Text("Used by the grid and by downloads for offline use.")
            }
            Section {
                Toggle("Load large previews", isOn: $preferences.loadsLargeViewerPreviews)
                    .disabled(preferences.thumbnailSize == .xl)
                Picker("Pixel interpolation", selection: $preferences.pixelInterpolation) {
                    ForEach(PixelInterpolationPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Default video quality", selection: $preferences.videoQuality) {
                    ForEach(VideoQualityPreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Viewer")
            } footer: {
                Text("Converted video starts faster and uses less bandwidth. Original may be slower or unsupported by the Mac.")
            }
            Section("Inspection overlays") {
                LabeledContent("Highlight peaking") {
                    HStack {
                        Slider(value: $highlightThreshold, in: 80...100, step: 1)
                        Text("\(Int(highlightThreshold))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Focus edge tolerance") {
                    HStack {
                        Slider(value: $focusEdgeTolerance, in: 1...2.5, step: 0.1)
                        Text(String(format: "%.1f×", focusEdgeTolerance)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

private struct StorageSettingsView: View {
    @Environment(LibraryModel.self) private var library
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.openWindow) private var openWindow
    @State private var confirmsClear = false

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Maximum size") {
                    HStack {
                        Slider(value: $preferences.budgetFraction, in: 0...1)
                        Text(bytes(CacheBudget.bytes(at: preferences.budgetFraction)))
                            .monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
                LabeledContent("In use", value: bytes(library.cacheUsage))
                    .monospacedDigit()
            } header: {
                Text("Cache")
            } footer: {
                Text("Counts cached photos, videos and metadata. The folder in Finder can be a few percent larger.")
            }
            Section("Offline use") {
                LabeledContent {
                    Button("Download…") { openWindow(id: "thumbnail-download") }
                } label: {
                    caption("Download thumbnails", "Choose dates and download their thumbnails ahead of browsing.")
                }
            }
            Section {
                LabeledContent {
                    Button("Revalidate") { Task { await library.revalidateAllMetadata() } }
                } label: {
                    caption("Revalidate metadata", "Keep cached metadata but read every timeline from the NAS again.")
                }
                LabeledContent {
                    Button("Clear") { Task { await library.clearMetadataCache() } }
                } label: {
                    caption("Clear metadata", "Remove timelines, albums and the map index. Thumbnails and photos stay.")
                }
                LabeledContent {
                    Button("Clear…", role: .destructive) { confirmsClear = true }
                } label: {
                    caption("Clear all cached data", "Remove everything this account has cached on this Mac.")
                }
            } header: {
                HStack {
                    Text("Maintenance")
                    if library.cacheResetInProgress { ProgressView().controlSize(.small) }
                }
            } footer: {
                if let error = library.cacheResetError { Text(error).foregroundStyle(.red) }
            }
            .disabled(library.cacheResetInProgress)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .task { await library.refreshUsage() }
        .confirmationDialog("Clear all cached data?", isPresented: $confirmsClear) {
            Button("Clear", role: .destructive) { Task { await library.clearCache() } }
        } message: {
            Text("Photos and metadata are downloaded again as you browse.")
        }
    }

    private func caption(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AccountSettingsView: View {
    let accounts: AccountController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Signed in") {
                if let context = accounts.context {
                    if let account = context.account {
                        LabeledContent("Server", value: account.serverURL.absoluteString)
                        LabeledContent("User", value: account.username)
                    } else {
                        LabeledContent("Source", value: ".env file")
                    }
                } else {
                    Text("Not signed in").foregroundStyle(.secondary)
                }
            }
            if accounts.usesEnvironmentFile {
                Section {
                    Text("A .env file beside the app supplies the account. Remove it to sign in from the app.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Accounts on this Mac") {
                    ForEach(accounts.accounts) { account in
                        LabeledContent(account.displayName) {
                            if accounts.context?.account?.id == account.id {
                                Text("Open").foregroundStyle(.secondary)
                            } else {
                                Button("Switch") { Task { await accounts.switchTo(account) } }
                            }
                        }
                    }
                }
                Section {
                    HStack {
                        Button("Add Account…") { openWindow(id: AddAccountWindow.id) }
                            .disabled(accounts.context == nil)
                        Spacer()
                        Button("Sign Out") { Task { await accounts.signOut() } }
                            .disabled(accounts.context == nil)
                    }
                } footer: {
                    Text("Signing out removes the saved password and trusted-device token. Cached photos stay until the cache is cleared.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
