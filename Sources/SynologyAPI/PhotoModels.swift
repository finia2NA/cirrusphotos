import Foundation

public struct PhotoItem: Codable, Sendable, Identifiable {
    public let id: Int64
    public let filename: String?
    /// Capture-local wall-clock components encoded by Synology as epoch-shaped seconds.
    /// Format with a GMT calendar/time zone; converting through the computer's current
    /// time zone changes the time the camera recorded.
    public let time: Int64
    public let type: String
    public let liveType: String?
    public var additional: Additional?

    enum CodingKeys: String, CodingKey {
        case id, filename, time, type, additional
        case liveType = "live_type"
    }

    public struct Additional: Codable, Sendable {
        public let thumbnail: ThumbnailInfo?
        public let resolution: Resolution?
        public let orientation: Int?
        public let videoMeta: VideoMetadata?
        public var favorite: Bool?

        enum CodingKeys: String, CodingKey {
            case thumbnail, resolution, orientation, favorite
            case videoMeta = "video_meta"
        }
    }

    public var isFavorite: Bool { additional?.favorite == true }

    public func withFavorite(_ favorite: Bool) -> PhotoItem {
        var copy = self
        if copy.additional == nil {
            copy.additional = Additional(
                thumbnail: nil,
                resolution: nil,
                orientation: nil,
                videoMeta: nil,
                favorite: favorite
            )
        } else {
            copy.additional?.favorite = favorite
        }
        return copy
    }

    public struct Resolution: Codable, Sendable {
        public let width: Int
        public let height: Int
    }

    /// Synology supplies video duration in milliseconds, as an integer, a
    /// floating-point number, or a numeric string. Keep the wire value intact
    /// when caching and expose seconds to the UI.
    public struct VideoMetadata: Codable, Sendable {
        private let durationMilliseconds: Double?
        public var duration: TimeInterval? { durationMilliseconds.map { $0 / 1_000 } }

        enum CodingKeys: String, CodingKey { case duration }

        public init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                durationMilliseconds = nil
                return
            }
            if let value = try? container.decode(Double.self, forKey: .duration) {
                durationMilliseconds = value
            } else if let value = try? container.decode(String.self, forKey: .duration) {
                durationMilliseconds = Double(value)
            } else {
                durationMilliseconds = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(durationMilliseconds, forKey: .duration)
        }
    }

    /// The server-provided resolution already describes the displayed orientation.
    public var displayAspectRatio: Double {
        guard let resolution = additional?.resolution,
              resolution.width > 0, resolution.height > 0 else { return 1 }
        let ratio = Double(resolution.width) / Double(resolution.height)
        return ratio.isFinite && ratio > 0 ? ratio : 1
    }

    /// Matches the UTC calendar boundaries used by timeline section requests.
    public var utcDayID: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: TimeInterval(time))
        )
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public var fullImageResource: FullImageResource? { FullImageResource(self) }

    /// Live Photos are returned as `type: "live"`; `live_type` identifies the
    /// still-image member that should use the normal original-photo path.
    public var hasDisplayableStillImage: Bool {
        type == "photo" || (type == "live" && liveType == "photo")
    }

    public var isVideo: Bool { type == "video" }
}

/// The stable server identity and revision used to request and cache an original image.
public struct FullImageResource: Hashable, Sendable {
    public let unitID: Int64
    public let cacheKey: String
    public let filename: String?

    public init(unitID: Int64, cacheKey: String, filename: String? = nil) {
        self.unitID = unitID
        self.cacheKey = cacheKey
        self.filename = filename
    }

    public init?(_ item: PhotoItem) {
        guard item.hasDisplayableStillImage,
              let thumbnail = item.additional?.thumbnail else { return nil }
        self.init(unitID: thumbnail.unitID, cacheKey: thumbnail.cacheKey, filename: item.filename)
    }
}

public struct ThumbnailInfo: Codable, Sendable {
    public let unitID: Int64
    public let cacheKey: String
    public let sm: String?
    public let m: String?
    public let xl: String?

    enum CodingKeys: String, CodingKey {
        case unitID = "unit_id", cacheKey = "cache_key", sm, m, xl
    }

    public func isReady(_ size: ThumbnailSize) -> Bool {
        switch size {
        case .sm: sm == "ready"
        case .m: m == "ready"
        case .xl: xl == "ready"
        }
    }
}

public enum ThumbnailSize: String, CaseIterable, Codable, Sendable { case sm, m, xl }

/// A server-side item collection that shares the Photos timeline/item APIs.
public enum PhotoCollectionDescriptor: String, CaseIterable, Codable, Hashable, Sendable {
    /// Preserve the existing Personal Library cache namespace.
    case personalLibrary = "personal"
    case favorites

    public var favoriteOnly: Bool { self == .favorites }
    public var supportsInitialTimeline: Bool { self == .personalLibrary }
}
