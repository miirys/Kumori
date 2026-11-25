import Foundation

/// A sign-in. `access` and `id` last about a day. `client` is the long-lived token that
/// renews them, and `refresh` is the standard renewal token, which device sign-ins don't
/// always get.
struct Tokens: Codable {
    var access: String
    var refresh: String?
    var id: String?
    var expiresAt: Date
    var client: String?

    /// The token GeForce NOW's services take: the ID token while it is valid, else the access token.
    var service: String {
        if let id, (Nvidia.jwtExpiry(id) ?? .distantFuture) > Date().addingTimeInterval(30) { return id }
        return access
    }

    var staleAt: Date { min(expiresAt, id.flatMap(Nvidia.jwtExpiry) ?? .distantFuture) }

    var canRenew: Bool { !(client ?? "").isEmpty || !(refresh ?? "").isEmpty }
}

struct Profile {
    let userId: String
    let name: String
    let email: String?
    let tier: String?
}

struct Provider {
    let idpId: String
    let streamingUrl: String
}

struct DeviceChallenge {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let interval: Int
    let expiresAt: Date
}

enum Poll {
    case pending, slowDown, expired, denied
    case done(Tokens)
}

/// One resolution and frame rate the membership may stream.
struct AllowedMode: Hashable {
    let width: Int
    let height: Int
    let fps: Int
}

struct Membership {
    let tier: String?
    let modes: [AllowedMode]
    let hoursLeft: Double?
    let unlimited: Bool
}

struct Region: Identifiable, Hashable {
    let name: String
    let url: String
    var id: String { url }
}

struct Shelf: Identifiable {
    let id: String
    let title: String
    let games: [Game]
}

/// NVIDIA's sign-in, catalog and account services.
enum Nvidia {
    private static let serviceUrls = "https://pcs.geforcenow.com/v1/serviceUrls"
    private static let deviceAuthorize = "https://login.nvidia.com/device/authorize"
    private static let token = "https://login.nvidia.com/token"
    private static let clientToken = "https://login.nvidia.com/client_token"
    private static let graphql = "https://games.geforce.com/graphql"
    static let defaultStreaming = "https://prod.cloudmatchbeta.nvidiagrid.net/"

    private static let authClientId = "q61ddeJrVt7O90Nl-P-N7I36yctih4Ml6FyXLrb6j-U"
    private static let browserClientId = "ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ"
    private static let scopes = "openid consent email tk_client age"
    static let lcarsClientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    static let clientVersion = "2.0.87.131"
    private static let browserUA = "Mozilla/5.0 (X11; Linux x86_64; Steam Deck) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    private static let gfnUA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/7b92719716 GFN-PC/2.0.87.131"
    private static let bifrostUA = "GFN-PC/30.0 (Linux) BifrostClientSDK/4.9 (38495286)"
    private static let appUA = "GFN-PC/22.0 (Android 14) PGC/3.8 (6.36.38319306) okhttp/4.12.0"
    private static let appOrigin = "https://nvfile"

    // MARK: Sign-in

    static func defaultProvider() async throws -> Provider {
        let j = try await HTTP.json(HTTP.request(serviceUrls, headers: ["Accept": "application/json", "User-Agent": gfnUA]))
        let info = j["gfnServiceInfo"]
        let wanted = info["defaultProvider"].string
        var fallback: Provider?
        for e in info["gfnServiceEndpoints"].array {
            guard let idp = e["idpId"].string else { continue }
            var url = e["streamingServiceUrl"].string ?? defaultStreaming
            if !url.hasSuffix("/") { url += "/" }
            let p = Provider(idpId: idp, streamingUrl: url)
            if fallback == nil { fallback = p }
            if wanted != nil, e["loginProvider"].string == wanted || e["loginProviderCode"].string == wanted { return p }
        }
        return fallback ?? Provider(idpId: "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg", streamingUrl: defaultStreaming)
    }

