#if DEBUG
import Foundation

/// A fixed, fictional catalogue for screenshots and tests (D06). No network, no real account,
/// no real artwork. Every run produces the same IDs, titles, dates and generated art.
///
/// It deliberately includes the awkward cases the real catalogue throws at the UI:
/// two games with the same title, a very long title, a game with no artwork, bright artwork,
/// a game running in the cloud, and art that arrives late.
///
/// Games are built through the real `Game(J)` initialiser, so screens that take `Game` can be
/// fed this catalogue unchanged.
enum CatalogueFixtures {
    struct Entry {
        let id: String
        let title: String
        let store: String
        let genres: [String]
        /// Generated-art seed, or nil for a game with no artwork at all.
        let art: Int?
        /// Hours before `now` it was last played, or nil if never.
        let playedHoursAgo: Int?
        var summary: String?
        /// Milliseconds the artwork takes to "download".
        var artDelay = 0
    }

    /// The fixed clock everything is measured from: 19 Nov 2026, 18:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_795_111_200)

    static let profile = Profile(userId: "fixture-user", name: "Sky Tester", email: "player@example.com", tier: "Ultimate")

    static let entries: [Entry] = [
        Entry(id: "fx-lanternfall", title: "Lanternfall", store: "STEAM", genres: ["ACTION", "ADVENTURE"], art: 0, playedHoursAgo: 2,
              summary: "Carry the last light through a drowned city, one lantern at a time. Every flame you leave behind changes the map."),
        Entry(id: "fx-tidebreaker", title: "Tidebreaker", store: "EPIC", genres: ["RACING"], art: 6, playedHoursAgo: 20,
              summary: "Hydrofoil racing across storm fronts. Read the swell, cut the corner, and hold the line when the wave breaks."),
        Entry(id: "fx-northwind", title: "Northwind Rally", store: "STEAM", genres: ["RACING", "SPORTS"], art: 1, playedHoursAgo: 30),
        Entry(id: "fx-ember-garden", title: "Ember Garden", store: "UBISOFT_CONNECT", genres: ["SIMULATION"], art: 2, playedHoursAgo: 50),
        Entry(id: "fx-quiet-orbit", title: "Quiet Orbit", store: "STEAM", genres: ["PUZZLE"], art: 3, playedHoursAgo: 70),
        Entry(id: "fx-hollow-signal-steam", title: "Hollow Signal", store: "STEAM", genres: ["HORROR"], art: 4, playedHoursAgo: 90),
        Entry(id: "fx-hollow-signal-xbox", title: "Hollow Signal", store: "XBOX", genres: ["HORROR"], art: 9, playedHoursAgo: nil),
        Entry(id: "fx-long-title", title: "The Extraordinarily Long Chronicle of the Lantern Keepers: Definitive Anniversary Edition",
              store: "GOG", genres: ["RPG"], art: 5, playedHoursAgo: 120,
              summary: "A title long enough to test every line limit in the app."),
        Entry(id: "fx-paper-moons", title: "Paper Moons", store: "EPIC", genres: ["PLATFORMER"], art: nil, playedHoursAgo: nil),
        Entry(id: "fx-saltmarsh", title: "Saltmarsh", store: "STEAM", genres: ["STRATEGY"], art: 7, playedHoursAgo: nil,
              summary: "Bright artwork, to check text and focus contrast over light pictures."),
        Entry(id: "fx-glass-harbor", title: "Glass Harbor", store: "EA_APP", genres: ["ADVENTURE"], art: 10, playedHoursAgo: nil),
        Entry(id: "fx-copperline", title: "Copperline", store: "BATTLENET", genres: ["SHOOTER"], art: 11, playedHoursAgo: nil),
        Entry(id: "fx-wildfrost", title: "Wildfrost Trail", store: "STEAM", genres: ["SURVIVAL"], art: 12, playedHoursAgo: nil),
        Entry(id: "fx-starling", title: "Starling Express", store: "STEAM", genres: ["SIMULATION"], art: 13, playedHoursAgo: nil),
        Entry(id: "fx-moth-and-key", title: "Moth & Key", store: "GOG", genres: ["PUZZLE"], art: 14, playedHoursAgo: nil),
        Entry(id: "fx-late-art", title: "Slow Download", store: "STEAM", genres: ["ARCADE"], art: 15, playedHoursAgo: nil, artDelay: 1500),
        Entry(id: "fx-deep-current", title: "Deep Current", store: "XBOX", genres: ["ACTION"], art: 16, playedHoursAgo: nil),
        Entry(id: "fx-pollen", title: "Pollen", store: "EPIC", genres: ["CASUAL"], art: 17, playedHoursAgo: nil),
    ]

    /// Games running in the cloud right now.
    static let runningIDs: Set<String> = ["fx-tidebreaker"]

    static var games: [Game] { entries.compactMap(game) }

    /// Played games, most recent first, as Home orders them.
    static var recent: [Game] {
        games.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    static var shelves: [Shelf] {
        let all = games
        func pick(_ ids: [String]) -> [Game] { ids.compactMap { id in all.first { $0.id == id } } }
        return [
            Shelf(id: "fx-shelf-new", title: "New on GeForce NOW", games: pick([
                "fx-saltmarsh", "fx-glass-harbor", "fx-copperline", "fx-wildfrost", "fx-starling", "fx-paper-moons", "fx-deep-current",
            ])),
            Shelf(id: "fx-shelf-indie", title: "Small and brilliant", games: pick([
                "fx-moth-and-key", "fx-pollen", "fx-hollow-signal-xbox", "fx-late-art", "fx-quiet-orbit",
            ])),
        ]
    }

    static func game(id: String) -> Game? { games.first { $0.id == id } }

    /// Builds the same JSON NVIDIA's catalogue sends, then parses it with the real model.
    static func game(_ e: Entry) -> Game? {
        let iso = ISO8601DateFormatter()
        var library: [String: Any] = ["selected": true, "status": "IN_LIBRARY"]
        if let h = e.playedHoursAgo {
            library["lastPlayedDate"] = iso.string(from: now.addingTimeInterval(-Double(h) * 3600))
        }
        var json: [String: Any] = [
            "id": e.id,
            "title": e.title,
            "publisherName": "Fixture Games",
            "genres": e.genres,
            "variants": [["id": e.id + "-v", "appStore": e.store, "gfn": ["library": library]]],
        ]
        if let seed = e.art {
            let delay = e.artDelay > 0 ? "?delay=\(e.artDelay)" : ""
            let url = "fixture://art/\(seed)\(delay)"
            json["images"] = ["TV_BANNER": [url], "GAME_BOX_ART": [url], "MARQUEE_HERO_IMAGE": [url]]
        }
        if let s = e.summary { json["shortDescription"] = s }
        return Game(J(json))
    }
}
#endif
