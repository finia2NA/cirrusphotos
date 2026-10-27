import Foundation
import TimelineCore

public enum PhotoMediaKind: Hashable, Sendable {
    case photo
    case video
    case livePhoto
    case unknown(String)

    public var accessibilityLabel: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        case .livePhoto: "Live Photo"
        case .unknown: "File"
        }
    }

    public var systemImage: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .livePhoto: "livephoto"
        case .unknown: "doc"
        }
    }
}

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
    /// Ephemeral UI projection while a normal server rotation is pending. It is
    /// deliberately excluded from cached/wire coding and returns to zero when the
    /// authoritative item is decoded.
    public var pendingRotationQuarterTurns: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, filename, time, type, filesize, additional
        case liveType = "live_type"
    }

    public struct Additional: Codable, Sendable, Equatable {
        public let thumbnail: ThumbnailInfo?
        public let resolution: Resolution?
        public let orientation: Int?
        public let orientationOriginal: Int?
        public let videoConvert: [VideoRendition]?
        public let videoMeta: VideoMetadata?
        public let exif: ExifInfo?
        public let gps: PhotoCoordinate?
        public let folderPath: String?
        public var favorite: Bool?

        enum CodingKeys: String, CodingKey {
            case thumbnail, resolution, orientation, exif, gps, favorite
            case orientationOriginal = "orientation_original"
            case videoConvert = "video_convert"
            case videoMeta = "video_meta"
            case folderPath = "folder"
        }
    }

    public var isFavorite: Bool { additional?.favorite == true }

    public var mediaKind: PhotoMediaKind {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedLiveType = liveType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedType == "live" || normalizedLiveType == "live" { return .livePhoto }
        if normalizedType == "video" { return .video }
        if normalizedType == "photo" { return .photo }
        return .unknown(type)
    }

    /// The validated capture location, when the server reported one.
    public var coordinate: PhotoCoordinate? {
        additional?.gps.flatMap { $0.isValid ? $0 : nil }
    }

    /// A local rotation result changes only rotation/media presentation metadata.
    /// Concurrent favorite, EXIF and location updates remain on the canonical item.
    public func withRotationMetadata(from replacement: PhotoItem) -> PhotoItem {
        guard replacement.id == id, let value = replacement.additional else { return self }
        var item = self
        let current = additional
        item.additional = Additional(thumbnail: value.thumbnail, resolution: value.resolution,
                                     orientation: value.orientation, orientationOriginal: value.orientationOriginal,
                                     videoConvert: current?.videoConvert, videoMeta: current?.videoMeta,
                                     exif: current?.exif, gps: current?.gps, folderPath: current?.folderPath,
                                     favorite: current?.favorite)
        item.pendingRotationQuarterTurns = replacement.pendingRotationQuarterTurns
        return item
    }

    public func withFavorite(_ favorite: Bool) -> PhotoItem {
        var copy = self
        if copy.additional == nil {
            copy.additional = Additional(
                thumbnail: nil,
                resolution: nil,
                orientation: nil,
                orientationOriginal: nil,
                videoConvert: nil,
                videoMeta: nil,
                exif: nil,
                gps: nil,
                folderPath: nil,
                favorite: favorite
            )
        } else {
            copy.additional?.favorite = favorite
        }
        return copy
    }

    /// Optimistic metadata projection used while Synology regenerates the normal
    /// display orientation. The authoritative item replaces this value after the write.
    public func rotated(_ direction: PhotoRotationDirection) -> PhotoItem {
        var copy = self
        copy.pendingRotationQuarterTurns += direction == .clockwise ? 1 : -1
        guard var additional = copy.additional else { return copy }
        if let resolution = additional.resolution {
            additional = Additional(
                thumbnail: additional.thumbnail,
                resolution: Resolution(width: resolution.height, height: resolution.width),
                orientation: Self.rotatedOrientation(additional.orientation, direction),
                orientationOriginal: additional.orientationOriginal,
                videoConvert: additional.videoConvert,
                videoMeta: additional.videoMeta,
                exif: additional.exif,
                gps: additional.gps,
                folderPath: additional.folderPath,
                favorite: additional.favorite
            )
        } else {
            additional = Additional(
                thumbnail: additional.thumbnail, resolution: nil,
                orientation: Self.rotatedOrientation(additional.orientation, direction),
                orientationOriginal: additional.orientationOriginal,
                videoConvert: additional.videoConvert, videoMeta: additional.videoMeta,
                exif: additional.exif, gps: additional.gps,
                folderPath: additional.folderPath, favorite: additional.favorite
            )
        }
        copy.additional = additional
        return copy
    }

    private static func rotatedOrientation(_ orientation: Int?, _ direction: PhotoRotationDirection) -> Int? {
        guard let orientation else { return nil }
        let clockwise = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]
        let counterClockwise = [1: 8, 8: 3, 3: 6, 6: 1, 2: 5, 5: 4, 4: 7, 7: 2]
        return (direction == .clockwise ? clockwise : counterClockwise)[orientation] ?? orientation
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
        public let audioBitrate: Double?
        public let audioChannel: Int?
        public let audioCodec: String?
        public let audioFrequency: Double?
        public let containerType: String?
        public let frameBitrate: Double?
        public let framerate: Double?
        public let orientation: Int?
        public let resolutionX: Int?
        public let resolutionY: Int?
        public let videoBitrate: Double?
        public let videoCodec: String?

        enum CodingKeys: String, CodingKey {
            case duration, orientation, framerate
            case audioBitrate = "audio_bitrate"
            case audioChannel = "audio_channel"
            case audioCodec = "audio_codec"
            case audioFrequency = "audio_frequency"
            case containerType = "container_type"
            case frameBitrate = "frame_bitrate"
            case resolutionX = "resolution_x"
            case resolutionY = "resolution_y"
            case videoBitrate = "video_bitrate"
            case videoCodec = "video_codec"
        }

        public init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                durationMilliseconds = nil
                audioBitrate = nil; audioChannel = nil; audioCodec = nil
                audioFrequency = nil; containerType = nil; frameBitrate = nil
                framerate = nil; orientation = nil; resolutionX = nil; resolutionY = nil
                videoBitrate = nil; videoCodec = nil
                return
            }
            durationMilliseconds = Self.double(container, .duration)
            audioBitrate = Self.double(container, .audioBitrate)
            audioChannel = Self.int(container, .audioChannel)
            audioCodec = try? container.decodeIfPresent(String.self, forKey: .audioCodec)
            audioFrequency = Self.double(container, .audioFrequency)
            containerType = try? container.decodeIfPresent(String.self, forKey: .containerType)
            frameBitrate = Self.double(container, .frameBitrate)
            framerate = Self.double(container, .framerate)
            orientation = Self.int(container, .orientation)
            resolutionX = Self.int(container, .resolutionX)
            resolutionY = Self.int(container, .resolutionY)
            videoBitrate = Self.double(container, .videoBitrate)
            videoCodec = try? container.decodeIfPresent(String.self, forKey: .videoCodec)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(durationMilliseconds, forKey: .duration)
            try container.encodeIfPresent(audioBitrate, forKey: .audioBitrate)
            try container.encodeIfPresent(audioChannel, forKey: .audioChannel)
            try container.encodeIfPresent(audioCodec, forKey: .audioCodec)
            try container.encodeIfPresent(audioFrequency, forKey: .audioFrequency)
            try container.encodeIfPresent(containerType, forKey: .containerType)
            try container.encodeIfPresent(frameBitrate, forKey: .frameBitrate)
            try container.encodeIfPresent(framerate, forKey: .framerate)
            try container.encodeIfPresent(orientation, forKey: .orientation)
            try container.encodeIfPresent(resolutionX, forKey: .resolutionX)
            try container.encodeIfPresent(resolutionY, forKey: .resolutionY)
            try container.encodeIfPresent(videoBitrate, forKey: .videoBitrate)
            try container.encodeIfPresent(videoCodec, forKey: .videoCodec)
        }

        private static func double(_ container: KeyedDecodingContainer<CodingKeys>,
                                   _ key: CodingKeys) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return value }
            if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
            return nil
        }

        private static func int(_ container: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? container.decode(String.self, forKey: key) { return Int(value) }
            return nil
        }
    }

    public struct VideoRendition: Codable, Sendable, Equatable {
        public let quality: String
        public let metadata: VideoMetadata
        public var knownQuality: VideoQuality? { VideoQuality(rawValue: quality) }
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

    /// Live Photos use the normal original-photo path for their still image.
    /// Cirrus has returned both `photo` and `live` for `live_type`.
    public var hasDisplayableStillImage: Bool {
        type == "photo" || type == "live"
    }

    public var isVideo: Bool { type == "video" }

    public func videoPlaybackResource(preference: VideoQualityPreference) -> VideoPlaybackResource? {
        guard isVideo, let thumbnail = additional?.thumbnail else { return nil }
        let variant: VideoPlaybackVariant
        if preference == .original {
            variant = .original
        } else {
            let target = preference.targetQuality ?? .high
            let available = Set((additional?.videoConvert ?? []).compactMap(\.knownQuality))
            if let chosen = VideoQuality.closest(to: target, in: available) {
                variant = .converted(chosen)
            } else {
                variant = .original
            }
        }
        return VideoPlaybackResource(unitID: thumbnail.unitID, cacheKey: thumbnail.cacheKey,
                                     filename: filename, variant: variant)
    }

    /// Additional clockwise quarter turns required after ImageIO has applied the
    /// stored original's EXIF orientation. Synology normal rotation changes
    /// `orientation` while leaving `orientation_original` and original bytes intact.
    /// Mirrored EXIF orientations form their own four-state rotation cycle.
    public var originalDisplayQuarterTurns: Int {
        guard let current = additional?.orientation,
              let original = additional?.orientationOriginal else { return 0 }
        let cycles = [[1, 6, 3, 8], [2, 7, 4, 5]]
        for cycle in cycles {
            guard let originalIndex = cycle.firstIndex(of: original),
                  let currentIndex = cycle.firstIndex(of: current) else { continue }
            let clockwise = (currentIndex - originalIndex + 4) % 4
            return clockwise == 3 ? -1 : clockwise
        }
        return 0
    }
}

