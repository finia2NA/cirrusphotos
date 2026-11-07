import Foundation
import Testing
@testable import CirrusPhotosApp

@Suite struct LogExportTests {
    @Test func fileNameUsesDateAndTime() {
        let zone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_794_000_000)
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        #expect(LogExport.fileName(date: date, timeZone: zone) == "Cirrus Photos Logs \(formatter.string(from: date)).txt")
        #expect(LogExport.fileName(date: Date(timeIntervalSince1970: 0), timeZone: zone) == "Cirrus Photos Logs 1970-01-01 00.00.txt")
    }

    @Test func headerNamesVersionSystemAndRange() {
        let text = LogExport.header(bundle: .main, osVersion: "Version 27.0", exported: Date(timeIntervalSince1970: 0), sessionOnly: false)
        #expect(text.contains("macOS: Version 27.0"))
        #expect(text.contains("Exported: 1970-01-01T00:00:00Z"))
        #expect(text.contains("Range: last 24 hours"))
        #expect(text.hasPrefix("Cirrus Photos "))
    }

    @Test func fallbackHeaderSaysSessionOnly() {
        let text = LogExport.header(sessionOnly: true)
        #expect(text.contains("current session only"))
        #expect(!text.contains("last 24 hours"))
    }

    @Test func linesAreScrubbed() {
        let line = "12:00 [x] GET https://nas.example:5001/webapi/entry.cgi?_sid=SECRET&api=x passwd=hunter2 ok"
        let scrubbed = LogExport.scrubbed(line)
        #expect(!scrubbed.contains("SECRET"))
        #expect(!scrubbed.contains("hunter2"))
        #expect(!scrubbed.contains("nas.example"))
        #expect(scrubbed.hasSuffix("ok"))
    }

    @Test func exportWritesHeaderAndOnlyThisSubsystem() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await LogExport.export(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("Cirrus Photos "))
        #expect(text.contains("Range: "))
        #expect(text.contains("----"))
    }
}
