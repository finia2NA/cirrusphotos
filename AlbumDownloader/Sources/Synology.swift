import Foundation

struct Album {
    let name: String
    let itemCount: Int
    let ownerName: String?
}

struct AlbumItem {
    let id: Int64
    let filename: String
    let filesize: Int64
    let type: String
}

/// What opening an album link without an account found.
enum LinkAccess: Equatable {
    /// The link is public; the guest session can read the album.
    case opened
    /// The link is public but protected by a password (or the password given was wrong).
    case passwordNeeded
    /// The album is shared with accounts only.
    case accountNeeded
}

enum SignInError: Error {
    case codeRequired
    case wrongCode
    case rejected(String)
}

/// The DSM and Synology Photos requests an album recipient needs, either as a signed-in account
/// or as a guest of a public link. Shapes follow docs/SYNOLOGY_PHOTOS_API.md
/// ("Album sharing and incoming albums").
final class Synology {
    let server: URL
    let http: HTTPClient
    /// True after `openLink` succeeded: requests use the public sharing endpoint.
    private(set) var isGuest = false
    private var guestReference = ""
    private var guestSession: String?
    private var linkPassword = ""
    private var sid: String?
    private var synoToken: String?
    private var username = ""
    private var password = ""
    private var deviceToken: String?

    init(server: URL) {
        self.server = server
        http = HTTPClient(server: server)
    }

    // MARK: Sign-in

    /// Opens a public link as a guest; `password` is the link's password when it has one.
    func openLink(reference: String, password: String?) throws -> LinkAccess {
        let envelope = try post(["api": "SYNO.Core.Sharing.Login", "version": "1", "method": "login",
                                 "sharing_id": Self.json(reference), "password": Self.json(password ?? "")],
                                authenticated: false, guest: true)  // no X-SYNO-SHARING: it turns the answer into 101
        guard envelope.success, let data = envelope.data as? [String: Any],
              let session = data["sharing_sid"] as? String, !session.isEmpty else {
            // 1003 means the album is shared with accounts only; an unknown link answers 1000.
            return envelope.errorCode == 1003 ? .accountNeeded : .passwordNeeded
        }
        isGuest = true
        guestReference = reference
        guestSession = session
        linkPassword = password ?? ""
        return .opened
    }

    /// Signs in; `code` is the six-digit two-factor code when the account requires one.
    func signIn(username: String, password: String, code: String?) throws {
        var parameters = [
            "api": "SYNO.API.Auth", "version": "6", "method": "login",
            "account": username, "passwd": password,
            "session": "webui", "format": "sid",
            "enable_syno_token": "yes", "enable_device_token": "no",
            "device_name": "Album Downloader"
        ]
        if let code {
            parameters["otp_code"] = code
            parameters["enable_device_token"] = "yes"
        } else if let deviceToken, username == self.username {
            parameters["device_id"] = deviceToken
            parameters["enable_device_token"] = "yes"
        }
        let envelope = try post(parameters, authenticated: false, guest: false)
        guard envelope.success, let data = envelope.data as? [String: Any], let sid = data["sid"] as? String else {
            switch envelope.errorCode {
            case 400: throw SignInError.rejected("The username or password is wrong.")
            case 401: throw SignInError.rejected("This account is disabled.")
            case 402: throw SignInError.rejected("This account may not sign in to this server.")
            case 403: throw SignInError.codeRequired
            case 404: throw SignInError.wrongCode
            case 406: throw SignInError.rejected("This account must set up two-factor authentication in DSM first.")
            case 407: throw SignInError.rejected("The server has blocked this IP address after too many failed sign-ins.")
            case 408, 409, 410: throw SignInError.rejected("The password has expired. Change it in DSM first.")
            default: throw SignInError.rejected("Sign-in failed (Synology error \(envelope.errorCode)).")
            }
        }
        isGuest = false
        self.sid = sid
        synoToken = data["synotoken"] as? String
        self.username = username
        self.password = password
        if let did = data["did"] as? String, !did.isEmpty { deviceToken = did }
    }

    /// Signs in again after DSM ends the session, with the remembered credentials unless a new
    /// password (the link password for a guest) or two-factor code is given.
    func renewSession(password newPassword: String? = nil, code: String? = nil) throws {
        guard isGuest else {
            try signIn(username: username, password: newPassword ?? password, code: code)
            return
        }
        switch try openLink(reference: guestReference, password: newPassword ?? linkPassword) {
        case .opened: return
        case .passwordNeeded: throw SignInError.rejected("The link password was not accepted.")
        case .accountNeeded: throw SignInError.rejected("The album is no longer shared publicly.")
        }
    }

    // MARK: Album

    func album(reference: String) throws -> Album {
        let data = try call(["api": "SYNO.Foto.Browse.Album", "version": "4", "method": "get",
                             "passphrase": Self.json(reference), "additional": "[\"sharing_info\"]"])
        guard let first = (data["list"] as? [[String: Any]])?.first else {
            throw TransferError.invalid("The album was not found.")
        }
        let sharing = (first["additional"] as? [String: Any])?["sharing_info"] as? [String: Any]
        let owner = (sharing?["owner"] as? [String: Any])?["name"] as? String
        return Album(name: first["name"] as? String ?? "Album",
                     itemCount: Self.int(first["item_count"]) ?? 0,
                     ownerName: owner)
    }

