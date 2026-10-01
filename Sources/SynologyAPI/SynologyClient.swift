import Foundation
import Security
import TimelineCore

public enum SynologyAPIError: LocalizedError, Sendable {
    case configuration(String)
    case transport(String)
    case invalidResponse
    case http(Int)
    case api(Int)

    public var errorDescription: String? {
        switch self {
        case .configuration(let message): message
        case .transport(let message): "Could not reach Cirrus: \(message)"
        case .invalidResponse: "Cirrus returned an unexpected response."
        case .http(let status): "Cirrus returned HTTP \(status)."
        case .api(let code):
            switch code {
            case 400: "The username or password was rejected."
            case 402: "The account is not permitted to use Synology Photos."
            case 403, 404: "Two-factor authentication was rejected. Check the NAS and Mac clocks."
            case 407: "The NAS temporarily blocked login attempts."
            case 119: "The Synology session expired."
            default: "Synology API error \(code)."
            }
        }
    }
}

public struct TimelineSnapshot: Sendable {
    public let timeline: Timeline
    public let sectionCount: Int

    public init(timeline: Timeline, sectionCount: Int) {
        self.timeline = timeline
        self.sectionCount = sectionCount
    }
}

public actor SynologyClient {
    public static let defaultBaseURL = URL(string: "https://nas.example.com:5001")!

    private let baseURL: URL
    private let session: URLSession
    private var sid: String?
    private var synoToken: String?

    public init(baseURL: URL = defaultBaseURL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage()
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let delegate = CirrusTrustDelegate(allowedHost: baseURL.host ?? "")
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func login(credentials: SynologyCredentials) async throws {
        let otpCode = try TOTP.generate(secret: credentials.otpSecret)
        let response: APIEnvelope<LoginData> = try await post(
            path: "/webapi/entry.cgi",
            parameters: [
                "api": "SYNO.API.Auth", "version": "6", "method": "login",
                "account": credentials.username, "passwd": credentials.password,
                "otp_code": otpCode, "session": "SynologyPhotos", "format": "sid",
                "enable_syno_token": "yes", "enable_device_token": "no",
                "device_name": "SynoTimeline"
            ], authenticated: false
        )
        guard response.success, let data = response.data else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        sid = data.sid
        synoToken = data.synoToken
    }

    public func timeline(initial: Bool) async throws -> TimelineSnapshot {
        guard let sid else { throw SynologyAPIError.api(119) }
        let response: APIEnvelope<TimelineData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Timeline",
            parameters: [
                "api": "SYNO.Foto.Browse.Timeline", "version": "6",
                "method": initial ? "get_init_timeline" : "get",
                "timeline_group_unit": "\"day\"", "_sid": sid
            ], authenticated: true
        )
        guard response.success, let data = response.data else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        let days = data.section.enumerated().flatMap { sectionIndex, section in
            section.list.map {
                LibraryDay(year: $0.year, month: $0.month, day: $0.day,
                           count: $0.itemCount, section: sectionIndex)
            }
        }
        return TimelineSnapshot(timeline: Timeline(days: days), sectionCount: data.section.count)
    }

    private func post<Response: Decodable>(path: String, parameters: [String: String], authenticated: Bool) async throws -> Response {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        guard let url = components.url else { throw SynologyAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        if authenticated, let synoToken { request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN") }
        request.httpBody = formBody(parameters)

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw SynologyAPIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw SynologyAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SynologyAPIError.http(http.statusCode) }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw SynologyAPIError.invalidResponse }
    }

    private func formBody(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

private final class CirrusTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowedHost: String
    init(allowedHost: String) { self.allowedHost = allowedHost }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == allowedHost,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct APIEnvelope<Value: Decodable>: Decodable {
    let success: Bool
    let data: Value?
    let error: APIError?
}

private struct APIError: Decodable { let code: Int }

private struct LoginData: Decodable {
    let sid: String
    let synoToken: String?
    enum CodingKeys: String, CodingKey { case sid; case synoToken = "synotoken" }
}

private struct TimelineData: Decodable { let section: [TimelineSection] }
private struct TimelineSection: Decodable { let offset: Int; let limit: Int; let list: [TimelineDay] }
private struct TimelineDay: Decodable {
    let year: Int; let month: Int; let day: Int; let itemCount: Int
    enum CodingKeys: String, CodingKey { case year, month, day; case itemCount = "item_count" }
}
