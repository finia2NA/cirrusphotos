import AppKit
import Foundation
import SynologyAPI
import XCTest
@testable import SynoTimelineApp

final class PhotoDownloadDestinationTests: XCTestCase {
    @MainActor
    func testContextMenuRoutesEachRequestedDownloadMode() {
        _ = NSApplication.shared
        var selected: [(PhotoDownloadKind, Bool)] = []
        let menu = photoDownloadMenu { selected.append(($0, $1)) }
        XCTAssertEqual(menu.items.map(\.title), ["Download", "Download to…", "Download Compressed JPEG", "Download Compressed JPEG to…"])
        for index in 0..<4 { menu.performActionForItem(at: index) }
        XCTAssertEqual(selected.map { $0.0 }, [.original, .original, .compressedJPEG, .compressedJPEG])
        XCTAssertEqual(selected.map { $0.1 }, [false, true, false, true])
    }

    @MainActor
    func testCloseGuardPreservesExistingWindowDelegate() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let original = OriginalCloseDelegate()
        window.delegate = original
        let view = DownloadCloseGuardView(frame: .zero)
        window.contentView?.addSubview(view)
        let delegate = window.delegate
        XCTAssertTrue(delegate is DownloadWindowDelegate)
        XCTAssertEqual(delegate?.windowShouldClose?(window), true)
        XCTAssertEqual(original.closeChecks, 1)
    }

    func testSavingPreservesExistingFilesAndCopiesCompleteBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: root.appendingPathComponent("download.zip"))
        let result = try PhotoDownloadManager.save(source, filename: "download.zip", directory: root)
        XCTAssertEqual(result.lastPathComponent, "download 1.zip")
        XCTAssertEqual(try Data(contentsOf: result), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("download.zip")), Data("old".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".syno-") })
    }
}

@MainActor
private final class OriginalCloseDelegate: NSObject, NSWindowDelegate {
    var closeChecks = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeChecks += 1; return true }
}
