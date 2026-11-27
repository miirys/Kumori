import SwiftUI

/// Settings › Playtime: what has been played on GeForce NOW, on every device, the way the
/// account's playtime page on nvidia.com lists it, in the app's own glass. A summary of the
/// month on top, then the sessions a page at a time, or the games by hours.
struct PlaytimePage: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openGamePage) private var openGame
    @State private var byGame = false
    @State private var page = 0
    @State private var expanded: String?

    private static let perPage = 6

    var body: some View {
        SettingsPage(symbol: "clock", title: "Playtime") {
            Section {
                PlaytimeSummary(used: usedThisMonth, left: app.membership?.hoursLeft.map { Int($0 * 3600) },
                                unlimited: app.membership?.unlimited ?? false, top: topGames,
                                localOnly: app.playSessions.isEmpty)
            }
            Section {
                HStack(spacing: 18) {
                    tab("Sessions", on: !byGame) { byGame = false }
                    tab("By Game", on: byGame) { byGame = true }
                }
                .focusSection()
            }
            if byGame {
                Section(app.playSessions.isEmpty ? "On This Apple TV" : "All Time") { gamesList }
            } else {
                Section(sessionsHeader) { sessionsList }
            }
        }
    }

    // MARK: Sessions

    /// The account's history from NVIDIA, every device. Until NVIDIA gives it, the streams
    /// this Apple TV has played itself, so the page is never empty after you've played.
    private var sessions: [PlayedSession] {
        if !app.playSessions.isEmpty { return app.playSessions }
        return local
    }

    private var local: [PlayedSession] {
        let iso = ISO8601DateFormatter()
        return StreamHistory.shared.records.reversed().compactMap { r in
            let title = r.title ?? r.gameId.flatMap { id in app.library.first { $0.id == id }?.title }
            guard let title, r.seconds >= 60 else { return nil }
            return PlayedSession(title: title, start: iso.string(from: r.startedAt), seconds: r.seconds,
                                 startDate: r.startedAt, store: nil,
                                 resolution: r.height.map { "\($0)p" }, fps: r.targetFps,
                                 device: "This Apple TV", membership: nil)
        }
    }
    private var pages: Int { max(1, (sessions.count + Self.perPage - 1) / Self.perPage) }

    private var sessionsHeader: String {
        if sessions.isEmpty { return "Sessions" }
        return app.playSessions.isEmpty ? "On This Apple TV \u{00B7} \(sessions.count)" : "Sessions \u{00B7} \(sessions.count)"
    }

    @ViewBuilder private var sessionsList: some View {
        if sessions.isEmpty {
            Text(app.playHistoryChecked ? "No sessions yet." : "Loading your play history\u{2026}")
                .font(TVType.callout)
                .foregroundStyle(TVColor.secondary)
                .frame(minHeight: SettingsMetrics.rowHeight)
        } else {
            let current = min(page, pages - 1)
            let slice = Array(sessions.dropFirst(current * Self.perPage).prefix(Self.perPage))
            ForEach(slice) { s in
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        expanded = expanded == s.id ? nil : s.id
                    }
                } label: {
                    SessionRow(session: s, art: art(for: s.title), open: expanded == s.id)
                }
                if expanded == s.id, let g = game(for: s.title), let openGame {
                    Button { openGame(g) } label: {
                        SettingsRow(title: "Open \(g.title)", icon: "arrow.up.forward.app", chevron: true)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            if pages > 1 { pager(current) }
        }
    }

    /// ‹ 2 / 8 ›, the way the playtime page on nvidia.com pages its sessions.
    private func pager(_ current: Int) -> some View {
        HStack(spacing: 22) {
            Button { turn(to: current - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(TVActionStyle(shape: .capsule, height: 64, alignment: .center))
                .fixedSize()
                .disabled(current == 0)
            Text("\(current + 1) / \(pages)")
                .font(TVType.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(TVColor.secondary)
                .contentTransition(.numericText())
                .frame(minWidth: 120)
            Button { turn(to: current + 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(TVActionStyle(shape: .capsule, height: 64, alignment: .center))
                .fixedSize()
                .disabled(current >= pages - 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .focusSection()
    }

    private func turn(to p: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            page = max(0, min(pages - 1, p))
            expanded = nil
        }
    }

    // MARK: By game

    private var gameTotals: [(title: String, seconds: Int, count: Int)] {
        var by: [String: (String, Int, Int)] = [:]
        for s in sessions {
            let k = Playtime.key(s.title)
            let old = by[k] ?? (s.title, 0, 0)
            by[k] = (old.0, old.1 + s.seconds, old.2 + 1)
        }
        return by.values.map { (title: $0.0, seconds: $0.1, count: $0.2) }.sorted { $0.seconds > $1.seconds }
    }

    @ViewBuilder private var gamesList: some View {
        let totals = gameTotals
        if totals.isEmpty {
            Text(app.playHistoryChecked ? "No games played yet." : "Loading your play history\u{2026}")
                .font(TVType.callout)
                .foregroundStyle(TVColor.secondary)
                .frame(minHeight: SettingsMetrics.rowHeight)
        } else {
            let most = max(1, totals.first?.seconds ?? 1)
            ForEach(totals, id: \.title) { t in
                Button {
                    if let g = game(for: t.title), let openGame { openGame(g) }
                } label: {
                    GameTotalRow(title: t.title, seconds: t.seconds, sessions: t.count,
                                 share: CGFloat(t.seconds) / CGFloat(most), art: art(for: t.title))
                }
            }
        }
    }

    // MARK: Parts

    private func tab(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                action()
                expanded = nil
            }
        } label: { Text(title) }
            .buttonStyle(TVActionStyle(shape: .capsule, selected: on, height: 64, alignment: .center))
            .fixedSize()
    }

    /// Time played in the last 30 days, the length of a playtime month.
    private var usedThisMonth: Int {
        let since = Date().addingTimeInterval(-30 * 86400)
        return sessions.filter { ($0.startDate ?? .distantPast) >= since }.reduce(0) { $0 + $1.seconds }
    }

    private var topGames: [(title: String, seconds: Int, art: TVArtworkSource)] {
        gameTotals.prefix(3).map { (title: $0.title, seconds: $0.seconds, art: art(for: $0.title)) }
    }

    private func game(for title: String) -> Game? {
        let k = Playtime.key(title)
        return app.library.first { Playtime.key($0.title) == k }
            ?? app.shelves.lazy.flatMap(\.games).first { Playtime.key($0.title) == k }
    }

    private func art(for title: String) -> TVArtworkSource {
        game(for: title)?.tvHeroCard ?? .missing
    }
}

/// "142 h", "3 h 20 min", "12 min".
enum PlaytimeFormat {
    /// Time left on the plan, from NVIDIA's hours: "None" under a minute, never "1 min" for
    /// nothing at all.
    static func left(hours: Double) -> String {
        let seconds = Int((hours * 3600).rounded())
        return seconds < 60 ? "None" : duration(seconds)
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h >= 10 { return "\(h) h" }
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return "\(max(1, m)) min"
    }
}

// MARK: Summary

/// The month at a glance: time used against time left as one bar, and the most played games.
private struct PlaytimeSummary: View {
    let used: Int
    let left: Int?
    let unlimited: Bool
    let top: [(title: String, seconds: Int, art: TVArtworkSource)]
    /// Only this Apple TV's own streams are known, not the account's history.
    var localOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .firstTextBaseline, spacing: 40) {
                figure(PlaytimeFormat.duration(used), localOnly ? "played on this Apple TV, last 30 days" : "played in the last 30 days")
                if unlimited {
                    figure("Unlimited", "time left")
                } else if let left {
                    figure(left < 60 ? "None" : PlaytimeFormat.duration(left), "left this month")
                }
                Spacer(minLength: 0)
            }
            if !unlimited, let left {
                UsageBar(fraction: used + left > 0 ? CGFloat(used) / CGFloat(used + left) : 0)
            }
            if !top.isEmpty {
                HStack(spacing: 28) {
                    ForEach(Array(top.enumerated()), id: \.offset) { _, g in
                        HStack(spacing: 14) {
                            TVArtwork(source: g.art, title: "", titleOnPlaceholder: false, fill: true, placeholder: true)
                                .frame(width: 72, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.title)
                                    .font(TVType.detail.weight(.semibold))
                                    .foregroundStyle(TVColor.primary)
                                    .lineLimit(1)
                                Text(PlaytimeFormat.duration(g.seconds))
                                    .font(TVType.detail.monospacedDigit())
                                    .foregroundStyle(TVColor.tertiary)
                            }
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
            SettingsRowGlass(shape: shape)
        }
        .accessibilityElement(children: .combine)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 52, weight: .bold).monospacedDigit())
                .foregroundStyle(TVColor.primary)
            Text(label)
                .font(TVType.detail.weight(.medium))
                .foregroundStyle(TVColor.tertiary)
        }
    }
}

/// Time used as a bar of light with a gentle sheen drifting along it. The sheen is only
/// decoration; the bar's length is the real share of the month.
private struct UsageBar: View {
    let fraction: CGFloat
    @Environment(\.tvReduceMotion) private var reduced
    @State private var grown = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = max(18, w * min(1, max(0, fraction)) * (grown ? 1 : 0.0001))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.78)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: fill)
                    .overlay {
                        if !reduced {
                            TimelineView(.animation) { context in
                                let t = context.date.timeIntervalSinceReferenceDate
                                let phase = CGFloat((t.truncatingRemainder(dividingBy: 3.2)) / 3.2)
                                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                               startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 140)
                                    .offset(x: -140 + (fill + 140) * phase)
                                    .blendMode(.plusLighter)
                            }
                            .frame(width: fill, alignment: .leading)
                            .clipShape(Capsule())
                        }
                    }
            }
        }
        .frame(height: 16)
        .onAppear {
            withAnimation(reduced ? TVMotion.reducedFade : .spring(response: 0.9, dampingFraction: 0.85).delay(0.15)) { grown = true }
        }
        .accessibilityLabel("\(Int(fraction * 100)) percent of this month used")
    }
}