public enum VideoQuality: String, Codable, CaseIterable, Sendable, Hashable {
    case mobile, low, medium, high
    case originalH264 = "orig_h264"

    public var rank: Int {
        switch self {
        case .mobile: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        case .originalH264: 4
        }
    }

    public var displayName: String {
        switch self {
        case .mobile: "Mobile"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .originalH264: "Original Resolution (Compatible)"
        }
    }

    public static func closest(to target: VideoQuality, in available: Set<VideoQuality>) -> VideoQuality? {
        available.min {
            let left = (abs($0.rank - target.rank), $0.rank > target.rank ? 1 : 0, $0.rank)
            let right = (abs($1.rank - target.rank), $1.rank > target.rank ? 1 : 0, $1.rank)
            return left < right
        }
    }
}

public enum VideoQualityPreference: String, Codable, CaseIterable, Sendable, Hashable {
    case automatic, original, high, medium, low, mobile

    public var targetQuality: VideoQuality? {
        switch self {
        case .automatic, .high: .high
        case .medium: .medium
        case .low: .low
        case .mobile: .mobile
        case .original: nil
        }
    }

    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .original: "Original"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        case .mobile: "Mobile"
        }
    }
}

public enum VideoPlaybackVariant: Hashable, Codable, Sendable {
    case original
    case converted(VideoQuality)

