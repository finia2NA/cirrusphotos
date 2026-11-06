import Foundation
import ImageIO
import UniformTypeIdentifiers

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

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (TransferProgress) -> Void
    init(progress: @escaping @Sendable (TransferProgress) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress(TransferProgress(completedBytes: totalBytesWritten, totalBytes: totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

public actor SynologyClient: PhotosTransport {
    private let baseURL: URL
    private let session: URLSession
    private let trustDelegate: CirrusTrustDelegate?
    private var sid: String?
    private var synoToken: String?
    /// Credentials that renew an expired session without user input; nil until signed in
    /// and after logout. A typed code is replaced by the trusted-device token it earned.
    private var renewal: SynologyCredentials?
    private var renewalTask: Task<Void, Error>?
    private var renewalFailureHandler: (@Sendable (SynologyAPIError) -> Void)?
    /// Increments with every new session, so concurrent expiries renew only once.
    private var sessionGeneration = 0

    public func uploadPhoto(at url: URL, destination: PhotoUploadDestination,
                            progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoUploadResult {
        let sid = try sessionID()
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.contains("\r"), !name.contains("\n"), !name.contains("\"") else {
            throw SynologyAPIError.unsupported("This filename cannot be uploaded.")
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .contentTypeKey])
        guard values.isRegularFile == true, values.contentType?.conforms(to: .image) == true else {
            throw SynologyAPIError.unsupported("Only local image files can be uploaded.")
        }
        let api: String
        let method: String
        let target: [(String, String)]
        switch destination {
        case .timeline(let space):
            api = Self.api("Upload.Item", space)
            method = "upload"
            target = [("uploadDestination", "\"timeline\""), ("folder", "[\"PhotoLibrary\"]")]
        case .album(let id):
            guard id > 0 else { throw SynologyAPIError.invalidResponse }
            api = "SYNO.Foto.Upload.Item"
            method = "upload"
            target = [("album_id", String(id)), ("folder", "[\"PhotoLibrary\"]")]
        case .folder(let id, let space):
            guard id > 0 else { throw SynologyAPIError.invalidResponse }
            api = Self.api("Upload.Item", space)
            method = "upload_to_folder"
            target = [("target_folder_id", String(id))]
        }
        let boundary = "SynoTimeline-\(UUID().uuidString)"
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw SynologyAPIError.invalidResponse }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let mime = values.contentType?.preferredMIMEType ?? "application/octet-stream"
        let modified = Int64((values.contentModificationDate ?? Date()).timeIntervalSince1970)
        let preparation = Task.detached(priority: .utility) {
          let output = try FileHandle(forWritingTo: temporary)
          do {
            func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
            func field(_ key: String, _ value: String) throws {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
            }
            try field("api", api); try field("method", method); try field("version", "8")
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try write("\r\n")
            for (key, value) in target { try field(key, value) }
            try field("duplicate", "\"ignore\"")
            let encodedName = String(data: try JSONEncoder().encode(name), encoding: .utf8)!
            try field("name", encodedName)
            try field("mtime", String(modified))
            try write("--\(boundary)--\r\n")
            try output.close()
          } catch {
            try? output.close()
            throw error
          }
        }
        try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/entry.cgi/\(api)"
        components.queryItems = [URLQueryItem(name: "api", value: api), URLQueryItem(name: "method", value: method), URLQueryItem(name: "version", value: "8")]
        guard let requestURL = components.url else { throw SynologyAPIError.invalidResponse }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        if let synoToken { request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN") }
        let (data, response) = try await session.upload(for: request, fromFile: temporary, delegate: UploadTransferDelegate(progress: progress))
        guard let http = response as? HTTPURLResponse else { throw SynologyAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SynologyAPIError.http(http.statusCode) }
        let envelope = try JSONDecoder().decode(APIEnvelope<PhotoUploadResult>.self, from: data)
        guard envelope.success else { throw SynologyAPIError.api(envelope.error?.code ?? -1) }
        guard let result = envelope.data, ["new", "ignore"].contains(result.action), result.id > 0, result.unitID > 0 else { throw SynologyAPIError.invalidResponse }
        return result
    }

    public init(credentials: SynologyCredentials) throws {
        guard let serverURL = credentials.serverURL else {
            throw SynologyAPIError.configuration("The credentials do not name a NAS URL.")
        }
        self.init(baseURL: serverURL, trust: credentials.serverTrust)
    }

    public init(baseURL: URL, trust: ServerTrust = .system) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage()
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 30
        // Request timeouts are inactivity timeouts and reset as data moves. Keep a
        // generous absolute cap so large originals are not killed while progressing.
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let delegate = CirrusTrustDelegate(allowedHost: baseURL.host ?? "", trust: trust)
        self.trustDelegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    init(baseURL: URL, session: URLSession) {
        self.baseURL = baseURL
        self.session = session
        self.trustDelegate = nil
    }

    public func login(credentials: SynologyCredentials) async throws {
        try await signIn(credentials)
    }

    /// Signs in and keeps what is needed to renew the session when DSM expires it.
    /// The returned device token lets later logins skip the code.
    @discardableResult
    public func signIn(_ credentials: SynologyCredentials) async throws -> SignInResult {
        let result = try await authenticate(credentials)
        if case .code = credentials.secondFactor, let token = result.deviceToken {
            renewal = SynologyCredentials(username: credentials.username, password: credentials.password,
                                          secondFactor: .deviceToken(token), serverURL: credentials.serverURL,
                                          serverTrust: credentials.serverTrust)
        } else if case .code = credentials.secondFactor {
            renewal = nil
        } else {
            renewal = credentials
        }
        return result
    }

    public func onSessionRenewalFailure(_ handler: @escaping @Sendable (SynologyAPIError) -> Void) async {
        renewalFailureHandler = handler
    }

    /// Ends the DSM session. Failures are ignored: the session expires on its own.
    public func logout() async {
        renewal = nil
        renewalTask?.cancel()
        renewalTask = nil
        guard let sid else { return }
        let _: APIEnvelope<EmptyData>? = try? await post(
            path: "/webapi/entry.cgi",
            parameters: ["api": "SYNO.API.Auth", "version": "6", "method": "logout", "session": "webui", "_sid": sid],
            authenticated: true)
        self.sid = nil
        synoToken = nil
    }

    static let deviceName = "Cirrus Photos"

    private func authenticate(_ credentials: SynologyCredentials) async throws -> SignInResult {
        for attempt in 0...1 {
            var parameters = [
                "api": "SYNO.API.Auth", "version": "6", "method": "login",
                "account": credentials.username, "passwd": credentials.password,
                "session": "webui", "format": "sid",
                "enable_syno_token": "yes", "enable_device_token": "no",
                "device_name": Self.deviceName
            ]
            switch credentials.secondFactor {
            case .none:
                break
            case .totpSecret(let secret):
                parameters["otp_code"] = try TOTP.generate(secret: secret)
            case .code(let code):
                parameters["otp_code"] = code
                parameters["enable_device_token"] = "yes"
            case .deviceToken(let token):
                parameters["device_id"] = token
                parameters["enable_device_token"] = "yes"
            }
            let response: APIEnvelope<LoginData> = try await post(
                path: "/webapi/entry.cgi",
                parameters: parameters, authenticated: false
            )
            if response.success, let data = response.data {
                sid = data.sid
                synoToken = data.synoToken
                sessionGeneration &+= 1
                return SignInResult(deviceToken: data.did.flatMap { $0.isEmpty ? nil : $0 })
            }
            let code = response.error?.code ?? -1
            switch (credentials.secondFactor, code) {
            case (.none, 403), (.deviceToken, 403):
                // No code, or DSM no longer trusts this device.
                throw SynologyAPIError.secondFactorRequired
            case (.totpSecret, 403), (.totpSecret, 404) where attempt == 0:
                // DSM rejects a TOTP already used by a previous session. Retry once with a fresh window.
                let remainder = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
                try await Task.sleep(for: .seconds(31 - remainder))
            default:
                throw SynologyAPIError.api(code)
            }
        }
        throw SynologyAPIError.api(404)
    }

    /// Renews an expired session once for all requests that saw it expire.
    private func renewSession(expiredGeneration: Int) async throws {
        guard sessionGeneration == expiredGeneration else { return }
        if let renewalTask { return try await renewalTask.value }
        guard let renewal else { throw SynologyAPIError.api(119) }
        let task = Task { _ = try await self.authenticate(renewal) }
        renewalTask = task
        defer { renewalTask = nil }
        do {
            try await task.value
            SynologyDiagnostics.authentication.info("Renewed an expired DSM session")
        } catch let error as SynologyAPIError {
            if case .transport = error { throw error }
            self.renewal = nil
            renewalFailureHandler?(error)
            throw error
        }
    }

    public func downloadIncomingPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, reference: String,
                                       progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        guard !reference.isEmpty else { throw SynologyAPIError.invalidResponse }
        return try await downloadPhotos(itemIDs: itemIDs, kind: kind, reference: reference, space: .personal, progress: progress)
    }

    public func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, space: PhotoSpace,
                               progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        try await downloadPhotos(itemIDs: itemIDs, kind: kind, reference: nil, space: space, progress: progress)
    }

    private func downloadPhotos(itemIDs: [Int64], kind: PhotoDownloadKind, reference: String?, space: PhotoSpace,
                                progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> PhotoDownloadResponse {
        let sid = try sessionID()
        guard !itemIDs.isEmpty else { throw SynologyAPIError.invalidResponse }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/entry.cgi"
        guard let url = components.url else { throw SynologyAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        if let synoToken { request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN") }
        var parameters = ["api": Self.api("Download", space), "version": "2", "method": "download",
                                    "force_download": "true", "item_id": "[\(itemIDs.map(String.init).joined(separator: ","))]",
                                    "download_type": "\"\(kind.rawValue)\"", "_sid": sid]
        if let reference { parameters["passphrase"] = String(decoding: try JSONEncoder().encode(reference), as: UTF8.self) }
        request.httpBody = formBody(parameters)
        let (temporary, response) = try await session.download(for: request, delegate: DownloadProgressDelegate(progress: progress))
        guard let http = response as? HTTPURLResponse else { throw SynologyAPIError.invalidResponse }
        guard http.statusCode == 200 else { throw SynologyAPIError.http(http.statusCode) }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard !contentType.contains("json"), !contentType.contains("text/html"),
              http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true,
              let suggested = response.suggestedFilename else { throw SynologyAPIError.invalidResponse }
        let filename = URL(fileURLWithPath: suggested).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { throw SynologyAPIError.invalidResponse }
        let file = try FileHandle(forReadingFrom: temporary)
        let prefix = try file.read(upToCount: 32) ?? Data()
        try file.close()
        guard !prefix.isEmpty else { throw SynologyAPIError.invalidResponse }
        if itemIDs.count > 1 {
            guard prefix.starts(with: [0x50, 0x4b, 0x03, 0x04]) || prefix.starts(with: [0x50, 0x4b, 0x05, 0x06]),
                  try PhotoDownloadValidation.hasCompleteZIPTrailer(at: temporary) else { throw SynologyAPIError.invalidResponse }
        } else if let text = String(data: prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.hasPrefix("{") || text.lowercased().hasPrefix("<!doctype html") {
            throw SynologyAPIError.invalidResponse
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return PhotoDownloadResponse(temporaryURL: destination, filename: filename)
    }

    public func collectionDayCatalog(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> CollectionDayCatalog {
        guard !collection.isSessionDerived else { throw SynologyAPIError.unsupported("Session collections have no server timeline.") }
        let sections = try await fetchTimelineSections(collection: collection, initial: initial)
        return try CollectionDayCatalog(sections: sections, completeness: initial ? .partial : .complete)
    }

    public func readAlbumCatalogBatch(albumID: Int64, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        guard offset >= 0, limit > 0, limit <= 1000 else { throw SynologyAPIError.invalidResponse }
        let data: ItemData = try await call("SYNO.Foto.Browse.Item", version: 7, method: "list", [
            "offset": String(offset), "limit": String(limit), "album_id": String(albumID),
            "sort_by": "\"takentime\"", "sort_direction": "\"desc\"", "additional": "[]"])
        return data.list.map { DayTimelineEntry(id: $0.id, time: $0.time) }
    }

    public func readIncomingAlbumCatalogBatch(reference: String, offset: Int, limit: Int) async throws -> [DayTimelineEntry] {
        guard !reference.isEmpty, offset >= 0, limit > 0, limit <= 1000 else { throw SynologyAPIError.invalidResponse }
        let data: ItemData = try await call("SYNO.Foto.Browse.Item", version: 7, method: "list", [
            "passphrase": try Self.jsonString(reference), "offset": String(offset), "limit": String(limit),
            "sort_by": "\"takentime\"", "sort_direction": "\"desc\"", "additional": "[]"])
        return data.list.map { DayTimelineEntry(id: $0.id, time: $0.time) }
    }

    public func readIncomingCollectionBatch(_ request: CollectionPageRequest, reference: String, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        guard !reference.isEmpty, request.collection.incomingAlbumIdentity != nil else { throw SynologyAPIError.invalidResponse }
        var parameters = ["passphrase": try Self.jsonString(reference),
                          "offset": String(request.offset), "limit": String(request.limit),
                          "start_time": String(request.oldestDay.startTime), "end_time": String(request.newestDay.endTime),
                          "additional": Self.additionalParameter(for: fields.additional)]
        if request.order == .takenTimeDescending {
            parameters["sort_by"] = "\"takentime\""; parameters["sort_direction"] = "\"desc\""
        }
        let data: ItemData = try await call("SYNO.Foto.Browse.Item", version: 7, method: "list", parameters)
        return CollectionBatchResult(items: data.list, profile: fields)
    }

    public func readFolderCatalogBatch(folderID: Int64, offset: Int, limit: Int, space: PhotoSpace) async throws -> [DayTimelineEntry] {
        guard offset >= 0, limit > 0, limit <= 1000 else { throw SynologyAPIError.invalidResponse }
        let data: ItemData = try await call(Self.api("Browse.Item", space), version: 7, method: "list", [
            "offset": String(offset), "limit": String(limit), "folder_id": String(folderID),
            "sort_by": "\"takentime\"", "sort_direction": "\"desc\"", "additional": "[]"])
        return data.list.map { DayTimelineEntry(id: $0.id, time: $0.time) }
    }

    public func collectionIndex(_ kind: CollectionIndexKind, space: PhotoSpace) async throws -> [CollectionIndexEntry] {
        let api: String, version: Int, filters: [String: String]
        switch kind {
        case .person: (api, version, filters) = (Self.api("Browse.Person", space), 1, ["show_more": "true", "show_hidden": "false"])
        case .subject: (api, version, filters) = (Self.api("Browse.Concept", space), 2, ["show_hidden": "false"])
        case .tag: (api, version, filters) = (Self.api("Browse.GeneralTag", space), 2, [:])
        }
        struct List: Decodable { let list: [CollectionIndexEntry] }
        struct Count: Decodable { let count: Int }
        // The count is read before and after paging so a concurrent change fails the read.
        func count() async throws -> Int {
            let data: Count = try await call(api, version: version, method: "count", filters)
            guard data.count >= 0, data.count <= 204_800 else { throw SynologyAPIError.invalidResponse }
            return data.count
        }
        let expectedCount = try await count()
        var result: [CollectionIndexEntry] = []; var seen: Set<Int64> = []
        for page in 0..<2048 {
            let data: List = try await call(api, version: version, method: "list", filters.merging([
                "offset": String(page * 100), "limit": "100", "additional": "[\"thumbnail\"]"]) { _, new in new },
                decoder: CollectionIndexEntry.decoder(for: kind))
            let rows = data.list
            guard rows.count <= 100 else { throw SynologyAPIError.invalidResponse }
            for row in rows { guard row.id > 0, row.itemCount >= 0, seen.insert(row.id).inserted else { throw SynologyAPIError.invalidResponse } }
            result.append(contentsOf: rows)
            if rows.count < 100 {
                guard result.count == expectedCount, try await count() == expectedCount else { throw SynologyAPIError.invalidResponse }
                return result
            }
        }
        throw CollectionCatalogError.exceedsLimit
    }

    public func suggestPeople(prefix: String, space: PhotoSpace) async throws -> [CollectionIndexEntry] {
        guard !prefix.isEmpty else { throw SynologyAPIError.invalidResponse }
        struct List: Decodable { let list: [CollectionIndexEntry] }
        let data: List = try await call(Self.api("Browse.Person", space), version: 3, method: "suggest",
            ["name_prefix": prefix, "limit": "10", "additional": "[\"thumbnail\"]"],
            decoder: CollectionIndexEntry.decoder(for: .person))
        let list = data.list
        guard list.count <= 10, list.allSatisfy({ $0.id > 0 && $0.itemCount >= 0 }), Set(list.map(\.id)).count == list.count else {
            throw SynologyAPIError.invalidResponse
        }
        return list
    }

    public func renamePerson(id: Int64, name: String, space: PhotoSpace) async throws -> CollectionIndexEntry {
        try await personMutation(method: "set", version: 1, targetID: id, sourceID: nil, name: name, space: space)
    }

    public func mergePerson(sourceID: Int64, targetID: Int64, name: String, space: PhotoSpace) async throws -> CollectionIndexEntry {
        guard sourceID > 0, sourceID != targetID else { throw SynologyAPIError.invalidResponse }
        return try await personMutation(method: "merge", version: 2, targetID: targetID, sourceID: sourceID, name: name, space: space)
    }

    private func personMutation(method: String, version: Int, targetID: Int64, sourceID: Int64?, name: String, space: PhotoSpace) async throws -> CollectionIndexEntry {
        guard targetID > 0 else { throw SynologyAPIError.invalidResponse }
        var parameters = ["name": try Self.jsonString(name)]
        if let sourceID {
            parameters["target_id"] = String(targetID)
            parameters["merged_id"] = Self.idArray([sourceID])
        } else { parameters["id"] = String(targetID) }
        let person: CollectionIndexEntry = try await call(Self.api("Browse.Person", space), version: version, method: method, parameters,
                                                          decoder: CollectionIndexEntry.decoder(for: .person))
        guard person.id == targetID, person.name == name, person.itemCount >= 0 else { throw SynologyAPIError.invalidResponse }
        return person
    }

    public func folder(id: Int64, space: PhotoSpace) async throws -> FolderSummary {
        struct Result: Decodable { let folder: FolderSummary }
        let data: Result = try await call(Self.api("Browse.Folder", space), version: 2, method: "get", ["id": String(id), "additional": "[]"])
        guard data.folder.id > 0, id == 0 || data.folder.id == id else { throw SynologyAPIError.invalidResponse }
        return data.folder
    }

    public func folders(parentID: Int64, space: PhotoSpace) async throws -> [FolderSummary] {
        struct Result: Decodable { let list: [FolderSummary] }
        guard parentID > 0 else { throw SynologyAPIError.invalidResponse }
        var result: [FolderSummary] = []; var seen: Set<Int64> = []
        for page in 0..<2048 {
            let data: Result = try await call(Self.api("Browse.Folder", space), version: 2, method: "list", [
                "id": String(parentID), "offset": String(page * 200), "limit": "200",
                "sort_by": "\"filename\"", "sort_direction": "\"asc\"", "additional": "[\"thumbnail\"]"])
            let rows = data.list
            guard rows.count <= 200 else { throw SynologyAPIError.invalidResponse }
            for row in rows { guard row.id > 0, row.id != parentID, row.parent == parentID, seen.insert(row.id).inserted else { throw SynologyAPIError.invalidResponse } }
            result.append(contentsOf: rows)
            if rows.count < 200 { return result }
        }
        throw CollectionCatalogError.exceedsLimit
    }

    public func readCollectionBatch(_ request: CollectionPageRequest, fields: ItemFieldProfile) async throws -> CollectionBatchResult {
        guard !request.collection.isSessionDerived else { throw SynologyAPIError.invalidResponse }
        // Album collections have no space; they read through the Foto endpoint with their album ID.
        let space = request.collection.space ?? .personal
        var parameters = ["offset": String(request.offset), "limit": String(request.limit),
                          "start_time": String(request.oldestDay.startTime), "end_time": String(request.newestDay.endTime),
                          "additional": Self.additionalParameter(for: fields.additional)]
        if request.collection.favoriteOnly { parameters["favorite_only"] = "true" }
        if let albumID = request.collection.albumID { parameters["album_id"] = String(albumID) }
        if let folderID = request.collection.folderID { parameters["folder_id"] = String(folderID) }
        if let personID = request.collection.personID { parameters["person_id"] = String(personID) }
        if let subjectID = request.collection.subjectID { parameters["concept_id"] = String(subjectID) }
        if let tagID = request.collection.tagID { parameters["general_tag_id"] = String(tagID) }
        if request.order == .takenTimeDescending {
            parameters["sort_by"] = "\"takentime\""; parameters["sort_direction"] = "\"desc\""
        }
        let data: ItemData = request.collection == .recentlyAdded
            ? try await call("SYNO.Foto.Browse.RecentlyAdded", version: 6, method: "list", parameters)
            : try await call(Self.api("Browse.Item", space), version: 7, method: "list", parameters)
        return CollectionBatchResult(items: data.list, profile: fields)
    }

    private func fetchTimelineSections(collection: PhotoCollectionDescriptor, initial: Bool) async throws -> [TimelineSection] {
        guard !collection.usesItemCatalog else {
            throw SynologyAPIError.unsupported("Albums use bounded item catalog enumeration.")
        }
        guard !initial || collection.supportsInitialTimeline else {
            throw SynologyAPIError.unsupported("Favorites does not support the initial timeline endpoint.")
        }
        var parameters = ["timeline_group_unit": "\"day\""]
        if collection.favoriteOnly { parameters["favorite_only"] = "true" }
        if let personID = collection.personID { parameters["person_id"] = String(personID) }
        if let subjectID = collection.subjectID { parameters["concept_id"] = String(subjectID) }
        if let tagID = collection.tagID { parameters["general_tag_id"] = String(tagID) }
        let data: TimelineData = collection == .recentlyAdded
            ? try await call("SYNO.Foto.Browse.RecentlyAdded", version: 6, method: "get_timeline", parameters)
            : try await call(Self.api("Browse.Timeline", collection.space ?? .personal), version: 6,
                             method: initial ? "get_init_timeline" : "get", parameters)
        return data.section
    }

    public func userProfiles(ids: [Int64]) async throws -> [PhotosUserProfile] {
        guard !ids.isEmpty, ids.count <= 32 else { throw SynologyAPIError.invalidResponse }
        struct ProfileList: Decodable { let list: [PhotosUserProfile] }
        let data: ProfileList = try await call("SYNO.Foto.UserInfo", version: 1, method: "get", ["id": Self.idArray(ids)])
        return data.list
    }

    public func profilePhoto(descriptor: String) async throws -> Data {
        let sid = try sessionID()
        guard !descriptor.isEmpty, descriptor.utf8.count <= 1024 else { throw SynologyAPIError.invalidResponse }
        guard let source = URLComponents(string: descriptor), source.scheme == nil, source.host == nil,
              source.path == "webapi/entry.cgi" || source.path == "/webapi/entry.cgi" else { throw SynologyAPIError.invalidResponse }
        let items = source.queryItems ?? []
        func single(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            return values.count == 1 ? values[0].value : nil
        }
        guard single("api") == "SYNO.Personal.Profile.Photo", single("method") == "get",
              single("version") == "1", let filename = single("f"), !filename.isEmpty else { throw SynologyAPIError.invalidResponse }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/entry.cgi"
        components.queryItems = [URLQueryItem(name: "api", value: "SYNO.Personal.Profile.Photo"),
            URLQueryItem(name: "version", value: "1"), URLQueryItem(name: "method", value: "get"),
            URLQueryItem(name: "f", value: filename)]
        if let synoToken { components.queryItems?.append(URLQueryItem(name: "SynoToken", value: synoToken)) }
        guard let url = components.url else { throw SynologyAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        if let synoToken { request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/png") == true,
              data.count <= 2_000_000, !data.isEmpty else { throw SynologyAPIError.invalidResponse }
        return data
    }

    public func albums() async throws -> [AlbumSummary] {
        try await albumList("SYNO.Foto.Browse.Album", version: 4, category: "normal")
    }

    private func albumList(_ api: String, version: Int, category: String) async throws -> [AlbumSummary] {
        let pageLimit = 100
        var collected: [AlbumSummary] = []
        var offset = 0
        while true {
            let data: AlbumListData = try await call(api, version: version, method: "list", [
                "offset": String(offset), "limit": String(pageLimit),
                "category": "\"\(category)\"", "sort_by": "\"album_name\"", "sort_direction": "\"asc\"",
                "additional": "[\"sharing_info\",\"thumbnail\"]"])
            collected.append(contentsOf: data.list)
            guard data.list.count == pageLimit else { break }
            offset += pageLimit
        }
        return collected
    }

    public func incomingAlbums() async throws -> [IncomingAlbum] {
        struct DataList: Decodable { let list: [IncomingAlbum] }
        var albums: [IncomingAlbum] = []
        var seen = Set<Int64>()
        for page in 0..<2048 {
            let data: DataList = try await call("SYNO.Foto.Sharing.Misc", version: 2, method: "list_shared_with_me_album", [
                "offset": String(page * 50), "limit": "50", "sort_by": "\"share_modify_time\"",
                "sort_direction": "\"desc\"", "additional": "[\"sharing_info\",\"thumbnail\",\"access_permission\"]"])
            guard data.list.count <= 50 else { throw SynologyAPIError.invalidResponse }
            for entry in data.list {
                guard entry.summary.id > 0, seen.insert(entry.summary.id).inserted else { throw SynologyAPIError.invalidResponse }
                albums.append(entry)
            }
            if data.list.count < 50 { return albums }
        }
        throw CollectionCatalogError.exceedsLimit
    }

    public func addableAlbums() async throws -> [AlbumSummary] {
        try await albumList("SYNO.Foto.Browse.NormalAlbum", version: 2, category: "addable")
    }

    public func album(id: Int64) async throws -> AlbumSummary {
        let data: AlbumListData = try await call("SYNO.Foto.Browse.Album", version: 4, method: "get", [
            "id": Self.idArray([id]), "additional": "[\"sharing_info\",\"flex_section\",\"provider_count\",\"thumbnail\"]"])
        guard data.list.count == 1, data.list[0].id == id else { throw SynologyAPIError.invalidResponse }
        return data.list[0]
    }

    public func currentPhotosUserID() async throws -> Int64 {
        struct CurrentUser: Decodable { let id: Int64 }
        let user: CurrentUser = try await call("SYNO.Foto.UserInfo", version: 1, method: "me")
        return user.id
    }

    public func sharingPrincipals() async throws -> [SharingPrincipal] {
        struct List: Decodable { let list: [SharingPrincipal] }
        let data: List = try await call("SYNO.Foto.Sharing.Misc", version: 1, method: "list_user_group", ["team_space_sharable_list": "false"])
        return data.list
    }

    public func setAlbumShared(id: Int64, enabled: Bool) async throws -> AlbumSharingReference {
        try await call("SYNO.Foto.Sharing.Passphrase", version: 1, method: "set_shared", [
            "policy": "\"album\"", "album_id": String(id), "enabled": enabled ? "true" : "false"])
    }

    public func updateAlbumSharing(reference: String, changes: [SharingPermissionChange], password: SharingPasswordChange, expiration: Int64?) async throws {
        guard !reference.isEmpty else { throw SynologyAPIError.invalidResponse }
        var parameters = ["passphrase": try Self.jsonString(reference),
                          "permission": String(decoding: try JSONEncoder().encode(changes), as: UTF8.self)]
        if let expiration { parameters["expiration"] = String(expiration) }
        switch password {
        case .unchanged: break
        case .set(let value): parameters["password"] = try Self.jsonString(value)
        case .clear: parameters["password"] = "\"\""
        }
        try await perform("SYNO.Foto.Sharing.Passphrase", version: 1, method: "update", parameters)
    }

    public func createAlbum(name: String, itemIDs: [Int64]) async throws -> AlbumSummary {
        let data = try await albumMutation(method: "create", parameters: ["name": try Self.jsonString(name), "item": Self.idArray(itemIDs)], requireData: true)
        guard let album = data?.album else { throw SynologyAPIError.invalidResponse }
        return album
    }

    public func deleteAlbum(id: Int64) async throws {
        try await perform("SYNO.Foto.Browse.Album", version: 1, method: "delete", ["id": Self.idArray([id])])
    }

    public func renameAlbum(id: Int64, name: String) async throws {
        try await perform("SYNO.Foto.Browse.Album", version: 1, method: "set_name", ["id": String(id), "name": try Self.jsonString(name)])
    }

    public func addItems(_ itemIDs: [Int64], toAlbum id: Int64) async throws {
        _ = try await albumMutation(method: "add_item", parameters: ["id": String(id), "item": Self.idArray(itemIDs)], requireData: true)
    }

    public func addItems(_ itemIDs: [Int64], toSharedAlbumReference reference: String) async throws {
        guard !reference.isEmpty, !itemIDs.isEmpty else { throw SynologyAPIError.invalidResponse }
        _ = try await albumMutation(method: "add_item", parameters: ["passphrase": try Self.jsonString(reference), "item": Self.idArray(itemIDs)], requireData: true)
    }

    public func removeItems(_ itemIDs: [Int64], fromAlbum id: Int64) async throws {
        _ = try await albumMutation(method: "delete_item", parameters: ["id": String(id), "item": Self.idArray(itemIDs)], requireData: false)
    }

    private func albumMutation(method: String, parameters: [String: String], requireData: Bool) async throws -> AlbumMutationData? {
        let response: APIEnvelope<AlbumMutationData> = try await request("SYNO.Foto.Browse.NormalAlbum", version: 1, method: method, parameters)
        guard response.success else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        if requireData && response.data?.errorList == nil { throw SynologyAPIError.invalidResponse }
        if let errors = response.data?.errorList, !errors.isEmpty { throw SynologyAPIError.unsupported("The album change was incomplete. Refresh and try again.") }
        return response.data
    }

    public func readPersonalInventoryBatch(offset: Int, limit: Int) async throws -> [PhotoItem] {
        let data: ItemData = try await call("SYNO.Foto.Browse.Item", version: 7, method: "list", [
            "offset": String(offset), "limit": String(limit),
            "additional": Self.additionalParameter(for: PhotosRequestFields.locationScanAdditional)])
        return data.list
    }

    public func diffVersion(space: PhotoSpace) async throws -> DiffCursor {
        let data: DiffVersionData = try await call(Self.api("Browse.Diff", space), version: 7, method: "get_version",
                                                   maximumBytes: Self.diffResponseLimit)
        return data.cursor
    }

    private static let diffResponseLimit = 4 * 1_024 * 1_024

    public func changes(since cursor: DiffCursor, space: PhotoSpace) async throws -> PhotoDiff {
        let data: PhotoDiffData = try await call(Self.api("Browse.Diff", space), version: 7, method: "list", [
            "geocoding_accept_language": "enu", "additional": Self.additionalParameter(),
            "diff_version": String(cursor.diffVersion), "version_time": String(cursor.versionTime)],
            maximumBytes: Self.diffResponseLimit)
        return data.value
    }

    public func userEvents(since cursor: DiffCursor) async throws -> UserEventDiff {
        let data: UserEventDiffData = try await call("SYNO.Foto.Browse.Diff", version: 7, method: "list_user_event", [
            "diff_version": String(cursor.diffVersion), "version_time": String(cursor.versionTime)],
            maximumBytes: Self.diffResponseLimit)
        return data.value
    }

    private static func additionalParameter(
        for fields: [String] = PhotosRequestFields.pageAdditional
    ) -> String {
        "[" + fields.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    public func setFavorite(itemIDs: [Int64], favorite: Bool, space: PhotoSpace) async throws {
        guard !itemIDs.isEmpty else { return }
        try await perform(Self.api("Browse.Item", space), version: 7, method: "set_favorite", [
            "id": Self.idArray(itemIDs), "favorite": favorite ? "true" : "false"])
    }

    /// Sets the star rating (0 clears it) of items in one space.
    public func setRating(itemIDs: [Int64], rating: Int, space: PhotoSpace) async throws {
        guard !itemIDs.isEmpty else { return }
        guard (0...PhotoAnnotations.maximumRating).contains(rating) else { throw SynologyAPIError.invalidResponse }
        let response: APIEnvelope<ItemWriteResult> = try await request(Self.api("Browse.Item", space), version: 7, method: "set", [
            "id": Self.idArray(itemIDs), "rating": String(rating)])
        guard response.success else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        guard response.data?.errorList.isEmpty == true else { throw SynologyAPIError.invalidResponse }
    }

    /// Creates a tag, or returns the existing tag of that name: the server treats a
    /// duplicate name as idempotent and rejects an empty name.
    public func createTag(name: String, space: PhotoSpace) async throws -> PhotoTag {
        struct Created: Decodable { let tag: PhotoTag }
        let created: Created = try await call(Self.api("Browse.GeneralTag", space), version: 2, method: "create", [
            "name": try Self.jsonString(name)])
        guard created.tag.id > 0, !created.tag.name.isEmpty else { throw SynologyAPIError.invalidResponse }
        return created.tag
    }

    public func addTags(_ tagIDs: [Int64], toItems itemIDs: [Int64], space: PhotoSpace) async throws {
        try await writeTags("add_tag", tagIDs, itemIDs, space)
    }

    public func removeTags(_ tagIDs: [Int64], fromItems itemIDs: [Int64], space: PhotoSpace) async throws {
        try await writeTags("remove_tag", tagIDs, itemIDs, space)
    }

    /// `error_list` names the items that were not changed (it also names every item for
    /// an unknown tag). An unknown item ID is silently ignored by the server.
    private func writeTags(_ method: String, _ tagIDs: [Int64], _ itemIDs: [Int64], _ space: PhotoSpace) async throws {
        guard !itemIDs.isEmpty, !tagIDs.isEmpty else { return }
        let response: APIEnvelope<ItemWriteResult> = try await request(Self.api("Browse.Item", space), version: 7, method: method, [
            "id": Self.idArray(itemIDs), "tag": Self.idArray(tagIDs)])
        guard response.success else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        guard response.data?.errorList.isEmpty == true else { throw SynologyAPIError.invalidResponse }
    }

    /// Submits a library deletion and waits for the background task to finish.
    /// Task `done` only means the NAS processed the request: unknown IDs and IDs
    /// from the other space also finish with `error` 0, so callers must verify
    /// absence themselves. Both spaces share `SYNO.Foto.BackgroundTask.Info`.
    public func deleteItems(_ itemIDs: [Int64], space: PhotoSpace) async throws {
        guard !itemIDs.isEmpty else { return }
        let submission: BackgroundTaskSubmission = try await call(Self.api("BackgroundTask.File", space), version: 1, method: "delete", [
            "item_id": Self.idArray(itemIDs), "folder_id": "[]"])
        let task = submission.taskInfo
        for attempt in 0..<Self.deletionStatusPolls {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(500)) }
            let status: BackgroundTaskList = try await call("SYNO.Foto.BackgroundTask.Info", version: 1, method: "get_status", [
                "id": Self.idArray([task.id])])
            guard let current = status.list.first(where: { $0.id == task.id }) else { throw SynologyAPIError.invalidResponse }
            guard current.error == 0 else { throw SynologyAPIError.unsupported("The server reported an error while deleting.") }
            if current.status == "done" { return }
        }
        throw SynologyAPIError.unsupported("The server has not finished deleting yet.")
    }

    private static let deletionStatusPolls = 60

    public func items(ids: [Int64], space: PhotoSpace) async throws -> [PhotoItem] {
        guard !ids.isEmpty, ids.count <= 1_000 else {
            throw SynologyAPIError.unsupported("Item lookup requires 1–1000 item IDs.")
        }
        let data: ItemData = try await call(Self.api("Browse.Item", space), version: 7, method: "get", [
            "id": Self.idArray(ids), "additional": Self.additionalParameter()])
        return data.list
    }

    public func albumItems(ids: [Int64], albumID: Int64) async throws -> [PhotoItem] {
        guard albumID > 0, !ids.isEmpty, ids.count <= 1_000 else { throw SynologyAPIError.invalidResponse }
        let data: ItemData = try await call("SYNO.Foto.Browse.Item", version: 7, method: "get", [
            "id": Self.idArray(ids), "album_id": String(albumID), "additional": Self.additionalParameter()])
        return data.list
    }

    public func incomingItems(ids: [Int64], reference: String) async throws -> [PhotoItem] {
        guard !reference.isEmpty, !ids.isEmpty, ids.count <= 1_000 else { throw SynologyAPIError.invalidResponse }
        let data: ItemData = try await call("SYNO.Foto.Browse.Item", version: 7, method: "get", [
            "id": Self.idArray(ids), "passphrase": try Self.jsonString(reference), "additional": Self.additionalParameter()])
        return data.list
    }

    public func rotate(itemIDs: [Int64], direction: PhotoRotationDirection, space: PhotoSpace) async throws {
        guard !itemIDs.isEmpty else { return }
        let response: APIEnvelope<ItemSetData> = try await request(Self.api("Browse.Item", space), version: 7, method: "set", [
            "id": Self.idArray(itemIDs), "rotate_action": direction.rawValue])
        guard response.success else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        guard response.data?.errorList.isEmpty == true else { throw SynologyAPIError.invalidResponse }
    }

    public func setRegenerating(itemIDs: [Int64], space: PhotoSpace) async throws -> [RegeneratingThumbnailUnit] {
        guard !itemIDs.isEmpty else { return [] }
        SynologyDiagnostics.rotationTransport.info(
            "Sending set_regenerating item_count=\(itemIDs.count, privacy: .public) first_item_id=\(itemIDs.first ?? -1, privacy: .public) api_version=1"
        )
        let response: APIEnvelope<RegeneratingData>
        do {
            response = try await request(Self.api("RegeneratePreview", space), version: 1, method: "set_regenerating",
                                         ["item_id": Self.idArray(itemIDs)])
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

    public func restoreFromRegenerating(unitIDs: [Int64], space: PhotoSpace) async throws {
        guard !unitIDs.isEmpty else { return }
        SynologyDiagnostics.rotationTransport.info(
            "Sending restore_from_regenerating unit_count=\(unitIDs.count, privacy: .public) first_unit_id=\(unitIDs.first ?? -1, privacy: .public) api_version=1"
        )
        let response: APIEnvelope<EmptyData>
        do {
            response = try await request(Self.api("RegeneratePreview", space), version: 1, method: "restore_from_regenerating",
                                         ["unit_id": Self.idArray(unitIDs)])
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

    public func uploadConvertedThumbnails(
        unitID: Int64, files: ConvertedThumbnailFiles, space: PhotoSpace,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws {
        let sid = try sessionID()
        SynologyDiagnostics.rotationTransport.info(
            "Preparing converted thumbnail upload unit_id=\(unitID, privacy: .public) sm_bytes=\(files.sm.count, privacy: .public) m_bytes=\(files.m.count, privacy: .public) xl_bytes=\(files.xl.count, privacy: .public) api_version=3"
        )
        let boundary = "SynoTimeline-\(UUID().uuidString)"
        let body = Self.convertedThumbnailMultipartBody(
            boundary: boundary, unitID: unitID, files: files, space: space
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
        boundary: String, unitID: Int64, files: ConvertedThumbnailFiles, space: PhotoSpace
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        // Match Synology's desktop converter and the confirmed live probe exactly.
        // Authentication is carried by the cookie and X-SYNO-TOKEN header. The prior
        // variant added `_sid` and sorted these fields; that request received API error
        // 101, so keep this body byte-shape aligned with the confirmed working request.
        let fields = [
            ("api", Self.api("Upload.ConvertedFile", space)),
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

    public func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, space: PhotoSpace) async throws -> Data {
        try await thumbnail(descriptor, size: size, albumID: nil, reference: nil, space: space)
    }

    public func albumThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, albumID: Int64) async throws -> Data {
        guard albumID > 0 else { throw SynologyAPIError.invalidResponse }
        // Keep the album authority on both endpoint candidates. A successful image
        // establishes only this scoped rendition, never canonical item origin.
        do {
            return try await thumbnail(descriptor, size: size, albumID: albumID, reference: nil, space: .personal)
        } catch {
            try Task.checkCancellation()
            return try await thumbnail(descriptor, size: size, albumID: albumID, reference: nil, space: .shared)
        }
    }

    public func incomingThumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, reference: String) async throws -> Data {
        guard !reference.isEmpty else { throw SynologyAPIError.invalidResponse }
        return try await thumbnail(descriptor, size: size, albumID: nil, reference: reference, space: .personal)
    }

    private func thumbnail(_ descriptor: ThumbnailInfo, size: ThumbnailSize, albumID: Int64?, reference: String?,
                           space: PhotoSpace) async throws -> Data {
        let sid = try sessionID()
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = space == .shared ? "/synofoto/api/v2/t/Thumbnail/get" : "/synofoto/api/v2/p/Thumbnail/get"
        var parameters = [
            URLQueryItem(name: "id", value: String(descriptor.unitID)),
            URLQueryItem(name: "cache_key", value: "\"\(descriptor.cacheKey)\""),
            URLQueryItem(name: "type", value: "\"\(descriptor.kind ?? "unit")\""),
            URLQueryItem(name: "_sid", value: sid)
        ]
        if descriptor.kind != "person" { parameters.append(URLQueryItem(name: "size", value: "\"\(size.rawValue)\"")) }
        if let albumID { parameters.append(URLQueryItem(name: "album_id", value: String(albumID))) }
        if let reference {
            parameters.append(URLQueryItem(name: "passphrase", value: String(decoding: try JSONEncoder().encode(reference), as: UTF8.self)))
        }
        if let synoToken { parameters.append(URLQueryItem(name: "SynoToken", value: synoToken)) }
        components.queryItems = parameters
        guard let url = components.url else { throw SynologyAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            // URLSession errors may contain the request URL, including its sharing reference.
            if reference != nil { throw SynologyAPIError.transport("Shared thumbnail request failed.") }
            throw SynologyAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SynologyAPIError.invalidResponse }
        guard http.statusCode == 200 else { throw SynologyAPIError.http(http.statusCode) }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/") == true,
              PhotoDownloadValidation.containsImage(data) else {
            if let code = PhotoDownloadValidation.apiErrorCode(in: data) { throw SynologyAPIError.api(code) }
            throw SynologyAPIError.invalidResponse
        }
        return data
    }

    public func fullImage(_ resource: FullImageResource,
                          etag: String? = nil, lastModified: String? = nil) async throws -> MediaResponse {
        try await fullImage(resource, etag: etag, lastModified: lastModified, progress: { _ in })
    }

    public func fullImage(
        _ resource: FullImageResource, etag: String? = nil, lastModified: String? = nil,
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> MediaResponse {
        let space: PhotoSpace
        let albumID: Int64?
        switch resource.scope {
        case .space(let value): space = value; albumID = nil
        case .album(let id) where id > 0: space = .personal; albumID = id
        default: throw SynologyAPIError.unsupported("Media requests in this content context are unavailable.")
        }
        let sid = try sessionID()
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/entry.cgi"
        var parameters = [
            URLQueryItem(name: "api", value: Self.api("Download", space)),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "unit_id", value: "[\(resource.unitID)]"),
            URLQueryItem(name: "cache_key", value: resource.cacheKey),
            URLQueryItem(name: "_sid", value: sid)
        ]
        if let albumID { parameters.append(URLQueryItem(name: "album_id", value: String(albumID))) }
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
        configuration.protocolClasses = session.configuration.protocolClasses
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
            return MediaResponse(data: nil, etag: http.value(forHTTPHeaderField: "ETag"),
                                     lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        }
        guard http.statusCode == 200 else {
            SynologyDiagnostics.transport.error(
                "Original response rejected unit_id=\(resource.unitID, privacy: .public) status=\(http.statusCode, privacy: .public) content_type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "nil", privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            throw SynologyAPIError.http(http.statusCode)
        }
        guard PhotoDownloadValidation.containsImage(data) else {
            SynologyDiagnostics.transport.error(
                "Original response was not a decodable image unit_id=\(resource.unitID, privacy: .public) status=200 content_type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "nil", privacy: .public) bytes=\(data.count, privacy: .public)"
            )
            if let code = PhotoDownloadValidation.apiErrorCode(in: data) { throw SynologyAPIError.api(code) }
            throw SynologyAPIError.invalidResponse
        }
        SynologyDiagnostics.transport.info(
            "Original response unit_id=\(resource.unitID, privacy: .public) status=200 bytes=\(data.count, privacy: .public)"
        )
        return MediaResponse(data: data, etag: http.value(forHTTPHeaderField: "ETag"),
                                 lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
    }

    public func livePhotoMotion(itemID: Int64, space: PhotoSpace) async throws -> VideoPlaybackResource? {
        let data: LivePhotoUnitData = try await call(Self.api("Browse.Unit", space), version: 1, method: "get", [
            "id_item": Self.idArray([itemID]),
            "additional": Self.additionalParameter(for: ["orientation", "resolution", "thumbnail", "video_meta", "video_convert"])])
        guard data.list.count == 1, let group = data.list.first, group.itemID == itemID else { throw SynologyAPIError.invalidResponse }
        let members = group.unit.filter { $0.liveType == "video" }
        guard members.count == 1 else { return nil }
        return members[0].playbackResource(scope: .space(space))
    }

    public func streamVideoRange(_ resource: VideoPlaybackResource, range: ClosedRange<Int64>,
                                 receive: @escaping @Sendable (VideoRangeEvent) async throws -> Void) async throws {
        guard let space = resource.scope.space else {
            throw SynologyAPIError.unsupported("Media requests in this content context are unavailable.")
        }
        let sid = try sessionID()
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
              range.upperBound - range.lowerBound < 8 * 1_024 * 1_024 else {
            throw SynologyAPIError.invalidResponse
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        switch resource.variant {
        case .original:
            components.path = "/webapi/entry.cgi"
            components.queryItems = [
                URLQueryItem(name: "api", value: Self.api("Download", space)),
                URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "method", value: "download"),
                URLQueryItem(name: space == .shared && resource.itemID != nil ? "item_id" : "unit_id",
                             value: "[\(space == .shared ? (resource.itemID ?? resource.unitID) : resource.unitID)]"),
                URLQueryItem(name: "cache_key", value: resource.cacheKey),
                URLQueryItem(name: "_sid", value: sid),
            ]
        case .converted(let quality):
            components.path = "/webapi/entry.cgi/" + Self.api("Streaming", space)
            components.queryItems = [
                URLQueryItem(name: "api", value: Self.api("Streaming", space)),
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
        let started = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 206,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let parsed = Self.parseContentRange(contentRange),
              parsed.range.lowerBound == range.lowerBound,
              parsed.range.upperBound <= range.upperBound,
              parsed.total > parsed.range.upperBound,
              parsed.range.upperBound == range.upperBound || parsed.range.upperBound == parsed.total - 1,
              let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.hasPrefix("video/") || contentType.hasPrefix("application/octet-stream") else {
            throw SynologyAPIError.invalidResponse
        }
        let expected = parsed.range.upperBound - parsed.range.lowerBound + 1
        if let length = http.value(forHTTPHeaderField: "Content-Length") {
            guard Int64(length) == expected else { throw SynologyAPIError.invalidResponse }
        }
        let header = VideoRangeHeader(range: parsed.range, totalLength: parsed.total,
                                      contentType: contentType,
                                      etag: http.value(forHTTPHeaderField: "ETag"),
                                      lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        SynologyDiagnostics.videoTransport.debug(
            "Video range headers unit_id=\(resource.unitID, privacy: .public) lower=\(parsed.range.lowerBound, privacy: .public) upper=\(parsed.range.upperBound, privacy: .public)"
        )
        try await receive(.header(header))
        var buffer = Data()
        buffer.reserveCapacity(16 * 1_024)
        var delivered: Int64 = 0
        var reportedFirst = false
        for try await byte in bytes {
            try Task.checkCancellation()
            guard delivered + Int64(buffer.count) < expected else { throw SynologyAPIError.invalidResponse }
            buffer.append(byte)
            if buffer.count == 16 * 1_024 {
                if !reportedFirst {
                    reportedFirst = true
                    let elapsed = started.duration(to: .now).components
                    let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                    SynologyDiagnostics.videoTransport.info("Video first chunk unit_id=\(resource.unitID, privacy: .public) elapsed_ms=\(ms, privacy: .public)")
                }
                try await receive(.bytes(offset: parsed.range.lowerBound + delivered, data: buffer))
                delivered += Int64(buffer.count)
                buffer = Data()
                buffer.reserveCapacity(16 * 1_024)
            }
        }
        if !buffer.isEmpty {
            if !reportedFirst {
                let elapsed = started.duration(to: .now).components
                let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                SynologyDiagnostics.videoTransport.info("Video first chunk unit_id=\(resource.unitID, privacy: .public) elapsed_ms=\(ms, privacy: .public)")
            }
            try await receive(.bytes(offset: parsed.range.lowerBound + delivered, data: buffer))
            delivered += Int64(buffer.count)
        }
        guard delivered == expected else { throw SynologyAPIError.invalidResponse }
        let elapsed = started.duration(to: .now).components
        let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        SynologyDiagnostics.videoTransport.info("Video range completed unit_id=\(resource.unitID, privacy: .public) bytes=\(delivered, privacy: .public) elapsed_ms=\(ms, privacy: .public)")
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

    private func post<Response: Decodable>(path: String, parameters: [String: String], authenticated: Bool,
                                        decoder: JSONDecoder = JSONDecoder()) async throws -> Response {
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
        catch { throw transportError(error) }
        guard let http = response as? HTTPURLResponse else { throw SynologyAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SynologyAPIError.http(http.statusCode) }
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw SynologyAPIError.invalidResponse }
    }

    private func postBounded<Response: Decodable>(
        path: String,
        parameters: [String: String],
        authenticated: Bool,
        maximumBytes: Int,
        decoder: JSONDecoder
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
        catch { throw transportError(error) }
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
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw SynologyAPIError.invalidResponse }
    }

    /// The Foto or FotoTeam variant of a Synology Photos API.
    static func api(_ name: String, _ space: PhotoSpace) -> String {
        (space == .shared ? "SYNO.FotoTeam." : "SYNO.Foto.") + name
    }

    private static func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// A refused certificate becomes `untrustedCertificate`, everything else `transport`.
    private func transportError(_ error: Error) -> SynologyAPIError {
        if let fingerprint = trustDelegate?.takeRejectedFingerprint() {
            return .untrustedCertificate(sha256: fingerprint)
        }
        return .transport(error.localizedDescription)
    }

    /// The current session for transfers that cannot use `request`, such as uploads and media.
    private func sessionID() throws -> String {
        guard let sid else { throw SynologyAPIError.api(119) }
        return sid
    }

    /// Sends one authenticated Web API request and returns its undecoded envelope.
    /// Every JSON Web API call passes through here, so session state has one owner.
    private func request<Value: Decodable>(_ api: String, version: Int, method: String, _ parameters: [String: String] = [:],
                                           decoder: JSONDecoder = JSONDecoder(), maximumBytes: Int? = nil) async throws -> APIEnvelope<Value> {
        let generation = sessionGeneration
        let response: APIEnvelope<Value> = try await send(api, version: version, method: method, parameters,
                                                          decoder: decoder, maximumBytes: maximumBytes)
        guard !response.success, let code = response.error?.code,
              SynologyAPIError.sessionCodes.contains(code), renewal != nil else { return response }
        try await renewSession(expiredGeneration: generation)
        return try await send(api, version: version, method: method, parameters, decoder: decoder, maximumBytes: maximumBytes)
    }

    private func send<Value: Decodable>(_ api: String, version: Int, method: String, _ parameters: [String: String],
                                        decoder: JSONDecoder, maximumBytes: Int?) async throws -> APIEnvelope<Value> {
        let sid = try sessionID()
        let form = parameters.merging(["api": api, "version": String(version), "method": method, "_sid": sid]) { _, new in new }
        let path = "/webapi/entry.cgi/" + api
        if let maximumBytes {
            return try await postBounded(path: path, parameters: form, authenticated: true, maximumBytes: maximumBytes, decoder: decoder)
        }
        return try await post(path: path, parameters: form, authenticated: true, decoder: decoder)
    }

    /// Returns the data of a successful response.
    private func call<Value: Decodable>(_ api: String, version: Int, method: String, _ parameters: [String: String] = [:],
                                        decoder: JSONDecoder = JSONDecoder(), maximumBytes: Int? = nil) async throws -> Value {
        let response: APIEnvelope<Value> = try await request(api, version: version, method: method, parameters,
                                                             decoder: decoder, maximumBytes: maximumBytes)
        guard response.success, let data = response.data else { throw SynologyAPIError.api(response.error?.code ?? -1) }
        return data
    }

    /// Sends a request whose successful response carries nothing the caller needs.
    private func perform(_ api: String, version: Int, method: String, _ parameters: [String: String] = [:]) async throws {
        let response: APIEnvelope<EmptyData> = try await request(api, version: version, method: method, parameters)
        guard response.success else { throw SynologyAPIError.api(response.error?.code ?? -1) }
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
