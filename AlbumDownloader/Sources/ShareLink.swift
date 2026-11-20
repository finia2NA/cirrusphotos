import Foundation

/// A Synology Photos album link, split into the DSM origin and the album's sharing reference.
///
/// Accepted forms:
/// - `https://nas:5001/mo/sharing/<reference>` (the link Synology Photos copies)
/// - `https://nas:5001/photo/mo/sharing/<reference>` (Photos portal alias)
/// - any DSM URL carrying a `passphrase=<reference>` query item
struct ShareLink: Equatable {
    let server: URL
    let reference: String

    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") { trimmed = String(trimmed.dropFirst().dropLast()) }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else { return nil }

        var reference: String?
        let parts = components.path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(of: "sharing"), index + 1 < parts.count {
            reference = parts[index + 1]
        }
        if reference == nil {
            reference = components.queryItems?.first(where: { $0.name == "passphrase" })?.value
        }
        if reference == nil, let fragment = components.fragment,
           let fragmentItems = URLComponents(string: "x:/?" + fragment)?.queryItems {
            reference = fragmentItems.first(where: { $0.name == "passphrase" })?.value
        }
        guard let reference, !reference.isEmpty,
              reference.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = components.port
        guard let server = origin.url else { return nil }
        self.server = server
        self.reference = reference
    }
}
