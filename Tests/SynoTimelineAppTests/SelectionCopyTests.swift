import AppKit
import SynologyAPI
import XCTest
@testable import SynoTimelineApp

final class SelectionCopyTests: XCTestCase {
    private func item(_ id: Int64, _ filename: String?) throws -> PhotoItem {
        let name = filename.map { "\"filename\":\(String(data: try! JSONEncoder().encode($0), encoding: .utf8)!)," } ?? ""
        return try JSONDecoder().decode(PhotoItem.self, from: Data("{\"id\":\(id),\(name)\"time\":1,\"type\":\"photo\"}".utf8))
    }

    func testCopyTextIsFilenameAndIDWithoutHeader() throws {
        let items = [try item(7, "IMG_0001.HEIC"), try item(9, "a,b.jpg"), try item(11, "say \"hi\".jpg"), try item(12, nil)]
        XCTAssertEqual(SelectionText.csv(for: items),
                       "IMG_0001.HEIC,7\n\"a,b.jpg\",9\n\"say \"\"hi\"\".jpg\",11\n,12")
    }

    @MainActor
    func testBrowserViewHandlesCopyOnlyWithASelection() {
        let view = FlippedDocumentView(frame: .zero)
        var copies = 0
        var hasSelection = false
        view.copyHandler = { copies += 1 }
        view.canCopyHandler = { hasSelection }
        let item = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        XCTAssertFalse(view.validateUserInterfaceItem(item))
        hasSelection = true
        XCTAssertTrue(view.validateUserInterfaceItem(item))
        view.copy(nil)
        XCTAssertEqual(copies, 1)
    }

    @MainActor
    func testDragProviderWritesTextBesideTheFilePromiseToAPasteboard() {
        let provider = LocalHandlePromiseProvider(fileType: "public.data", delegate: PhotoPromiseDelegateStub())
        let pasteboard = NSPasteboard(name: .init("test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertFalse(provider.writableTypes(for: pasteboard).contains(.string))
        provider.text = "a.jpg,1\nb.jpg,2"
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([provider]))
        XCTAssertEqual(pasteboard.string(forType: .string), "a.jpg,1\nb.jpg,2")
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("com.apple.pasteboard.NSFilePromiseID")) == true)

        let writer = LocalHandleWriter(type: SelectionDragRegistry.type, nonce: UUID(), text: "c.mov,3")
        XCTAssertEqual(writer.writableTypes(for: pasteboard), [SelectionDragRegistry.type, .string])
        XCTAssertEqual(writer.pasteboardPropertyList(forType: .string) as? String, "c.mov,3")
        XCTAssertEqual(LocalHandleWriter(type: SelectionDragRegistry.type, nonce: UUID()).writableTypes(for: pasteboard),
                       [SelectionDragRegistry.type])
    }
}

private final class PhotoPromiseDelegateStub: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "a" }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
}