    static func startDeviceLogin(_ provider: Provider, deviceId: String) async throws -> DeviceChallenge {
        let body = HTTP.form([
            ("client_id", authClientId), ("scope", scopes), ("device_id", deviceId),
            ("display_name", "Apple TV"), ("idp_id", provider.idpId),
        ])
        let j = try await HTTP.json(HTTP.request(deviceAuthorize, method: "POST", headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://play.geforcenow.com",
            "Referer": "https://play.geforcenow.com/",
            "User-Agent": browserUA,
            "x-device-id": deviceId,
            "nv-client-id": authClientId,
            "nv-client-streamer": "WEBRTC",
            "nv-client-type": "BROWSER",
            "nv-client-platform-name": "browser",
            "nv-browser-type": "CHROME",
            "nv-device-os": "STEAMOS",
            "nv-device-type": "CONSOLE",
            "nv-device-model": "STEAMDECK",
            "nv-device-make": "VALVE",
        ], body: body))
        guard let device = j["device_code"].string, let user = j["user_code"].string, let uri = j["verification_uri"].string else {
            throw APIError(message: "The sign-in service sent no code.")
        }
        let life = min(max(j["expires_in"].int ?? 600, 60), 3600)
        return DeviceChallenge(
            deviceCode: device,
            userCode: user,
            verificationUri: uri,
            verificationUriComplete: j["verification_uri_complete"].string ?? uri,
            interval: min(max(j["interval"].int ?? 5, 1), 60),
            expiresAt: Date().addingTimeInterval(TimeInterval(life))
        )
    }

    static func pollDeviceLogin(_ c: DeviceChallenge) async throws -> Poll {
        let body = HTTP.form([
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ("device_code", c.deviceCode), ("client_id", authClientId),
        ])
        let (code, j) = try await HTTP.send(HTTP.request(token, method: "POST", headers: [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://play.geforcenow.com",
            "Referer": "https://play.geforcenow.com/",
            "User-Agent": browserUA,
        ], body: body))
        guard (200..<300).contains(code) else {
            switch j["error"].string {
            case "authorization_pending": return .pending
            case "slow_down": return .slowDown
            case "expired_token": return .expired
            case "access_denied": return .denied
            default: throw APIError(message: "Sign-in failed (\(code)).", code: code)
            }
        }
        guard let t = tokens(j, old: nil) else { throw APIError(message: "The sign-in service sent no token.") }
        return .done(t)
    }

    /// Fetches the long-lived client token for a fresh sign-in, so the app stays signed in.
    static func withClientToken(_ t: Tokens) async throws -> Tokens {
        let j = try await HTTP.json(HTTP.request(clientToken, headers: [
            "Authorization": "Bearer \(t.access)",
            "Origin": appOrigin,
            "Accept": "application/json, text/plain, */*",
            "User-Agent": appUA,
        ]))
        guard let c = j["client_token"].string else { throw APIError(message: "The sign-in service sent no client token.") }
        var out = t
        out.client = c
        return out
    }

    /// Renews a sign-in, first with the client token and then with the refresh token, under
    /// each client id the sign-in may belong to.
    static func renew(_ t: Tokens, userId: String?) async throws -> Tokens {
        var last: Error?
        var attempts: [[(String, String)]] = []
        for id in [authClientId, browserClientId] {
            if let c = t.client, !c.isEmpty, let userId {
                attempts.append([("grant_type", "urn:ietf:params:oauth:grant-type:client_token"), ("client_token", c), ("client_id", id), ("sub", userId)])
            }
        }
        for id in [authClientId, browserClientId] {
            if let r = t.refresh, !r.isEmpty {
                attempts.append([("grant_type", "refresh_token"), ("refresh_token", r), ("client_id", id)])
            }
        }
        // A busy or failing server (429, 5xx) on one attempt says nothing about the sign-in.
        // If another attempt is then refused (often just the wrong client id), the busy
        // answer is what's reported, so a passing outage never signs the player out.
        var busy: APIError?
        for fields in attempts {
            do {
                let j = try await HTTP.json(HTTP.request(token, method: "POST", headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Origin": appOrigin,
                    "Accept": "application/json, text/plain, */*",
                    "User-Agent": appUA,
                ], body: HTTP.form(fields)))
                if let out = tokens(j, old: t) { return out }
            } catch let e as APIError {
                last = e
                // Only a refusal is worth trying another way. A network failure is not.
                if e.code == 0 { throw e }
                if e.code == 429 || e.code >= 500 { busy = busy ?? e }
            }
        }
        throw busy ?? last ?? APIError(message: "Your sign-in has expired.", code: 401)
    }

    private static func tokens(_ j: J, old: Tokens?) -> Tokens? {
        guard let access = j["access_token"].string else { return nil }
        // An answer without an ID token must not keep an expired one: its expiry would make
        // every later call renew again.
        var keptId: String?
        if let id = old?.id, (jwtExpiry(id) ?? .distantFuture) > Date().addingTimeInterval(60) { keptId = id }
        return Tokens(
            access: access,
            refresh: j["refresh_token"].string ?? old?.refresh,
            id: j["id_token"].string ?? keptId,
            expiresAt: Date().addingTimeInterval(TimeInterval(j["expires_in"].int ?? 86_400)),
            client: j["client_token"].string ?? old?.client
        )
    }

    private static func jwtPayload(_ token: String) -> J? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var s = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s) else { return nil }
        return J(data: d)
    }

    static func jwtExpiry(_ token: String) -> Date? {
        guard let exp = jwtPayload(token)?["exp"].double, exp > 0 else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func profile(from token: String) -> Profile? {
        guard let j = jwtPayload(token), let sub = j["sub"].string else { return nil }
        let email = j["email"].string
        let name = j["preferred_username"].string ?? email?.split(separator: "@").first.map(String.init) ?? "Player"
        return Profile(userId: sub, name: name, email: email, tier: j["gfn_tier"].string.map(tierName))
    }

    static func tierName(_ raw: String) -> String {
        switch raw.uppercased() {
        case "FREE": return "Free"
        case "PRIORITY", "PERFORMANCE": return "Performance"
        case "ULTIMATE": return "Ultimate"
        case "FOUNDERS": return "Founders"
        default: return raw.capitalized
        }
    }

    // MARK: Account

    private static func lcars(_ token: String) -> [String: String] {
        [
            "Accept": "application/json, text/plain, */*",
            "Authorization": "GFNJWT \(token)",
            "nv-client-id": lcarsClientId,
            "nv-client-type": "NATIVE",
            "nv-client-version": clientVersion,
            "nv-client-streamer": "NVIDIA-CLASSIC",
            "nv-device-os": "LINUX",
            "nv-device-type": "DESKTOP",
            "nv-device-make": "GENERIC",
            "nv-device-model": "PC",
            "x-nv-client-identity": "GFN-PC",
            "User-Agent": gfnUA,
        ]
    }

    static func membership(token: String, userId: String, vpcId: String?) async throws -> Membership {
        var c = URLComponents(string: "https://mes.geforcenow.com/v4/subscriptions")!
        c.queryItems = [
            URLQueryItem(name: "serviceName", value: "gfn_pc"),
            URLQueryItem(name: "languageCode", value: "en_US"),
            URLQueryItem(name: "vpcId", value: vpcId ?? "NP-AMS-08"),
            URLQueryItem(name: "userId", value: userId),
        ]
        let j = try await HTTP.json(HTTP.request(c.url!.absoluteString, headers: [
            "Authorization": "GFNJWT \(token)",
            "Accept": "application/json",
            "nv-client-id": lcarsClientId,
            "nv-client-type": "NATIVE",
            "nv-client-version": clientVersion,
            "nv-client-streamer": "NVIDIA-CLASSIC",
            "nv-device-os": "WINDOWS",
            "nv-device-type": "DESKTOP",
        ]))
        var all: [(AllowedMode, Bool)] = []
        for r in j["features"]["resolutions"].array {
            let m = AllowedMode(width: r["widthInPixels"].int ?? 0, height: r["heightInPixels"].int ?? 0, fps: r["framesPerSecond"].int ?? 0)
            if m.width > 0, m.height > 0, m.fps > 0 { all.append((m, r["isEntitled"].bool ?? true)) }
        }
        // Some accounts list every mode without flags. Then all of them are allowed.
        var entitled = all.filter { $0.1 }.map { $0.0 }
        if entitled.isEmpty { entitled = all.map { $0.0 } }
        return Membership(
            tier: j["membershipTier"].string.map(tierName),
            modes: Array(Set(entitled)).sorted { ($0.height, $0.fps) > ($1.height, $1.fps) },
            hoursLeft: j["remainingTimeInMinutes"].double.map { $0 / 60 },
            unlimited: j["subType"].string == "UNLIMITED"
        )
    }

    /// The streaming region the account is served from. The catalog is per region.
    static func serverInfo(streamingBase: String, token: String) async throws -> (vpcId: String, regions: [Region]) {
        let j = try await HTTP.json(HTTP.request(streamingBase + "v2/serverInfo", headers: lcars(token)))
        guard let vpc = j["requestStatus"]["serverId"].string else {
            throw APIError(message: "The server did not say which region you are in.")
        }
        var seen = Set<String>()
        var regions: [Region] = []
        for e in j["metaData"].array {
            guard let key = e["key"].string, var value = e["value"].string, value.hasPrefix("https://"), !key.hasPrefix("gfn-") else { continue }
            if !value.hasSuffix("/") { value += "/" }
            if seen.insert(value).inserted { regions.append(Region(name: key, url: value)) }
        }
        return (vpc, regions.sorted { $0.name < $1.name })
    }

    // MARK: Catalog

    private static let appFields = """
      id title developerName publisherName genres shortDescription
      library { favorited }
      images { KEY_ART KEY_IMAGE GAME_BOX_ART TV_BANNER HERO_IMAGE MARQUEE_HERO_IMAGE FEATURE_IMAGE GAME_LOGO SCREENSHOTS }
      variants {
        id appStore storeUrl
        gfn { status library { status selected lastPlayedDate } }
      }
    """

    private static func query(_ token: String, _ text: String, _ variables: [String: Any]) async throws -> J {
        var headers = lcars(token)
        headers["Content-Type"] = "application/json"
        headers["Origin"] = "https://play.geforcenow.com"
        headers["Referer"] = "https://play.geforcenow.com/"
        headers["nv-browser-type"] = "CHROME"
        func run(_ q: String) async throws -> J {
            let j = try await HTTP.json(HTTP.request(graphql, method: "POST", headers: headers, body: jsonData(["query": q, "variables": variables])))
            if !j["data"].isObject, let m = j["errors"][0]["message"].string { throw APIError(message: m, code: 400) }
            guard j["data"].isObject else { throw APIError(message: "GeForce NOW sent an empty answer.") }
            return j["data"]
        }
        do {
            return try await run(text)
        } catch let e as APIError where e.code == 400 {
            // Not every catalog version has descriptions. Ask again without them.
            return try await run(text.replacingOccurrences(of: " shortDescription", with: ""))
        }
    }

    private static func apps(_ token: String, vpcId: String, filters: [String: Any], sort: String, pages: Int, count: Int, search: String? = nil) async throws -> [Game] {
        let q = """
        query Apps($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, \(search == nil ? "" : "$searchString: String!, ")$filters: AppFilterFields!) {
          apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, \(search == nil ? "" : "searchQuery: $searchString, ")filters: $filters) {
            numberReturned pageInfo { hasNextPage endCursor totalCount }
            items { \(appFields) }
          }
        }
        """
        var games: [Game] = []
        var cursor = ""
        for _ in 0..<pages {
            var vars: [String: Any] = ["vpcId": vpcId, "locale": "en_US", "sortString": sort, "fetchCount": count, "cursor": cursor, "filters": filters]
            if let search { vars["searchString"] = search }
            let a = try await query(token, q, vars)["apps"]
            games += a["items"].array.compactMap(Game.init)
            guard a["pageInfo"]["hasNextPage"].bool == true, let next = a["pageInfo"]["endCursor"].string else { break }
            cursor = next
        }
        return games
    }

    static func library(token: String, vpcId: String) async throws -> [Game] {
        try await apps(
            token, vpcId: vpcId,
            filters: ["variants": ["gfn": ["library": ["status": ["notEquals": "NOT_OWNED"]]]]],
            sort: "variants.gfn.library.lastPlayedDate:DESC,computedValues.libraryAddedDate:DESC,sortName:ASC",
            pages: 12, count: 100
        )
    }

    static func search(token: String, vpcId: String, text: String) async throws -> [Game] {
        try await apps(token, vpcId: vpcId, filters: [:], sort: "itemMetadata.relevance:DESC,sortName:ASC", pages: 1, count: 60, search: text)
    }

    /// The storefront's rails: new, popular, picked for you and so on.
    static func shelves(token: String, vpcId: String) async throws -> [Shelf] {
        let q = """
        query GetPanels($vpcId: String!, $locale: String!, $panelNames: [String]!) {
          panels(vpcId: $vpcId, language: $locale, names: $panelNames) {
            name
            sections { id title items { __typename ... on GameItem { app { \(appFields) } } } }
          }
        }
        """
        let data = try await query(token, q, ["vpcId": vpcId, "locale": "en_US", "panelNames": ["MAIN"]])
        var out: [Shelf] = []
        for panel in data["panels"].array {
            for (i, s) in panel["sections"].array.enumerated() {
                var seen = Set<String>()
                let games = s["items"].array.compactMap { Game($0["app"]) }.filter { seen.insert($0.id).inserted }
                if !games.isEmpty { out.append(Shelf(id: s["id"].string ?? "\(i)", title: s["title"].string ?? "", games: games)) }
            }
        }
        return out
    }

    // MARK: Sessions

    /// Sessions running for this account on any device, so they can be picked up here.
    static func activeSessions(streamingBase: String, token: String, deviceId: String) async throws -> [ActiveSession] {
        let j = try await HTTP.json(HTTP.request(streamingBase + "v2/session", headers: [
            "User-Agent": bifrostUA,
            "Authorization": "GFNJWT \(token)",
            "Content-Type": "text/plain",
            "nv-client-id": lcarsClientId,
            "nv-client-streamer": "NVIDIA-CLASSIC",
            "nv-client-type": "NATIVE",
            "nv-client-version": clientVersion,
            "nv-device-os": "LINUX",
            "nv-device-type": "DESKTOP",
            "nv-device-make": "UNKNOWN",
            "nv-device-model": "UNKNOWN",
            "x-device-id": deviceId,
            "x-nv-client-identity": bifrostUA,
        ]))
        return j["sessions"].array.compactMap { ActiveSession($0, base: streamingBase) }
    }
}
