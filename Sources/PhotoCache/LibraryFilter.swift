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

public struct LibraryFilter: Equatable, Sendable {
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

    public init(mediaKinds: Set<PhotoMediaKind> = [], cameras: Set<String> = [],
                lenses: Set<String> = [], extensions: Set<String> = [],
                megapixels: OptionalNumericRange<Double> = .init(),
                bytes: OptionalNumericRange<Int64> = .init(),
                iso: OptionalNumericRange<Double> = .init(),
                focalLengthMM: OptionalNumericRange<Double> = .init(),
                aperture: OptionalNumericRange<Double> = .init(),
                exposureSeconds: OptionalNumericRange<Double> = .init()) {
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
    }

    public var isEmpty: Bool {
        mediaKinds.isEmpty && cameras.isEmpty && lenses.isEmpty && extensions.isEmpty &&
            megapixels.isEmpty && bytes.isEmpty && iso.isEmpty && focalLengthMM.isEmpty &&
            aperture.isEmpty && exposureSeconds.isEmpty
    }

    public var activeCriterionCount: Int {
        [!mediaKinds.isEmpty, !cameras.isEmpty, !lenses.isEmpty, !extensions.isEmpty,
         !megapixels.isEmpty, !bytes.isEmpty, !iso.isEmpty, !focalLengthMM.isEmpty,
         !aperture.isEmpty, !exposureSeconds.isEmpty].filter { $0 }.count
    }

    public func matches(_ item: PhotoItem) -> Bool {
        matches(LibraryFilterValues(item))
    }

    func matches(_ values: LibraryFilterValues) -> Bool {
        if !mediaKinds.isEmpty && !mediaKinds.contains(values.mediaKind) { return false }
        if !matches(cameras, value: values.camera, normalizer: LibraryFilterParsing.lookupKey) { return false }
        if !matches(lenses, value: values.lens, normalizer: LibraryFilterParsing.lookupKey) { return false }
        if !matches(extensions, value: values.fileExtension, normalizer: LibraryFilterParsing.extensionKey) { return false }
        return megapixels.contains(values.megapixels) && bytes.contains(values.bytes) &&
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

struct LibraryFilterValues: Sendable {
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

    init(_ item: PhotoItem) {
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
