import PhotoCache
import SynologyAPI

/// Problems with the item the viewer shows, one line each, from the NAS's metadata and, for
/// photos, from the viewer's own loads (videos report playback themselves). Several can apply at
/// once, such as an empty file whose previews the NAS could not create and whose original then fails.
enum ViewerProblems {
    struct Inputs: Equatable {
        /// The item's NAS file size, when reported.
        var filesize: Int64?
        var thumbnail: ThumbnailInfo?
        var thumbnailStatus: PhotoViewerResourceStatus
        var fullStatus: PhotoViewerResourceStatus
        var fullImageLimit: FullImageLimit?
        var decodeFailure: String?
        /// An image is on screen. Load failures that leave a usable image show only while connected.
        var hasImage: Bool
        var allowNetwork: Bool
        var isVideo = false
    }

    static func make(_ inputs: Inputs) -> [String] {
        var problems: [String] = []
        if inputs.filesize == 0 { problems.append("The file on the NAS is empty.") }
        let broken = brokenSizes(inputs.thumbnail)
        if !broken.isEmpty {
            problems.append(broken.count == ThumbnailSize.allCases.count
                ? "The NAS couldn't create previews of this \(inputs.isVideo ? "video" : "photo")."
                : "The NAS couldn't create the \(list(broken.map(name))) preview\(broken.count == 1 ? "" : "s").")
        }
        if inputs.isVideo { return problems }
        if broken.isEmpty, !inputs.hasImage || inputs.allowNetwork {
            switch inputs.thumbnailStatus {
            case .failure(let message), .unsupported(let message): problems.append("Preview unavailable: \(message)")
            default: break
            }
        }
        if let failure = inputs.decodeFailure {
            problems.append("The original couldn't be decoded: \(failure)")
        }
        switch inputs.fullStatus {
        case .failure(let message) where !inputs.hasImage || inputs.allowNetwork:
            problems.append("\(inputs.allowNetwork ? "Original unavailable" : "Original unavailable offline"): \(message)")
        case .unsupported(let message) where !inputs.hasImage && inputs.fullImageLimit != .qualitySetting:
            problems.append(message)
        default: break
        }
        return problems
    }

    /// Sizes with a status other than ready, such as `broken` or `ame_defect`. `converting` is
    /// still in progress, and a missing status says nothing.
    private static func brokenSizes(_ thumbnail: ThumbnailInfo?) -> [ThumbnailSize] {
        guard let thumbnail else { return [] }
        return ThumbnailSize.allCases.filter { size in
            let status = switch size {
            case .sm: thumbnail.sm
            case .m: thumbnail.m
            case .xl: thumbnail.xl
            }
            guard let status else { return false }
            return status != "ready" && status != "converting"
        }
    }

    private static func name(_ size: ThumbnailSize) -> String {
        switch size {
        case .sm: "small"
        case .m: "medium"
        case .xl: "large"
        }
    }

    private static func list(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + words.last!
    }
}
