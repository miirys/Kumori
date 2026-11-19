import XCTest
@testable import Kumori

/// D06 and T01: the fixture catalogue is stable and covers the awkward cases, and the
/// launch arguments parse.
final class CatalogueFixtureTests: XCTestCase {
    func testCatalogueIsStableBetweenRuns() {
        let a = CatalogueFixtures.games, b = CatalogueFixtures.games
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(a.map(\.banner), b.map(\.banner))
        XCTAssertEqual(a.map(\.lastPlayed), b.map(\.lastPlayed))
        XCTAssertEqual(a.count, CatalogueFixtures.entries.count, "every entry parses through Game(J)")
    }

    func testIdsAreUnique() {
        let ids = CatalogueFixtures.games.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testCoversTheAwkwardCases() {
        let games = CatalogueFixtures.games
        let titles = Dictionary(grouping: games, by: \.title)
        XCTAssertTrue(titles.values.contains { $0.count > 1 }, "two games share a title")
        XCTAssertTrue(games.contains { $0.title.count > 60 }, "a very long title")
        XCTAssertTrue(games.contains { $0.banner == nil && $0.boxArt == nil && $0.hero == nil }, "a game without art")
        XCTAssertTrue(games.contains { GeneratedArt.isBright(seed: Self.seed($0) ?? -1) }, "bright art")
        XCTAssertFalse(CatalogueFixtures.runningIDs.isEmpty, "a running session")
        XCTAssertTrue(games.contains { if case .generated(_, let d) = TVArtworkSource($0.banner) { return d > 0 } else { return false } }, "late art")
    }

    func testNoArtworkPointsAtTheNetwork() {
        for g in CatalogueFixtures.games {
            for url in [g.banner, g.boxArt, g.hero].compactMap({ $0 }) {
                XCTAssertTrue(url.hasPrefix("fixture://"), url)
            }
        }
    }

    func testRecentIsNewestFirst() {
        let dates = CatalogueFixtures.recent.compactMap(\.lastPlayed)
        XCTAssertEqual(dates, dates.sorted(by: >))
        XCTAssertEqual(CatalogueFixtures.recent.first?.id, "fx-lanternfall")
    }

    func testArtworkSourceParsing() {
        XCTAssertEqual(TVArtworkSource("fixture://art/7"), .generated(seed: 7, delay: 0))
        XCTAssertEqual(TVArtworkSource("fixture://art/15?delay=1500"), .generated(seed: 15, delay: 1500))
        XCTAssertEqual(TVArtworkSource(nil), TVArtworkSource.missing)
        XCTAssertEqual(TVArtworkSource("https://example.com/a.jpg"), .remote(URL(string: "https://example.com/a.jpg")!))
    }

    func testLaunchArguments() {
        XCTAssertNil(FixtureConfig.parse(["Kumori"]))
        let c = FixtureConfig.parse(["Kumori", "-fixture", "home", "-focus", "fx-tidebreaker", "-typeSize", "ax3", "-reduceMotion", "1"])
        XCTAssertEqual(c?.name, "home")
        XCTAssertEqual(c?.focus, "fx-tidebreaker")
        XCTAssertEqual(c?.typeSize, .accessibility3)
        XCTAssertEqual(c?.reduceMotion, true)
        XCTAssertEqual(c?.reduceTransparency, false)
    }

    private static func seed(_ g: Game) -> Int? {
        if case .generated(let s, _) = TVArtworkSource(g.banner) { return s }
        return nil
    }
}
