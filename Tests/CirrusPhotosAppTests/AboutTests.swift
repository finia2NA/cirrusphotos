import Foundation
import Testing
@testable import CirrusPhotosApp

@Suite struct AboutTests {
    private func bundle(_ info: [String: String]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: root))
    }

    @Test func versionTextShowsVersionAndBuild() throws {
        let info = ["CFBundleShortVersionString": "0.1", "CFBundleVersion": "1"]
        #expect(AppVersion.text(bundle: try bundle(info)) == "Version 0.1 (1)")
    }

    @Test func versionTextWithoutKeysIsDevelopmentBuild() throws {
        #expect(AppVersion.text(bundle: try bundle(["CFBundleIdentifier": "x.y"])) == "development build")
    }

    @Test func bundledNoticesDecode() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ThirdPartyNotices.json")
        let notices = ThirdPartyNotice.load(from: url)
        let grdb = try #require(notices.first { $0.name == "GRDB.swift" })
        #expect(grdb.license == "MIT")
        #expect(grdb.licenseText.contains("Permission is hereby granted"))
    }
}
