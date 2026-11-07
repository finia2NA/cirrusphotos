import OSLog

/// Unified logging shared by the app's layers. Keep the subsystem stable so a
/// single Console predicate can include every category.
public enum SynologyDiagnostics {
    public static let subsystem = AppIdentity.bundleIdentifier

    /// Intervals for browser scrolling and thumbnail work, shown in Instruments'
    /// os_signpost / Points of Interest lanes (`make profile`).
    public static let browserSignposts = OSSignposter(subsystem: subsystem, category: "performance.browser")
    public static let viewer = Logger(subsystem: subsystem, category: "viewer.assets")
    public static let originals = Logger(subsystem: subsystem, category: "repository.originals")
    public static let transport = Logger(subsystem: subsystem, category: "transport.originals")
    public static let authentication = Logger(subsystem: subsystem, category: "transport.authentication")
    public static let videoTransport = Logger(subsystem: subsystem, category: "transport.video")
    public static let videoPlayback = Logger(subsystem: subsystem, category: "repository.video")
    public static let videoPlayer = Logger(subsystem: subsystem, category: "viewer.video")
    public static let decoding = Logger(subsystem: subsystem, category: "viewer.decoding")
    public static let rotations = Logger(subsystem: subsystem, category: "repository.rotations")
    public static let rotationTransport = Logger(subsystem: subsystem, category: "transport.rotations")
    /// Folder navigation timings. Console: `s:io.github.finia2na.cirrusphotos c:navigation.folders`.
    public static let folders = Logger(subsystem: subsystem, category: "navigation.folders")
    /// Diff reconciliation outcomes and full inventory scans with their cause.
    /// Console: `s:io.github.finia2na.cirrusphotos c:repository.diff`.
    public static let diff = Logger(subsystem: subsystem, category: "repository.diff")
    /// Failures that indicate a bug, a malformed response or an unconfirmed write.
    /// Console: `s:io.github.finia2na.cirrusphotos c:unexpected`.
    public static let unexpected = Logger(subsystem: subsystem, category: "unexpected")
    /// Expected failures such as offline reads, busy operations and stale selections.
    public static let failures = Logger(subsystem: subsystem, category: "failures")
}
