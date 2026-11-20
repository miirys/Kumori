// swift-tools-version:5.9
// Unit tests for the launch logic in Kumori/Launch, which uses Foundation only. The app
// itself is built from project.yml with XcodeGen; this manifest only runs `swift test`,
// on a Mac or on Linux.
import PackageDescription

let package = Package(
    name: "KumoriLaunch",
    platforms: [.macOS(.v14), .tvOS(.v17)],
    products: [],
    targets: [
        .target(name: "KumoriLaunch", path: "Kumori/Launch"),
        .testTarget(name: "KumoriLaunchTests", dependencies: ["KumoriLaunch"], path: "Tests/KumoriLaunchTests"),
    ]
)
