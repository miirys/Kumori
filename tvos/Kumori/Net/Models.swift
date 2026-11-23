import Foundation

struct Variant: Hashable {
    let id: String
    let store: String
    let lastPlayed: Date?
    let selected: Bool
    /// In the user's library on that store.
    let owned: Bool
}

struct Game: Identifiable, Hashable {
    let id: String
    let title: String
    let publisher: String?
    let genres: [String]
    /// Wide artwork for backgrounds.
    let hero: String?
    /// Portrait box art.
    let boxArt: String?
    /// Landscape art for tiles.
    let banner: String?
    let variants: [Variant]
    let summary: String?
    /// In-game screenshots, for the game page's lower section. Often empty.
    let screenshots: [String]

    var lastPlayed: Date? { variants.compactMap(\.lastPlayed).max() }

    /// An empty game, for places that need one to hold before any is chosen.
    static let placeholder = Game(J(["id": "placeholder", "title": ""]))!

    /// The variant a launch uses: the one picked on the account, else the first.
    var launchVariant: Variant? { variants.first(where: \.selected) ?? variants.first }

    var store: String? { launchVariant.map { Stores.label($0.store, publisher: publisher) } }

    init?(_ j: J) {
        guard let id = j["id"].string, let title = j["title"].string else { return nil }
        let images = j["images"]
        func image(_ width: Int, _ keys: String...) -> String? {
            for k in keys {
                guard let url = images[k].firstString?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { continue }
                // NVIDIA's image server resizes on request.
                return url.contains("img.nvidiagrid.net") ? "\(url);f=jpg;w=\(width)" : url
            }
            return nil
        }
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.id = id
        self.title = title
        publisher = j["publisherName"].string ?? j["developerName"].string
        genres = j["genres"].array.compactMap(\.string).map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        hero = image(3840, "MARQUEE_HERO_IMAGE", "HERO_IMAGE", "KEY_ART", "FEATURE_IMAGE", "SCREENSHOTS")
        boxArt = image(720, "GAME_BOX_ART", "KEY_IMAGE")
        banner = image(1280, "TV_BANNER", "KEY_ART", "HERO_IMAGE", "FEATURE_IMAGE")
        screenshots = images["SCREENSHOTS"].array.compactMap { s -> String? in
            guard let url = s.string?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return nil }
            return url.contains("img.nvidiagrid.net") ? "\(url);f=jpg;w=1280" : url
        }.prefix(8).map { $0 }
        variants = j["variants"].array.map { v in
            let lib = v["gfn"]["library"]
            let played = lib["lastPlayedDate"].string.flatMap { iso.date(from: $0) ?? fractional.date(from: $0) }
            return Variant(
                id: v["id"].string ?? "",
                store: v["appStore"].string ?? "",
                lastPlayed: played,
                selected: lib["selected"].bool == true,
                owned: ["MANUAL", "PLATFORM_SYNC", "IN_LIBRARY"].contains(lib["status"].string ?? "")
            )
        }
        summary = j["shortDescription"].string.map {
            $0.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
    }
}

/// A session running in the cloud for this account, possibly started on another device.
struct ActiveSession: Identifiable, Hashable {
    let sessionId: String
    let appId: String
    let status: Int
    let streamingBase: String
    /// The rig or regional host that owns the session. Claims go there.
    let serverHost: String?

    var id: String { sessionId }

    init?(_ j: J, base: String) {
        guard let id = j["sessionId"].string, let status = j["status"].int, (1...6).contains(status) else { return nil }
        sessionId = id
        self.status = status
        appId = j["sessionRequestData"]["appId"].string ?? ""
        streamingBase = base
        let signal = j["connectionInfo"].array.first { $0["usage"].int == 14 }
        serverHost = signal?["ip"].firstString ?? j["sessionControlInfo"]["ip"].firstString
    }

    init(sessionId: String, appId: String, base: String, host: String?) {
        self.sessionId = sessionId
        self.appId = appId
        status = 2
        streamingBase = base
        serverHost = host
    }
}

/// Store names the way GeForce NOW shows them.
enum Stores {
    private static let names: [String: String] = [
        "STEAM": "Steam", "EPIC": "Epic Games Store", "EPIC_GAMES_STORE": "Epic Games Store", "EGS": "Epic Games Store",
        "UPLAY": "Ubisoft Connect", "UBISOFT": "Ubisoft Connect", "UBISOFT_CONNECT": "Ubisoft Connect",
        "ORIGIN": "EA app", "EA_APP": "EA app", "EA": "EA app",
        "BATTLENET": "Battle.net", "BATTLE_NET": "Battle.net",
        "XBOX": "Xbox", "MICROSOFT": "Xbox", "MICROSOFT_STORE": "Microsoft Store",
        "GOG": "GOG", "HOYOPLAY": "HoYoPlay", "HOYOVERSE": "HoYoPlay", "KURO": "Kuro Games",
        "ROCKSTAR": "Rockstar Games Launcher", "WARGAMING": "Wargaming Game Center", "GAIJIN": "Gaijin",
        "BETHESDA": "Bethesda.net", "NEXON": "Nexon", "RIOT": "Riot Client", "RIOT_GAMES": "Riot Client",
        "GAMEPASS": "PC Game Pass", "PC_GAME_PASS": "PC Game Pass", "GFN": "GeForce NOW", "FREE": "Free to play",
    ]

    static func label(_ code: String, publisher: String? = nil) -> String {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        if let n = names[c] { return n }
        if c.isEmpty || ["NONE", "UNKNOWN", "OTHER"].contains(c) {
            if let publisher, !publisher.isEmpty { return "\(publisher) launcher" }
            return "Own launcher"
        }
        return c.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
