import OSLog

/// Unified logging shared by the app's layers. Keep the subsystem stable so a
/// single Console predicate can include every category.
public enum SynologyDiagnostics {
    public static let subsystem = "local.cirrus.syno-timeline"

    public static let viewer = Logger(subsystem: subsystem, category: "viewer.assets")
    public static let originals = Logger(subsystem: subsystem, category: "repository.originals")
    public static let transport = Logger(subsystem: subsystem, category: "transport.originals")
    public static let videoTransport = Logger(subsystem: subsystem, category: "transport.video")
    public static let videoPlayback = Logger(subsystem: subsystem, category: "repository.video")
    public static let videoPlayer = Logger(subsystem: subsystem, category: "viewer.video")
    public static let decoding = Logger(subsystem: subsystem, category: "viewer.decoding")
    public static let rotations = Logger(subsystem: subsystem, category: "repository.rotations")
    public static let rotationTransport = Logger(subsystem: subsystem, category: "transport.rotations")
    /// Failures that indicate a bug, a malformed response or an unconfirmed write.
    /// Console: `s:local.cirrus.syno-timeline c:unexpected`.
    public static let unexpected = Logger(subsystem: subsystem, category: "unexpected")
    /// Expected failures such as offline reads, busy operations and stale selections.
    public static let failures = Logger(subsystem: subsystem, category: "failures")
}
