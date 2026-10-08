import OSLog

/// Unified logging shared by the app's layers. Keep the subsystem stable so a
/// single Console predicate can include every category.
public enum SynologyDiagnostics {
    public static let subsystem = "local.cirrus.syno-timeline"

    public static let viewer = Logger(subsystem: subsystem, category: "viewer.assets")
    public static let originals = Logger(subsystem: subsystem, category: "repository.originals")
    public static let transport = Logger(subsystem: subsystem, category: "transport.originals")
    public static let decoding = Logger(subsystem: subsystem, category: "viewer.decoding")
}
