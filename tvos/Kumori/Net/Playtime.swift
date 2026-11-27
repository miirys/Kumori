import Foundation
import OSLog

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

    /// Every session the service will give for the last year, signed with the app's own
    /// sign-in. The service answers 400 to a span that crosses a billing period, so the year
    /// is asked for a calendar month at a time, and a month it refuses is split in halves
    /// until each half fits (down to a day). How to ask (which sign-in header, which
    /// parameters) is worked out on the first request and kept for the rest.
    static func sessions(token: String, access: String, unlimited: Bool, now: Date = Date()) async throws -> [PlayedSession] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        var style: Style?
        var all: [String: PlayedSession] = [:]
        var lastError: Error = APIError(message: "No play history.")
        var emptyMonths = 0
        var monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        var monthEnd = now
        for _ in 0..<12 {
            var found: [PlayedSession] = []
            var spans = [(monthStart, monthEnd)]
            var asked = 0
            while let span = spans.first, asked < 40 {
                let (a, b) = span
                spans.removeFirst()
                asked += 1
                do {
                    let (j, used) = try await fetch(from: a, to: b, style: style, unlimited: unlimited, token: token, access: access)
                    style = used
                    found += parse(j.raw)
                } catch let e as APIError where e.code == 400 && b.timeIntervalSince(a) > 86400 * 1.5 && (style != nil || asked <= 3) {
                    // Refused: most likely the span crosses a billing period. Ask in halves.
                    let mid = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
                    spans.insert(contentsOf: [(a, mid), (mid, b)], at: 0)
                    lastError = e
                } catch {
                    lastError = error
                    // No way of asking has worked yet: the sign-in or the request is wrong,
                    // and asking more spans the same way would only repeat the same refusal.
                    if style == nil, all.isEmpty, found.isEmpty { break }
                }
            }
            for s in found { all[s.id] = s }
            emptyMonths = found.isEmpty ? emptyMonths + 1 : 0
            if style == nil && all.isEmpty && emptyMonths >= 1 { break }
            // Two empty months in a row: the history goes no further back.
            if emptyMonths >= 2 { break }
            monthEnd = monthStart
            monthStart = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart.addingTimeInterval(-30 * 86400)
        }
        if all.isEmpty, style == nil { throw lastError }
        return Array(all.values)
    }

    /// One way of asking: which sign-in header and which parameters besides the span.
    struct Style: Equatable {
        var auth: Int
        var params: Int
    }

    /// The sign-in headers to try, in order. The account site sends the ID token in an
    /// `idtoken` header; the app's other services take it as `GFNJWT`.
    private static func authHeaders(_ i: Int, token: String, access: String) -> [String: String] {
        switch i {
        case 0: return ["idtoken": token, "Authorization": "GFNJWT \(token)"]
        case 1: return ["Authorization": "GFNJWT \(token)"]
        case 2: return ["idtoken": token, "Authorization": "Bearer \(access)"]
        default: return ["Authorization": "Bearer \(access)"]
        }
    }
    private static let authKinds = ["idtoken+gfnjwt", "gfnjwt", "idtoken+bearer", "bearer"]

    /// The parameters to try besides the span, in order: none, as the account site's own
    /// tool does, then the plan, then everything the first version sent.
    private static func extraParams(_ i: Int, unlimited: Bool) -> [URLQueryItem] {
        let sub = URLQueryItem(name: "subType", value: unlimited ? "UNLIMITED" : "TIME_CAPPED")
        switch i {
        case 0: return []
        case 1: return [sub]
        default: return [sub, URLQueryItem(name: "locale", value: "en-US"), URLQueryItem(name: "paginate", value: "false")]
        }
    }

    /// One span. With a known style, that style only; without one, each combination in turn
    /// until one is accepted. Every try is noted (sign-in kind, parameters, status, NVIDIA's
    /// error code and the answer's shape; never a token).
    private static func fetch(from a: Date, to b: Date, style: Style?, unlimited: Bool, token: String, access: String) async throws -> (J, Style) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let styles = style.map { [$0] } ?? (0..<3).flatMap { p in (0..<4).map { Style(auth: $0, params: p) } }
        var lastError: Error = APIError(message: "No play history.")
        let days = Int((b.timeIntervalSince(a) / 86400).rounded())
        for st in styles {
            var c = URLComponents(string: history)!
            let extra = extraParams(st.params, unlimited: unlimited)
            c.queryItems = [URLQueryItem(name: "spanStartDate", value: iso.string(from: a)),
                            URLQueryItem(name: "spanEndDate", value: iso.string(from: b))] + extra
            guard let url = c.url?.absoluteString else { continue }
            var headers = authHeaders(st.auth, token: token, access: access)
            headers["Accept"] = "application/json"
            headers["nv-client-id"] = Nvidia.lcarsClientId
            headers["nv-client-type"] = "NATIVE"
            headers["nv-client-version"] = Nvidia.clientVersion
            headers["nv-client-streamer"] = "NVIDIA-CLASSIC"
            headers["nv-device-os"] = "WINDOWS"
            headers["nv-device-type"] = "DESKTOP"
            let what = "\(authKinds[st.auth]) [\(extra.map(\.name).joined(separator: ","))] \(days)d"
            do {
                let (code, j) = try await HTTP.send(HTTP.request(url, headers: headers))
                let codeName = j["errors"]["errorCode"].string ?? j["errorCode"].string ?? ""
                let summary = "\(what) http=\(code)\(codeName.isEmpty ? "" : " error=\(codeName)") sessions=\(parse(j.raw).count) shape=\(shape(j.raw))"
                log.notice("history \(summary, privacy: .public)")
                note(summary)
                guard (200..<300).contains(code), j.exists else {
                    lastError = APIError(message: "The server answered \(code).", code: code)
                    // A known style refused: the span is the problem, not the way of asking.
                    if style != nil { throw lastError }
                    continue
                }
                return (j, st)
            } catch let e as APIError {
                throw e
            } catch {
                log.notice("history \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                note("\(what) failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    private static let log = Logger(subsystem: "app.kumori.tv", category: "playtime")

    /// The last requests and what came back (status and the answer's shape, never a token),
    /// for the local API's /playtime: the TV's system log relay drops these lines.
    static func note(_ line: String) {
        traceLock.lock()
        traceLines.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        if traceLines.count > 120 { traceLines.removeFirst(traceLines.count - 120) }
        traceLock.unlock()
    }

    static var trace: [String] {
        traceLock.lock()
        defer { traceLock.unlock() }
        return traceLines
    }

    private static let traceLock = NSLock()
    nonisolated(unsafe) private static var traceLines: [String] = []

    /// The keys of an answer, two levels deep, with array lengths, for the log.
    static func shape(_ v: Any?, depth: Int = 0) -> String {
        if let a = v as? [Any] { return "[\(a.count)]" + (depth < 2 ? (a.first.map { shape($0, depth: depth + 1) } ?? "") : "") }
        if let d = v as? [String: Any] {
            guard depth < 3 else { return "{\(d.count)}" }
            return "{" + d.keys.sorted().map { "\($0):\(shape(d[$0], depth: depth + 1))" }.joined(separator: ",") + "}"
        }
        if v is String { return "s" }
        if v is NSNumber { return "n" }
        return "-"
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
        // The start and end, when both are there, say exactly how long it was; a bare
        // "totalPlaytime" doesn't say its unit (minutes, going by the account site).
        if let s = startKey.flatMap({ date(d[$0.0]) }), let e = endKey.flatMap({ date(d[$0.0]) }), e > s {
            seconds = Int(e.timeIntervalSince(s))
        }
        if seconds == nil, let k = keys.first(where: { ["duration", "minute", "second", "playtime", "timeplayed", "length"].contains(where: $0.1.contains) && !$0.1.contains("start") && !$0.1.contains("end") }) {
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
        if key.contains("min") || key.contains("playtime") { return Int(v * 60) }
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
