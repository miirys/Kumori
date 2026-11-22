import XCTest

/// Drives the real app screens with the remote and checks that every press goes where a
/// person expects: across the hero's buttons, up to the tab bar, down into the shelves, and
/// back up from anywhere along a shelf. A press that leaves focus where it was, or sends it
/// somewhere unexpected, is the "stuck" a person feels on the device.
///
/// Each check reports what actually had focus, so one run maps every trap at once.
final class AppFocusTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: Home

    func testHomeHeroButtonsTabBarAndShelves() {
        let app = FixtureHarness.launch("app-home-running")
        reachContent(app, prefix: "hero-")
        check(app, is: "hero-play", "starts on Resume")

        FixtureHarness.press(.right)
        check(app, is: "hero-details", "Right from Resume")
        FixtureHarness.press(.right)
        check(app, is: "hero-end", "Right from Details")
        FixtureHarness.press(.right)
        check(app, is: "hero-end", "Right from the last button stays put")
        FixtureHarness.press(.left, times: 2)
        check(app, is: "hero-play", "Left twice back to Resume")

        FixtureHarness.press(.up)
        checkTabBar(app, "Up from Resume reaches the tab bar")
        FixtureHarness.press(.down)
        check(app, hasPrefix: "hero-", "Down from the tab bar comes back to the hero")

        // Down from the rightmost hero button still reaches a shelf.
        FixtureHarness.press(.right, times: 2)
        FixtureHarness.press(.down)
        check(app, hasPrefix: "lockup-", "Down from End Game reaches the first shelf")

        // Along the shelf: every press moves.
        var last = focused(app)
        for i in 1...3 {
            FixtureHarness.press(.right)
            let now = focused(app)
            XCTAssertNotEqual(now, last, "Right #\(i) along the first shelf didn't move (still \(now))")
            last = now
        }

        // Up from a tile far to the right, under no button, still reaches the hero.
        FixtureHarness.press(.up)
        check(app, hasPrefix: "hero-", "Up from the fourth tile reaches the hero")

        // Down through every shelf (three in this fixture), then all the way back up.
        FixtureHarness.press(.down)
        var seen = [focused(app)]
        for i in 1...2 {
            FixtureHarness.press(.down)
            let now = focused(app)
            XCTAssertTrue(now.hasPrefix("lockup-"), "Down #\(i) between shelves went to \(now)")
            seen.append(now)
        }
        XCTAssertEqual(Set(seen).count, seen.count, "Down between shelves stuck somewhere: \(seen)")
        FixtureHarness.press(.down)
        XCTAssertEqual(focused(app), seen.last, "Down from the last shelf should stay on it")
        XCTAssertTrue(pressUntil(app, .up, times: 6) { $0.hasPrefix("hero-") },
                      "Up from the lower shelves never reached the hero (ended on \(focused(app)))")
    }

    func testHomeWithoutARunningGame() {
        let app = FixtureHarness.launch("app-home")
        reachContent(app, prefix: "hero-")
        check(app, is: "hero-play", "starts on Play")
        FixtureHarness.press(.right)
        check(app, is: "hero-details", "Right from Play")
        FixtureHarness.press(.down)
        check(app, hasPrefix: "lockup-", "Down from Details reaches a shelf")
        FixtureHarness.press(.up)
        check(app, hasPrefix: "hero-", "and Up comes back")
        FixtureHarness.press(.up)
        checkTabBar(app, "Up from the hero reaches the tab bar")
    }

    // MARK: Library

    func testLibraryGrid() {
        let app = FixtureHarness.launch("app-library")
        reachContent(app, prefix: "lockup-")
        var last = focused(app)
        for (i, dir) in [XCUIRemote.Button.right, .right, .down, .left, .down].enumerated() {
            FixtureHarness.press(dir)
            let now = focused(app)
            XCTAssertNotEqual(now, last, "Press #\(i + 1) (\(dir.rawValue)) in the library grid didn't move (still \(now))")
            last = now
        }
        XCTAssertTrue(pressUntil(app, .up, times: 5) { !$0.hasPrefix("lockup-") },
                      "Up from the grid never reached the tab bar (ended on \(focused(app)))")
    }

    // MARK: Settings

    func testSettingsRows() {
        let app = FixtureHarness.launch("app-settings")
        reachContent(app, prefix: "settings-")
        check(app, is: "settings-stream", "starts on Stream")
        let order = ["settings-dlss", "settings-controllers", "settings-account", "settings-about", "settings-debug"]
        for id in order {
            FixtureHarness.press(.down)
            check(app, is: id, "Down to \(id)")
        }
        FixtureHarness.press(.up, times: order.count)
        check(app, is: "settings-stream", "Up back to Stream")
        FixtureHarness.press(.up)
        checkTabBar(app, "Up from Stream reaches the tab bar")
        FixtureHarness.press(.down)
        check(app, hasPrefix: "settings-", "Down from the tab bar comes back to the list")

        // Into the Stream page and through its rows.
        FixtureHarness.press(.select)
        XCTAssertTrue(app.buttons["settings-mode"].waitForExistence(timeout: 3), "Stream page didn't open")
        check(app, is: "settings-mode", "Stream page starts on Resolution")
        for id in ["settings-fps", "settings-codec", "settings-bitrate", "settings-show-stats"] {
            FixtureHarness.press(.down)
            check(app, is: id, "Down to \(id)")
        }
        let before = app.buttons["settings-show-stats"].value as? String
        FixtureHarness.press(.select)
        let after = app.buttons["settings-show-stats"].value as? String
        XCTAssertNotEqual(before, after, "Select on Show Stats didn't switch it (\(before ?? "nil"))")
        FixtureHarness.press(.menu)
        check(app, is: "settings-stream", "Back from the Stream page returns to the Stream row")
    }

    // MARK: Detail and stream

    func testDetailButtons() {
        let app = FixtureHarness.launch("app-detail-running")
        check(app, is: "detail-play", "starts on Resume")
        FixtureHarness.press(.right)
        check(app, is: "detail-end", "Right to End Game")
        FixtureHarness.press(.left)
        check(app, is: "detail-play", "Left back to Resume")
    }

    func testStreamErrorButtons() {
        let app = FixtureHarness.launch("app-stream-error")
        check(app, is: "stream-retry", "starts on Try Again")
        // The buttons between Try Again and Close depend on the failure (a safe retry, End
        // Session); every press moves, and Close is last.
        XCTAssertTrue(pressUntil(app, .right, times: 3) { $0 == "stream-close" },
                      "Right never reached Close (ended on \(focused(app)))")
        XCTAssertTrue(pressUntil(app, .left, times: 3) { $0 == "stream-retry" },
                      "Left never got back to Try Again (ended on \(focused(app)))")
    }

    func testStreamMenu() {
        let app = FixtureHarness.launch("app-stream-menu")
        check(app, is: "menu-resume", "menu starts on Resume")
        var last = focused(app)
        for i in 1...6 {
            FixtureHarness.press(.down)
            let now = focused(app)
            if now == last { break }
            XCTAssertFalse(now.isEmpty, "Down #\(i) in the menu lost focus")
            last = now
        }
        XCTAssertTrue(pressUntil(app, .up, times: 8) { $0 == "menu-resume" },
                      "Up through the menu never got back to Resume (ended on \(focused(app)))")
    }

    // MARK: Helpers

    /// What has focus: its identifier, or its type and label when it has none (the tab bar).
    private func focused(_ app: XCUIApplication) -> String {
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        if let named = all.last(where: { !$0.identifier.isEmpty }) { return named.identifier }
        if let any = all.last { return "<\(any.elementType.rawValue)> \(any.label)" }
        return ""
    }

    /// Fixtures can start with focus on the tab bar. Move down into the page.
    private func reachContent(_ app: XCUIApplication, prefix: String, line: UInt = #line) {
        if focused(app).hasPrefix(prefix) { return }
        XCTAssertTrue(pressUntil(app, .down, times: 2) { $0.hasPrefix(prefix) },
                      "Couldn't get into the page; focus is on \(focused(app))", line: line)
    }

    /// Presses `button` up to `times` times, stopping as soon as `done` holds. Checks once
    /// before pressing.
    private func pressUntil(_ app: XCUIApplication, _ button: XCUIRemote.Button, times: Int, _ done: (String) -> Bool) -> Bool {
        Thread.sleep(forTimeInterval: 0.3)
        if done(focused(app)) { return true }
        for _ in 0..<times {
            FixtureHarness.press(button)
            if done(focused(app)) { return true }
        }
        return false
    }

    /// Waits up to two seconds for focus to settle on `id`, as a page animates in.
    private func check(_ app: XCUIApplication, is id: String, _ what: String, line: UInt = #line) {
        let end = Date().addingTimeInterval(2)
        repeat {
            if focused(app) == id { return }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < end
        XCTFail("\(what): expected \(id), focus is on \(focused(app))", line: line)
    }

    private func check(_ app: XCUIApplication, hasPrefix prefix: String, _ what: String, line: UInt = #line) {
        let now = focused(app)
        if !now.hasPrefix(prefix) { XCTFail("\(what): expected \(prefix)…, focus is on \(now)", line: line) }
    }

    /// The tab bar's items have no identifiers of ours, so "on the tab bar" means focus left
    /// the page for one of the four tab names.
    private func checkTabBar(_ app: XCUIApplication, _ what: String, line: UInt = #line) {
        let now = focused(app)
        let tabs = ["Home", "Library", "Search", "Settings"]
        if !tabs.contains(where: { now.hasSuffix($0) }) {
            XCTFail("\(what): focus is on \(now)", line: line)
        }
    }
}
