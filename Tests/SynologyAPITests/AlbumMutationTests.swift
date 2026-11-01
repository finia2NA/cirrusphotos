import Foundation
import XCTest
@testable import SynologyAPI

final class AlbumMutationTests: XCTestCase {
    func testCapturedRequestsAndDataLessDelete() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlbumMutationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let created = try await client.createAlbum(name: "A \"trip\"", itemIDs: [11, 12])
        XCTAssertEqual(created.id, 69)
        try await client.addItems([13, 14], toAlbum: 69)
        try await client.removeItems([11], fromAlbum: 69)
        try await client.deleteAlbum(id: 69)
        let album = try await client.album(id: 69)
        XCTAssertEqual(album.itemCount, 2)
        XCTAssertEqual(album.type, "normal")
        XCTAssertEqual(album.ownerUserID, 1)
        let addable = try await client.addableAlbums()
        XCTAssertEqual(addable.map(\.id), [69])
    }

    func testNonemptyErrorListDoesNotClaimSuccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlbumMutationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        do {
            try await client.addItems([99], toAlbum: 69)
            XCTFail("Expected partial failure")
        } catch { }
    }

    func testEmptyAlbumCreateEncodesEmptyItemList() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlbumMutationProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SynologyClient(baseURL: URL(string: "https://example.test")!, session: session)
        try await client.login(credentials: .init(username: "test", password: "test"))
        let album = try await client.createAlbum(name: "Empty", itemIDs: [])
        XCTAssertEqual(album.itemCount, 0)
    }

    func testEmptyThumbnailObjectIsAbsentButMalformedThumbnailFails() throws {
        let empty = Data(#"{"id":70,"name":"Empty","item_count":0,"additional":{"thumbnail":{}}}"#.utf8)
        let album = try JSONDecoder().decode(AlbumSummary.self, from: empty)
        XCTAssertNil(album.thumbnail)
        let malformed = Data(#"{"id":70,"name":"Empty","item_count":0,"additional":{"thumbnail":{"unit_id":70}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AlbumSummary.self, from: malformed))
    }
}

private final class AlbumMutationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
        }
        let components = URLComponents(string: "https://example.test/?" + String(decoding: body, as: UTF8.self))!
        let values = Dictionary(components.queryItems!.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        let method = values["method"] ?? ""
        let json: String
        switch method {
        case "login": json = #"{"success":true,"data":{"sid":"fixture"}}"#
        case "create":
            XCTAssertEqual(values["api"], "SYNO.Foto.Browse.NormalAlbum")
            XCTAssertEqual(values["version"], "1")
            if values["name"] == #""Empty""# {
                XCTAssertEqual(values["item"], "[]")
                json = #"{"success":true,"data":{"album":{"id":70,"name":"Empty","item_count":0},"error_list":[]}}"#
            } else {
                XCTAssertEqual(values["name"], #""A \"trip\"""#)
                XCTAssertEqual(values["item"], "[11,12]")
                json = #"{"success":true,"data":{"album":{"id":69,"name":"Trip","item_count":2},"error_list":[]}}"#
            }
        case "add_item":
            XCTAssertEqual(values["id"], "69")
            json = values["item"] == "[99]" ? #"{"success":true,"data":{"error_list":[{"anything":[1]}]}}"# : #"{"success":true,"data":{"error_list":[]}}"#
        case "delete_item":
            XCTAssertEqual(values["item"], "[11]")
            json = #"{"success":true}"#
        case "delete":
            XCTAssertEqual(values["api"], "SYNO.Foto.Browse.Album")
            XCTAssertEqual(values["version"], "1")
            XCTAssertEqual(values["id"], "[69]")
            json = #"{"success":true}"#
        case "get":
            XCTAssertEqual(values["id"], "[69]")
            XCTAssertEqual(values["version"], "4")
            json = #"{"success":true,"data":{"list":[{"id":69,"name":"Trip","item_count":2,"type":"normal","owner_user_id":1}]}}"#
        case "list":
            XCTAssertEqual(values["api"], "SYNO.Foto.Browse.NormalAlbum")
            XCTAssertEqual(values["version"], "2")
            XCTAssertEqual(values["category"], "\"addable\"")
            XCTAssertEqual(values["offset"], "0")
            XCTAssertEqual(values["limit"], "100")
            XCTAssertEqual(values["sort_by"], "\"album_name\"")
            XCTAssertEqual(values["sort_direction"], "\"asc\"")
            XCTAssertEqual(values["additional"], "[\"sharing_info\",\"thumbnail\"]")
            json = #"{"success":true,"data":{"list":[{"id":69,"name":"Trip","item_count":2}]}}"#
        default: XCTFail("Unexpected method \(method)"); json = #"{"success":false}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
