import Foundation
import CryptoKit
import XCTest
@testable import SynologyAPI

final class PhotoDownloadTests: XCTestCase {
    func testZIPTrailerRejectsTruncationAndAcceptsComment() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var archive = Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: 0, count: 16) + [3, 0] + [1, 2, 3])
        try archive.write(to: url)
        XCTAssertTrue(try PhotoDownloadValidation.hasCompleteZIPTrailer(at: url))
        archive.removeLast()
        try archive.write(to: url)
        XCTAssertFalse(try PhotoDownloadValidation.hasCompleteZIPTrailer(at: url))
    }

    func testDownloadRequestAndOriginalFallbackFilename() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "unused"))
        let result = try await client.downloadPhotos(itemIDs: [1], kind: .compressedJPEG, space: .personal, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: result.temporaryURL.deletingLastPathComponent()) }
        XCTAssertEqual(result.filename, "fallback.heic")
        XCTAssertEqual(try Data(contentsOf: result.temporaryURL), Data("original".utf8))
    }

    func testIncomingDownloadIncludesEncodedSharingReference() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "unused"))
        let result = try await client.downloadIncomingPhotos(itemIDs: [2], kind: .compressedJPEG,
                                                             reference: "fixture-reference", progress: { _ in })
        defer { try? FileManager.default.removeItem(at: result.temporaryURL.deletingLastPathComponent()) }
        XCTAssertEqual(result.filename, "fallback.heic")
    }

    func testLiveOriginalAndExplicitDownloadBytesMatchWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SYNOLOGY_TEST"] == "1" else {
            throw XCTSkip("Live download verification is opt-in.")
        }
        let credentials = try CredentialStore.load()
        let client = try SynologyClient(credentials: credentials)
        try await client.login(credentials: credentials)
        let items = try await client.items(ids: [284351], space: .personal)
        let item = try XCTUnwrap(items.first)
        let resource = try XCTUnwrap(item.fullImageResource(in: .space(.personal)))
        let original = try await client.fullImage(resource, etag: nil, lastModified: nil)
        let originalData = try XCTUnwrap(original.data)
        let download = try await client.downloadPhotos(itemIDs: [item.id], kind: .original, space: .personal, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: download.temporaryURL.deletingLastPathComponent()) }
        let downloadData = try Data(contentsOf: download.temporaryURL)
        XCTAssertEqual(SHA256.hash(data: originalData), SHA256.hash(data: downloadData))
        XCTAssertEqual(download.filename, item.filename)
    }

    func testLivePhotoDownloadComparisonWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SYNOLOGY_TEST"] == "1" else {
            throw XCTSkip("Live download verification is opt-in.")
        }
        let credentials = try CredentialStore.load()
        let client = try SynologyClient(credentials: credentials)
        try await client.login(credentials: credentials)
        let items = try await client.items(ids: [129468], space: .personal)
        let item = try XCTUnwrap(items.first)
        let resource = try XCTUnwrap(item.fullImageResource(in: .space(.personal)))
        let response = try await client.fullImage(resource, etag: nil, lastModified: nil)
        let original = try XCTUnwrap(response.data)
        let downloaded = try await client.downloadPhotos(itemIDs: [item.id], kind: .original, space: .personal, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: downloaded.temporaryURL.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: downloaded.temporaryURL)
        XCTAssertNotEqual(SHA256.hash(data: original), SHA256.hash(data: bytes))
        XCTAssertTrue(bytes.starts(with: [0x50, 0x4b]))
        XCTAssertEqual(downloaded.temporaryURL.pathExtension.lowercased(), "zip")
    }

    func testCapturedDownloadCasesAgainstCirrusWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SYNOLOGY_TEST"] == "1" else {
            throw XCTSkip("Live download verification is opt-in.")
        }
        let credentials = try CredentialStore.load()
        let client = try SynologyClient(credentials: credentials)
        try await client.login(credentials: credentials)
        for ids: [Int64] in [[284351], [284351, 284353]] {
            for kind: PhotoDownloadKind in [.original, .compressedJPEG] {
                let result = try await client.downloadPhotos(itemIDs: ids, kind: kind, space: .personal, progress: { _ in })
                defer { try? FileManager.default.removeItem(at: result.temporaryURL.deletingLastPathComponent()) }
                let attributes = try FileManager.default.attributesOfItem(atPath: result.temporaryURL.path)
                XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
                XCTAssertFalse(result.filename.isEmpty)
                if ids.count > 1 { XCTAssertEqual(result.temporaryURL.pathExtension.lowercased(), "zip") }
            }
        }
    }
}

private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
            data = bytes
        } else { data = Data() }
        let components = URLComponents(string: "https://example.test/?" + String(decoding: data, as: UTF8.self))
        let params = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let login = params["api"] == "SYNO.API.Auth"
        if !login {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(params["api"], "SYNO.Foto.Download")
            if params["item_id"] == "[2]" {
                XCTAssertEqual(params["passphrase"], "\"fixture-reference\"")
            } else {
                XCTAssertEqual(params["item_id"], "[1]")
                XCTAssertNil(params["passphrase"])
            }
            XCTAssertEqual(params["download_type"], "\"optimized_jpeg\"")
        }
        let headers = login ? ["Content-Type": "application/json"] : ["Content-Type": "application/force-download", "Content-Disposition": "attachment; filename=\"fallback.heic\""]
        let body = login ? Data("{\"success\":true,\"data\":{\"sid\":\"test\"}}".utf8) : Data("original".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
