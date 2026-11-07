import CryptoKit
import Foundation

/// How a login proves the second factor, if the account has one.
public enum SecondFactor: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case none
    /// A base32 TOTP secret or otpauth URL from `.env`; a code is generated per login.
    case totpSecret(String)
    /// A six-digit code typed by the user. The login asks DSM to trust this device.
    case code(String)
    /// The DSM trusted-device token (`did`) from an earlier login with a code.
    case deviceToken(String)

    /// Names the kind only, so a secret or token cannot reach a log through string interpolation.
    public var description: String {
        switch self {
        case .none: "none"
        case .totpSecret: "totpSecret(<redacted>)"
        case .code: "code(<redacted>)"
        case .deviceToken: "deviceToken(<redacted>)"
        }
    }

    public var debugDescription: String { description }
}

/// Which server certificates a client accepts.
public enum ServerTrust: Sendable, Equatable {
    /// Normal system validation.
    case system
    /// System validation, or else exactly this leaf certificate (SHA-256 of its DER bytes, hex),
    /// which the user accepted for a NAS whose certificate macOS cannot verify.
    case pinned(sha256: String)
}

public struct SynologyCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let username: String
    public let password: String
    public let secondFactor: SecondFactor
    /// The NAS base URL; nil only for credentials built outside the loaders.
    public let serverURL: URL?
    public let serverTrust: ServerTrust

    public init(username: String, password: String, secondFactor: SecondFactor = .none,
                serverURL: URL? = nil, serverTrust: ServerTrust = .system) {
        self.username = username
        self.password = password
        self.serverURL = serverURL
        self.serverTrust = serverTrust
        if case .totpSecret(let secret) = secondFactor {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            self.secondFactor = trimmed.isEmpty ? .none : .totpSecret(trimmed)
        } else {
            self.secondFactor = secondFactor
        }
    }

    /// Omits the username, password and second factor so credentials cannot reach a log.
    public var description: String { "SynologyCredentials(<redacted>)" }
    public var debugDescription: String { description }
}

public enum CredentialStore {
    /// The `.env` file beside the project or app build, if one exists. Its presence selects
    /// development credentials over the accounts signed in from the app. Distribution builds
    /// never look for one, so they always use the app's own sign-in.
    public static func environmentFile() -> URL? {
        #if CIRRUS_DISTRIBUTION
        return nil
        #else
        let fileManager = FileManager.default
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [
            workingDirectory.appendingPathComponent(".env"),
            bundleParent.appendingPathComponent(".env"),
            bundleParent.deletingLastPathComponent().appendingPathComponent(".env")
        ]

        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
        #endif
    }

    public static func load() throws -> SynologyCredentials {
        guard let url = environmentFile() else {
            throw SynologyAPIError.configuration("No .env file was found beside the project or app build.")
        }
        return try credentials(from: Data(contentsOf: url))
    }

    static func credentials(from data: Data) throws -> SynologyCredentials {
        let values = try parseEnv(data)
        let missing = ["USER", "PW", "NAS_URL"].filter { values[$0, default: ""].isEmpty }
        guard missing.isEmpty else {
            throw SynologyAPIError.configuration("Missing .env key(s): \(missing.joined(separator: ", "))")
        }
        guard let serverURL = URL(string: values["NAS_URL"]!), serverURL.scheme != nil, serverURL.host != nil else {
            throw SynologyAPIError.configuration("NAS_URL in .env must be a full URL such as https://nas.example.com:5001.")
        }
        return SynologyCredentials(username: values["USER"]!, password: values["PW"]!,
                                   secondFactor: .totpSecret(values["OTP"] ?? ""), serverURL: serverURL)
    }

    static func parseEnv(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SynologyAPIError.configuration("The .env file is not valid UTF-8.")
        }
        var values: [String: String] = [:]
        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let separator = line.firstIndex(of: "=") else {
                throw SynologyAPIError.configuration("Invalid .env entry on line \(offset + 1).")
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value.removeFirst(); value.removeLast()
            }
            values[key] = value
        }
        return values
    }
}

enum TOTP {
    static func generate(secret: String, date: Date = Date()) throws -> String {
        var candidate = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasPrefix("otpauth://"),
           let components = URLComponents(string: candidate),
           let value = components.queryItems?.first(where: { $0.name == "secret" })?.value {
            candidate = value
        }
        let normalized = candidate
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        guard let keyData = decodeBase32(normalized), !keyData.isEmpty else {
            throw SynologyAPIError.configuration("OTP must be a base32 secret or otpauth URL.")
        }

        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: keyData)))
        let offset = Int(digest.last! & 0x0f)
        let value = digest[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fff_ffff
        return String(format: "%06u", value % 1_000_000)
    }

    private static func decodeBase32(_ value: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })
        var buffer = 0
        var bits = 0
        var result = Data()
        for character in value where character != "=" {
            guard let digit = lookup[character] else { return nil }
            buffer = (buffer << 5) | digit
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        return result
    }
}

public enum ServerAddress {
    /// Reads a typed NAS address. Without a scheme it means DSM's HTTPS default,
    /// `https://host:5001`; `https://host` keeps port 443. Plain HTTP would send the
    /// password unencrypted and is rejected, as are paths, queries and credentials.
    public static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let hasScheme = trimmed.contains("://")
        guard var components = URLComponents(string: hasScheme ? trimmed : "https://" + trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.path = ""
        if !hasScheme, components.port == nil { components.port = 5001 }
        return components.url
    }
}
