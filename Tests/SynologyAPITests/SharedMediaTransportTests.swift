import Foundation
import XCTest
@testable import SynologyAPI

final class SharedMediaTransportTests: XCTestCase {
    func testSharedMediaAndWritesUseFotoTeamAndRetainItemVersusUnitIdentity() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedMediaProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        try await client.setFavorite(itemIDs: [5], favorite: true, space: .shared)
        try await client.setFavorite(itemIDs: [5], favorite: false, space: .shared)
        try await client.rotate(itemIDs: [5], direction: .counterClockwise, space: .shared)
        let still = try await client.fullImage(.init(scope: .space(.shared), unitID: 9, cacheKey: "revision"))
        XCTAssertNotNil(still.data)
        let download = try await client.downloadPhotos(itemIDs: [5], kind: .original, space: .shared, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: download.temporaryURL.deletingLastPathComponent()) }
        XCTAssertEqual(download.filename, "fixture.png")
        let original = VideoPlaybackResource(scope: .space(.shared), unitID: 9, cacheKey: "revision", filename: "fixture.mp4", variant: .original, itemID: 5)
        let bytes = try await client.videoRange(original, range: 0...3)
        XCTAssertEqual(bytes.data, Data([1, 2, 3, 4]))
        let motion = try await client.livePhotoMotion(itemID: 5, space: .shared)
        XCTAssertEqual(motion?.scope, .space(.shared))
        let converted = try XCTUnwrap(motion)
        _ = try await client.videoRange(converted, range: 0...3)
    }

    func testUnresolvedAlbumMediaFailsBeforeSendingSpaceRequests() async throws {
        let client = SynologyClient(baseURL: URL(string: "https://example.invalid")!)
        do {
            _ = try await client.fullImage(.init(scope: .incomingAlbum(ownerID: 1, albumID: 3), unitID: 9, cacheKey: "revision"))
            XCTFail("Unresolved album media must retain its contextual authority")
        } catch SynologyAPIError.unsupported {} catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await client.videoRange(.init(scope: .album(3), unitID: 9, cacheKey: "revision", filename: nil, variant: .original), range: 0...3)
            XCTFail("Unresolved album media must retain its contextual authority")
        } catch SynologyAPIError.unsupported {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class SharedMediaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n))
            }
        }
        let components = request.httpMethod == "GET" ? URLComponents(url: request.url!, resolvingAgainstBaseURL: false)! : URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!
        let values = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, b in b })
        let api = values["api"] ?? ""
        var payload = Data()
        var headers: [String: String] = [:]
        var status = 200
        if api == "SYNO.API.Auth" { payload = Data(#"{"success":true,"data":{"sid":"fixture"}}"#.utf8) }
        else {
            XCTAssertTrue(api.hasPrefix("SYNO.FotoTeam."))
            if api.hasSuffix("Browse.Item") {
                XCTAssertEqual(values["version"], "7")
                XCTAssertEqual(values["id"], "[5]")
                if values["method"] == "set_favorite" { XCTAssertTrue(["true", "false"].contains(values["favorite"] ?? "")) }
                else { XCTAssertEqual(values["rotate_action"], "counter_clockwise") }
                payload = Data(#"{"success":true,"data":{"error_list":[]}}"#.utf8)
            } else if api.hasSuffix("Browse.Unit") {
                XCTAssertEqual(values["id_item"], "[5]")
                payload = Data(#"{"success":true,"data":{"list":[{"id_item":5,"unit":[{"live_type":"video","filename":"motion.mp4","additional":{"thumbnail":{"unit_id":99,"cache_key":"motion"},"video_convert":[{"quality":"high","metadata":{}}]}}]}]}}"#.utf8)
            } else if request.value(forHTTPHeaderField: "Range") != nil {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-3")
                if api.hasSuffix("Streaming") { XCTAssertEqual(values["id"], "99"); XCTAssertEqual(values["quality"], "\"high\"") }
                else { XCTAssertEqual(values["item_id"], "[5]"); XCTAssertNil(values["unit_id"]) }
                status = 206; headers = ["Content-Type": "video/mp4", "Content-Range": "bytes 0-3/4"]
                payload = Data([1, 2, 3, 4])
            } else {
                XCTAssertEqual(api, "SYNO.FotoTeam.Download")
                XCTAssertEqual(values["version"], "2")
                if request.httpMethod == "POST" {
                    XCTAssertEqual(values["item_id"], "[5]")
                    XCTAssertEqual(values["download_type"], "\"source\"")
                    headers["Content-Disposition"] = "attachment; filename=\"fixture.png\""
                } else { XCTAssertEqual(values["unit_id"], "[9]"); XCTAssertNil(values["item_id"]) }
                headers["Content-Type"] = "image/png"
                payload = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aXcAAAAASUVORK5CYII=")!
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
    }
}