// MARK: Rows

private struct SessionRow: View {
    let session: PlayedSession
    let art: TVArtworkSource
    let open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 22) {
                Thumb(art: art)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).lineLimit(1)
                    Text(dateLine)
                        .font(TVType.detail)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                Text(PlaytimeFormat.duration(session.seconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
                    .font(TVType.detail.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            if open {
                HStack(alignment: .top, spacing: 48) {
                    ForEach(details, id: \.0) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(d.0.uppercased())
                                .font(TVType.detail.weight(.semibold))
                                .tracking(1.2)
                                .foregroundStyle(.tertiary)
                            Text(d.1)
                                .font(TVType.callout.weight(.semibold))
                        }
                    }
                }
                .padding(.leading, 118)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var dateLine: String {
        guard let d = session.startDate else { return session.start }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private var details: [(String, String)] {
        var out: [(String, String)] = []
        if let s = session.startDate, let e = session.endDate {
            out.append(("Time", "\(s.formatted(date: .omitted, time: .shortened)) \u{2013} \(e.formatted(date: .omitted, time: .shortened))"))
        }
        if let store = session.store { out.append(("Store", Stores.label(store))) }
        let quality = [session.resolution, session.fps.map { "\($0) fps" }].compactMap { $0 }.joined(separator: ", ")
        if !quality.isEmpty { out.append(("Quality", quality)) }
        if let device = session.device { out.append(("Device", device)) }
        if let tier = session.membership { out.append(("Membership", tier.capitalized)) }
        if out.isEmpty { out.append(("Length", PlaytimeFormat.duration(session.seconds))) }
        return out
    }
}

private struct GameTotalRow: View {
    let title: String
    let seconds: Int
    let sessions: Int
    let share: CGFloat
    let art: TVArtworkSource

    var body: some View {
        HStack(spacing: 22) {
            Thumb(art: art)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).lineLimit(1)
                    Spacer(minLength: 20)
                    Text(PlaytimeFormat.duration(seconds)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    GeometryReader { geo in
                        Capsule().fill(Color.primary.opacity(0.14))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.7)).frame(width: max(8, geo.size.width * share))
                            }
                    }
                    .frame(height: 6)
                    Text(sessions == 1 ? "1 session" : "\(sessions) sessions")
                        .font(TVType.detail)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
        }
    }
}

/// A game's picture, small: enough to tell what it is.
private struct Thumb: View {
    let art: TVArtworkSource

    var body: some View {
        TVArtwork(source: art, title: "", titleOnPlaceholder: false, fill: true, placeholder: true)
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: Opening a game from anywhere

private struct OpenGamePageKey: EnvironmentKey {
    static let defaultValue: ((Game) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens a game's page over the current screen, from places that have no tile for it.
    var openGamePage: ((Game) -> Void)? {
        get { self[OpenGamePageKey.self] }
        set { self[OpenGamePageKey.self] = newValue }
    }
}
