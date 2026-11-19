import XCTest

/// Remote-driven focus checks for the design system components (D01, D02, D04, D05).
final class FocusTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: D01 geometry

    func testLandscapeShelfUsesApplesFourColumnWidth() {
        let app = FixtureHarness.launch("shelves")
        // The second tile is unfocused; its frame is the lockup at rest.
        let tile = app.buttons["lockup-fx-glass-harbor"]
        XCTAssertTrue(tile.exists)
        XCTAssertEqual(tile.frame.width, 410, accuracy: 2)
        let first = app.buttons["lockup-fx-saltmarsh"]
        // The first tile starts on the safe edge (the focused one may have lifted a little).
        XCTAssertEqual(first.frame.midX - first.frame.width / 2, 80, accuracy: 24)
    }

    func testPosterGridUsesSixColumnsThenFewerAtLargeText() {
        var app = FixtureHarness.launch("library")
        XCTAssertEqual(app.buttons["lockup-fx-tidebreaker"].frame.width, 260, accuracy: 2)
        app.terminate()
        app = FixtureHarness.launch("library", ["-typeSize", "ax3"])
        // Accessibility sizes: three posters across, 560 pt each.
        XCTAssertEqual(app.buttons["lockup-fx-tidebreaker"].frame.width, 560, accuracy: 2)
    }

    // MARK: D02 traversal

    func testShelfTraversalAndEdges() {
        let app = FixtureHarness.launch("shelves")
        XCTAssertEqual(FixtureHarness.focusedID(app), "fx-saltmarsh")

        // Left from the first tile stays put.
        FixtureHarness.press(.left)
        XCTAssertEqual(FixtureHarness.focusedID(app), "fx-saltmarsh")

        FixtureHarness.press(.right, times: 3)
        XCTAssertEqual(FixtureHarness.focusedID(app), "fx-wildfrost")

        // Past the end stops on the last tile.
        FixtureHarness.press(.right, times: 6)
        XCTAssertEqual(FixtureHarness.focusedID(app), "fx-deep-current")

        // Down from the far end of a long shelf still reaches the shorter shelf below.
        FixtureHarness.press(.down)
        let second = ["fx-moth-and-key", "fx-pollen", "fx-hollow-signal-xbox", "fx-late-art", "fx-quiet-orbit"]
        XCTAssertTrue(second.contains(FixtureHarness.focusedID(app)), "focus went to \(FixtureHarness.focusedID(app))")

        // And back up lands in the first shelf again.
        FixtureHarness.press(.up)
        let first = ["fx-saltmarsh", "fx-glass-harbor", "fx-copperline", "fx-wildfrost", "fx-starling", "fx-paper-moons", "fx-deep-current"]
        XCTAssertTrue(first.contains(FixtureHarness.focusedID(app)), "focus went to \(FixtureHarness.focusedID(app))")
    }

    func testLateArtworkKeepsFocus() {
        let app = FixtureHarness.launch("art-load")
        // The fixture settles after the slow artwork has arrived.
        XCTAssertEqual(FixtureHarness.focusedID(app), "fx-late-art")
        XCTAssertTrue(app.buttons["lockup-fx-late-art"].hasFocus)
    }

    func testOneFocusableElementPerTile() {
        let app = FixtureHarness.launch("shelves")
        let lockups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'lockup-'"))
        let ids = lockups.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(ids.count, Set(ids).count, "a tile appears as two buttons")
    }

    // MARK: D04 Back restoration

    func testBackFromDetailRestoresTheTile() {
        let app = FixtureHarness.launch("restore")
        XCTAssertEqual(FixtureHarness.focusedID(app), "fx-lanternfall")
        FixtureHarness.press(.right, times: 2)
        let picked = FixtureHarness.focusedID(app)
        XCTAssertEqual(picked, "fx-northwind")

        FixtureHarness.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["detail-" + picked].waitForExistence(timeout: 5))
        FixtureHarness.press(.menu)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(FixtureHarness.focusedID(app), picked)
        XCTAssertTrue(app.buttons["lockup-" + picked].hasFocus)
    }

    // MARK: D05 confirmation

    func testEndConfirmationCancelsByDefault() {
        let app = FixtureHarness.launch("confirm-end")
        let count = app.staticTexts["end-count"]
        let cancel = app.buttons["confirm-cancel"]
        let end = app.buttons["confirm-end"]

        // Open: Cancel has focus. Select = cancel, nothing ends.
        FixtureHarness.press(.select)
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.hasFocus)
        FixtureHarness.press(.select)
        XCTAssertEqual(count.label, "Ended 0 · Cancelled 1")

        // Reopen: Cancel has focus again. Back = cancel.
        FixtureHarness.press(.select)
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.hasFocus)
        FixtureHarness.press(.menu)
        XCTAssertEqual(count.label, "Ended 0 · Cancelled 2")

        // Third time: move to End and confirm. It ends exactly once.
        FixtureHarness.press(.select)
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.hasFocus)
        FixtureHarness.press(.right)
        XCTAssertTrue(end.hasFocus)
        FixtureHarness.press(.select)
        XCTAssertEqual(count.label, "Ended 1 · Cancelled 2")
        XCTAssertFalse(end.exists)
    }
}
