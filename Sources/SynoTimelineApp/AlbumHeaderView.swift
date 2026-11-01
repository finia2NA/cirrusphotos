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

    var sharingStatus: String? {
        guard let album else { return nil }
        guard album.shared else { return "Not shared" }
        guard let info = album.sharingInfo else { return "Shared" }
        if info.isExpired == true { return "Sharing expired" }
        switch info.privacyType {
        case "private": return "Shared privately"
        case "public-view": return "Public · View"
        case "public-download": return "Public · Download"
        default: return "Shared"
        }
    }
    var recipients: [AlbumSharingPermission] {
        guard album?.shared == true else { return [] }
        return (album?.sharingInfo?.permission ?? []).filter { $0.type != "public" }
    }
    static func height(for width: CGFloat) -> CGFloat {
        240
    }
}

struct AlbumHeaderView: View {
    let model: AlbumHeaderModel
    let repository: CachedPhotosRepository?
    let width: CGFloat
    let onManageSharing: () -> Void

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
                if let status = model.sharingStatus {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                if model.album != nil, repository != nil {
                    Button(model.album?.shared == true ? "Manage Sharing…" : "Share…") { onManageSharing() }
                }
                if !model.recipients.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(model.recipients.enumerated()), id: \.offset) { _, recipient in
                                RecipientAvatar(recipient: recipient, repository: repository)
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: width, height: AlbumHeaderModel.height(for: width), alignment: .topLeading)
    }
}

private struct RecipientAvatar: View {
    let recipient: AlbumSharingPermission
    let repository: CachedPhotosRepository?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.16))
            if let image {
                Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
            } else if recipient.type == "group" {
                Image(systemName: "person.2.fill").font(.caption)
            } else if let initial = recipient.name.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(initial).uppercased()).font(.caption.weight(.medium))
            } else {
                Image(systemName: "person.fill").font(.caption)
            }
        }
        .frame(width: 28, height: 28)
        .help(recipient.name)
        .accessibilityLabel(recipient.name.isEmpty ? "Recipient" : recipient.name)
        .task(id: recipient) {
            image = nil
            guard recipient.type == "user", let photosID = recipient.photosUserID,
                  let principalID = recipient.principalID, let repository,
                  let data = await repository.recipientAvatar(photosID: photosID, principalID: principalID),
                  !Task.isCancelled else { return }
            image = NSImage(data: data)
        }
    }
}
