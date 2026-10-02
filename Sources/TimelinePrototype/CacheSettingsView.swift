import PhotoCache
import SwiftUI
import SynologyAPI

struct CacheSettingsView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        Form {
            Picker("Thumbnail rendition", selection: $library.thumbnailSize) {
                Text("Small").tag(ThumbnailSize.sm)
                Text("Medium").tag(ThumbnailSize.m)
                Text("Large").tag(ThumbnailSize.xl)
            }
            Toggle("Load large previews in viewer", isOn: $library.loadsLargeViewerPreviews)
                .disabled(library.thumbnailSize == .xl)
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
                Button("Clear Cache") { Task { await library.clearCache() } }
            }
        }
        .padding(24)
        .frame(width: 500)
        .task { await library.refreshUsage() }
    }
}
