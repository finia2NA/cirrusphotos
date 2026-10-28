import Foundation
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
        let result = try await client.downloadPhotos(itemIDs: [1], kind: .compressedJPEG, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: result.temporaryURL.deletingLastPathComponent()) }
        XCTAssertEqual(result.filename, "fallback.heic")
        XCTAssertEqual(try Data(contentsOf: result.temporaryURL), Data("original".utf8))
    }

    func testCapturedDownloadCasesAgainstCirrusWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SYNOLOGY_TEST"] == "1" else {
            throw XCTSkip("Live download verification is opt-in.")
        }
        let client = SynologyClient()
        try await client.login(credentials: CredentialStore.load())
        for ids: [Int64] in [[284351], [284351, 284353]] {
            for kind: PhotoDownloadKind in [.original, .compressedJPEG] {
                let result = try await client.downloadPhotos(itemIDs: ids, kind: kind, progress: { _ in })
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
            XCTAssertEqual(params["item_id"], "[1]")
            XCTAssertEqual(params["download_type"], "\"optimized_jpeg\"")
        }
        let headers = login ? ["Content-Type": "application/json"] : ["Content-Type": "application/force-download", "Content-Disposition": "attachment; filename=\"fallback.heic\""]
        let body = login ? Data("{\"success\":true,\"data\":{\"sid\":\"test\"}}".utf8) : Data("original".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