    public var cacheComponent: String {
        switch self {
        case .original: "original"
        case .converted(let quality): quality.rawValue
        }
    }

    public var displayName: String {
        switch self {
        case .original: "Original"
        case .converted(let quality): quality.displayName
        }
    }
}

public struct VideoPlaybackResource: Hashable, Codable, Sendable {
    public let unitID: Int64
    public let cacheKey: String
    public let filename: String?
    public let variant: VideoPlaybackVariant

    public init(unitID: Int64, cacheKey: String, filename: String?, variant: VideoPlaybackVariant) {
        self.unitID = unitID
        self.cacheKey = cacheKey
        self.filename = filename
        self.variant = variant
    }
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
    /// cluster). Never persisted; pages are filtered from Personal Library pages.
    case mapFilter(UUID)
    /// A session-only client-side filtered Personal Library collection.
    case libraryFilter(UUID)

    /// Stable cache/restoration identity. Personal Library and Favorites keep their
    /// stable raw values for persistent collection identity.
    public var rawValue: String {
        switch self {
        case .personalLibrary: "personal"
        case .favorites: "favorites"
        case .album(let id): "album:\(id)"
        case .mapFilter(let id): "map:\(id.uuidString)"
        case .libraryFilter(let id): "filter:\(id.uuidString)"
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

    public var libraryFilterID: UUID? {
        if case .libraryFilter(let id) = self { return id }
        return nil
    }

    public var isLibraryFilter: Bool { libraryFilterID != nil }
    public var usesPersonalLibrarySource: Bool { isMapFilter || isLibraryFilter }

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
            if rawValue.hasPrefix(mapPrefix),
               let id = UUID(uuidString: String(rawValue.dropFirst(mapPrefix.count))) {
                self = .mapFilter(id)
                return
            }
            let filterPrefix = "filter:"
            guard rawValue.hasPrefix(filterPrefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(filterPrefix.count))) else { return nil }
            self = .libraryFilter(id)
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
