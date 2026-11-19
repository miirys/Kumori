import XCTest
@testable import Kumori

/// D04: Back goes to the tile that opened the detail screen, or its nearest neighbour.
final class BrowseMemoryTests: XCTestCase {
    func testRestoresTheRememberedItem() {
        var m = BrowseMemory()
        m.remember(tab: "library", section: "grid", item: "c", order: ["a", "b", "c", "d"])
        XCTAssertEqual(m.restoreTarget(in: "library", current: ["a", "b", "c", "d"]), "c")
        // A reload that reorders keeps the same item.
        XCTAssertEqual(m.restoreTarget(in: "library", current: ["d", "c", "b", "a"]), "c")
    }

    func testFallsBackToTheNextThenPreviousNeighbour() {
        let order = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(BrowseMemory.restoreTarget(remembered: "c", previous: order, current: ["a", "b", "d", "e"]), "d")
        XCTAssertEqual(BrowseMemory.restoreTarget(remembered: "c", previous: order, current: ["a", "b"]), "b")
        XCTAssertEqual(BrowseMemory.restoreTarget(remembered: "e", previous: order, current: ["a"]), "a")
    }

    func testFallsBackToFirstWhenNothingIsKnown() {
        XCTAssertEqual(BrowseMemory.restoreTarget(remembered: nil, previous: [], current: ["x", "y"]), "x")
        XCTAssertEqual(BrowseMemory.restoreTarget(remembered: "q", previous: [], current: ["x", "y"]), "x")
        XCTAssertNil(BrowseMemory.restoreTarget(remembered: "q", previous: ["q"], current: []))
    }

    func testTabsAreIndependent() {
        var m = BrowseMemory()
        m.remember(tab: "home", section: "recent", item: "a", order: ["a"])
        m.remember(tab: "library", section: "grid", item: "z", order: ["z"])
        XCTAssertEqual(m.origin(in: "home"), .init(section: "recent", item: "a"))
        XCTAssertEqual(m.origin(in: "library")?.item, "z")
        m.forget(tab: "home")
        XCTAssertNil(m.origin(in: "home"))
        XCTAssertEqual(m.origin(in: "library")?.item, "z")
    }
}
