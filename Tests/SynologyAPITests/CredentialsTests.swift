import XCTest
@testable import SynologyAPI

final class CredentialsTests: XCTestCase {
    func testDotEnvParsingHandlesQuotesAndExport() throws {
        let values = try CredentialStore.parseEnv(Data("# comment\nexport USER=alice\nPW='secret value'\nOTP=ABC234\n".utf8))
        XCTAssertEqual(values["USER"], "alice")
        XCTAssertEqual(values["PW"], "secret value")
        XCTAssertEqual(values["OTP"], "ABC234")
    }

    func testLivePersonalTimelineWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SYNOLOGY_TEST"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_SYNOLOGY_TEST=1 to test against Cirrus.")
        }
        let client = SynologyClient()
        try await client.login(credentials: CredentialStore.load())
        let initial = try await client.timeline(initial: true)
        let full = try await client.timeline(initial: false)
        XCTAssertFalse(initial.timeline.days.isEmpty)
        XCTAssertLessThanOrEqual(initial.timeline.days.reduce(0) { $0 + $1.count }, 500)
        XCTAssertGreaterThanOrEqual(full.timeline.days.count, initial.timeline.days.count)
        XCTAssertGreaterThanOrEqual(full.sectionCount, initial.sectionCount)
    }
}
