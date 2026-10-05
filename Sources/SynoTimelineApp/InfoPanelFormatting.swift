import Foundation

enum InfoPanelFormatting {
    static func dayRange(newest: String?, oldest: String?,
                         locale: Locale = .current) -> String? {
        guard let newest, let oldest,
              let newestDate = dayIDFormatter().date(from: newest),
              let oldestDate = dayIDFormatter().date(from: oldest) else { return nil }
        if newest == oldest {
            return localizedDay(newestDate, withYear: true, locale: locale)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sameYear = calendar.component(.year, from: newestDate) ==
            calendar.component(.year, from: oldestDate)
        let older = localizedDay(oldestDate, withYear: !sameYear, locale: locale)
        let newer = localizedDay(newestDate, withYear: true, locale: locale)
        return "\(older) – \(newer)"
    }

    static func singleDateTime(_ time: Int64, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(time)))
    }

    static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useAll]
        return formatter.string(fromByteCount: bytes)
    }

    static func megapixels(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        let count = Int((Double(width) * Double(height)) / 1_000_000)
        return "\(count) MP"
    }

    static func formatBadge(filename: String) -> String? {
        let ext = (filename as NSString).pathExtension.uppercased()
        guard !ext.isEmpty else { return nil }
        switch ext {
        case "HEIC", "HEIF", "HIF": return "HEIF"
        case "JPG", "JPEG": return "JPEG"
        case "TIF", "TIFF": return "TIFF"
        default: return ext
        }
    }

    static func apertureValue(_ value: String) -> String {
        guard value.count > 1, value.hasPrefix("F") else { return value }
        return "f/" + value.dropFirst()
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func dayIDFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func localizedDay(_ date: Date, withYear: Bool, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate(withYear ? "MMM d, yyyy" : "MMM d")
        return formatter.string(from: date)
    }
}
