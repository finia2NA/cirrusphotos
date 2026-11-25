import Foundation
import SynologyAPI
import TransportTestSupport
import XCTest
@testable import PhotoCache

private actor SessionTransport: TestPhotosTransport {
    private(set) var logins = 0
    private(set) var logouts = 0
    private var handler: (@Sendable (SynologyAPIError) -> Void)?

    func login(credentials: SynologyCredentials) async throws { logins += 1 }
    func logout() async { logouts += 1 }
    func onSessionRenewalFailure(_ handler: @escaping @Sendable (SynologyAPIError) -> Void) async {
        self.handler = handler
    }
    func failRenewal(_ error: SynologyAPIError) { handler?(error) }

    private var reachabilityHandler: (@Sendable (Bool) -> Void)?
    func onReachabilityChange(_ handler: @escaping @Sendable (Bool) -> Void) async { reachabilityHandler = handler }
    func report(reachable: Bool) { reachabilityHandler?(reachable) }
}

final class RepositoryAccountTests: XCTestCase {
    private func repository(_ transport: SessionTransport, root: URL) throws -> CachedPhotosRepository {
        try CachedPhotosRepository(credentials: .init(username: "account", password: "pw"),
                                   baseURL: URL(string: "https://nas.example.test")!,
                                   cacheRoot: root, transport: transport)
    }

    func testRejectedRenewalRequiresSignInAndStopsRequests() async throws {
        let root = temporaryTestRoot("RepositoryAccount")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SessionTransport()
        let repository = try repository(transport, root: root)
        try await repository.connect()

        await transport.failRenewal(.secondFactorRequired)
        var statuses = await repository.authentication().makeAsyncIterator()
        var status = await statuses.next()
        if status == .signedIn { status = await statuses.next() }
        XCTAssertEqual(status, .needsSignIn(SynologyAPIError.secondFactorRequired.localizedDescription))
        do {
            try await repository.connect()
            XCTFail("A rejected sign-in must not be retried automatically")
        } catch {}
        let logins = await transport.logins
        XCTAssertEqual(logins, 1)
    }

    func testConnectionEpochRisesOnlyWhenTheNASAnswersAgainOrTheNetworkReturns() async throws {
        let root = temporaryTestRoot("RepositoryAccount")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SessionTransport()
        let repository = try repository(transport, root: root)
        try await repository.connect()
        var epochs = await repository.connectionRestorations().makeAsyncIterator()

        // Reachable while already reachable, and a network return while reachable, change nothing.
        await repository.reachabilityChanged(true)
        await repository.networkPathReturned()
        await repository.reachabilityChanged(false)
        await repository.reachabilityChanged(false)
        await repository.networkPathReturned()
        let afterNetwork = await epochs.next()
        XCTAssertEqual(afterNetwork, 1)
        await repository.reachabilityChanged(true)
        await repository.reachabilityChanged(true)
        let afterAnswer = await epochs.next()
        XCTAssertEqual(afterAnswer, 2)

        // The transport's report reaches the repository through the handler `connect` installs.
        await transport.report(reachable: false)
        await transport.report(reachable: true)
        let reported = await epochs.next()
        XCTAssertEqual(reported, 3)
    }

    func testShutdownEndsTheSessionAndAdmitsNoFurtherWork() async throws {
        let root = temporaryTestRoot("RepositoryAccount")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = SessionTransport()
        let repository = try repository(transport, root: root)
        try await repository.connect()

        await repository.shutdown()
        await repository.shutdown()
        let logouts = await transport.logouts
        XCTAssertEqual(logouts, 1)
        do {
            try await repository.connect()
            XCTFail("A shut-down repository must not reconnect")
        } catch is CancellationError {}
        await repository.retryAuthentication()
        do {
            try await repository.connect()
            XCTFail("Retry must not reopen a shut-down repository")
        } catch is CancellationError {}
    }

    func testStatusClassification() {
        XCTAssertEqual(CachedPhotosRepository.status(after: SynologyAPIError.api(400)),
                       .needsSignIn(SynologyAPIError.api(400).localizedDescription))
        XCTAssertEqual(CachedPhotosRepository.status(after: SynologyAPIError.untrustedCertificate(sha256: "ab")),
                       .untrustedCertificate(sha256: "ab"))
        XCTAssertEqual(CachedPhotosRepository.status(after: SynologyAPIError.transport("offline")),
                       .unreachable(SynologyAPIError.transport("offline").localizedDescription))
        XCTAssertEqual(CachedPhotosRepository.status(after: SynologyAPIError.api(407)),
                       .failed(SynologyAPIError.api(407).localizedDescription))
    }
}
