import Foundation
import ImageIO

private final class UploadTransferDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (TransferProgress) -> Void

    init(progress: @escaping @Sendable (TransferProgress) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        progress(TransferProgress(
            completedBytes: totalBytesSent,
            totalBytes: totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil
        ))
    }
}

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
        // Request timeouts are inactivity timeouts and reset as data moves. Keep a
        // generous absolute cap so large originals are not killed while progressing.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let delegate = CirrusTrustDelegate(allowedHost: baseURL.host ?? "")
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
    }

    public func login(credentials: SynologyCredentials) async throws {
        for attempt in 0...1 {
            var parameters = [
                "api": "SYNO.API.Auth", "version": "6", "method": "login",
                "account": credentials.username, "passwd": credentials.password,
                "session": "webui", "format": "sid",
                "enable_syno_token": "yes", "enable_device_token": "no",
                "device_name": "SynoTimeline"
            ]
            if let secret = credentials.otpSecret {
                parameters["otp_code"] = try TOTP.generate(secret: secret)
            }
            let response: APIEnvelope<LoginData> = try await post(
                path: "/webapi/entry.cgi",
                parameters: parameters, authenticated: false
            )
            if response.success, let data = response.data {
                sid = data.sid
                synoToken = data.synoToken
                return
            }
            let code = response.error?.code ?? -1
            if credentials.otpSecret == nil, [403, 404, 406].contains(code) {
                throw SynologyAPIError.configuration(
                    "The NAS requires two-factor authentication for this account. Set OTP in .env to its base32 secret or otpauth URL."
                )
            }
            guard credentials.otpSecret != nil, attempt == 0, code == 403 || code == 404 else {
                throw SynologyAPIError.api(code)
            }
            // DSM rejects a TOTP already used by a previous session. Retry once with a fresh window.
            let remainder = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
            try await Task.sleep(for: .seconds(31 - remainder))
        }
    }

    public func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        let sections = try await fetchTimelineSections(collection: collection, initial: initial)
        return try CollectionDayCatalog(sections: sections, completeness: initial ? .partial : .complete)
    }

    public func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard offset >= 0, limit > 0, limit <= 1000 else { throw SynologyAPIError.invalidResponse }
        let response: APIEnvelope<ItemData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item",
            parameters: ["api": "SYNO.Foto.Browse.Item", "version": "7", "method": "list",
                         "offset": String(offset), "limit": String(limit), "album_id": String(albumID),
                         "sort_by": "\"takentime\"", "sort_direction": "\"desc\"", "additional": "[]", "_sid": sid], authenticated: true)
        guard response.success, let data = response.data else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        return data.list.map { DayTimelineEntry(id: $0.id, time: $0.time) }
    }

    public func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard !request.collection.usesPersonalLibrarySource else { throw SynologyAPIError.invalidResponse }
        var parameters = ["api": "SYNO.Foto.Browse.Item", "version": "7", "method": "list",
                          "offset": String(request.offset), "limit": String(request.limit),
                          "start_time": String(request.oldestDay.startTime), "end_time": String(request.newestDay.endTime),
                          "additional": Self.additionalParameter(for: fields.additional), "_sid": sid]
        if request.collection.favoriteOnly { parameters["favorite_only"] = "true" }
        if let albumID = request.collection.albumID { parameters["album_id"] = String(albumID) }
        if request.order == .takenTimeDescending {
            parameters["sort_by"] = "\"takentime\""; parameters["sort_direction"] = "\"desc\""
        }
        let response: APIEnvelope<ItemData> = try await post(path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item", parameters: parameters, authenticated: true)
        guard response.success, let data = response.data else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        return CollectionBatchResult(items: data.list, profile: fields)
    }

    private func fetchTimelineSections(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> [TimelineSection] {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard collection.albumID == nil else {
            throw SynologyAPIError.unsupported("Albums use bounded item catalog enumeration.")
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
        return data.section
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

    public func readPersonalInventoryBatch(offset: Int, limit: Int) async throws -> [PhotoItem] {
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
                "api": "SYNO.Foto.Browse.Diff", "version": "7",
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
                "api": "SYNO.Foto.Browse.Diff", "version": "7", "method": "list",
                "geocoding_accept_language": "enu",
                "additional": Self.additionalParameter(),
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

    public func items(ids: [Int64]) async throws -> [PhotoItem] {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard !ids.isEmpty, ids.count <= 1_000 else {
            throw SynologyAPIError.unsupported("Item lookup requires 1–1000 item IDs.")
        }
        let response: APIEnvelope<ItemData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item",
            parameters: [
                "api": "SYNO.Foto.Browse.Item", "version": "7", "method": "get",
                "id": Self.idArray(ids), "additional": Self.additionalParameter(), "_sid": sid,
            ], authenticated: true
        )
        guard response.success, let data = response.data else {
            throw SynologyAPIError.api(response.error?.code ?? -1)
        }
        return data.list
    }

    public func rotate(itemIDs: [Int64], direction: PhotoRotationDirection) async throws {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard !itemIDs.isEmpty else { return }
        let response: APIEnvelope<ItemSetData> = try await post(
            path: "/webapi/entry.cgi/SYNO.Foto.Browse.Item",
            parameters: [
                "api": "SYNO.Foto.Browse.Item", "version": "7", "method": "set",
                "id": Self.idArray(itemIDs), "rotate_action": direction.rawValue, "_sid": sid,
            ], authenticated: true
        )
        guard response.success else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        guard response.data?.errorList.isEmpty != false else { throw SynologyAPIError.invalidResponse }
    }

    public func setRegenerating(itemIDs: [Int64]) async throws -> [RegeneratingThumbnailUnit] {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard !itemIDs.isEmpty else { return [] }
        SynologyDiagnostics.rotationTransport.info(
            "Sending set_regenerating item_count=\(itemIDs.count, privacy: .public) first_item_id=\(itemIDs.first ?? -1, privacy: .public) api_version=1"
        )
        let response: APIEnvelope<RegeneratingData>
        do {
            response = try await post(
                path: "/webapi/entry.cgi",
                parameters: [
                    "api": "SYNO.Foto.RegeneratePreview", "version": "1",
                    "method": "set_regenerating", "item_id": Self.idArray(itemIDs), "_sid": sid,
                ], authenticated: true
            )
        } catch {
            SynologyDiagnostics.rotationTransport.error(
                "set_regenerating transport failed item_count=\(itemIDs.count, privacy: .public) first_item_id=\(itemIDs.first ?? -1, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        guard response.success, let data = response.data else {
            SynologyDiagnostics.rotationTransport.error(
                "set_regenerating API rejected request item_count=\(itemIDs.count, privacy: .public) first_item_id=\(itemIDs.first ?? -1, privacy: .public) api_code=\(response.error?.code ?? -1, privacy: .public)"
            )
            throw SynologyAPIError.api(response.error?.code ?? -1)
        }
        SynologyDiagnostics.rotationTransport.info(
            "set_regenerating accepted item_count=\(itemIDs.count, privacy: .public) first_item_id=\(itemIDs.first ?? -1, privacy: .public) returned_units=\(data.list.count, privacy: .public) first_unit_id=\(data.list.first?.unitID ?? -1, privacy: .public)"
        )
        return data.list.map { RegeneratingThumbnailUnit(itemID: $0.itemID, unitID: $0.unitID) }
    }

    public func restoreFromRegenerating(unitIDs: [Int64]) async throws {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard !unitIDs.isEmpty else { return }
        SynologyDiagnostics.rotationTransport.info(
            "Sending restore_from_regenerating unit_count=\(unitIDs.count, privacy: .public) first_unit_id=\(unitIDs.first ?? -1, privacy: .public) api_version=1"
        )
        let response: APIEnvelope<EmptyData>
        do {
            response = try await post(
                path: "/webapi/entry.cgi",
                parameters: [
                    "api": "SYNO.Foto.RegeneratePreview", "version": "1",
                    "method": "restore_from_regenerating", "unit_id": Self.idArray(unitIDs), "_sid": sid,
                ], authenticated: true
            )
        } catch {
            SynologyDiagnostics.rotationTransport.error(
                "restore_from_regenerating transport failed unit_count=\(unitIDs.count, privacy: .public) first_unit_id=\(unitIDs.first ?? -1, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        guard response.success else {
            SynologyDiagnostics.rotationTransport.error(
                "restore_from_regenerating API rejected request unit_count=\(unitIDs.count, privacy: .public) first_unit_id=\(unitIDs.first ?? -1, privacy: .public) api_code=\(response.error?.code ?? -1, privacy: .public)"
            )
            throw SynologyAPIError.api(response.error?.code ?? -1)
        }
        SynologyDiagnostics.rotationTransport.info(
            "restore_from_regenerating accepted unit_count=\(unitIDs.count, privacy: .public) first_unit_id=\(unitIDs.first ?? -1, privacy: .public)"
        )
    }

    public func uploadConvertedThumbnails(unitID: Int64, files: ConvertedThumbnailFiles) async throws {
        try await uploadConvertedThumbnails(unitID: unitID, files: files, progress: { _ in })
    }

    public func uploadConvertedThumbnails(
        unitID: Int64, files: ConvertedThumbnailFiles,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        guard let sid else { throw SynologyAPIError.api(119) }
        SynologyDiagnostics.rotationTransport.info(
            "Preparing converted thumbnail upload unit_id=\(unitID, privacy: .public) sm_bytes=\(files.sm.count, privacy: .public) m_bytes=\(files.m.count, privacy: .public) xl_bytes=\(files.xl.count, privacy: .public) api_version=3"
        )
        let boundary = "SynoTimeline-\(UUID().uuidString)"
        let body = Self.convertedThumbnailMultipartBody(
            boundary: boundary, unitID: unitID, files: files
        )

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/entry.cgi"
        guard let url = components.url else { throw SynologyAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        if let synoToken { request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN") }
        let data: Data
        let response: URLResponse
        let delegate = UploadTransferDelegate(progress: progress)
        do { (data, response) = try await session.upload(for: request, from: body, delegate: delegate) }
        catch is CancellationError {
            SynologyDiagnostics.rotationTransport.info(
                "Converted thumbnail upload cancelled unit_id=\(unitID, privacy: .public)"
            )
            throw CancellationError()
        }
        catch {
            SynologyDiagnostics.rotationTransport.error(
                "Converted thumbnail upload transport failed unit_id=\(unitID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw SynologyAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            SynologyDiagnostics.rotationTransport.error(
                "Converted thumbnail upload missing HTTP response unit_id=\(unitID, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            throw SynologyAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            SynologyDiagnostics.rotationTransport.error(
                "Converted thumbnail upload HTTP failure unit_id=\(unitID, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            throw SynologyAPIError.http(http.statusCode)
        }
        guard let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: data),
              envelope.success else {
            if let envelope = try? JSONDecoder().decode(APIEnvelope<EmptyData>.self, from: data) {
                SynologyDiagnostics.rotationTransport.error(
                    "Converted thumbnail upload API rejected request unit_id=\(unitID, privacy: .public) status=\(http.statusCode, privacy: .public) api_code=\(envelope.error?.code ?? -1, privacy: .public) response_bytes=\(data.count, privacy: .public)"
                )
                throw SynologyAPIError.api(envelope.error?.code ?? -1)
            }
            SynologyDiagnostics.rotationTransport.error(
                "Converted thumbnail upload returned invalid JSON unit_id=\(unitID, privacy: .public) status=\(http.statusCode, privacy: .public) response_bytes=\(data.count, privacy: .public)"
            )
            throw SynologyAPIError.invalidResponse
        }
        SynologyDiagnostics.rotationTransport.info(
            "Converted thumbnail upload accepted unit_id=\(unitID, privacy: .public) status=\(http.statusCode, privacy: .public) response_bytes=\(data.count, privacy: .public)"
        )
    }

    static func convertedThumbnailMultipartBody(
        boundary: String, unitID: Int64, files: ConvertedThumbnailFiles
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        // Match Synology's desktop converter and the confirmed live probe exactly.
        // Authentication is carried by the cookie and X-SYNO-TOKEN header. The prior
        // variant added `_sid` and sorted these fields; that request received API error
        // 101, so keep this body byte-shape aligned with the confirmed working request.
        let fields = [
            ("api", "SYNO.Foto.Upload.ConvertedFile"),
            ("version", "3"),
            ("method", "upload"),
            ("unit_id", String(unitID)),
        ]
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        for (name, data) in [("thumb_sm", files.sm), ("thumb_m", files.m), ("thumb_xl", files.xl)] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
            body.append(data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    private static func idArray(_ ids: [Int64]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
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
        try await fullImage(resource, etag: etag, lastModified: lastModified, progress: { _ in })
    }

    public func fullImage(
        _ resource: FullImageResource, etag: String? = nil, lastModified: String? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> FullImageResponse {
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
        request.timeoutInterval = 120
        request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        else if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let data: Data
        let response: URLResponse
        SynologyDiagnostics.transport.debug(
            "Sending original request unit_id=\(resource.unitID, privacy: .public) conditional=\(etag != nil || lastModified != nil, privacy: .public)"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let transfer = ProgressiveDataTransfer(
            allowedHost: baseURL.host ?? "", configuration: configuration, progress: progress
        )
        do {
            (data, response) = try await transfer.data(for: request)
        }
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

    public func videoRange(_ resource: VideoPlaybackResource,
                           range: ClosedRange<Int64>) async throws -> VideoRangeResponse {
        guard let sid else { throw SynologyAPIError.api(119) }
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
              range.upperBound - range.lowerBound < 8 * 1_024 * 1_024 else {
            throw SynologyAPIError.invalidResponse
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        switch resource.variant {
        case .original:
            components.path = "/webapi/entry.cgi"
            components.queryItems = [
                URLQueryItem(name: "api", value: "SYNO.Foto.Download"),
                URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "method", value: "download"),
                URLQueryItem(name: "unit_id", value: "[\(resource.unitID)]"),
                URLQueryItem(name: "cache_key", value: resource.cacheKey),
                URLQueryItem(name: "_sid", value: sid),
            ]
        case .converted(let quality):
            components.path = "/webapi/entry.cgi/SYNO.Foto.Streaming"
            components.queryItems = [
                URLQueryItem(name: "api", value: "SYNO.Foto.Streaming"),
                URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "method", value: "streaming"),
                URLQueryItem(name: "id", value: String(resource.unitID)),
                URLQueryItem(name: "type", value: "\"unit\""),
                URLQueryItem(name: "quality", value: "\"\(quality.rawValue)\""),
                URLQueryItem(name: "cache_key", value: resource.cacheKey),
                URLQueryItem(name: "_sid", value: sid),
            ]
        }
        if let synoToken { components.queryItems?.append(URLQueryItem(name: "SynoToken", value: synoToken)) }
        guard let url = components.url else { throw SynologyAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        request.setValue("video/*,application/octet-stream;q=0.8", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        let started = Date()
        SynologyDiagnostics.videoTransport.info(
            "Video range request started unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) lower=\(range.lowerBound, privacy: .public) upper=\(range.upperBound, privacy: .public)"
        )
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError {
            SynologyDiagnostics.videoTransport.debug(
                "Video range request cancelled unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) lower=\(range.lowerBound, privacy: .public) upper=\(range.upperBound, privacy: .public)"
            )
            throw CancellationError()
        }
        catch {
            let nsError = error as NSError
            SynologyDiagnostics.videoTransport.error(
                "Video range transport failed unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) lower=\(range.lowerBound, privacy: .public) upper=\(range.upperBound, privacy: .public) error_domain=\(nsError.domain, privacy: .public) error_code=\(nsError.code, privacy: .public)"
            )
            throw SynologyAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SynologyAPIError.invalidResponse }
        guard http.statusCode == 206,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let parsed = Self.parseContentRange(contentRange),
              parsed.range.lowerBound == range.lowerBound,
              parsed.range.upperBound <= range.upperBound,
              parsed.total > parsed.range.upperBound,
              data.count == Int(parsed.range.upperBound - parsed.range.lowerBound + 1),
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.hasPrefix("video/") || contentType.hasPrefix("application/octet-stream") else {
            SynologyDiagnostics.videoTransport.error(
                "Video range rejected unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) status=\(http.statusCode, privacy: .public) bytes=\(data.count, privacy: .public) content_range=\(http.value(forHTTPHeaderField: "Content-Range") ?? "nil", privacy: .public) content_type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "nil", privacy: .public)"
            )
            throw SynologyAPIError.invalidResponse
        }
        let elapsedMS = Int(Date().timeIntervalSince(started) * 1_000)
        SynologyDiagnostics.videoTransport.info(
            "Video range response accepted unit_id=\(resource.unitID, privacy: .public) quality=\(resource.variant.cacheComponent, privacy: .public) status=\(http.statusCode, privacy: .public) lower=\(parsed.range.lowerBound, privacy: .public) upper=\(parsed.range.upperBound, privacy: .public) bytes=\(data.count, privacy: .public) total=\(parsed.total, privacy: .public) elapsed_ms=\(elapsedMS, privacy: .public)"
        )
        return VideoRangeResponse(data: data, range: parsed.range, totalLength: parsed.total,
                                  contentType: contentType,
                                  etag: http.value(forHTTPHeaderField: "ETag"),
                                  lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }

    private static func parseContentRange(_ value: String) -> (range: ClosedRange<Int64>, total: Int64)? {
        let pieces = value.split(separator: " ", maxSplits: 1)
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let values = pieces[1].split(separator: "/", maxSplits: 1)
        let bounds = values.first?.split(separator: "-", maxSplits: 1)
        guard values.count == 2, bounds?.count == 2,
              let lower = bounds.flatMap({ Int64($0[0]) }),
              let upper = bounds.flatMap({ Int64($0[1]) }),
              let total = Int64(values[1]), lower <= upper else { return nil }
        return (lower...upper, total)
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
