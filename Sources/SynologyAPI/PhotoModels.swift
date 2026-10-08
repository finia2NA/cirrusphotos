import Foundation
import TimelineCore

public struct PhotoItem: Codable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let filename: String?
    /// Capture-local wall-clock components encoded by Synology as epoch-shaped seconds.
    /// Format with a GMT calendar/time zone; converting through the computer's current
    /// time zone changes the time the camera recorded.
    public let time: Int64
    public let type: String
    public let liveType: String?
    public let filesize: Int64?
    public var additional: Additional?

    enum CodingKeys: String, CodingKey {
        case id, filename, time, type, filesize, additional
        case liveType = "live_type"
    }

    public struct Additional: Codable, Sendable, Equatable {
        public let thumbnail: ThumbnailInfo?
        public let resolution: Resolution?
        public let orientation: Int?
        public let videoMeta: VideoMetadata?
        public let exif: ExifInfo?
        public let gps: PhotoCoordinate?
        public var favorite: Bool?

        enum CodingKeys: String, CodingKey {
            case thumbnail, resolution, orientation, exif, gps, favorite
            case videoMeta = "video_meta"
        }
    }

    public var isFavorite: Bool { additional?.favorite == true }

    /// The validated capture location, when the server reported one.
    public var coordinate: PhotoCoordinate? {
        additional?.gps.flatMap { $0.isValid ? $0 : nil }
    }

    public func withFavorite(_ favorite: Bool) -> PhotoItem {
        var copy = self
        if copy.additional == nil {
            copy.additional = Additional(
                thumbnail: nil,
                resolution: nil,
                orientation: nil,
                videoMeta: nil,
                exif: nil,
                gps: nil,
                favorite: favorite
            )
        } else {
            copy.additional?.favorite = favorite
        }
        return copy
    }

    public struct Resolution: Codable, Sendable, Equatable {
        public let width: Int
        public let height: Int
    }

    /// Synology supplies video duration in milliseconds, as an integer, a
    /// floating-point number, or a numeric string. Keep the wire value intact
    /// when caching and expose seconds to the UI.
    public struct VideoMetadata: Codable, Sendable, Equatable {
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

public struct ThumbnailInfo: Codable, Sendable, Equatable, Hashable {
    public let unitID: Int64
    public let cacheKey: String
    public let sm: String?
    public let m: String?
    public let xl: String?

    enum CodingKeys: String, CodingKey {
        case unitID = "unit_id", cacheKey = "cache_key", sm, m, xl
    }

    public init(unitID: Int64, cacheKey: String, sm: String? = nil, m: String? = nil, xl: String? = nil) {
        self.unitID = unitID
        self.cacheKey = cacheKey
        self.sm = sm
        self.m = m
        self.xl = xl
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

/// A JSON scalar as returned in an EXIF object. Non-scalar or unrecognized shapes decode to `.null`.
public enum ExifValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// The complete EXIF object returned for an item. Every server key is retained in
/// `raw`; the typed accessors expose the fields the UI displays today. Missing and
/// empty values both surface as `nil`.
public struct ExifInfo: Codable, Sendable, Equatable {
    /// Every key the server returned, preserved verbatim for future display.
    public let raw: [String: ExifValue]

    public init(raw: [String: ExifValue]) {
        self.raw = raw
    }

    public var aperture: String? { displayValue("aperture") }
    public var camera: String? { displayValue("camera") }
    public var exposureTime: String? { displayValue("exposure_time") }
    public var focalLength: String? { displayValue("focal_length") }
    public var iso: String? { displayValue("iso") }
    public var lens: String? { displayValue("lens") }

    /// True when at least one of the six display fields has a non-empty value.
    public var hasAnyValue: Bool {
        aperture != nil || camera != nil || exposureTime != nil ||
            focalLength != nil || iso != nil || lens != nil
    }

    private func displayValue(_ key: String) -> String? {
        guard let value = raw[key] else { return nil }
        let text: String
        switch value {
        case .string(let string): text = string
        case .number(let number): text = Self.string(from: number)
        case .bool(let flag): text = flag ? "true" : "false"
        case .null: return nil
        }
        return text.isEmpty ? nil : text
    }

    private static func string(from number: Double) -> String {
        if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
            return String(Int64(number))
        }
        return String(number)
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var values: [String: ExifValue] = [:]
        for key in container.allKeys {
            values[key.stringValue] = (try? container.decode(ExifValue.self, forKey: key)) ?? .null
        }
        raw = values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in raw {
            guard let codingKey = AnyKey(stringValue: key) else { continue }
            try container.encode(value, forKey: codingKey)
        }
    }
}

/// A server-side item collection that shares the Photos timeline/item APIs.
public enum PhotoCollectionDescriptor: CaseIterable, Codable, Hashable, Sendable {
    case personalLibrary
    case favorites
    /// A Personal Space album, identified by its Synology album id.
    case album(Int64)
    /// A session-only timeline filtered to an explicit item set (a map pin or
    /// cluster). Never persisted; pages come from `Browse.Item get`.
    case mapFilter(UUID)

    /// Stable cache/restoration identity. Personal Library and Favorites keep their
    /// historical raw values so existing cache keys do not move.
    public var rawValue: String {
        switch self {
        case .personalLibrary: "personal"
        case .favorites: "favorites"
        case .album(let id): "album:\(id)"
        case .mapFilter(let id): "map:\(id.uuidString)"
        }
    }

    public var albumID: Int64? {
        if case .album(let id) = self { return id }
        return nil
    }

    public var mapFilterID: UUID? {
        if case .mapFilter(let id) = self { return id }
        return nil
    }

    public var isMapFilter: Bool { mapFilterID != nil }

    public var favoriteOnly: Bool { self == .favorites }
    public var supportsInitialTimeline: Bool { self == .personalLibrary }

    /// Albums are fetched lazily when opened and are never part of eager bootstrap loads.
    /// Map filters are session-only and never fetched from the timeline endpoint.
    public static var allCases: [PhotoCollectionDescriptor] { [.personalLibrary, .favorites] }

    public init?(rawValue: String) {
        switch rawValue {
        case "personal": self = .personalLibrary
        case "favorites": self = .favorites
        default:
            let albumPrefix = "album:"
            if rawValue.hasPrefix(albumPrefix),
               let id = Int64(rawValue.dropFirst(albumPrefix.count)) {
                self = .album(id)
                return
            }
            let mapPrefix = "map:"
            guard rawValue.hasPrefix(mapPrefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(mapPrefix.count))) else { return nil }
            self = .mapFilter(id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = PhotoCollectionDescriptor(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown collection descriptor \(raw)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
