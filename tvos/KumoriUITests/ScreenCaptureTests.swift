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

    /// The real app screens with fixture data (U01–U12): every page a person can reach.
    static let appCaptures: [(String, String, [String])] = [
        ("app-01-splash", "app-splash", []),
        ("app-02-signin", "app-signin", []),
        ("app-03-signin-waiting", "app-signin-waiting", []),
        ("app-04-signin-declined", "app-signin-declined", []),
        ("app-05-home", "app-home", []),
        ("app-06-home-running", "app-home-running", []),
        ("app-07-home-shelves", "app-home", ["-press", "down"]),
        ("app-08-home-loading", "app-home-loading", []),
        ("app-09-home-empty", "app-home-empty", []),
        ("app-10-home-error", "app-home-error", []),
        ("app-11-library", "app-library", []),
        ("app-12-library-large-text", "app-library", ["-typeSize", "ax3"]),
        ("app-13-library-empty", "app-library-empty", []),
        ("app-14-search-start", "app-search-start", []),
        ("app-15-search-results", "app-search", []),
        ("app-16-search-none", "app-search-none", []),
        ("app-17-search-error", "app-search-error", []),
        ("app-18-detail", "app-detail", []),
        ("app-19-detail-running", "app-detail-running", []),
        ("app-20-detail-long-title", "app-detail-long", []),
        ("app-21-settings", "app-settings", []),
        ("app-22-settings-stream", "app-settings-stream", []),
        ("app-23-settings-resolution", "app-settings-mode", []),
        ("app-24-settings-codec", "app-settings-codec", []),
        ("app-25-settings-dlss", "app-settings-dlss", []),
        ("app-26-settings-account", "app-settings-account", []),
        ("app-27-settings-about", "app-settings-about", []),
        ("app-27b-settings-controllers", "app-settings-controllers", []),
        ("app-28-stream-starting", "app-stream-starting", []),
        ("app-29-stream-queued", "app-stream-queued", []),
        ("app-30-stream-connecting", "app-stream-connecting", []),
        ("app-31-stream-live-stats", "app-stream-live", []),
        ("app-32-stream-menu", "app-stream-menu", []),
        ("app-33-stream-ended", "app-stream-ended", []),
        ("app-34-stream-error", "app-stream-error", []),
        ("app-35-home-reduced", "app-home", ["-reduceMotion", "1", "-reduceTransparency", "1"]),
        ("app-36-stream-menu-opaque", "app-stream-menu", ["-reduceTransparency", "1"]),
        ("app-37-settings-focused", "app-settings", ["-press", "down1"]),
        ("app-38-settings-stream-focused", "app-settings-stream", ["-press", "down1"]),
        // Select on a category moves focus into its page.
        ("app-39-settings-entering", "app-settings", ["-press", "down1", "-select"]),
        ("app-40-settings-entered", "app-settings", ["-press", "down1", "-select", "-settle"]),
        // Mid-transition: a game's page zooming out of the tile that opened it.
        ("app-41-detail-zoom", "app-home", ["-press", "down", "-select"]),
        ("app-42-detail-opened", "app-home", ["-press", "down", "-select", "-settle"]),
        // A choice page sliding in over its category, and settled.
        ("app-43-settings-push", "app-settings-stream", ["-select"]),
        ("app-44-settings-pushed", "app-settings-stream", ["-select", "-settle"]),
        ("app-45-stream-menu-end", "app-stream-menu", ["-press", "down"]),
        ("app-46-library-focused", "app-library", ["-press", "down1"]),
    ]

    func testCaptureEveryAppScreen() {
        for (name, fixture, extra) in Self.appCaptures {
            var args = extra
            var presses: [XCUIRemote.Button] = []
            if let i = args.firstIndex(of: "-press") {
                if args[i + 1] == "down" { presses = [.down, .down] }
                if args[i + 1] == "down1" { presses = [.down] }
                args.removeSubrange(i...(i + 1))
            }
            let select = args.contains("-select")
            let settle = args.contains("-settle")
            args.removeAll { $0 == "-select" || $0 == "-settle" }
            let app = FixtureHarness.launch(fixture, args)
            for p in presses { FixtureHarness.press(p) }
            if select {
                Thread.sleep(forTimeInterval: 0.6)
                XCUIRemote.shared.press(.select)
                // Caught part way through the page's arrival, unless asked to let it settle.
                Thread.sleep(forTimeInterval: settle ? 1.5 : 0.12)
            } else {
                Thread.sleep(forTimeInterval: 1.0)
            }
            FixtureHarness.capture(name, in: self)
            app.terminate()
        }
    }

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
