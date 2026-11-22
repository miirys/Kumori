// swift-tools-version:5.9
// Tests for Kumori's controller input logic. The sources are links to the app's own files
// (Kumori/Stream/PadLogic.swift and InputEncoder.swift), which import only Foundation, so
// these run with `swift test` on a Mac or on Linux, with no Apple TV or Simulator.
import PackageDescription

let package = Package(
    name: "KumoriInput",
    platforms: [.macOS(.v13), .tvOS(.v17)],
    targets: [
        .target(name: "KumoriInput", path: "Sources/KumoriInput"),
        .testTarget(name: "KumoriInputTests", dependencies: ["KumoriInput"], path: "Tests/KumoriInputTests"),
    ]
)
