import XCTest
@testable import SynologyAPI

final class LogSafetyTests: XCTestCase {
    func testURLErrorSummaryOmitsFailingURLAndSessionSecrets() {
        let url = URL(string: "https://nas.example.com:5001/webapi/entry.cgi?api=SYNO.Foto&_sid=SID123&SynoToken=TOK456")!
        let error = URLError(.timedOut, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSURLErrorFailingURLStringErrorKey: url.absoluteString,
            NSLocalizedDescriptionKey: "Request to \(url.absoluteString) failed",
        ])
        let summary = error.logSummary
        for secret in ["SID123", "TOK456", "nas.example.com", "_sid=SID123"] {
            XCTAssertFalse(summary.contains(secret), summary)
        }
        XCTAssertTrue(summary.contains("NSURLErrorDomain(\(URLError.Code.timedOut.rawValue))"), summary)
    }

    func testAPIErrorSummaryKeepsCodeButNotServerText() {
        XCTAssertEqual(SynologyAPIError.api(119).logSummary, "SynologyAPIError.api(119)")
        XCTAssertFalse(SynologyAPIError.transport("failed _sid=SID123").logSummary.contains("SID123"))
    }

    func testScrubRemovesDeviceTokensAndURLs() {
        let text = LogRedaction.scrub("did=DEVICE&device_id=DEV2 at http://nas.local/x?y=1 done")
        XCTAssertEqual(text, "did=<removed>&device_id=<removed> at <url> done")
    }

    func testCredentialDescriptionsOmitPasswordAndSecrets() {
        let credentials = SynologyCredentials(username: "alice-name", password: "hunter2-pass",
                                              secondFactor: .totpSecret("JBSWY3DPEHPK3PXP"),
                                              serverURL: URL(string: "https://nas.example.com"))
        let texts = [String(describing: credentials), String(reflecting: credentials), "\(credentials)",
                     String(describing: credentials.secondFactor), String(reflecting: credentials.secondFactor),
                     String(describing: SecondFactor.code("123456")), String(describing: SecondFactor.deviceToken("DEVTOKEN"))]
        for text in texts {
            for secret in ["hunter2-pass", "JBSWY3DPEHPK3PXP", "alice-name", "123456", "DEVTOKEN", "nas.example.com"] {
                XCTAssertFalse(text.contains(secret), text)
            }
        }
    }
}
