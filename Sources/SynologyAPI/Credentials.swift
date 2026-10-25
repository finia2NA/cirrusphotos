import CryptoKit
import Foundation

public struct SynologyCredentials: Sendable {
    public let username: String
    public let password: String
    public let otpSecret: String?

    public init(username: String, password: String, otpSecret: String? = nil) {
        self.username = username
        self.password = password
        let trimmed = otpSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.otpSecret = trimmed?.isEmpty == false ? trimmed : nil
    }
}

public enum CredentialStore {
    public static func load() throws -> SynologyCredentials {
        let fileManager = FileManager.default
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [
            workingDirectory.appendingPathComponent(".env"),
            bundleParent.appendingPathComponent(".env"),
            bundleParent.deletingLastPathComponent().appendingPathComponent(".env")
        ]

        guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw SynologyAPIError.configuration("No .env file was found beside the project or app build.")
        }
        return try credentials(from: Data(contentsOf: url))
    }

    static func credentials(from data: Data) throws -> SynologyCredentials {
        let values = try parseEnv(data)
        let missing = ["USER", "PW"].filter { values[$0, default: ""].isEmpty }
        guard missing.isEmpty else {
            throw SynologyAPIError.configuration("Missing .env key(s): \(missing.joined(separator: ", "))")
        }
        return SynologyCredentials(username: values["USER"]!, password: values["PW"]!, otpSecret: values["OTP"])
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
