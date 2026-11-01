import SwiftUI
import PhotoCache
import SynologyAPI

struct AlbumHeaderModel: Hashable {
    let album: AlbumSummary?

    var dateRange: String? {
        guard let album, album.itemCount > 0, let start = album.startTime, let end = album.endTime,
              start > 0, end > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return InfoPanelFormatting.dayRange(
            newest: formatter.string(from: Date(timeIntervalSince1970: TimeInterval(max(start, end)))),
            oldest: formatter.string(from: Date(timeIntervalSince1970: TimeInterval(min(start, end)))))
    }

    static func height(for width: CGFloat) -> CGFloat {
        max(96, min(144, max(0, width * 0.25))) + 48
    }
}

struct AlbumHeaderView: View {
    let model: AlbumHeaderModel
    let repository: CachedPhotosRepository?
    let width: CGFloat

    var body: some View {
        let coverSize = min(144, max(0, width * 0.25))
        HStack(alignment: .top, spacing: 20) {
            AlbumCoverView(thumbnail: model.album?.thumbnail, repository: repository)
                .frame(width: coverSize, height: coverSize)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.album?.name ?? "Album")
                    .font(.title2.weight(.semibold))
                    .lineLimit(3)
                if let range = model.dateRange {
                    Text(range).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: width, height: AlbumHeaderModel.height(for: width), alignment: .topLeading)
    }
}
