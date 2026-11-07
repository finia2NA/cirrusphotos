import Foundation
import XCTest
@testable import SynologyAPI

final class PhotoUploadTests: XCTestCase {
    func testCapturedTimelineAndAlbumUploads() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let shared = try await client.uploadPhoto(at: url, destination: .timeline(.shared), progress: { _ in })
        XCTAssertEqual(shared.action, "new")
        let album = try await client.uploadPhoto(at: url, destination: .album(77), progress: { _ in })
        XCTAssertEqual(album.action, "ignore")
        XCTAssertEqual(album.id, 11)
        XCTAssertEqual(album.unitID, 12)
        for space in [PhotoSpace.personal, .shared] {
            let folder = try await client.uploadPhoto(at: url, destination: .folder(1568, space: space), progress: { _ in })
            XCTAssertEqual(folder.id, 13)
        }
    }

    func testVideoUploadsAndOtherFilesAreRejected() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "fixture", password: "fixture"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent("IMG_0001.MOV")
        try Data([1, 2, 3, 4]).write(to: video)
        UploadFixtureProtocol.expectedContentType = "video/quicktime"
        defer { UploadFixtureProtocol.expectedContentType = nil }
        let uploaded = try await client.uploadPhoto(at: video, destination: .timeline(.shared), progress: { _ in })
        XCTAssertEqual(uploaded.id, 11)
        let text = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: text)
        do {
            _ = try await client.uploadPhoto(at: text, destination: .timeline(.personal), progress: { _ in })
            XCTFail("a text file must not upload")
        } catch SynologyAPIError.unsupported {}
    }
}

private final class UploadFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var expectedContentType: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let api = query.first(where: { $0.name == "api" })?.value
        let json: String
        if api == nil {
            json = #"{"success":true,"data":{"sid":"fixture"}}"#
        } else {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(query.first(where: { $0.name == "version" })?.value, "8")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("name=\"file\""))
            if let expected = Self.expectedContentType {
                XCTAssertTrue(text.contains("Content-Type: \(expected)\r\n"))
            }
            XCTAssertTrue(text.contains("name=\"duplicate\"\r\n\r\n\"ignore\""))
            if query.first(where: { $0.name == "method" })?.value == "upload_to_folder" {
                XCTAssertTrue(text.contains("name=\"method\"\r\n\r\nupload_to_folder"))
                XCTAssertTrue(text.contains("name=\"target_folder_id\"\r\n\r\n1568"))
                XCTAssertFalse(text.contains("name=\"folder\""))
                XCTAssertFalse(text.contains("name=\"uploadDestination\""))
                XCTAssertTrue(["SYNO.Foto.Upload.Item", "SYNO.FotoTeam.Upload.Item"].contains(api))
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"success":true,"data":{"action":"new","id":13,"unit_id":14}}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            XCTAssertTrue(text.contains("name=\"folder\"\r\n\r\n[\"PhotoLibrary\"]"))
            if api == "SYNO.FotoTeam.Upload.Item" {
                XCTAssertTrue(text.contains("name=\"uploadDestination\"\r\n\r\n\"timeline\""))
                json = #"{"success":true,"data":{"action":"new","id":11,"unit_id":12}}"#
            } else {
                XCTAssertEqual(api, "SYNO.Foto.Upload.Item")
                XCTAssertTrue(text.contains("name=\"album_id\"\r\n\r\n77"))
                XCTAssertFalse(text.contains("name=\"uploadDestination\""))
                json = #"{"success":true,"data":{"action":"ignore","id":11,"unit_id":12}}"#
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
