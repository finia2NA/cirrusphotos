import Foundation
import ImageIO

public actor SynologyClient: PhotosTransport {
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
        configuration.timeoutIntervalForResource = 300
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

    public func timeline(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> TimelineSnapshot {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard collection.albumID == nil else {
            throw SynologyAPIError.unsupported("Albums do not use Browse.Timeline; use albumTimeline(albumID:).")
        }
        guard !initial || collection.supportsInitialTimeline else {
            throw SynologyAPIError.unsupported("Favorites does not support the initial timeline endpoint.")
        }
        var parameters = [
            "api": "SYNO.Foto.Browse.Timeline", "version": "6",
            "method": initial ? "get_init_timeline" : "get",
            "timeline_group_unit": "\"day\"", "_sid": sid
        ]
        if collection.favoriteOnly { parameters["favorite_only"] = "true" }
        let response: APIEnvelope<TimelineData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Timeline",
            parameters: parameters, authenticated: true
        )
        guard response.success, let data = response.data else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        return TimelineSnapshot(sections: data.section)
    }

    public func albums() async throws -> [AlbumSummary] {
        guard let sid else { throw SynologyAPIError.api(119) }
        let pageLimit = 100
        var collected: [AlbumSummary] = []
        var offset = 0
        while true {
            let response: APIEnvelope<AlbumListData> = try await post(
                path: "/webapi/entry.cgi/SYNO.Foto.Browse.Album",
                parameters: [
                    "api": "SYNO.Foto.Browse.Album", "version": "4", "method": "list",
                    "offset": String(offset), "limit": String(pageLimit),
                    "category": "\"normal\"", "sort_by": "\"album_name\"", "sort_direction": "\"asc\"",
                    "additional": "[\"sharing_info\",\"thumbnail\"]", "_sid": sid
                ], authenticated: true
            )
            guard response.success, let data = response.data else {
                throw SynologyAPIError.api(response.error?.code ?? -1)
            }
            collected.append(contentsOf: data.list)
            guard data.list.count == pageLimit else { break }
            offset += pageLimit
        }
        return collected
    }

    public func albumTimeline(albumID: Int64) async throws -> TimelineSnapshot {
        guard let sid else { throw SynologyAPIError.api(119) }
        let pageLimit = 1000
        let pageCap = 2048
        var entries: [DayTimelineEntry] = []
        var offset = 0
        var pages = 0
        while true {
            guard pages < pageCap else {
                throw SynologyAPIError.unsupported("Album \(albumID) exceeds the scan page cap.")
            }
            let response: APIEnvelope<ItemData> = try await post(
                path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item",
                parameters: [
                    "api": "SYNO.Foto.Browse.Item", "version": "7", "method": "list",
                    "offset": String(offset), "limit": String(pageLimit),
                    "album_id": String(albumID),
                    "sort_by": "\"takentime\"", "sort_direction": "\"desc\"",
                    "additional": "[]", "_sid": sid
                ], authenticated: true
            )
            guard response.success, let data = response.data else {
                throw SynologyAPIError.api(response.error?.code ?? -1)
            }
            pages += 1
            guard !data.list.isEmpty else { break }
            entries.append(contentsOf: data.list.map { DayTimelineEntry(id: $0.id, time: $0.time) })
            guard data.list.count == pageLimit else { break }
            offset += pageLimit
        }
        return DayGroupedTimelineBuilder.build(entries: entries).snapshot
    }

    public func items(in section: TimelineSection, collection: PhotoCollectionDescriptor) async throws -> [PhotoItem] {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard let bounds = section.dateBounds else { throw SynologyAPIError.invalidResponse }
        var parameters = [
            "api": "SYNO.Foto.Browse.Item", "version": "7", "method": "list",
            "offset": String(section.offset), "limit": String(section.limit),
            "start_time": String(bounds.start), "end_time": String(bounds.end),
            "additional": Self.additionalParameter(),
            "_sid": sid
        ]
        if collection.favoriteOnly { parameters["favorite_only"] = "true" }
        if let albumID = collection.albumID {
            parameters["album_id"] = String(albumID)
            parameters["sort_by"] = "\"takentime\""
            parameters["sort_direction"] = "\"desc\""
        }
        let response: APIEnvelope<ItemData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item",
            parameters: parameters, authenticated: true
        )
        guard response.success, let data = response.data else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        return data.list
    }

    public func locationScanPage(offset: Int, limit: Int) async throws -> [PhotoItem] {
        guard let sid else { throw SynologyAPIError.api(119) }
        let response: APIEnvelope<ItemData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item",
            parameters: [
                "api": "SYNO.Foto.Browse.Item", "version": "7", "method": "list",
                "offset": String(offset), "limit": String(limit),
                "additional": Self.additionalParameter(for: PhotosRequestFields.locationScanAdditional),
                "_sid": sid
            ], authenticated: true
        )
        guard response.success, let data = response.data else {
            throw SynologyAPIError.api(response.error?.code ?? -1)
        }
        return data.list
    }

    public func diffVersion() async throws -> DiffCursor {
        guard let sid else { throw SynologyAPIError.api(119) }
        let response: APIEnvelope<DiffVersionData> = try await postBounded(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Diff",
            parameters: [
                "api": "SYNO.Foto.Browse.Diff", "version": "1",
                "method": "get_version", "_sid": sid,
            ],
            authenticated: true,
            maximumBytes: 4 * 1_024 * 1_024
        )
        guard response.success, let data = response.data else {
            throw SynologyAPIError.api(response.error?.code ?? -1)
        }
        return data.cursor
    }

    public func changes(since cursor: DiffCursor) async throws -> PhotoDiff {
        guard let sid else { throw SynologyAPIError.api(119) }
        let response: APIEnvelope<PhotoDiffData> = try await postBounded(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Diff",
            parameters: [
                "api": "SYNO.Foto.Browse.Diff", "version": "1", "method": "get",
                "diff_version": String(cursor.diffVersion),
                "version_time": String(cursor.versionTime), "_sid": sid,
            ],
            authenticated: true,
            maximumBytes: 4 * 1_024 * 1_024
        )
        guard response.success, let data = response.data else {
            throw SynologyAPIError.api(response.error?.code ?? -1)
        }
        return data.value
    }

    public func locationItems(ids: [Int64]) async throws -> LocationItemLookup {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard !ids.isEmpty, ids.count <= 100 else {
            throw SynologyAPIError.unsupported("Location lookup requires 1–100 item IDs.")
        }
        let response: APIEnvelope<ItemData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item",
            parameters: [
                "api": "SYNO.Foto.Browse.Item", "version": "7", "method": "get",
                "id": "[" + ids.map(String.init).joined(separator: ",") + "]",
                "additional": Self.additionalParameter(for: PhotosRequestFields.locationScanAdditional),
                "_sid": sid,
            ], authenticated: true
        )
        guard response.success, let data = response.data else {
            throw SynologyAPIError.api(response.error?.code ?? -1)
        }
        return LocationItemLookup(requestedIDs: ids, items: data.list)
    }

    private static func additionalParameter(
        for fields: [String] = PhotosRequestFields.pageAdditional
    ) -> String {
        "[" + fields.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    public func setFavorite(itemIDs: [Int64], favorite: Bool) async throws {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard !itemIDs.isEmpty else { return }
        let ids = "[" + itemIDs.map(String.init).joined(separator: ",") + "]"
        let response: APIEnvelope<EmptyData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item",
            parameters: ["api": "SYNO.Foto.Browse.Item", "version": "7",
                         "method": "set_favorite", "id": ids,
                         "favorite": favorite ? "true" : "false", "_sid": sid],
            authenticated: true
        )
        guard response.success else { throw SynologyAPIError.api(response.error?.code ?? -1) }
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

    public func fullImage(_ resource: FullImageResource,
                          etag: String? = nil, lastModified: String? = nil) async throws -> FullImageResponse {
        guard let sid else { throw SynologyAPIError.api(119) }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/entry.cgi"
        var parameters = [
            URLQueryItem(name: "api", value: "SYNO.Foto.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "unit_id", value: "[\(resource.unitID)]"),
            URLQueryItem(name: "cache_key", value: resource.cacheKey),
            URLQueryItem(name: "_sid", value: sid)
        ]
        if let synoToken { parameters.append(URLQueryItem(name: "SynoToken", value: synoToken)) }
        components.queryItems = parameters
        guard let url = components.url else { throw SynologyAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 300
        request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        else if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let data: Data
        let response: URLResponse
        SynologyDiagnostics.transport.debug(
            "Sending original request unit_id=\(resource.unitID, privacy: .public) conditional=\(etag != nil || lastModified != nil, privacy: .public)"
        )
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError {
            SynologyDiagnostics.transport.debug(
                "Original transport cancelled unit_id=\(resource.unitID, privacy: .public)"
            )
            throw CancellationError()
        }
        catch {
            SynologyDiagnostics.transport.error(
                "Original transport failed unit_id=\(resource.unitID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw SynologyAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SynologyAPIError.invalidResponse }
        if http.statusCode == 304 {
            SynologyDiagnostics.transport.info(
                "Original response unit_id=\(resource.unitID, privacy: .public) status=304"
            )
            return FullImageResponse(data: nil, etag: http.value(forHTTPHeaderField: "ETag"),
                                     lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        }
        guard http.statusCode == 200 else {
            SynologyDiagnostics.transport.error(
                "Original response rejected unit_id=\(resource.unitID, privacy: .public) status=\(http.statusCode, privacy: .public) content_type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "nil", privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            throw SynologyAPIError.http(http.statusCode)
        }
        guard !data.isEmpty, CGImageSourceCreateWithData(data as CFData, nil) != nil else {
            SynologyDiagnostics.transport.error(
                "Original response was not a decodable image unit_id=\(resource.unitID, privacy: .public) status=200 content_type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "nil", privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            if let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: data),
               let error = envelope.error { throw SynologyAPIError.api(error.code) }
            throw SynologyAPIError.invalidResponse
        }
        SynologyDiagnostics.transport.info(
            "Original response unit_id=\(resource.unitID, privacy: .public) status=200 bytes=\(data.count, privacy: .public)"
        )
        return FullImageResponse(data: data, etag: http.value(forHTTPHeaderField: "ETag"),
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

    private func postBounded<Response: Decodable>(
        path: String,
        parameters: [String: String],
        authenticated: Bool,
        maximumBytes: Int
    ) async throws -> Response {
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

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SynologyAPIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw SynologyAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SynologyAPIError.http(http.statusCode) }
        if let expected = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           expected > maximumBytes {
            throw SynologyAPIError.responseTooLarge(maximumBytes)
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        do {
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw SynologyAPIError.responseTooLarge(maximumBytes)
                }
                data.append(byte)
            }
        } catch let error as SynologyAPIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SynologyAPIError.transport(error.localizedDescription)
        }
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
