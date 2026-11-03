// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SynoTimeline",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "SynoTimeline", targets: ["SynoTimelineApp"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")],
    targets: [
        .target(name: "TimelineCore"),
        .target(name: "SynologyAPI", dependencies: ["TimelineCore"]),
        .target(name: "PhotoCache", dependencies: ["SynologyAPI", "TimelineCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "SynoTimelineApp", dependencies: ["TimelineCore", "SynologyAPI", "PhotoCache"]),
        .target(name: "TransportTestSupport", dependencies: ["SynologyAPI"], path: "Tests/TransportTestSupport"),
        .testTarget(name: "TimelineCoreTests", dependencies: ["TimelineCore"]),
        .testTarget(name: "SynoTimelineAppTests", dependencies: ["SynoTimelineApp", "PhotoCache", "SynologyAPI", "TransportTestSupport"]),
        .testTarget(name: "SynologyAPITests", dependencies: ["SynologyAPI"]),
        .testTarget(name: "PhotoCacheTests", dependencies: ["PhotoCache", "SynologyAPI", "TransportTestSupport"])
    ]
)
