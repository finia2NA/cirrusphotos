import Foundation
import XCTest
import SynologyAPI

/// Opt-in check that the NAS indexes an uploaded video. A runner passes `RUN_LIVE_VIDEO_UPLOAD=1`
/// and `LIVE_UPLOAD_VIDEO` (a local .mov or .mp4). Runs only on the disposable account and
/// deletes the uploaded item afterwards.
final class LiveVideoUploadTests: XCTestCase {
    func testVideoUploadIsIndexedWithThumbnails() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_LIVE_VIDEO_UPLOAD"] == "1", let path = environment["LIVE_UPLOAD_VIDEO"] else {
            throw XCTSkip("Set RUN_LIVE_VIDEO_UPLOAD=1 and LIVE_UPLOAD_VIDEO.")
        }
        let credentials = try CredentialStore.load()
        guard credentials.username.lowercased() == "phototest" else { throw XCTSkip("Runs only on the disposable account.") }
        let client = try SynologyClient(credentials: credentials)
        try await client.login(credentials: credentials)
        let result = try await client.uploadPhoto(at: URL(fileURLWithPath: path), destination: .timeline(.personal),
                                                  progress: { _ in })
        print("LIVE video upload: action=\(result.action) id=\(result.id)")
        var ready = false
        for delay in [5, 10, 20, 30, 60] {
            try await Task.sleep(for: .seconds(delay))
            guard let item = try await client.items(ids: [result.id], space: .personal).first else {
                print("LIVE video upload: item \(result.id) not listed yet"); continue
            }
            let thumbnail = item.additional?.thumbnail
            ready = thumbnail.map { thumbnail in ThumbnailSize.allCases.allSatisfy(thumbnail.isReady) } ?? false
            print("LIVE video upload: type=\(item.type) thumbnails ready=\(ready)")
            if ready { XCTAssertEqual(item.type.lowercased(), "video"); break }
        }
        if result.action == "new" { try await client.deleteItems([result.id], space: .personal) }
        XCTAssertTrue(ready, "the uploaded video's thumbnails did not become ready")
    }
}
