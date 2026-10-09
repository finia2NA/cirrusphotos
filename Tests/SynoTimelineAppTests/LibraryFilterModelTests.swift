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
            TimelineSection(offset: 1, limit: 1,
                list: [TimelineDay(year: 2024, month: 4, day: 19, itemCount: 1)]),
        ]
        let video = try filterItem(id: 1, filename: "clip.MOV", type: "video", time: 1_713_571_200)
        let photo = try filterItem(id: 2, filename: "photo.JPG", type: "photo", time: 1_713_484_800)
        let transport = FilterModelTransport(
            snapshot: TimelineSnapshot(sections: sections), pages: [1: [photo]], delay: .milliseconds(100)
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
        filter.ingest(sectionIndex: 0, items: [video], verified: true)
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

    func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        collection == .personalLibrary ? snapshot : TimelineSnapshot(sections: [])
    }

    func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        try await Task.sleep(for: delay)
        return pages[section.offset] ?? []
    }
}
