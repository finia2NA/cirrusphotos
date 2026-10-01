import Foundation
import ImageIO
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

public struct TimelineSnapshot: Codable, Sendable {
    public let timeline: Timeline
    public let sections: [TimelineSection]
    public var sectionCount: Int { sections.count }

    public init(sections: [TimelineSection]) {
        self.sections = sections
        let days = sections.enumerated().flatMap { sectionIndex, section in
            section.list.map {
                LibraryDay(year: $0.year, month: $0.month, day: $0.day,
                           count: $0.itemCount, section: sectionIndex)
            }
        }
        timeline = Timeline(days: days)
    }

    private enum CodingKeys: String, CodingKey { case sections }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sections: try container.decode([TimelineSection].self, forKey: .sections))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sections, forKey: .sections)
    }
}

public struct TimelineSection: Codable, Sendable, Equatable {
    public let offset: Int
    public let limit: Int
    public let list: [TimelineDay]
    public init(offset: Int, limit: Int, list: [TimelineDay]) {
        self.offset = offset; self.limit = limit; self.list = list
    }
}

public struct TimelineDay: Codable, Sendable, Equatable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let itemCount: Int
    enum CodingKeys: String, CodingKey { case year, month, day; case itemCount = "item_count" }
    public init(year: Int, month: Int, day: Int, itemCount: Int) {
        self.year = year; self.month = month; self.day = day; self.itemCount = itemCount
    }
}

public struct PhotoItem: Codable, Sendable, Identifiable {
    public let id: Int64
    public let time: Int64
    public let type: String
    public let additional: Additional?

    public struct Additional: Codable, Sendable {
        public let thumbnail: ThumbnailInfo?
        public let resolution: Resolution?
    }
    public struct Resolution: Codable, Sendable {
        public let width: Int
        public let height: Int
    }
}

public struct ThumbnailInfo: Codable, Sendable {
    public let unitID: Int64
    public let cacheKey: String
    public let sm: String?
    public let m: String?
    public let xl: String?
    enum CodingKeys: String, CodingKey {
        case unitID = "unit_id", cacheKey = "cache_key", sm, m, xl
    }
    public func isReady(_ size: ThumbnailSize) -> Bool {
        switch size { case .sm: sm == "ready"; case .m: m == "ready"; case .xl: xl == "ready" }
    }
}

public enum ThumbnailSize: String, CaseIterable, Codable, Sendable { case sm, m, xl }

public struct ThumbnailResponse: Sendable {
    public let data: Data?
    public let etag: String?
    public let lastModified: String?
    public var notModified: Bool { data == nil }
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
        for attempt in 0...1 {
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
            if response.success, let data = response.data {
                sid = data.sid
                synoToken = data.synoToken
                return
            }
            let code = response.error?.code ?? -1
            guard attempt == 0, code == 403 || code == 404 else { throw SynologyAPIError.api(code) }
            // DSM rejects a TOTP already used by a previous session. Retry once with a fresh window.
            let remainder = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
            try await Task.sleep(for: .seconds(31 - remainder))
        }
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
        return TimelineSnapshot(sections: data.section)
    }

    public func items(in section: TimelineSection) async throws -> [PhotoItem] {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard let bounds = section.dateBounds else { throw SynologyAPIError.invalidResponse }
        let response: APIEnvelope<ItemData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item",
            parameters: [
                "api": "SYNO.Foto.Browse.Item", "version": "7", "method": "list",
                "offset": String(section.offset), "limit": String(section.limit),
                "start_time": String(bounds.start), "end_time": String(bounds.end),
                "additional": "[\"thumbnail\",\"resolution\",\"orientation\",\"video_convert\",\"video_meta\",\"address\",\"favorite\"]",
                "_sid": sid
            ], authenticated: true
        )
        guard response.success, let data = response.data else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        return data.list
    }

    public func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize,
                          etag: String? = nil, lastModified: String? = nil) async throws -> ThumbnailResponse {
        guard let sid else { throw SynologyAPIError.api(119) }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/synofoto/api/v2/p/Thumbnail/get"
        var parameters = [
            URLQueryItem(name: "id", value: String(descriptor.unitID)),
            URLQueryItem(name: "cache_key", value: "\"\(descriptor.cacheKey)\""),
            URLQueryItem(name: "type", value: "\"unit\""),
            URLQueryItem(name: "size", value: "\"\(size.rawValue)\""),
            URLQueryItem(name: "_sid", value: sid)
        ]
        if let synoToken { parameters.append(URLQueryItem(name: "SynoToken", value: synoToken)) }
        components.queryItems = parameters
        guard let url = components.url else { throw SynologyAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        else if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw SynologyAPIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw SynologyAPIError.invalidResponse }
        if http.statusCode == 304 {
            return ThumbnailResponse(data: nil, etag: http.value(forHTTPHeaderField: "ETag"),
                                     lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        }
        guard http.statusCode == 200 else { throw SynologyAPIError.http(http.statusCode) }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/") == true,
              !data.isEmpty,
              CGImageSourceCreateWithData(data as CFData, nil) != nil else {
            if let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: data),
               let error = envelope.error { throw SynologyAPIError.api(error.code) }
            throw SynologyAPIError.invalidResponse
        }
        return ThumbnailResponse(data: data, etag: http.value(forHTTPHeaderField: "ETag"),
                                 lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
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
        // URL query encoding leaves '+' literal, but form decoders interpret it as a space.
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
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
private struct ItemData: Decodable { let list: [PhotoItem] }
private struct EmptyData: Decodable {}

public extension TimelineSection {
    var dateBounds: (start: Int64, end: Int64)? {
        guard let newest = list.first, let oldest = list.last else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let startDate = calendar.date(from: DateComponents(year: oldest.year, month: oldest.month, day: oldest.day)),
              let endDate = calendar.date(from: DateComponents(year: newest.year, month: newest.month, day: newest.day)) else { return nil }
        return (Int64(startDate.timeIntervalSince1970), Int64(endDate.timeIntervalSince1970) + 86_399)
    }
}
