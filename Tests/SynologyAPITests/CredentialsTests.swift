import XCTest
@testable import SynologyAPI

final class CredentialsTests: XCTestCase {
    func testDotEnvParsingHandlesQuotesAndExport() throws {
        let values = try CredentialStore.parseEnv(Data("# comment\nexport USER=alice\nPW='secret value'\nOTP=ABC234\n".utf8))
        XCTAssertEqual(values["USER"], "alice")
        XCTAssertEqual(values["PW"], "secret value")
        XCTAssertEqual(values["OTP"], "ABC234")
    }

    func testStandardTOTPVector() throws {
        XCTAssertEqual(try TOTP.generate(secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", date: Date(timeIntervalSince1970: 59)), "287082")
    }

    func testLiveTOTPMatchesPythonProbeWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SYNOLOGY_TEST"] == "1" else {
            throw XCTSkip("Live credential comparison is opt-in.")
        }
        guard case .totpSecret(let secret) = try CredentialStore.load().secondFactor else {
            throw XCTSkip("The configured account does not use OTP.")
        }
        let script = "import importlib.util,pathlib; s=importlib.util.spec_from_file_location('probe','scripts/test_synology_login.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.generate_totp(m.load_env(pathlib.Path('.env'))['OTP']))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let reference = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let swift = try TOTP.generate(secret: secret)
        XCTAssertTrue(swift == reference, "Swift and Python TOTP calculations differ.")
    }

    func testLivePersonalTimelineWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_SYNOLOGY_TEST"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_SYNOLOGY_TEST=1 to test against Cirrus.")
        }
        let credentials = try CredentialStore.load()
        let client = try SynologyClient(credentials: credentials)
        try await client.login(credentials: credentials)
        let initial = try await client.collectionDayCatalog(collection: .library(.personal), initial: true)
        let full = try await client.collectionDayCatalog(collection: .library(.personal), initial: false)
        XCTAssertFalse(initial.days.isEmpty)
        XCTAssertEqual(initial.completeness, .partial)
        XCTAssertGreaterThanOrEqual(full.days.count, initial.days.count)
        XCTAssertEqual(full.completeness, .complete)
    }
}
