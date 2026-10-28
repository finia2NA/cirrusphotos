import PhotoCache
import SwiftUI
import SynologyAPI

struct CacheSettingsView: View {
    @EnvironmentObject private var library: LibraryModel
    @AppStorage("viewerHighlightThreshold") private var highlightThreshold = 100.0

    var body: some View {
        Form {
            Picker("Thumbnail rendition", selection: $library.thumbnailSize) {
                Text("Small").tag(ThumbnailSize.sm)
                Text("Medium").tag(ThumbnailSize.m)
                Text("Large").tag(ThumbnailSize.xl)
            }
            Toggle("Load large previews in viewer", isOn: $library.loadsLargeViewerPreviews)
                .disabled(library.thumbnailSize == .xl)
            Picker("Pixel interpolation", selection: $library.pixelInterpolation) {
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
            Picker("Default video quality", selection: $library.videoQuality) {
                ForEach(VideoQualityPreference.allCases, id: \.self) { quality in
                    Text(quality.displayName).tag(quality)
                }
            }
            Text("Converted qualities start faster and use less bandwidth. Original may be slower or unsupported by the Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Maximum cache")
                Slider(value: $library.budgetFraction, in: 0...1)
                Text(ByteCountFormatter.string(
                    fromByteCount: CacheBudget.bytes(at: library.budgetFraction),
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
            if library.cacheResetInProgress { ProgressView("Clearing cache…") }
            if let error = library.cacheResetError {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 500)
        .task { await library.refreshUsage() }
    }
}
