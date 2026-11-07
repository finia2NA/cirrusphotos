import Foundation

/// The GitHub "new issue" link with a prefilled bug template. Contains only app, macOS and Mac
/// model details, never the NAS address, account or library content.
enum IssueReport {
    static let newIssue = "https://github.com/finia2NA/cirrusphotos/issues/new"

    static func environment(bundle: Bundle = .main,
                            osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                            model: String = macModel()) -> String {
        """
        - App: \(AppVersion.versionAndBuild(bundle: bundle))
        - macOS: \(osVersion)
        - Mac: \(model)
        """
    }

    static func body(bundle: Bundle = .main,
                     osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                     model: String = macModel()) -> String {
        """
        ## What happened


        ## Steps to reproduce

        1.
        2.
        3.

        ## Expected result


        ## Environment

        \(environment(bundle: bundle, osVersion: osVersion, model: model))

        If it helps, attach the log file from Help > Export Logs. Check it for anything private first.
        """
    }

    static func url(bundle: Bundle = .main,
                    osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
                    model: String = macModel()) -> URL {
        let query = [("labels", "bug"), ("body", body(bundle: bundle, osVersion: osVersion, model: model))]
            .map { "\($0.0)=\(encode($0.1))" }
            .joined(separator: "&")
        return URL(string: "\(newIssue)?\(query)")!
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The hardware identifier, such as "Mac15,6".
    static func macModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}
