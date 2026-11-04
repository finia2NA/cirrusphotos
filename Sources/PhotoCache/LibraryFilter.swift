import Foundation
import SynologyAPI

public struct OptionalNumericRange<Value: Comparable & Sendable>: Equatable, Sendable {
    public var minimum: Value?
    public var maximum: Value?

    public init(minimum: Value? = nil, maximum: Value? = nil) {
        self.minimum = minimum
        self.maximum = maximum
    }

    var isEmpty: Bool { minimum == nil && maximum == nil }

    func contains(_ value: Value?) -> Bool {
        guard !isEmpty else { return true }
        guard let value else { return false }
        if let minimum, value < minimum { return false }
        if let maximum, value > maximum { return false }
        return true
    }
}

/// A filename criterion: a case- and diacritic-insensitive substring, or a
/// case-insensitive regular expression matched anywhere in the filename.
public struct FilenameSearch: Equatable, Sendable {
    public enum Mode: Sendable { case text, regularExpression }
    public let text: String
    public let mode: Mode
    private let key: String
    private let expression: NSRegularExpression?

    public init(_ text: String = "", mode: Mode = .text) {
        self.text = text
        self.mode = mode
        key = LibraryFilterParsing.searchKey(text.trimmingCharacters(in: .whitespacesAndNewlines))
        expression = mode == .regularExpression && !text.isEmpty
            ? try? NSRegularExpression(pattern: text, options: [.caseInsensitive]) : nil
    }

    public var isEmpty: Bool { mode == .text ? key.isEmpty : text.isEmpty }
    /// False for a regular expression that does not compile.
    public var isValid: Bool { mode == .text || text.isEmpty || expression != nil }

    func matches(filename: String?, key filenameKey: String?) -> Bool {
        guard !isEmpty else { return true }
        switch mode {
        case .text:
            guard let filenameKey else { return false }
            return filenameKey.contains(key)
        case .regularExpression:
            guard let expression, let filename else { return false }
            return expression.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text && lhs.mode == rhs.mode }
}

public struct LibraryFilter: Equatable, Sendable {
    public var filename: FilenameSearch
    public var mediaKinds: Set<PhotoMediaKind>
    public var cameras: Set<String>
    public var lenses: Set<String>
    public var extensions: Set<String>
    public var megapixels: OptionalNumericRange<Double>
    public var bytes: OptionalNumericRange<Int64>
    public var iso: OptionalNumericRange<Double>
    public var focalLengthMM: OptionalNumericRange<Double>
    public var aperture: OptionalNumericRange<Double>
    public var exposureSeconds: OptionalNumericRange<Double>
    /// Matches an item that has at least one of these tags, compared by name.
    public var tags: Set<String>
    /// Star rating bounds; 0 is unrated.
    public var rating: OptionalNumericRange<Int>

    public init(filename: FilenameSearch = .init(), mediaKinds: Set<PhotoMediaKind> = [], cameras: Set<String> = [],
                lenses: Set<String> = [], extensions: Set<String> = [],
                megapixels: OptionalNumericRange<Double> = .init(),
                bytes: OptionalNumericRange<Int64> = .init(),
                iso: OptionalNumericRange<Double> = .init(),
                focalLengthMM: OptionalNumericRange<Double> = .init(),
                aperture: OptionalNumericRange<Double> = .init(),
                exposureSeconds: OptionalNumericRange<Double> = .init(),
                tags: Set<String> = [], rating: OptionalNumericRange<Int> = .init()) {
        self.filename = filename
        self.mediaKinds = mediaKinds
        self.cameras = cameras
        self.lenses = lenses
        self.extensions = extensions
        self.megapixels = megapixels
        self.bytes = bytes
        self.iso = iso
        self.focalLengthMM = focalLengthMM
        self.aperture = aperture
        self.exposureSeconds = exposureSeconds
        self.tags = tags
        self.rating = rating
    }

    public var isEmpty: Bool {
        filename.isEmpty && mediaKinds.isEmpty && cameras.isEmpty && lenses.isEmpty && extensions.isEmpty &&
            megapixels.isEmpty && bytes.isEmpty && iso.isEmpty && focalLengthMM.isEmpty &&
            aperture.isEmpty && exposureSeconds.isEmpty && tags.isEmpty && rating.isEmpty
    }

    public var activeCriterionCount: Int {
        [!filename.isEmpty, !mediaKinds.isEmpty, !cameras.isEmpty, !lenses.isEmpty, !extensions.isEmpty,
         !megapixels.isEmpty, !bytes.isEmpty, !iso.isEmpty, !focalLengthMM.isEmpty,
         !aperture.isEmpty, !exposureSeconds.isEmpty, !tags.isEmpty, !rating.isEmpty].filter { $0 }.count
    }

    public func matches(_ item: PhotoItem) -> Bool {
        matches(LibraryFilterValues(item))
    }

