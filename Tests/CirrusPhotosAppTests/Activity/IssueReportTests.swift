import Foundation
import Testing
@testable import CirrusPhotosApp

@Suite struct IssueReportTests {
    private func bundle() throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try (["CFBundleShortVersionString": "0.1", "CFBundleVersion": "7"] as NSDictionary)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: root))
    }

    @Test func urlCarriesLabelAndEncodedBody() throws {
        let url = IssueReport.url(bundle: try bundle(), osVersion: "Version 27.0 (Build 1)", model: "Mac15,6")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "github.com")
        #expect(components.path == "/finia2NA/syno/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["labels"] == "bug")
        let body = try #require(items["body"])
        #expect(body.contains("## Steps to reproduce"))
        #expect(body.contains("App: 0.1 (7)"))
        #expect(body.contains("macOS: Version 27.0 (Build 1)"))
        #expect(body.contains("Mac: Mac15,6"))
        #expect(body.contains("Export Logs"))
        // The raw query has no unescaped separators from the body.
        let query = try #require(components.percentEncodedQuery)
        #expect(!query.contains(" ") && !query.contains("\n"))
        #expect(query.split(separator: "&").count == 2)
    }

    @Test func bodyHasNoNASDetails() throws {
        let body = IssueReport.body(bundle: try bundle(), osVersion: "Version 27.0", model: "Mac15,6").lowercased()
        for forbidden in ["nas_url", "http://", "https://", "user=", "cirrus.local"] {
            #expect(!body.contains(forbidden))
        }
    }

    @Test func macModelIsNotEmpty() {
        #expect(!IssueReport.macModel().isEmpty)
    }
}
