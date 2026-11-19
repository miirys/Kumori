import XCTest

/// One screenshot per fixture state (T01, D01–D06). Run on the tvOS Simulator; the PNGs land
/// in the result bundle and, on CI, in the `kumori-tvos-captures` artifact.
final class ScreenCaptureTests: XCTestCase {
    /// Capture name, fixture, extra launch arguments.
    static let captures: [(String, String, [String])] = [
        ("01-gallery", "gallery", []),
        ("02-home", "home", []),
        ("03-home-focus-running", "home", ["-focus", "fx-tidebreaker"]),
        ("04-home-safe-frame", "home", ["-safeFrame", "1"]),
        ("05-home-large-text", "home", ["-typeSize", "ax3"]),
        ("06-home-reduced", "home", ["-reduceMotion", "1", "-reduceTransparency", "1"]),
        ("07-home-loading", "home-loading", []),
        ("08-home-error", "home-error", []),
        ("09-shelves", "shelves", []),
        ("10-shelves-safe-frame", "shelves", ["-safeFrame", "1"]),
        ("11-art-load", "art-load", []),
        ("12-library", "library", []),
        ("13-library-focus-long-title", "library", ["-focus", "fx-long-title"]),
        ("14-library-large-text", "library", ["-typeSize", "ax3"]),
        ("15-library-empty", "library-empty", []),
        ("16-detail", "detail", []),
        ("17-detail-long-title", "detail-long", []),
        ("18-detail-long-title-large-text", "detail-long", ["-typeSize", "ax3"]),
        ("19-detail-running", "detail-running", []),
        ("20-confirm-end", "confirm-end", ["-openDialog"]),
        ("21-materials", "materials", []),
        ("22-materials-opaque", "materials", ["-reduceTransparency", "1"]),
    ]

    override func setUp() {
        continueAfterFailure = true
    }

    func testCaptureEveryFixture() {
        for (name, fixture, extra) in Self.captures {
            let app = FixtureHarness.launch(fixture, extra)
            // Let the focus animation finish before the picture.
            Thread.sleep(forTimeInterval: fixture == "confirm-end" ? 1.2 : 0.8)
            FixtureHarness.capture(name, in: self)
            app.terminate()
        }
    }
}
