import Foundation

/// One GeForce NOW session from the account's play history, on any device: the same list as
/// the playtime page on nvidia.com (Account › Playtime › Details).
struct PlayedSession: Hashable, Codable, Identifiable {
    let title: String
    /// As the service writes it, so a session seen twice is counted once.
    let start: String
    let seconds: Int
    var startDate: Date?
    var store: String?
    var resolution: String?
    var fps: Int?
    var device: String?
    var membership: String?

    var id: String { "\(title)\u{1F}\(start)" }
    var endDate: Date? { startDate.map { $0.addingTimeInterval(TimeInterval(seconds)) } }
}

enum Playtime {
    private static let history = "https://api-prod.nvidia.com/gfn-paywall-api/api/v2/userplaytime/sessionshistory"

    /// Every session the service will give, month by month back through the last year, every
    /// page of each, signed with the app's own sign-in. The service's own page asks one
    /// playtime month at a time and, as it turned out, gets one page of it back unless it
    /// asks for more, which is why the first version only ever counted six sessions.
    static func sessions(token: String, access: String, unlimited: Bool, now: Date = Date()) async throws -> [PlayedSession] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var auth: String?
        var all: [String: PlayedSession] = [:]
        var lastError: Error = APIError(message: "No play history.")
        var emptyMonths = 0
        for month in 0..<12 {
            let end = now.addingTimeInterval(-Double(month) * 30 * 86400)
            let start = end.addingTimeInterval(-30 * 86400)
            let base = [
                URLQueryItem(name: "subType", value: unlimited ? "UNLIMITED" : "TIME_CAPPED"),
                URLQueryItem(name: "spanStartDate", value: iso.string(from: start)),
                URLQueryItem(name: "spanEndDate", value: iso.string(from: end)),
                URLQueryItem(name: "locale", value: "en-US"),
            ]
            var found: [PlayedSession] = []
            do {
                let (first, signed) = try await fetch(base + [URLQueryItem(name: "paginate", value: "false")], auth: auth, token: token, access: access)
                auth = signed
                found = parse(first.raw)
                // Ask for more until a page brings nothing new. Each way of asking is tried
                // once; whichever the service understands carries on.
                let pagers: [(Int) -> [URLQueryItem]] = [
                    { [URLQueryItem(name: "paginate", value: "true"), URLQueryItem(name: "pageSize", value: "100"), URLQueryItem(name: "pageNumber", value: "\($0)")] },
                    { [URLQueryItem(name: "paginate", value: "true"), URLQueryItem(name: "page", value: "\($0)"), URLQueryItem(name: "size", value: "100")] },
                    { [URLQueryItem(name: "paginate", value: "true"), URLQueryItem(name: "offset", value: "\(($0 - 1) * 100)"), URLQueryItem(name: "limit", value: "100")] },
                    { [URLQueryItem(name: "paginate", value: "true"), URLQueryItem(name: "pageIndex", value: "\($0 - 1)"), URLQueryItem(name: "pageSize", value: "100")] },
                ]
                var seen = Set(found.map(\.id))
                for pager in pagers {
                    var page = 1
                    var grew = false
                    while page <= 60 {
                        guard let (j, _) = try? await fetch(base + pager(page), auth: auth, token: token, access: access) else { break }
                        let more = parse(j.raw).filter { !seen.contains($0.id) }
                        if more.isEmpty { break }
                        grew = true
                        more.forEach { seen.insert($0.id) }
                        found += more
                        page += 1
                    }
                    if grew { break }
                }
            } catch {
                lastError = error
                if auth == nil { break }
            }
            for s in found { all[s.id] = s }
            emptyMonths = found.isEmpty ? emptyMonths + 1 : 0
            // Two empty months in a row: the history goes no further back.
            if emptyMonths >= 2 { break }
        }
        if all.isEmpty, auth == nil { throw lastError }
        return Array(all.values)
    }

    /// One request, with the sign-in that worked last time, or each kind in turn.
    private static func fetch(_ items: [URLQueryItem], auth: String?, token: String, access: String) async throws -> (J, String) {
        var c = URLComponents(string: history)!
        c.queryItems = items
        var lastError: Error = APIError(message: "No play history.")
        for a in auth.map({ [$0] }) ?? ["GFNJWT \(token)", "Bearer \(access)"] {
            do {
                let j = try await HTTP.json(HTTP.request(c.url!.absoluteString, headers: [
                    "Authorization": a,
                    "Accept": "application/json",
                ]))
                return (j, a)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// The answer's exact shape isn't documented, so this reads it loosely: every object in
    /// it with a game name and a duration (or a start and an end) is a session.
    static func parse(_ raw: Any?) -> [PlayedSession] {
        var out: [PlayedSession] = []
        func walk(_ v: Any?) {
            if let a = v as? [Any] {
                a.forEach(walk)
            } else if let d = v as? [String: Any] {
                if let s = session(d) { out.append(s) } else { d.values.forEach(walk) }
            }
        }
        walk(raw)
        return out
    }

    private static func session(_ d: [String: Any]) -> PlayedSession? {
        let keys = d.keys.map { ($0, $0.lowercased()) }
        let titleKey = keys.first { ["gamename", "gametitle", "title", "appname", "game"].contains($0.1) }
            ?? keys.first { ($0.1.contains("game") || $0.1.contains("title")) && d[$0.0] is String }
        guard let titleKey, let title = d[titleKey.0] as? String, !title.isEmpty else { return nil }
        let startKey = keys.first { $0.1.contains("start") }
        let endKey = keys.first { $0.1.contains("end") && !$0.1.contains("spend") }
        let start = startKey.flatMap { d[$0.0] }.map { "\($0)" } ?? ""
        var seconds: Int?
        if let k = keys.first(where: { ["duration", "minute", "second", "playtime", "timeplayed", "length"].contains(where: $0.1.contains) && !$0.1.contains("start") && !$0.1.contains("end") }) {
            seconds = duration(d[k.0], key: k.1)
        }
        if seconds == nil, let s = startKey.flatMap({ date(d[$0.0]) }), let e = endKey.flatMap({ date(d[$0.0]) }), e > s {
            seconds = Int(e.timeIntervalSince(s))
        }
        guard let seconds, seconds >= 0 else { return nil }
        func text(_ words: [String]) -> String? {
            keys.first { k in words.contains { k.1.contains($0) } && d[k.0] is String }.flatMap { d[$0.0] as? String }
        }
        func number(_ words: [String]) -> Int? {
            keys.first { k in words.contains { k.1.contains($0) } && d[k.0] is NSNumber }.flatMap { (d[$0.0] as? NSNumber)?.intValue }
        }
        var resolution = text(["resolution"])
        if resolution == nil, let h = number(["height"]), h > 0 { resolution = h >= 2160 ? "4K" : "\(h)p" }
        return PlayedSession(title: title, start: start, seconds: seconds,
                             startDate: startKey.flatMap { date(d[$0.0]) },
                             store: text(["store", "platform", "launcher"]),
                             resolution: resolution,
                             fps: number(["fps", "framerate", "frame_rate"]),
                             device: text(["device", "client"]),
                             membership: text(["membership", "tier", "subtype"]))
    }

    private static func duration(_ v: Any?, key: String) -> Int? {
        if let s = v as? String {
            if s.hasPrefix("PT") { return isoDuration(s) }
            return Double(s).flatMap { scaled($0, key: key) }
        }
        if let n = v as? NSNumber { return scaled(n.doubleValue, key: key) }
        if let d = v as? [String: Any] {
            // { hours, minutes, seconds }
            let h = (d["hours"] as? NSNumber)?.doubleValue ?? 0
            let m = (d["minutes"] as? NSNumber)?.doubleValue ?? 0
            let s = (d["seconds"] as? NSNumber)?.doubleValue ?? 0
            return h + m + s > 0 ? Int(h * 3600 + m * 60 + s) : nil
        }
        return nil
    }

    private static func scaled(_ v: Double, key: String) -> Int {
        if key.contains("ms") || key.contains("milli") { return Int(v / 1000) }
        if key.contains("hour") { return Int(v * 3600) }
        if key.contains("min") { return Int(v * 60) }
        if key.contains("sec") { return Int(v) }
        // A bare "duration": milliseconds when it's that large, else seconds.
        return v > 200_000 ? Int(v / 1000) : Int(v)
    }

    private static func isoDuration(_ s: String) -> Int? {
        var total = 0.0, number = ""
        for ch in s.dropFirst(2) {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            let n = Double(number) ?? 0
            number = ""
            switch ch {
            case "H": total += n * 3600
            case "M": total += n * 60
            case "S": total += n
            default: break
            }
        }
        return Int(total)
    }

    private static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { let t = n.doubleValue; return Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t) }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: Kept on this Apple TV

    private static let storeKey = "playtimeHistory"

    /// Every session seen, kept so totals keep growing past whatever the service returns.
    /// Newest first.
    static func remember(_ list: [PlayedSession]) -> [PlayedSession] {
        var all = Dictionary(remembered().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in list { all[s.id] = s }
        let sorted = all.values.sorted { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
        if let data = try? JSONEncoder().encode(sorted) { UserDefaults.standard.set(data, forKey: storeKey) }
        return sorted
    }

    static func remembered() -> [PlayedSession] {
        // The first version kept a title and seconds only, with the wrong totals: drop it.
        UserDefaults.standard.removeObject(forKey: "playtimeSessions")
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([PlayedSession].self, from: data) else { return [] }
        return list
    }

    /// Seconds per game, by a simplified title.
    static func totals(_ list: [PlayedSession]) -> [String: Int] {
        var by: [String: Int] = [:]
        for s in list { by[key(s.title), default: 0] += s.seconds }
        return by
    }

    /// The last time each game was played, by a simplified title.
    static func lastPlayed(_ list: [PlayedSession]) -> [String: Date] {
        var by: [String: Date] = [:]
        for s in list { if let d = s.startDate, d > (by[key(s.title)] ?? .distantPast) { by[key(s.title)] = d } }
        return by
    }

    /// "Honkai: Star Rail™" and "honkai star rail" are the same game.
    static func key(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
