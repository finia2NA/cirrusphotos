// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SynoTimeline",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SynoTimeline", targets: ["TimelinePrototype"])],
    targets: [
        .target(name: "TimelineCore"),
        .target(name: "SynologyAPI", dependencies: ["TimelineCore"]),
        .executableTarget(name: "TimelinePrototype", dependencies: ["TimelineCore", "SynologyAPI"]),
        .testTarget(name: "TimelineCoreTests", dependencies: ["TimelineCore"]),
        .testTarget(name: "SynologyAPITests", dependencies: ["SynologyAPI"])
    ]
)
