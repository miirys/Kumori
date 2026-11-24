import XCTest

/// Drives the real screens with scripted Kumori Link input (the `-linkScript` fixture
/// argument), the way a controller relayed from the Android box does, and checks focus moves,
/// A selects and B goes back. Each failure prints the navigator's own trace.
final class LinkNavigationTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testDirectionsMoveFocus() {
        let app = FixtureHarness.launch("app-home-running", ["-linkScript", "right,right,left,stick-right", "-linkDelay", "8"])
        XCTAssertTrue(pressUntil(app, .down, times: 2) { $0 == "hero-play" }, "Couldn't start on Resume (on \(focused(app)))")
        let seen = watch(app)
        XCTAssertEqual(seen, ["hero-play", "hero-details", "hero-end", "hero-details", "hero-end"],
                       "Link presses: \(trace(app))")
    }

    func testSettingsRowsGoStraightDownAndBack() {
        // 8 s, like the library test: on a slow simulator the remote presses below could still
        // be going at 5 s, and the scripted presses then ran first and moved focus off Stream.
        let app = FixtureHarness.launch("app-settings", ["-linkScript", "down,down,up", "-linkDelay", "8"])
        XCTAssertTrue(pressUntil(app, .down, times: 2) { $0 == "settings-stream" }, "Couldn't start on Stream (on \(focused(app)))")
        let seen = watch(app)
        XCTAssertEqual(seen.count, 4, "Saw \(seen). Link: \(trace(app))")
        if seen.count == 4 {
            XCTAssertEqual(seen[1], seen[3], "Up didn't come back. Saw \(seen). Link: \(trace(app))")
            XCTAssertTrue(sameColumn(app, seen[0], seen[1]) && sameColumn(app, seen[1], seen[2]),
                          "Down went sideways. Saw \(seen). Link: \(trace(app))")
        }
    }

    func testLibraryGridMovesInAllFourDirections() {
        let app = FixtureHarness.launch("app-library", ["-linkScript", "right,down,up,left", "-linkDelay", "8"])
        XCTAssertTrue(pressUntil(app, .down, times: 2) { $0.hasPrefix("lockup-") }, "Couldn't reach the grid (on \(focused(app)))")
        let seen = watch(app)
        XCTAssertEqual(seen.count, 5, "Saw \(seen). Link: \(trace(app))")
        if seen.count == 5 {
            XCTAssertEqual(seen[1], seen[3], "Up didn't undo down. Saw \(seen). Link: \(trace(app))")
            XCTAssertEqual(seen[0], seen[4], "Left didn't undo right. Saw \(seen). Link: \(trace(app))")
            XCTAssertTrue(straight(trace(app), "down"), "Down went to the neighbour. Saw \(seen). Link: \(trace(app))")
        }
    }

    func testDownFromTheTabBarReachesTheContent() {
        let app = FixtureHarness.launch("app-library", ["-linkScript", "down", "-linkDelay", "6"])
        let seen = watch(app)
        XCTAssertTrue(seen.last?.hasPrefix("lockup-") == true, "Saw \(seen). Link: \(trace(app))")
    }

    func testGamePageButtons() {
        let app = FixtureHarness.launch("app-detail-running", ["-linkScript", "right,left", "-linkDelay", "6"])
        let seen = watch(app)
        XCTAssertEqual(seen.count, 3, "Saw \(seen). Link: \(trace(app))")
        if seen.count == 3 { XCTAssertEqual(seen[0], seen[2], "Saw \(seen). Link: \(trace(app))") }
    }

    func testSelectAndBack() {
        let app = FixtureHarness.launch("app-settings", ["-linkScript", "a,down,b", "-linkDelay", "8"])
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

    /// Whether Link's own record of a move ("[x,y to x,y of n]") kept the same column.
    private func straight(_ trace: String, _ dir: String) -> Bool {
        guard let step = trace.components(separatedBy: " | ").first(where: { $0.hasPrefix(dir + " ") && $0.contains("moved") }),
              let open = step.lastIndex(of: "[") else { return false }
        let nums = step[open...].split(whereSeparator: { !"0123456789-".contains($0) }).compactMap { Int($0) }
        return nums.count >= 4 && abs(nums[0] - nums[2]) <= 4
    }

    /// Whether two focused elements sit in one column, so a vertical move went straight.
    private func sameColumn(_ app: XCUIApplication, _ a: String, _ b: String) -> Bool {
        let fa = app.descendants(matching: .any)[a].firstMatch.frame
        let fb = app.descendants(matching: .any)[b].firstMatch.frame
        guard !fa.isEmpty, !fb.isEmpty else { return true }
        return abs(fa.midX - fb.midX) < max(fa.width, fb.width) / 2
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
