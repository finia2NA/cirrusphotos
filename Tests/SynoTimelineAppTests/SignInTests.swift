import Foundation
import os
import SynologyAPI
import XCTest
@testable import SynoTimelineApp

private final class MemorySecrets: AccountSecrets, @unchecked Sendable {
    private let values = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    func read(account: String, item: String) -> String? { values.withLock { $0["\(account)|\(item)"] } }
    func write(_ value: String, account: String, item: String) throws { values.withLock { $0["\(account)|\(item)"] = value } }
    func delete(account: String, item: String) { _ = values.withLock { $0.removeValue(forKey: "\(account)|\(item)") } }
    var count: Int { values.withLock { $0.count } }
}

/// Records each attempted login and answers from a script.
private final class ScriptedLogin: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(answers: [Result<SignInResult, SynologyAPIError>], seen: [SynologyCredentials])>(
        initialState: ([], []))

    init(_ answers: [Result<SignInResult, SynologyAPIError>]) { state.withLock { $0.answers = answers } }

    var seen: [SynologyCredentials] { state.withLock { $0.seen } }

    func authenticate(_ credentials: SynologyCredentials) throws -> SignInResult {
        try state.withLock { state in
            state.seen.append(credentials)
            return try state.answers.removeFirst().get()
        }
    }
}

@MainActor
final class SignInTests: XCTestCase {
    private func model(_ login: ScriptedLogin) -> SignInModel {
        let model = SignInModel { try login.authenticate($0) }
        model.server = "nas.example.test"
        model.username = "alice"
        model.password = "secret"
        return model
    }

    func testAccountWithoutSecondFactorSignsInDirectly() async {
        let login = ScriptedLogin([.success(SignInResult(deviceToken: "unused"))])
        let model = model(login)
        let signedIn = await model.submit()
        XCTAssertEqual(signedIn?.account.serverURL.absoluteString, "https://nas.example.test:5001")
        XCTAssertEqual(signedIn?.account.username, "alice")
        XCTAssertNil(signedIn?.deviceToken, "Only a login that proved a code keeps its token")
        XCTAssertEqual(login.seen.first?.secondFactor, SecondFactor.none)
        XCTAssertEqual(login.seen.first?.serverTrust, ServerTrust.system)
    }

    func testCodeStepThenTrustedDevice() async {
        let login = ScriptedLogin([.failure(.secondFactorRequired), .failure(.api(404)),
                                   .success(SignInResult(deviceToken: "device"))])
        let model = model(login)
        let first = await model.submit()
        XCTAssertNil(first)
        XCTAssertEqual(model.step, SignInModel.Step.code)
        XCTAssertFalse(model.canSubmit)

        model.setCode("12 34-56 7")
        XCTAssertEqual(model.code, "123456")
        let rejected = await model.submit()
        XCTAssertNil(rejected)
        XCTAssertEqual(model.step, SignInModel.Step.code)
        XCTAssertEqual(model.code, "")
        XCTAssertNotNil(model.errorMessage)

        model.setCode("654321")
        let signedIn = await model.submit()
        XCTAssertEqual(signedIn?.deviceToken, "device")
        XCTAssertEqual(login.seen.last?.secondFactor, SecondFactor.code("654321"))
    }

    func testUntrustedCertificateIsPinnedOnlyAfterTheUserAccepts() async {
        let login = ScriptedLogin([.failure(.untrustedCertificate(sha256: "abcd")), .success(SignInResult(deviceToken: nil))])
        let model = model(login)
        let first = await model.submit()
        XCTAssertNil(first)
        XCTAssertEqual(model.step, SignInModel.Step.certificate("abcd"))
        XCTAssertEqual(SignInModel.formatted(fingerprint: "abcd"), "AB:CD")
        let signedIn = await model.submit()
        XCTAssertEqual(signedIn?.account.pinnedCertificate, "abcd")
        XCTAssertEqual(login.seen.last?.serverTrust, ServerTrust.pinned(sha256: "abcd"))
    }

    func testBackForgetsAnUnacceptedCertificate() async {
        let login = ScriptedLogin([.failure(.untrustedCertificate(sha256: "abcd"))])
        let model = model(login)
        _ = await model.submit()
        model.back()
        XCTAssertEqual(model.step, SignInModel.Step.credentials)
        XCTAssertEqual(model.server, "nas.example.test")
    }

