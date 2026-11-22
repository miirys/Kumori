import XCTest

/// Drives the real screens with scripted Kumori Link input (the `-linkScript` fixture
/// argument), the way a controller relayed from the Android box does, and checks focus moves,
/// A selects and B goes back. Each failure prints the navigator's own trace.
final class LinkNavigationTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testDirectionsMoveFocus() {
        let app = FixtureHarness.launch("app-home-running", ["-linkScript", "right,right,left,stick-right", "-linkDelay", "5"])
        XCTAssertTrue(pressUntil(app, .down, times: 2) { $0 == "hero-play" }, "Couldn't start on Resume (on \(focused(app)))")
        let seen = watch(app)
        XCTAssertEqual(seen, ["hero-play", "hero-details", "hero-end", "hero-details", "hero-end"],
                       "Link presses: \(trace(app))")
    }

    func testSelectAndBack() {
        let app = FixtureHarness.launch("app-settings", ["-linkScript", "a,down,b", "-linkDelay", "5"])
        XCTAssertTrue(pressUntil(app, .down, times: 2) { $0 == "settings-stream" }, "Couldn't start on Stream (on \(focused(app)))")
        let seen = watch(app)
        XCTAssertTrue(seen.contains("settings-mode"), "A didn't open the Stream page. Saw \(seen). Link: \(trace(app))")
        XCTAssertEqual(seen.last, "settings-stream", "B didn't come back. Saw \(seen). Link: \(trace(app))")
    }

    func testBackAtTheTopKeepsTheAppOpen() {
        let app = FixtureHarness.launch("app-home-running", ["-linkScript", "b", "-linkDelay", "1"])
        _ = watch(app)
        XCTAssertEqual(app.state, .runningForeground, "B on Home closed the app. Link: \(trace(app))")
    }

    // MARK: Helpers

    /// Every distinct focus, in order, until the script finishes.
    private func watch(_ app: XCUIApplication) -> [String] {
        var seen: [String] = []
        let end = Date().addingTimeInterval(30)
        let done = app.descendants(matching: .any)["link-done"]
        repeat {
            let now = focused(app)
            if !now.isEmpty, seen.last != now { seen.append(now) }
            if done.exists { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < end
        let now = focused(app)
        if !now.isEmpty, seen.last != now { seen.append(now) }
        return seen
    }

    private func trace(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["link-trace"].label
    }

    private func focused(_ app: XCUIApplication) -> String {
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).allElementsBoundByIndex
        if let named = all.last(where: { !$0.identifier.isEmpty }) { return named.identifier }
        if let any = all.last { return "<\(any.elementType.rawValue)> \(any.label)" }
        return ""
    }

    private func pressUntil(_ app: XCUIApplication, _ button: XCUIRemote.Button, times: Int, _ done: (String) -> Bool) -> Bool {
        Thread.sleep(forTimeInterval: 0.3)
        if done(focused(app)) { return true }
        for _ in 0..<times {
            FixtureHarness.press(button)
            if done(focused(app)) { return true }
        }
        return false
    }
}
