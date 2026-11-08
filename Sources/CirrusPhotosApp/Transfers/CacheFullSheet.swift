import SwiftUI

/// Asks whether to raise the maximum cache size or stop a thumbnail download that paused
/// because the cache was nearly full. A larger maximum continues the download.
struct CacheFullSheet: View {
    @ObservedObject var preload: ThumbnailPreloadModel

    var body: some View {
        SheetScaffold(title: "Cache Is Full", confirmsDecision: true) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Downloading thumbnails is paused. Raise the maximum size to continue. Thumbnails downloaded so far are kept.")
                    .fixedSize(horizontal: false, vertical: true)
                CacheSizeSlider()
            }
        } trailing: {
            Button("Stop Download") { preload.stopDownload() }
            Button("Done") { preload.showsCacheFullSheet = false }
                .keyboardShortcut(.defaultAction)
        }
    }
}