    func testAccountStoreKeepsSecretsOutOfDefaultsAndForgetsThemOnRemove() throws {
        let defaults = UserDefaults(suiteName: "SignInTests-\(UUID().uuidString)")!
        let secrets = MemorySecrets()
        let store = AccountStore(defaults: defaults, secrets: secrets)
        let account = StoredAccount(serverURL: URL(string: "https://nas.example.test:5001")!, username: "alice", pinnedCertificate: "abcd")
        try store.save(account, password: "secret", deviceToken: "device")
        store.setCurrent(account)

        let reloaded = AccountStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reloaded.accounts, [account])
        XCTAssertEqual(reloaded.currentAccount, account)
        let credentials = reloaded.credentials(for: account)
        XCTAssertEqual(credentials?.password, "secret")
        XCTAssertEqual(credentials?.secondFactor, SecondFactor.deviceToken("device"))
        XCTAssertEqual(credentials?.serverTrust, ServerTrust.pinned(sha256: "abcd"))
        let stored = defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        XCTAssertFalse(stored.contains("secret"))

        reloaded.remove(account)
        XCTAssertTrue(reloaded.accounts.isEmpty)
        XCTAssertNil(reloaded.currentAccount)
        XCTAssertEqual(secrets.count, 0)
    }

    func testSavingWithoutTokenRemovesAnOldOne() throws {
        let defaults = UserDefaults(suiteName: "SignInTests-\(UUID().uuidString)")!
        let secrets = MemorySecrets()
        let store = AccountStore(defaults: defaults, secrets: secrets)
        let account = StoredAccount(serverURL: URL(string: "https://nas.example.test:5001")!, username: "alice")
        try store.save(account, password: "one", deviceToken: "device")
        try store.save(account, password: "two", deviceToken: nil)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.credentials(for: account)?.secondFactor, SecondFactor.none)
        XCTAssertEqual(store.credentials(for: account)?.password, "two")
    }

    func testCertificatePinsForStoredAndEnvironmentAccounts() throws {
        let defaults = UserDefaults(suiteName: "SignInTests-\(UUID().uuidString)")!
        let store = AccountStore(defaults: defaults, secrets: MemorySecrets())
        let account = StoredAccount(serverURL: URL(string: "https://nas.example.test:5001")!, username: "alice")
        try store.save(account, password: "secret", deviceToken: nil)
        let pinned = store.pin("abcd", for: account)
        XCTAssertEqual(pinned.pinnedCertificate, "abcd")
        XCTAssertEqual(AccountStore(defaults: defaults, secrets: MemorySecrets()).accounts.first?.pinnedCertificate, "abcd")
        XCTAssertEqual(store.credentials(for: pinned)?.serverTrust, ServerTrust.pinned(sha256: "abcd"))

        XCTAssertNil(store.environmentPin(host: "nas.example.test"))
        store.setEnvironmentPin("ef01", host: "NAS.example.test")
        XCTAssertEqual(store.environmentPin(host: "nas.example.test"), "ef01")
    }

    func testOnlyAnsweringServersAreRemembered() async {
        let unreachable = ScriptedLogin([.failure(.transport("offline"))])
        let offline = model(unreachable)
        _ = await offline.submit()
        XCTAssertNil(offline.answeringServer)

        let rejected = ScriptedLogin([.failure(.api(400))])
        let wrongPassword = model(rejected)
        _ = await wrongPassword.submit()
        XCTAssertEqual(wrongPassword.answeringServer?.absoluteString, "https://nas.example.test:5001")
    }

    func testServerSuggestionsAreRecentFirstWithoutDuplicates() throws {
        let defaults = UserDefaults(suiteName: "SignInTests-\(UUID().uuidString)")!
        let store = AccountStore(defaults: defaults, secrets: MemorySecrets())
        try store.save(StoredAccount(serverURL: URL(string: "https://stored.example.test:5001")!, username: "alice"),
                       password: "secret", deviceToken: nil)
        store.rememberServer(URL(string: "https://first.example.test:5001")!)
        store.rememberServer(URL(string: "https://stored.example.test:5001")!)
        store.rememberServer(URL(string: "https://first.example.test:5001")!)
        XCTAssertEqual(store.serverSuggestions, ["https://first.example.test:5001", "https://stored.example.test:5001"])
        for index in 0..<15 { store.rememberServer(URL(string: "https://nas\(index).example.test")!) }
        XCTAssertEqual(defaults.stringArray(forKey: AccountStore.recentServersKey)?.count, AccountStore.recentServerLimit)
    }

    func testSavedThumbnailDownloadSurvivesSuspension() {
        let defaults = UserDefaults(suiteName: "SignInTests-\(UUID().uuidString)")!
        let request = ThumbnailPreloadModel.Request(earliest: "2024-01-01", latest: "2024-02-01",
                                                    includesSharedSpace: true, size: "m")
        defaults.set(try? JSONEncoder().encode(request), forKey: ThumbnailPreloadModel.requestKey(namespace: "ns"))
        let model = ThumbnailPreloadModel(defaults: defaults)
        model.suspend()
        XCTAssertEqual(model.savedRequest(namespace: "ns"), request)
        XCTAssertNil(model.savedRequest(namespace: "other"))
    }
}
