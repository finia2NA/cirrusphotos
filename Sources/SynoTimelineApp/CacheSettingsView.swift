import PhotoCache
import SwiftUI
import SynologyAPI

struct CacheSettingsView: View {
    @Environment(LibraryModel.self) private var library
    @EnvironmentObject private var preferences: AppPreferences
    @AppStorage(AppPreferences.Key.photoDownloadDirectory) private var downloadDirectory = ""
    @AppStorage(AppPreferences.Key.viewerHighlightThreshold) private var highlightThreshold = 100.0
    @AppStorage(AppPreferences.Key.viewerFocusEdgeTolerance) private var focusEdgeTolerance = 1.5

    var body: some View {
        Form {
            HStack {
                Text("Download folder")
                Spacer()
                Text(downloadDirectory.isEmpty ? PhotoDownloadManager.directory.path : downloadDirectory).lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    if let url = PhotoDownloadManager.shared.chooseDirectory() {
                        UserDefaults.standard.set(url.path, forKey: AppPreferences.Key.photoDownloadDirectory)
                        downloadDirectory = url.path
                    }
                }
            }
            Picker("Thumbnail rendition", selection: $preferences.thumbnailSize) {
                Text("Small").tag(ThumbnailSize.sm)
                Text("Medium").tag(ThumbnailSize.m)
                Text("Large").tag(ThumbnailSize.xl)
            }
            Toggle("Load large previews in viewer", isOn: $preferences.loadsLargeViewerPreviews)
                .disabled(preferences.thumbnailSize == .xl)
            Picker("Pixel interpolation", selection: $preferences.pixelInterpolation) {
                ForEach(PixelInterpolationPreference.allCases, id: \.self) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            HStack {
                Text("Highlight peaking threshold")
                Slider(value: $highlightThreshold, in: 80...100, step: 1)
                Text("\(Int(highlightThreshold))%")
                    .frame(width: 45, alignment: .trailing)
            }
            HStack {
                Text("Focus edge tolerance")
                Slider(value: $focusEdgeTolerance, in: 1...2.5, step: 0.1)
                Text(String(format: "%.1f×", focusEdgeTolerance))
                    .frame(width: 45, alignment: .trailing)
            }
            Picker("Default video quality", selection: $preferences.videoQuality) {
                ForEach(VideoQualityPreference.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            Text("Converted qualities start faster and use less bandwidth. Original may be slower or unsupported by the Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Maximum stored data")
                Slider(value: $preferences.budgetFraction, in: 0...1)
                Text(ByteCountFormatter.string(
                    fromByteCount: CacheBudget.bytes(at: preferences.budgetFraction),
                    countStyle: .file
                ))
                .frame(width: 90, alignment: .trailing)
            }
            HStack {
                Text("Stored data")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: library.cacheUsage, countStyle: .file))
                Button("Clear Metadata Cache") { Task { await library.clearMetadataCache() } }
                    .disabled(library.cacheResetInProgress)
                    .help("Remove timelines, loaded sections, album metadata and the map index. Keep thumbnails, previews, originals and cached video ranges.")
                Button("Clear Cache") { Task { await library.clearCache() } }
                    .disabled(library.cacheResetInProgress)
            }
            Text("Counts cached photos, videos and metadata. Database overhead and filesystem rounding are not included, so the folder in Finder can be a few percent larger.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Cached metadata is checked against the NAS")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revalidate Metadata") { Task { await library.revalidateAllMetadata() } }
                    .disabled(library.cacheResetInProgress)
                    .help("Keep cached metadata but treat it as unverified, so every timeline and section is read from the NAS again.")
            }
            if library.cacheResetInProgress { ProgressView("Updating cache…") }
            if let error = library.cacheResetError {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task { await library.refreshUsage() }
    }
}
