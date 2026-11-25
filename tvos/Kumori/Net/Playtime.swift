import Foundation

/// One GeForce NOW session from the account's play history, on any device: the same list as
/// the playtime page on nvidia.com (Account › Playtime › Details).
struct PlayedSession: Hashable {
    let title: String
    /// As the service writes it, so a session seen twice is counted once.
    let start: String
    let seconds: Int
}

enum Playtime {
    private static let history = "https://api-prod.nvidia.com/gfn-paywall-api/api/v2/userplaytime/sessionshistory"

    /// Every session in the last year (or, if the service won't give that much at once, this
    /// playtime month), signed with the app's own sign-in.
    static func sessions(token: String, access: String, unlimited: Bool, now: Date = Date()) async throws -> [PlayedSession] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lastError: Error = APIError(message: "No play history.")
        for days in [365.0, 31.0] {
            var c = URLComponents(string: history)!
            c.queryItems = [
                URLQueryItem(name: "subType", value: unlimited ? "UNLIMITED" : "TIME_CAPPED"),
                URLQueryItem(name: "spanStartDate", value: iso.string(from: now.addingTimeInterval(-days * 86400))),
                URLQueryItem(name: "spanEndDate", value: iso.string(from: now)),
                URLQueryItem(name: "locale", value: "en-US"),
                URLQueryItem(name: "paginate", value: "false"),
            ]
            for auth in ["GFNJWT \(token)", "Bearer \(access)"] {
                do {
                    let j = try await HTTP.json(HTTP.request(c.url!.absoluteString, headers: [
                        "Authorization": auth,
                        "Accept": "application/json",
                    ]))
                    return parse(j.raw)
                } catch {
                    lastError = error
                }
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
        return PlayedSession(title: title, start: start, seconds: seconds)
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

    private static let storeKey = "playtimeSessions"

    /// Sessions already seen, kept so totals keep growing past whatever window the service
    /// returns: title and start → seconds.
    static func remember(_ list: [PlayedSession]) -> [String: Int] {
        var all = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Int]) ?? [:]
        for s in list { all["\(s.title)\u{1F}\(s.start)"] = s.seconds }
        UserDefaults.standard.set(all, forKey: storeKey)
        return totals(all)
    }

    static func remembered() -> [String: Int] {
        totals((UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Int]) ?? [:])
    }

    /// Seconds per game, by a simplified title.
    private static func totals(_ all: [String: Int]) -> [String: Int] {
        var by: [String: Int] = [:]
        for (k, v) in all {
            let title = String(k.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            by[key(title), default: 0] += v
        }
        return by
    }

    /// "Honkai: Star Rail™" and "honkai star rail" are the same game.
    static func key(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
