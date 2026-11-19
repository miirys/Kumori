import XCTest

/// Launches the app on one fixture screen and waits for it to settle (T01).
enum FixtureHarness {
    static let bundleID = "app.kumori.tv"

    /// Launches `fixture` with extra arguments and waits for its `ready-<name>` marker.
    @discardableResult
    static func launch(_ fixture: String, _ extra: [String] = [], file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-fixture", fixture] + extra
        app.launch()
        let ready = app.descendants(matching: .any)["ready-" + fixture]
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "fixture \(fixture) never settled", file: file, line: line)
        return app
    }

    /// Saves a screenshot as a kept test attachment, and as a PNG in
    /// $KUMORI_CAPTURE_DIR when the runner has one (CI sets it).
    static func capture(_ name: String, in test: XCTestCase) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
        if let dir = ProcessInfo.processInfo.environment["KUMORI_CAPTURE_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url)
        }
    }

    /// The ID the fixture says has focus (fixtures that track it show it in `focused-id`).
    static func focusedID(_ app: XCUIApplication) -> String {
        app.staticTexts["focused-id"].label
    }

    static func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times {
            XCUIRemote.shared.press(button)
            // Give the focus engine a moment between presses, like a person would.
            Thread.sleep(forTimeInterval: 0.35)
        }
    }
}
