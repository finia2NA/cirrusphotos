import SynologyAPI
import XCTest
@testable import PhotoCache

final class RepositoryErrorTests: XCTestCase {
    func testNormalizationKeepsTypedCasesAndWrapsServerErrors() {
        XCTAssertEqual(RepositoryError(RepositoryError.busy("Busy")), .busy("Busy"))
        XCTAssertEqual(RepositoryError(SynologyAPIError.api(119)), .server(.api(119)))
        XCTAssertEqual(RepositoryError(MetadataAdmissionError.superseded), .stale(MetadataAdmissionError.superseded.localizedDescription))
        if case .unexpected = RepositoryError(TestFailure("Broken")) {} else { XCTFail("Unknown errors are unexpected") }
    }

    func testOnlyMalformedResponsesUnconfirmedWritesAndInvariantsAreUnexpected() {
        XCTAssertFalse(RepositoryError.server(.transport("offline")).isUnexpected)
        XCTAssertFalse(RepositoryError.server(.api(119)).isUnexpected)
        XCTAssertFalse(RepositoryError.busy("Busy").isUnexpected)
        XCTAssertFalse(RepositoryError.stale("Changed").isUnexpected)
        XCTAssertTrue(RepositoryError.server(.invalidResponse).isUnexpected)
        XCTAssertTrue(RepositoryError.server(.api(9999)).isUnexpected)
        XCTAssertTrue(RepositoryError.unconfirmed("Maybe").isUnexpected)
        XCTAssertTrue(RepositoryError.unexpected("Bug").isUnexpected)
    }
}