    func matches(_ values: LibraryFilterValues) -> Bool {
        if !filename.matches(filename: values.filename, key: values.filenameKey) { return false }
        if !mediaKinds.isEmpty && !mediaKinds.contains(values.mediaKind) { return false }
        if !matches(cameras, value: values.camera, normalizer: LibraryFilterParsing.lookupKey) { return false }
        if !matches(lenses, value: values.lens, normalizer: LibraryFilterParsing.lookupKey) { return false }
        if !matches(extensions, value: values.fileExtension, normalizer: LibraryFilterParsing.extensionKey) { return false }
        if !tags.isEmpty {
            let wanted = Set(tags.map(LibraryFilterParsing.lookupKey))
            guard values.tags.contains(where: { wanted.contains(LibraryFilterParsing.lookupKey($0)) }) else { return false }
        }
        return rating.contains(values.rating) && megapixels.contains(values.megapixels) && bytes.contains(values.bytes) &&
            iso.contains(values.iso) && focalLengthMM.contains(values.focalLengthMM) &&
            aperture.contains(values.aperture) && exposureSeconds.contains(values.exposureSeconds)
    }

    private func matches(_ selected: Set<String>, value: String?,
                         normalizer: (String) -> String) -> Bool {
        guard !selected.isEmpty else { return true }
        guard let value else { return false }
        let keys = Set(selected.map(normalizer))
        return keys.contains(normalizer(value))
    }
}

struct LibraryFilterValues: Equatable, Sendable {
    let filename: String?
    /// `filename` folded for plain-text search.
    let filenameKey: String?
    let mediaKind: PhotoMediaKind
    let camera: String?
    let lens: String?
    let fileExtension: String?
    let megapixels: Double?
    let bytes: Int64?
    let iso: Double?
    let focalLengthMM: Double?
    let aperture: Double?
    let exposureSeconds: Double?
    let rating: Int
    let tags: [String]

    init(filename: String?, filenameKey: String?, mediaKind: PhotoMediaKind, camera: String?, lens: String?, fileExtension: String?, megapixels: Double?,
         bytes: Int64?, iso: Double?, focalLengthMM: Double?, aperture: Double?, exposureSeconds: Double?,
         rating: Int = 0, tags: [String] = []) {
        self.rating = rating; self.tags = tags
        self.filename = filename; self.filenameKey = filenameKey
        self.mediaKind = mediaKind; self.camera = camera; self.lens = lens; self.fileExtension = fileExtension
        self.megapixels = megapixels; self.bytes = bytes; self.iso = iso; self.focalLengthMM = focalLengthMM
        self.aperture = aperture; self.exposureSeconds = exposureSeconds
    }

    init(_ item: PhotoItem) {
        filename = item.filename
        filenameKey = item.filename.map(LibraryFilterParsing.searchKey)
        mediaKind = item.mediaKind
        camera = LibraryFilterParsing.displayString(item.additional?.exif?.camera)
        lens = LibraryFilterParsing.displayString(item.additional?.exif?.lens)
        fileExtension = LibraryFilterParsing.fileExtension(item.filename)
        if let resolution = item.additional?.resolution, resolution.width > 0, resolution.height > 0 {
            megapixels = Double(resolution.width) * Double(resolution.height) / 1_000_000
        } else { megapixels = nil }
        bytes = item.filesize.flatMap { $0 > 0 ? $0 : nil }
        iso = LibraryFilterParsing.firstPositiveNumber(item.additional?.exif?.iso)
        focalLengthMM = LibraryFilterParsing.firstPositiveNumber(item.additional?.exif?.focalLength)
        aperture = LibraryFilterParsing.aperture(item.additional?.exif?.aperture)
        exposureSeconds = LibraryFilterParsing.exposureSeconds(item.additional?.exif?.exposureTime)
        rating = item.rating
        tags = item.tags.map(\.name)
    }
}

enum LibraryFilterParsing {
    static let locale = Locale(identifier: "en_US_POSIX")

    static func displayString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func lookupKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: locale)
    }

    static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }

    static func extensionKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(with: locale)
    }

    static func fileExtension(_ filename: String?) -> String? {
        guard let filename, let dot = filename.lastIndex(of: "."), dot < filename.index(before: filename.endIndex) else { return nil }
        return extensionKey(String(filename[filename.index(after: dot)...]))
    }

    static func firstPositiveNumber(_ text: String?) -> Double? {
        guard let text else { return nil }
        let pattern = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"#
        guard let range = text.range(of: pattern, options: .regularExpression),
              let value = Double(text[range]), value.isFinite, value > 0 else { return nil }
        return value
    }

    static func aperture(_ text: String?) -> Double? {
        firstPositiveNumber(text)
    }

    static func exposureSeconds(_ text: String?) -> Double? {
        guard var value = displayString(text)?.lowercased() else { return nil }
        if value.hasSuffix("s") { value.removeLast(); value = value.trimmingCharacters(in: .whitespaces) }
        let result: Double?
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        if pieces.count == 2, let numerator = Double(pieces[0].trimmingCharacters(in: .whitespaces)),
           let denominator = Double(pieces[1].trimmingCharacters(in: .whitespaces)), denominator != 0 {
            result = numerator / denominator
        } else if pieces.count == 1 { result = Double(value) }
        else { result = nil }
        guard let result, result.isFinite, result > 0 else { return nil }
        return result
    }
}
