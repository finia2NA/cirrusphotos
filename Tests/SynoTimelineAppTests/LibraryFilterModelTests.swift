import XCTest
@testable import SynoTimelineApp
import PhotoCache
import SynologyAPI

@MainActor
final class LibraryFilterModelTests: XCTestCase {
    func testRangeValidationAcceptsDocumentedFormsAndRejectsInvalidBounds() {
        let model = LibraryFilterModel()
        model.apertureMin = "f/2.8"
        model.shutterMax = "1/250 s"
        XCTAssertTrue(model.canApply)
        model.isoMin = "800"
        model.isoMax = "400"
        XCTAssertFalse(model.canApply)
        model.isoMin = "nan"
        model.isoMax = ""
        XCTAssertFalse(model.canApply)
        model.isoMin = "100.5"
        XCTAssertFalse(model.canApply)
    }

    func testDraftActiveCriterionCountUsesFacetsRatherThanValues() {
        let model = LibraryFilterModel()
        model.draft.mediaKinds = [.photo, .video]
        model.draft.extensions = ["HIF", "HEIC"]
        XCTAssertEqual(model.draft.activeCriterionCount, 2)
    }

    func testLoadingSectionWithoutMatchesDoesNotRepublishFilteredCollection() async throws {
        let root = temporaryTestRoot("LibraryFilterNoMatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let sections = [
            TimelineSection(offset: 0, limit: 1,
                list: [TimelineDay(year: 2024, month: 4, day: 20, itemCount: 1)]),
            TimelineSection(offset: 0, limit: 1,
                list: [TimelineDay(year: 2024, month: 4, day: 19, itemCount: 1)]),
        ]
        let video = try filterItem(id: 1, filename: "clip.MOV", type: "video", time: 1_713_571_200)
        let photo = try filterItem(id: 2, filename: "photo.JPG", type: "photo", time: 1_713_484_800)
        let transport = FilterModelTransport(
            snapshot: TimelineSnapshot(sections: sections), pages: [0: [video], 1: [photo]], delay: .milliseconds(100)
        )
        let repository = try CachedPhotosRepository(
            credentials: .init(username: "filter-model", password: "unused", otpSecret: "unused"),
            baseURL: URL(string: "https://filter-model.example.invalid")!, cacheRoot: root,
            transport: transport
        )
        let library = LibraryModel(repository: repository)
        await library.load()

        let filter = LibraryFilterModel()
        filter.configure(library: library)
        for await _ in await repository.page(sections[0]) {}
        let ingested = await waitUntil { filter.progress.verified == 1 }
        XCTAssertTrue(ingested)
        filter.draft.mediaKinds = [.video]
        filter.apply()
        let applied = await waitUntil { filter.activeCollection != nil }
        XCTAssertTrue(applied)
        let collection = try XCTUnwrap(filter.activeCollection)
        let revision = library.snapshotRevision(for: collection)
        filter.edgeDemand(syntheticSectionIndices: [0], direction: .older,
                          userScrollGeneration: 1)

        let loaded = await waitUntil { filter.progress.verified == 2 }
        XCTAssertTrue(loaded)
        XCTAssertEqual(library.snapshotRevision(for: collection), revision)
    }

    private func filterItem(id: Int64, filename: String, type: String, time: Int64) throws -> PhotoItem {
        try JSONDecoder().decode(PhotoItem.self, from: Data("""
        {"id":\(id),"filename":"\(filename)","time":\(time),"type":"\(type)",
         "additional":{"resolution":{"width":1920,"height":1080}}}
        """.utf8))
    }

    func testSameTimelineAfterMetadataResetCreatesNewFilterObserver() async throws {
        let root = temporaryTestRoot("LibraryFilterReset")
        defer { try? FileManager.default.removeItem(at: root) }
        let section = TimelineSection(offset: 0, limit: 1,
            list: [TimelineDay(year: 2024, month: 4, day: 20, itemCount: 1)])
        let video = try filterItem(id: 1, filename: "clip.MOV", type: "video", time: 1_713_571_200)
        let transport = FilterModelTransport(snapshot: .init(sections: [section]),
                                             pages: [0: [video]], delay: .zero)
        let repository = try CachedPhotosRepository(
            credentials: .init(username: "filter-reset", password: "unused", otpSecret: "unused"),
            cacheRoot: root, transport: transport)
        let library = LibraryModel(repository: repository)
        await library.load()
        let filter = LibraryFilterModel()
        filter.configure(library: library)
        for await _ in await repository.page(section) {}
        let first = await waitUntil { filter.progress.verified == 1 }
        XCTAssertTrue(first)

        await library.clearMetadataCache()
        let reset = await waitUntil { library.metadataInvalidationRevision > 0 && library.timelineVerified }
        XCTAssertTrue(reset)
        filter.configure(library: library)
        let empty = await waitUntil { filter.progress.indexed == 0 }
        XCTAssertTrue(empty)
        for await _ in await repository.page(section) {}
        let refreshed = await waitUntil { filter.progress.verified == 1 }
        XCTAssertTrue(refreshed)
    }
}

private actor FilterModelTransport: PhotosTransport {
    let snapshot: TimelineSnapshot
    let pages: [Int: [PhotoItem]]
    let delay: Duration

    init(snapshot: TimelineSnapshot, pages: [Int: [PhotoItem]], delay: Duration) {
        self.snapshot = snapshot
        self.pages = pages
        self.delay = delay
    }

    func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        return try fixtureDayCatalog(collection == .personalLibrary ? snapshot : TimelineSnapshot(sections: []), initial: initial)
    }

    func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        let section = fixtureSection(request)
        let collection = request.collection

        try await Task.sleep(for: delay)
        var rows: [PhotoItem] = []
        for (index, descriptor) in snapshot.sections.enumerated() {
            let raw = descriptor.list[0]
            let day = try CaptureDay(year: raw.year, month: raw.month, day: raw.day)
            if day <= request.newestDay && day >= request.oldestDay {
                rows += try (pages[index] ?? []).map { try fixtureItem($0, on: day) }
            }
        }
        return CollectionBatchResult(items: rows, profile: fields)
    }
}