    /// Whether the signed-in account may download from the album.
    func canDownload(reference: String) throws -> Bool {
        let data = try call(["api": "SYNO.Foto.Sharing.Passphrase", "version": "1", "method": "get_permission",
                             "passphrase": Self.json(reference), "exclude_public": "false"])
        let permission = data["permission"] as? [String: Any]
        return permission?["download"] as? Bool ?? false
    }

    func items(reference: String, expected: Int) throws -> [AlbumItem] {
        let pageSize = 200
        var items: [AlbumItem] = []
        while true {
            let data = try call(["api": "SYNO.Foto.Browse.Item", "version": "7", "method": "list",
                                 "passphrase": Self.json(reference),
                                 "offset": String(items.count), "limit": String(pageSize),
                                 "sort_by": "\"takentime\"", "sort_direction": "\"asc\""])
            let page = (data["list"] as? [[String: Any]]) ?? []
            for row in page {
                guard let id = Self.int64(row["id"]) else { continue }
                items.append(AlbumItem(id: id,
                                       filename: row["filename"] as? String ?? "item-\(id)",
                                       filesize: Self.int64(row["filesize"]) ?? 0,
                                       type: row["type"] as? String ?? "photo"))
            }
            if page.count < pageSize || (expected > 0 && items.count >= expected) { break }
        }
        return items
    }

    // MARK: Download

    /// Requests the original of one item, resuming at the partial file's size when it has one.
    func download(item: AlbumItem, reference: String, into partial: URL,
                  progress: @escaping (Int64, Int64?) -> Void) throws -> StreamOutcome {
        var request = try makeRequest(authenticated: true, guest: isGuest, reference: guestReference)
        let offset = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        var parameters = ["api": "SYNO.Foto.Download", "version": "2", "method": "download",
                          "force_download": "true", "item_id": "[\(item.id)]",
                          "passphrase": Self.json(reference), "download_type": "\"source\""]
        if !isGuest, let sid { parameters["_sid"] = sid }
        request.httpBody = Self.form(parameters)
        return try http.stream(request, into: partial, progress: progress)
    }

    /// True when the server answers HTTP at all; used to tell an outage from a failing item.
    func isReachable() -> Bool {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.path = "/webapi/entry.cgi"
        components.queryItems = [URLQueryItem(name: "api", value: "SYNO.API.Info"),
                                 URLQueryItem(name: "version", value: "1"),
                                 URLQueryItem(name: "method", value: "query"),
                                 URLQueryItem(name: "query", value: "SYNO.API.Auth")]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        return (try? http.data(for: request)) != nil
    }

    // MARK: Requests

    private struct Envelope {
        let success: Bool
        let data: Any?
        let errorCode: Int
    }

    /// An authenticated Photos call. Renews an expired session once.
    private func call(_ parameters: [String: String]) throws -> [String: Any] {
        var envelope = try post(parameters, authenticated: true, guest: isGuest, reference: guestReference)
        if !envelope.success, TransferError.api(envelope.errorCode).isSessionExpired {
            try renewSession()
            envelope = try post(parameters, authenticated: true, guest: isGuest, reference: guestReference)
        }
        guard envelope.success else { throw TransferError.api(envelope.errorCode) }
        return envelope.data as? [String: Any] ?? [:]
    }

    private func post(_ parameters: [String: String], authenticated: Bool, guest: Bool,
                      reference: String = "") throws -> Envelope {
        var parameters = parameters
        if authenticated, !guest {
            guard let sid else { throw TransferError.api(119) }
            parameters["_sid"] = sid
        }
        var request = try makeRequest(authenticated: authenticated, guest: guest, reference: reference)
        request.httpBody = Self.form(parameters)
        let (data, response) = try http.data(for: request)
        guard response.statusCode == 200 else { throw TransferError.http(response.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransferError.invalid("The server sent an unexpected response.")
        }
        let error = object["error"] as? [String: Any]
        return Envelope(success: object["success"] as? Bool ?? false, data: object["data"],
                        errorCode: Self.int(error?["code"]) ?? -1)
    }

    /// Account requests go to `/webapi` with the DSM session; guest requests go to the public
    /// sharing endpoint with the link reference and the guest session cookie.
    private func makeRequest(authenticated: Bool, guest: Bool, reference: String) throws -> URLRequest {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.path = guest ? "/mo/sharing/webapi/entry.cgi" : "/webapi/entry.cgi"
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        if guest {
            if !reference.isEmpty { request.setValue(reference, forHTTPHeaderField: "X-SYNO-SHARING") }
            if authenticated {
                guard let guestSession else { throw TransferError.api(119) }
                request.setValue("sharing_sid=\(guestSession)", forHTTPHeaderField: "Cookie")
            }
        } else if authenticated {
            guard let sid else { throw TransferError.api(119) }
            if let synoToken { request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN") }
            request.setValue("id=\(sid)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// Decodes a Synology JSON error body served in place of media.
    static func apiErrorCode(in data: Data) -> Int? {
        guard data.count <= 4_096, data.first == UInt8(ascii: "{"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == false else { return nil }
        return int((object["error"] as? [String: Any])?["code"])
    }

    static func form(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URL query encoding leaves '+' literal, but form decoders read it as a space.
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }

    static func json(_ string: String) -> String {
        String(decoding: (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    private static func int64(_ value: Any?) -> Int64? { (value as? NSNumber)?.int64Value }
}
