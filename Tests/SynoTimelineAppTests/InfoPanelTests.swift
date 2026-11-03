import Foundation
import TimelineCore
import XCTest
import SynologyAPI
import PhotoCache
@testable import SynoTimelineApp

@MainActor
final class InfoPanelTests: XCTestCase {

    // MARK: - Formatting

    func testDayRangeFormatting() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(InfoPanelFormatting.dayRange(newest: "2026-07-08", oldest: "2026-07-08",
                                                    locale: locale), "Jul 8, 2026")
        XCTAssertEqual(InfoPanelFormatting.dayRange(newest: "2026-07-08", oldest: "2026-04-21",
                                                    locale: locale), "Apr 21 – Jul 8, 2026")
        XCTAssertEqual(InfoPanelFormatting.dayRange(newest: "2026-07-08", oldest: "2025-04-21",
                                                    locale: locale), "Apr 21, 2025 – Jul 8, 2026")
        XCTAssertNil(InfoPanelFormatting.dayRange(newest: nil, oldest: "2026-07-08", locale: locale))
        XCTAssertNil(InfoPanelFormatting.dayRange(newest: "2026-07-08", oldest: nil, locale: locale))
    }

    func testMegapixelTruncationAndBadgeMapping() {
        XCTAssertEqual(InfoPanelFormatting.megapixels(width: 5152, height: 7728), "39 MP")
        XCTAssertEqual(InfoPanelFormatting.megapixels(width: 4000, height: 3000), "12 MP")
        XCTAssertNil(InfoPanelFormatting.megapixels(width: 0, height: 100))
        XCTAssertEqual(InfoPanelFormatting.formatBadge(filename: "IMG_1.HEIC"), "HEIF")
        XCTAssertEqual(InfoPanelFormatting.formatBadge(filename: "a.hif"), "HEIF")
        XCTAssertEqual(InfoPanelFormatting.formatBadge(filename: "a.jpeg"), "JPEG")
        XCTAssertEqual(InfoPanelFormatting.formatBadge(filename: "a.PNG"), "PNG")
        XCTAssertEqual(InfoPanelFormatting.formatBadge(filename: "a.tiff"), "TIFF")
        XCTAssertEqual(InfoPanelFormatting.formatBadge(filename: "raw.dng"), "DNG")
        XCTAssertEqual(InfoPanelFormatting.formatBadge(filename: "clip.mov"), "MOV")
        XCTAssertEqual(InfoPanelFormatting.formatBadge(filename: "noext"), nil)
    }

    func testApertureDurationAndByteCountFormatting() {
        XCTAssertEqual(InfoPanelFormatting.apertureValue("F2.8"), "f/2.8")
        XCTAssertEqual(InfoPanelFormatting.apertureValue("f/2.8"), "f/2.8")
        XCTAssertEqual(InfoPanelFormatting.apertureValue("2.8"), "2.8")
        XCTAssertEqual(InfoPanelFormatting.duration(49), "0:49")
        XCTAssertEqual(InfoPanelFormatting.duration(65.4), "1:05")
        XCTAssertEqual(InfoPanelFormatting.duration(0), "0:00")
        let bytes = InfoPanelFormatting.byteCount(1_230_000_000)
        XCTAssertTrue(bytes.contains("GB"))
        XCTAssertTrue(InfoPanelFormatting.byteCount(2_000).contains("KB"))
    }

    func testPageCacheKeyDerivesFromSharedRequestFields() throws {
        XCTAssertTrue(PhotosRequestFields.pageAdditional.contains("exif"))
        XCTAssertTrue(PhotosRequestFields.pageAdditional.contains("gps"))
        XCTAssertTrue(PhotosRequestFields.pageAdditional.contains("folder"))
        XCTAssertEqual(PhotosRequestFields.locationScanAdditional, ["gps", "thumbnail"])
        let section = TimelineSection(offset: 0, limit: 1,
                                      list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 1)])
        let namespace = CacheKey.namespace(server: URL(string: "https://nas.invalid")!, account: "alice")
        let standard = try XCTUnwrap(CacheKey.page(scope: .space(.personal), namespace: namespace, section: section, collection: .library(.personal)))
        XCTAssertEqual(standard, CacheKey.page(scope: .space(.personal), namespace: namespace, section: section, collection: .library(.personal)))
        let growth = TimelineSection(offset: 0, limit: 2, list: [TimelineDay(year: 2024, month: 4, day: 3, itemCount: 2)])
        XCTAssertEqual(standard, CacheKey.page(scope: .space(.personal), namespace: namespace, section: growth, collection: .library(.personal)))

    }

    // MARK: - Model

    func testEmptySelectionShowsPlaceholder() async throws {
        let setup = try await makeContext()
        setup.model.updateBrowserContext(repository: setup.repo, snapshot: nil,
                                         collection: .library(.personal), selection: IndexSet())
        setup.model.setVisible(true)
        XCTAssertEqual(setup.model.content.kind, .empty)
    }

    func testSingleSelectionBuildsCameraMetricsAndExposure() async throws {
        let exif = """
        {"aperture":"F2.8","camera":"iPhone 13 Pro","exposure_time":"1/25 s","focal_length":"9.0 mm","iso":"1250","lens":"iPhone 13 Pro back triple camera 9mm f/2.8"}
        """
        let item = makeItem(id: 5, filename: "IMG_3905.HEIC", filesize: 1_768_222,
                            exif: exif, width: 4032, height: 3024,
                            folderPath: "/MobileBackup/iPhone/2024/11")
        let setup = try await makeContext(items: [item])
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integer: 0))
        model.setVisible(true)
        let resolved = await waitUntil { model.content.kind == .single && !model.content.isLoading }
        XCTAssertTrue(resolved)
        XCTAssertEqual(model.content.filename, "IMG_3905.HEIC")
        XCTAssertEqual(model.content.mediaKind, .photo)
        XCTAssertEqual(model.content.itemIDText, "5")
        XCTAssertEqual(model.content.folderPath, "/MobileBackup/iPhone/2024/11")
        XCTAssertEqual(model.content.camera, "iPhone 13 Pro")
        XCTAssertEqual(model.content.lens, "iPhone 13 Pro back triple camera 9mm f/2.8")
        XCTAssertEqual(model.content.exposure, ["ISO 1250", "9.0 mm", "f/2.8", "1/25 s"])
        XCTAssertEqual(model.content.formatBadge, "HEIF")
        XCTAssertTrue(model.content.metrics.contains("12 MP"))
        XCTAssertTrue(model.content.metrics.contains("4032 × 3024"))
        XCTAssertTrue(model.content.metrics.contains(InfoPanelFormatting.byteCount(1_768_222)))
        XCTAssertNotNil(model.content.dateTimeText)
    }

    func testEmptyExifHidesCameraBlock() async throws {
        let exif = """
        {"aperture":"","camera":"","exposure_time":"","focal_length":"","iso":"","lens":""}
        """
        let item = makeItem(id: 6, filename: "IMG_3987.PNG", filesize: 512_000, exif: exif)
        let setup = try await makeContext(items: [item])
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integer: 0))
        model.setVisible(true)
        _ = await waitUntil { model.content.kind == .single && !model.content.isLoading }
        XCTAssertNil(model.content.camera)
        XCTAssertNil(model.content.lens)
        XCTAssertTrue(model.content.exposure.isEmpty)
        XCTAssertEqual(model.content.formatBadge, "PNG")
    }

    func testVideoShowsDurationInsteadOfCameraFields() async throws {
        let item = makeItem(id: 7, type: "video", filename: "clip.mov", filesize: 2_000_000,
                            durationMilliseconds: 49_000)
        let setup = try await makeContext(items: [item])
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integer: 0))
        model.setVisible(true)
        _ = await waitUntil { model.content.kind == .single && !model.content.isLoading }
        XCTAssertEqual(model.content.durationText, "0:49")
        XCTAssertNil(model.content.camera)
        XCTAssertTrue(model.content.exposure.isEmpty)
        XCTAssertTrue(model.content.metrics.contains(InfoPanelFormatting.byteCount(2_000_000)))
    }

    func testMultipleSelectionResolvesCountDateAndSize() async throws {
        let items = [makeItem(id: 1, filesize: 1000), makeItem(id: 2, filesize: 1000)]
        let setup = try await makeContext(items: items)
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integersIn: 0...1))
        model.setVisible(true)
        let resolved = await waitUntil {
            model.content.kind == .multiple && model.content.countText == "2 Photos" &&
                !model.content.isResolvingSize
        }
        XCTAssertTrue(resolved)
        XCTAssertEqual(model.content.sizeText, InfoPanelFormatting.byteCount(2000))
        XCTAssertEqual(model.content.dateRangeText,
                       InfoPanelFormatting.dayRange(newest: "2024-04-03", oldest: "2024-04-03"))
        XCTAssertNil(model.content.itemIDText)
        XCTAssertNil(model.content.folderPath)
    }

    func testMixedSelectionUsesItemsNoun() async throws {
        let items = [makeItem(id: 1, filesize: 1000),
                     makeItem(id: 2, type: "video", filesize: 2000)]
        let setup = try await makeContext(items: items)
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integersIn: 0...1))
        model.setVisible(true)
        let resolved = await waitUntil {
            model.content.kind == .multiple && model.content.countText == "2 Items" &&
                !model.content.isResolvingSize
        }
        XCTAssertTrue(resolved)
    }

    func testSingleSelectionWithGPSBuildsOnePin() async throws {
        let item = makeItem(id: 5, latitude: 35.5, longitude: 139.25)
        let setup = try await makeContext(items: [item])
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integer: 0))
        model.setVisible(true)
        let resolved = await waitUntil { model.content.kind == .single && !model.content.isLoading }
        XCTAssertTrue(resolved)
        XCTAssertEqual(model.content.pins,
                       [InfoPanelPin(id: 5, coordinate: PhotoCoordinate(latitude: 35.5,
                                                                        longitude: 139.25))])
    }

    func testSingleSelectionWithoutGPSHasNoPins() async throws {
        let item = makeItem(id: 6, filename: "IMG_0006.PNG")
        let setup = try await makeContext(items: [item])
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integer: 0))
        model.setVisible(true)
        _ = await waitUntil { model.content.kind == .single && !model.content.isLoading }
        XCTAssertTrue(model.content.pins.isEmpty)
    }

    func testMultipleSelectionCoordinatesBecomePins() async throws {
        let items = [makeItem(id: 1, filesize: 1000, latitude: 10, longitude: 11),
                     makeItem(id: 2, filesize: 1000, latitude: 20, longitude: 21)]
        let setup = try await makeContext(items: items)
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integersIn: 0...1))
        model.setVisible(true)
        let resolved = await waitUntil {
            model.content.kind == .multiple && !model.content.isResolvingSize
        }
        XCTAssertTrue(resolved)
        XCTAssertEqual(model.content.pins, [
            InfoPanelPin(id: 0, coordinate: PhotoCoordinate(latitude: 10, longitude: 11)),
            InfoPanelPin(id: 1, coordinate: PhotoCoordinate(latitude: 20, longitude: 21)),
        ])
    }

    func testMultipleSelectionIncludesEveryLocatedItem() async throws {
        let items = (0..<501).map { index in
            makeItem(id: Int64(index + 1), filesize: 1000,
                     latitude: 10 + Double(index) * 0.001, longitude: 20)
        }
        let setup = try await makeContext(items: items)
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integersIn: 0...500))
        model.setVisible(true)
        let resolved = await waitUntil {
            model.content.kind == .multiple && !model.content.isResolvingSize
        }
        XCTAssertTrue(resolved)
        XCTAssertEqual(model.content.countText, "501 Photos")
        XCTAssertEqual(model.content.pins.count, 501)
        XCTAssertEqual(model.content.pins.last?.id, 500)
    }

    func testMultipleSelectionWithoutCoordinatesHasNoPins() async throws {
        let items = [makeItem(id: 1, filesize: 1000), makeItem(id: 2, filesize: 1000)]
        let setup = try await makeContext(items: items)
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integersIn: 0...1))
        model.setVisible(true)
        let resolved = await waitUntil {
            model.content.kind == .multiple && !model.content.isResolvingSize
        }
        XCTAssertTrue(resolved)
        XCTAssertTrue(model.content.pins.isEmpty)
    }

    func testViewerItemOverridesBrowserSelectionAndRevertsOnClose() async throws {
        let items = [makeItem(id: 1, filesize: 1000), makeItem(id: 2, filesize: 1000)]
        let setup = try await makeContext(items: items)
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integersIn: 0...1))
        model.setVisible(true)
        _ = await waitUntil { model.content.kind == .multiple }

        model.updateViewer(active: true, item: makeItem(id: 9, filename: "IMG_0009.HEIC"))
        XCTAssertEqual(model.content.kind, .single)
        XCTAssertEqual(model.content.filename, "IMG_0009.HEIC")

        model.updateViewer(active: true, item: nil)
        XCTAssertEqual(model.content.kind, .single)
        XCTAssertTrue(model.content.isLoading)

        model.updateViewer(active: false, item: nil)
        let reverted = await waitUntil { model.content.kind == .multiple }
        XCTAssertTrue(reverted)
    }

    func testViewerActiveWithNilItemNeverShowsBrowserSummary() async throws {
        let items = [makeItem(id: 1, filesize: 1000), makeItem(id: 2, filesize: 1000)]
        let setup = try await makeContext(items: items)
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integersIn: 0...1))
        model.setVisible(true)
        model.updateViewer(active: true, item: nil)
        XCTAssertEqual(model.content.kind, .single)
        XCTAssertTrue(model.content.isLoading)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.content.kind, .single)
        XCTAssertTrue(model.content.isLoading)
    }

    func testViewerRefreshesMetadataForSameItemIdentity() async throws {
        let model = InfoPanelModel()
        model.updateViewer(active: true, item: makeItem(id: 9, filename: "IMG_0009.HEIC"))
        XCTAssertNil(model.content.camera)

        model.updateViewer(
            active: true,
            item: makeItem(id: 9, filename: "IMG_0009.HEIC", filesize: 1_000,
                           exif: "{\"camera\":\"Verified Camera\"}"))

        XCTAssertEqual(model.content.camera, "Verified Camera")
        XCTAssertTrue(model.content.metrics.contains(InfoPanelFormatting.byteCount(1_000)))
    }

    func testHiddenModelPerformsNoPageReads() async throws {
        let setup = try await makeContext(items: [makeItem(id: 1, filesize: 1000)])
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integer: 0))
        try? await Task.sleep(for: .milliseconds(250))
        let calls = await setup.transport.recordedItemCalls()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.content.kind, .empty)
    }

    func testReopeningPanelRestartsCanceledResolutionForSameSelection() async throws {
        let setup = try await makeContext(items: [makeItem(id: 1, filesize: 1000)])
        await setup.transport.setBlocked(true)
        let model = setup.model
        model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                   collection: .library(.personal), selection: IndexSet(integer: 0))
        model.setVisible(true)
        let initiallyStarted = await waitUntil { await setup.transport.recordedItemCalls() == 1 }
        XCTAssertTrue(initiallyStarted)

        model.setVisible(false)
        let canceled = await waitUntil { await setup.transport.recordedCancellations() == 1 }
        XCTAssertTrue(canceled)
        model.setVisible(true)
        let restarted = await waitUntil { await setup.transport.recordedItemCalls() == 2 }
        XCTAssertTrue(restarted)

        await setup.transport.setBlocked(false)
        let resolved = await waitUntil {
            model.content.kind == .single && !model.content.isLoading
        }
        XCTAssertTrue(resolved)
    }

    func testRapidSelectionUpdatesResolveOnlyOnce() async throws {
        let items = [makeItem(id: 1, filename: "IMG_0001.HEIC", filesize: 1000),
                     makeItem(id: 2, filename: "IMG_0002.HEIC", filesize: 1000)]
        let setup = try await makeContext(items: items)
        let model = setup.model
        model.setVisible(true)
        for selection in [IndexSet(integer: 0), IndexSet(integer: 1), IndexSet(integer: 0)] {
            model.updateBrowserContext(repository: setup.repo, snapshot: setup.snapshot,
                                       collection: .library(.personal), selection: selection)
            try? await Task.sleep(for: .milliseconds(20))
        }
        let resolved = await waitUntil { model.content.kind == .single && !model.content.isLoading }
        XCTAssertTrue(resolved)
        XCTAssertEqual(model.content.filename, "IMG_0001.HEIC")
        try? await Task.sleep(for: .milliseconds(200))
        let calls = await setup.transport.recordedItemCalls()
        XCTAssertEqual(calls, 1)
    }

    func testUnavailableLibraryShowsFailureForNonEmptySelection() async throws {
        let model = InfoPanelModel()
        model.updateBrowserContext(repository: nil, snapshot: nil, collection: .library(.personal),
                                   selection: IndexSet(integer: 0))
        model.setVisible(true)
        guard case .failure = model.content.kind else {
            return XCTFail("Expected failure content")
        }
    }

    // MARK: - Support

    private struct Context {
        let model: InfoPanelModel
        let repo: CachedPhotosRepository
        let transport: InfoPanelMockTransport
        let snapshot: TimelineSnapshot
    }

    private func makeContext(items: [PhotoItem] = []) async throws -> Context {
        let root = temporaryTestRoot("InfoPanel")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let transport = InfoPanelMockTransport()
        let section = TimelineSection(offset: 0, limit: max(1, items.count),
                                      list: [TimelineDay(year: 2024, month: 4, day: 3,
                                                         itemCount: max(1, items.count))])
        if !items.isEmpty {
            await transport.setPage(items, start: section.dateBounds!.start)
        }
        let credentials = SynologyCredentials(username: "alice", password: "pw", otpSecret: "unused")
        let repo = try CachedPhotosRepository(credentials: credentials, budget: 100_000_000,
                                              cacheRoot: root, transport: transport)
        return Context(model: InfoPanelModel(), repo: repo, transport: transport,
                       snapshot: try CollectionDayPager.snapshot(catalog: fixtureDayCatalog(TimelineSnapshot(sections: [section]), initial: false)))
    }

    private func makeItem(id: Int64, time: Int64 = 1712102400, type: String = "photo",
                          filename: String? = nil, filesize: Int64? = nil,
                          exif: String? = nil, width: Int = 1000, height: Int = 1000,
                          durationMilliseconds: Int? = nil,
                          latitude: Double? = nil, longitude: Double? = nil,
                          folderPath: String? = nil) -> PhotoItem {
        var fields = ["\"id\":\(id)", "\"time\":\(time)", "\"type\":\"\(type)\""]
        if let filename { fields.append("\"filename\":\"\(filename)\"") }
        if let filesize { fields.append("\"filesize\":\(filesize)") }
        var additional = ["\"resolution\":{\"width\":\(width),\"height\":\(height)}"]
        if let exif { additional.append("\"exif\":\(exif)") }
        if let durationMilliseconds { additional.append("\"video_meta\":{\"duration\":\(durationMilliseconds)}") }
        if let latitude, let longitude {
            additional.append("\"gps\":{\"latitude\":\(latitude),\"longitude\":\(longitude)}")
        }
        if let folderPath {
            let encoded = try! JSONEncoder().encode(folderPath)
            additional.append("\"folder\":\(String(decoding: encoded, as: UTF8.self))")
        }
        fields.append("\"additional\":{\(additional.joined(separator: ","))}")
        let json = "{" + fields.joined(separator: ",") + "}"
        return try! JSONDecoder().decode(PhotoItem.self, from: Data(json.utf8))
    }
}

actor InfoPanelMockTransport: TestPhotosTransport {
    private var pages: [Int64: [PhotoItem]] = [:]
    private var itemCalls = 0
    private var cancellations = 0
    private var blocked = false

    func setPage(_ items: [PhotoItem], start: Int64) { pages[start] = items }
    func recordedItemCalls() -> Int { itemCalls }
    func recordedCancellations() -> Int { cancellations }
    func setBlocked(_ value: Bool) { blocked = value }

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        try CollectionDayCatalog(days: pages.map { try CollectionDayCount(day: CaptureDay(time: $0.key), count: $0.value.count) }, completeness: initial ? .partial : .complete)
    }
    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        itemCalls += 1
        do {
            while blocked { try await Task.sleep(for: .milliseconds(10)) }
        } catch is CancellationError {
            cancellations += 1
            throw CancellationError()
        }
        return try fixtureBatch(Array((pages[request.newestDay.startTime] ?? []).dropFirst(request.offset).prefix(request.limit)), request: request, fields: fields)
    }
}
