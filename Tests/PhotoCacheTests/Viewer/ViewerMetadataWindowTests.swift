import XCTest
import SynologyAPI
@testable import PhotoCache

final class ViewerMetadataWindowTests: XCTestCase {
    /// Twenty-four photos in twelve two-photo sections, so the filmstrip's ±10 items cross many sections.
    private func window() -> ViewerMetadataWindow {
        let sections = (1...12).map { day in
            TimelineSection(offset: (day - 1) * 2, limit: 2,
                            list: [TimelineDay(year: 2024, month: 4, day: day, itemCount: 2)])
        }
        return ViewerMetadataWindow(index: LibraryIndex(snapshot: TimelineSnapshot(sections: sections)), maximumPages: 3)
    }

    func testRetainsOnlyBoundedSectionsWithoutFilmstrip() throws {
        let window = window()
        let center = try XCTUnwrap(window.location(for: 12))
        XCTAssertEqual(window.retainedSections(around: center).count, 3)
    }

    func testFilmstripRetainsEverySectionWithinReach() throws {
        var window = window()
        window.retainsFilmstrip = true
        let center = try XCTUnwrap(window.location(for: 12))
        let retained = window.retainedSections(around: center)
        for offset in -10...10 {
            let location = try XCTUnwrap(window.location(for: 12 + offset))
            XCTAssertTrue(retained.contains(location.sectionIndex), "offset \(offset)")
        }
    }
}
