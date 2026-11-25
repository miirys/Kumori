import SwiftUI

// A game's page (U06), approved take 5 (2026-11-25). The page grows out of the tile that
// opened it with its words already inside the picture, riding out with it on a chain of
// stiff springs: each line follows the one above, blurring only while it lags. Back runs the
// chain in reverse and the picture shrinks into the tile as one piece, which catches it with
// a small bounce. All of the motion is in `GamePageMotion`.

/// The picture behind a game's page and the dark that comes up behind it. The screen that
/// opens the page draws it, under the page and over its own tiles, so the picture grows out
/// of a tile in the same coordinates the tile was measured in.
final class GamePageStage: ObservableObject {
    let game: Game
    /// Every spring on the page. The screen that opens pages shares one with its tiles.
    let motion: GamePageMotion
    /// The tile the page grows out of. Without one the page comes up in place. On Back it
    /// is moved to where the tile is then, in case the screen underneath has moved.
    @Published private(set) var origin: TVZoomSources.Source?
    /// The page itself came up. The screen that opened it checks this, so a page that never
    /// appeared can't leave its picture over everything with nothing to press Back on.
    var presented = false
    /// The whole screen, edge to edge, in the coordinates tiles are measured in (the
    /// window's). Never the stage view's own frame: that is laid out inside the TV's safe
    /// area, and a page grown to it stopped 80 points short of each side and 60 short of the
    /// top and bottom, with black around it.
    /// Every Apple TV lays out at 1920 × 1080 points, whatever the TV's resolution.
    let screen = CGRect(origin: .zero, size: TVTokens.stage)
    private let openedAt = Date()

    init(game: Game, origin: TVZoomSources.Source?, motion: GamePageMotion = GamePageMotion()) {
        self.game = game
        self.origin = origin
        self.motion = motion
    }

    /// Where the tile is now, to shrink back into: nil once it has gone, or is mostly off
    /// screen, so the page fades in place instead of flying to an empty spot.
    func currentTile() -> TVZoomSources.Source? {
        guard var tile = origin else { return nil }
        // The page covers the screen, so the screen underneath can't have scrolled the tile
        // away; a tile the system took off screen under the page still has its last frame.
        // Going by "has it left" sent a closing page into a fade at the last moment instead
        // of all the way home.
        if let hub = tile.hub, !tile.id.isEmpty, let live = hub.sources[tile.id] { tile = live }
        let seen = tile.frame.intersection(screen)
        let area = tile.frame.width * tile.frame.height
        guard !seen.isNull, area > 0, seen.width * seen.height >= area * 0.5 else { return nil }
        return tile
    }

    func retarget(_ tile: TVZoomSources.Source) { origin = tile }

    /// The picture's frame now (global coordinates), the scale the first screen is drawn at
    /// inside it, and its corner radius. Opening, it grows from the tile as it was; closing,
    /// it follows the tile wherever it is now, so it lands exactly on it.
    func artFrame() -> (rect: CGRect, scale: CGFloat, radius: CGFloat) {
        let g = motion.g
        let s = screen
        let tile = (motion.mode == .close ? currentTile() : nil) ?? origin
        guard let tile, s.width > 0 else { return (s, 1, 0) }
        let t = tile.frame
        let rect = CGRect(x: lerp(t.minX, s.minX, g), y: lerp(t.minY, s.minY, g),
                          width: lerp(t.width, s.width, g), height: lerp(t.height, s.height, g))
        return (rect, lerp(t.width / s.width, 1, g), lerp(tile.radius, 0, clamp01(g)))
    }
}

/// Draws a `GamePageStage`.
struct GamePageStageView: View {
    @ObservedObject var stage: GamePageStage

    var body: some View {
        let motion = stage.motion
        GeometryReader { geo in
            let me = geo.frame(in: .global)
            let f = stage.artFrame()
            let rect = f.rect.offsetBy(dx: -me.minX, dy: -me.minY)
            let g = clamp01(motion.g)
            let presence = clamp01(motion.presence.x)
            let scroll = max(0, motion.scroll)
            let shape = RoundedRectangle(cornerRadius: f.radius, style: .continuous)
            ZStack {
                // The screen behind goes dark as the picture grows over it, edge to edge
                // whatever frame this view was given.
                Color.black.opacity(g * presence)
                    .frame(width: stage.screen.width, height: stage.screen.height)
                    .position(x: stage.screen.midX - me.minX, y: stage.screen.midY - me.minY)
                ZStack {
                    ZStack {
                        // The tile's own picture underneath, there from the first frame; the
                        // full size picture covers it as soon as it has loaded.
                        if let origin = stage.origin, origin.art != stage.game.tvHero {
                            TVArtwork(source: origin.art, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                        }
                        TVArtwork(source: stage.game.tvHero, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                    }
                    // The deepest layer: it drifts up at a fraction of the scroll and leans in.
                    .offset(y: -0.22 * scroll * g)
                    .scaleEffect(1 + 0.06 * clamp01(scroll / 900))
                    // Part of the picture, so it clips with it and can never move on its own
                    // (a scrim that moved separately left a see-through strip in take 3).
                    GamePageScrim().opacity(g)
                    // The lower sections read over a dimmed picture.
                    Color.black.opacity(0.62 * clamp01(motion.below.x) * g)
                }
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .clipShape(shape)
                // Lifted off the screen while it is still tile-sized. A plain shape casts the
                // shadow, never the picture, so it costs nothing to redraw each frame.
                .background {
                    shape.fill(Color.black)
                        .shadow(color: .black.opacity(0.5 * (1 - g)), radius: 30, y: 30)
                }
                .position(x: rect.midX, y: rect.midY)
                // A page without a tile fades up with the grow instead.
                .opacity(stage.origin == nil ? min(presence, g * 1.5) : presence)
            }
            // Leaving in place, it sinks back a touch as it fades.
            .scaleEffect(1 - 0.035 * (1 - presence))
            .opacity(motion.artVisible ? motion.sinkOpacity : 0)
        }
        .ignoresSafeArea()
        .background { GamePageMotionPulse(motion: stage.motion) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct DetailView: View {
    let game: Game
    /// The picture behind the page, when the screen that opened it draws it. Without one
    /// the page draws its own and comes up in place.
    let stage: GamePageStage?
    let close: () -> Void

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @Environment(\.tvReduceMotion) private var reduced
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 100
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 19
    @StateObject private var ownStage: GamePageStage
    @State private var confirming = false
    @State private var tuning = false
    @State private var viewing: String?
    /// The screenshot last opened, so focus goes back to it when the viewer closes.
    @State private var lastViewed: String?
    /// Focus is below the first screen.
    @State private var below = false
    @FocusState private var focus: String?
    /// The page's top left corner on screen, for carrying it inside the picture.
    @State private var pageOrigin: CGPoint = .zero
    @State private var opened = false
    @State private var leaving = false
    @State private var closed = OneShot()

    init(game: Game, stage: GamePageStage? = nil, close: @escaping () -> Void) {
        self.game = game
        self.stage = stage
        self.close = close
        _ownStage = StateObject(wrappedValue: GamePageStage(game: game, origin: nil))
    }

    private var active: GamePageStage { stage ?? ownStage }

    var body: some View {
        let running = app.session(for: game)
        let motion = active.motion
        ZStack(alignment: .topLeading) {
            if stage == nil { GamePageStageView(stage: ownStage) }
            Color.clear
                .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { pageOrigin = $0 }
            ZStack(alignment: .topLeading) {
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 0) {
                                // The first screen ends a little short, so the next section
                                // peeks in under the buttons and says there is more below.
                                page(running: running)
                                    .frame(height: max(600, geo.size.height - Self.peek))
                                    .id("top")
                                details(width: geo.size.width, running: running)
                                    .modifier(ChainRide(motion: motion, piece: .lower, blurs: false))
                                    .id("details")
                            }
                            // Where the page is scrolled to, for the words' scroll links and
                            // the picture's parallax.
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.scrollSpace)).minY } action: { y in
                                motion.setScroll(-y)
                            }
                            // No inset of its own: this page is not in TVPage, so the system's
                            // 80 pt safe area is already the edge, the same one Home uses.
                        }
                        .coordinateSpace(.named(Self.scrollSpace))
                        .scrollClipDisabled()
                        .onChange(of: focus) { _, now in
                            // Nil is focus leaving the page (a dialog over it, or the page
                            // closing), not focus going below: keep things as they were.
                            guard let now else { return }
                            below = !Self.topFocus.contains(now)
                            motion.setFocusSection(section(for: now))
                            // Back on the buttons: the whole first screen again, not just
                            // enough of it to show the focused one.
                            guard Self.topFocus.contains(now) else { return }
                            withAnimation(reduced ? TVMotion.reducedFade : .spring(response: 0.55, dampingFraction: 0.95)) {
                                proxy.scrollTo("top", anchor: .top)
                            }
                        }
                    }
                }
                hoursLeft
                    .modifier(ChainRide(motion: motion, piece: .hours))
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(.top, 10)
            }
            // The whole first screen lives inside the picture's frame, at its scale.
            .modifier(PageCarrier(stage: active, origin: pageOrigin))
        }
        .onAppear(perform: arrive)
        .defaultFocus($focus, "play")
        .task {
            // The page arrives in a cover over the screen that opened it, and the focus
            // engine may not take the default at once. Ask until Play has it, and stop as
            // soon as anything on the page is focused.
            for wait in [60, 250, 600] {
                try? await Task.sleep(for: .milliseconds(wait))
                if focus != nil || leaving { return }
                focus = "play"
            }
        }
        .onBack(perform: leave)
        .endSessionConfirmation(
            isPresented: $confirming, title: game.title,
            onCancel: { focus = "end" },
            onEnd: {
                if let running { player.quit(running) }
                focus = "play"
            }
        )
        .fullScreenCover(isPresented: $tuning, onDismiss: { focus = "tune" }) {
            GameStreamSettings { tuning = false }
                .presentationBackground(.clear)
        }
        .fullScreenCover(item: Binding(get: { viewing.map(Shot.init) }, set: { viewing = $0?.url }),
                         onDismiss: { if let s = lastViewed { focus = "shot|" + s } }) { shot in
            ScreenshotViewer(url: shot.url) { viewing = nil }
                .presentationBackground(.black)
        }
        // `.contain` first, so the identifier names the page and doesn't replace the
        // buttons' own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-\(game.id)")
    }

    private static let peek: CGFloat = 118
    private static let topFocus: Set<String> = ["play", "end", "store", "tune"]
    private static let scrollSpace = "gamePageScroll"

    /// The lower sections, in order: screenshots when there are any, then the text columns.
    private var sectionCounts: [Int] { game.screenshots.isEmpty ? [3] : [game.screenshots.count, 3] }
    private var infoSection: Int { game.screenshots.isEmpty ? 0 : 1 }

    private func section(for id: String) -> Int {
        if Self.topFocus.contains(id) { return -1 }
        if id.hasPrefix("shot|") { return 0 }
        return infoSection
    }

    // MARK: The first screen

    /// Everything anchored low on the left, the way the Apple TV app sets a show: the
    /// publisher, the title, the genres with the stream's quality as badges, two lines about
    /// the game, then the glass buttons with a quiet note of when it was last played. The
    /// right side stays empty for the picture.
    private func page(running: ActiveSession?) -> some View {
        let motion = active.motion
        return VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            if let kicker {
                Text(kicker.uppercased())
                    .font(TVType.caption.weight(.semibold))
                    .tracking(3)
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(1)
                    .modifier(ChainRide(motion: motion, piece: .publisher))
                    .padding(.bottom, 14)
            }
            Text(game.title)
                .font(.system(size: titleSize, weight: .heavy))
                .kerning(-2.5)
                .foregroundStyle(TVColor.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 6)
                .frame(maxWidth: 1300, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .modifier(ChainRide(motion: motion, piece: .title))
            genreLine(running: running)
                .modifier(ChainRide(motion: motion, piece: .genres))
                .padding(.top, 22)
            if let summary = game.summary, !summary.isEmpty {
                PageSummary(text: summary, motion: motion)
                    .padding(.top, 18)
            }

            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: TVTokens.group))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 42))
            layout {
                PageButtons(
                    motion: motion, running: running != nil,
                    store: game.variants.count > 1 && running == nil ? storeName : nil,
                    focus: $focus,
                    play: { if leaving { turnBack() } else { player.play(game) } },
                    end: { if leaving { turnBack() } else { confirming = true } },
                    cycleStore: { if leaving { turnBack() } else { settings.cycleStore(for: game) } },
                    tune: { if leaving { turnBack() } else { tuning = true } }
                )
                // Glass is never blurred, and it keeps a faint presence while away so the
                // focus engine always has Play to land on.
                .modifier(ChainRide(motion: motion, piece: .buttons, blurs: false, floor: 0.02))
                history(running: running)
                    .modifier(ChainRide(motion: motion, piece: .caption, blurs: false))
            }
            .padding(.top, 38)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// "Action, Adventure, RPG" and then the stream's quality as small badges, the way the
    /// Apple TV app marks 4K and Dolby Vision.
    private func genreLine(running: ActiveSession?) -> some View {
        let mode = streamMode(running: running)
        let badges = [mode.resolution, "\(mode.fps) FPS"]
        return HStack(alignment: .center, spacing: 0) {
            if !facts.isEmpty {
                Text(facts.joined(separator: ", "))
                    .font(TVType.callout.weight(.medium))
                    .foregroundStyle(TVColor.secondary)
            }
            ForEach(Array(badges.enumerated()), id: \.offset) { i, badge in
                Text(badge)
                    .font(.system(size: badgeSize, weight: .bold).monospacedDigit())
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 9)
                    .padding(.top, 3)
                    .padding(.bottom, 2)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.2)))
                    .padding(.leading, i == 0 ? (facts.isEmpty ? 0 : 20) : 12)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// Two quiet lines beside the buttons: when it was last played, and how long on which
    /// store. The hours come from the account's GeForce NOW history, across every device.
    private func history(running: ActiveSession?) -> some View {
        let first: String? = running != nil ? "Still running"
            : (app.lastPlayed(game) != nil ? lastPlayed : (playedLine == nil ? "Not played yet" : nil))
        return VStack(alignment: .leading, spacing: 2) {
            if let first {
                Text(first)
                    .font(TVType.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            if let played = playedLine {
                Text(played)
                    .font(TVType.detail.weight(.medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// The mode the stream will use: a running game resumes in its own session's mode, not
    /// the one in Settings.
    private func streamMode(running: ActiveSession?) -> (resolution: String, fps: Int) {
        if let running, let m = Player.recall(running.sessionId)?.mode {
            return (StreamMode.closest(height: m.height, fps: m.fps).resolution.label, m.fps)
        }
        return (settings.mode.resolution.label, settings.mode.fps)
    }

    /// The account's time left this month, small in the corner like the system's own status.
    @ViewBuilder private var hoursLeft: some View {
        if let m = app.membership,
           let left = TimeLeft.estimate(reportedHours: m.hoursLeft, unlimited: m.unlimited, at: app.membershipAt, liveSince: nil, now: Date()),
           !left.unlimited {
            Label("\(left.label) left this month", systemImage: "clock")
                .font(TVType.detail.weight(.semibold).monospacedDigit())
                .foregroundStyle(TVColor.secondary)
                .accessibilityIdentifier("detail-hours")
        }
    }

    // MARK: Below the fold

    /// Screenshots, when the catalogue has them, then the description in full and the facts.
    /// One three-column grid for the whole section: the screenshots and the three text
    /// columns under them share the same column width and gutter, so they line up, with the
    /// same margin on both sides. Each section waits tucked away until focus comes near.
    private func details(width: CGFloat, running: ActiveSession?) -> some View {
        let motion = active.motion
        let gutter: CGFloat = 48
        let mode = streamMode(running: running)
        let codec = running == nil && settings.codec != .auto ? ", \(codecName)" : ""
        let stream = "\(mode.resolution), \(mode.fps) fps\(codec)"
        let column = max(300, (width - 2 * gutter) / 3)
        let info = infoSection
        return VStack(alignment: .leading, spacing: 44) {
            if !game.screenshots.isEmpty {
                VStack(alignment: .leading, spacing: 22) {
                    sectionTitle("Screenshots")
                        .modifier(SectionReveal(motion: motion, section: 0, item: nil))
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: gutter) {
                            ForEach(Array(game.screenshots.enumerated()), id: \.element) { i, url in
                                Button { lastViewed = url; viewing = url } label: {
                                    TVArtwork(source: TVArtworkSource(url), title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                                        .frame(width: column, height: column * 9 / 16)
                                }
                                .buttonStyle(.card)
                                .focused($focus, equals: "shot|" + url)
                                .accessibilityLabel("Screenshot")
                                .modifier(SectionReveal(motion: motion, section: 0, item: i))
                            }
                        }
                        .padding(.vertical, 24)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
            }
            HStack(alignment: .top, spacing: gutter) {
                if let summary = game.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionTitle("About")
                        Text(summary)
                            .font(TVType.callout)
                            .foregroundStyle(TVColor.secondary)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: column, alignment: .leading)
                    .modifier(SectionReveal(motion: motion, section: info, item: 0))
                }
                infoColumn(column, "Information", [
                    ("Publisher", game.publisher),
                    ("Genres", game.genres.isEmpty ? nil : game.genres.map(Game.genreLabel).joined(separator: ", ")),
                ])
                .modifier(SectionReveal(motion: motion, section: info, item: 1))
                infoColumn(column, "On GeForce NOW", [
                    ("Launches from", storeLine),
                    ("Your stream", stream),
                    ("Last played", game.lastPlayed == nil ? nil : lastPlayed),
                ])
                .modifier(SectionReveal(motion: motion, section: info, item: 2))
            }
            // Focusable, so the remote can reach this far down and the page scrolls to it.
            .focusable()
            .focused($focus, equals: "info")
        }
        .padding(.top, 34)
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(TVType.callout.weight(.bold))
            .foregroundStyle(TVColor.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func infoColumn(_ width: CGFloat, _ title: String, _ rows: [(String, String?)]) -> some View {
        let shown = rows.compactMap { r in r.1.map { InfoRow(name: r.0, value: $0) } }
        // A heading with nothing under it reads as broken: leave the column out.
        if !shown.isEmpty {
            infoList(width, title, shown)
        }
    }

    private func infoList(_ width: CGFloat, _ title: String, _ rows: [InfoRow]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(title)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name.uppercased())
                        .font(TVType.detail.weight(.semibold))
                        .tracking(1.2)
                        .foregroundStyle(TVColor.tertiary)
                    Text(row.value)
                        .font(TVType.callout.weight(.semibold))
                        .foregroundStyle(TVColor.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: Words

    private var codecName: String {
        switch settings.codec {
        case .auto: return "Auto"
        case .hevc: return "HEVC"
        default: return settings.codec.label
        }
    }

    /// The publisher, when the catalogue has one.
    private var kicker: String? {
        if let p = game.publisher, !p.isEmpty { return p }
        return nil
    }

    private var storeName: String {
        settings.variant(for: game).map { Stores.label($0.store, publisher: game.publisher) } ?? (game.store ?? "")
    }

    /// "Steam, also Epic Games Store".
    private var storeLine: String? {
        let chosen = storeName
        guard !chosen.isEmpty else { return nil }
        let others = Set(game.variants.map { Stores.label($0.store, publisher: game.publisher) }).subtracting([chosen]).sorted()
        return others.isEmpty ? chosen : "\(chosen), also \(others.joined(separator: ", "))"
    }

    /// "Action, Adventure, RPG". The store is on the caption by the buttons instead.
    private var facts: [String] {
        game.genres.prefix(3).map(Game.genreLabel)
    }

    private var lastPlayed: String {
        guard let date = app.lastPlayed(game) else { return "Not played yet" }
        return "Played " + date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// "142 hours on Steam": time played on GeForce NOW, on the store
    /// this game launches from, by a short name ("Kuro", "Epic"). Just the store when it
    /// hasn't been streamed here.
    private var playedLine: String? {
        let ids = Set([game.id] + game.variants.map(\.id))
        let here = StreamHistory.shared.records.reduce(0) { $0 + ($1.gameId.map { ids.contains($0) } == true ? $1.seconds : 0) }
        // The account's own history (every device) when NVIDIA gives it; this Apple TV's
        // record otherwise.
        let account = app.secondsPlayed(game)
        let seconds = max(account ?? 0, here)
        let store = (settings.variant(for: game) ?? game.launchVariant).map { Stores.short($0.store, publisher: game.publisher) } ?? ""
        // Without the account's history, the hours are only this Apple TV's, and say so
        // rather than passing for the game's total.
        let fromHistory = account != nil && account! >= here
        let on = !fromHistory && seconds >= 60 ? " on this Apple TV" : (store.isEmpty ? "" : " on \(store)")
        if seconds >= 3600 {
            let h = seconds / 3600
            return "\(h) \(h == 1 ? "hour" : "hours")\(on)"
        }
        if seconds >= 60 { return "\(seconds / 60) min\(on)" }
        return store.isEmpty ? nil : "On \(store)"
    }

    // MARK: Arriving and leaving

    private func arrive() {
        let stage = active
        stage.presented = true
        guard !opened, !leaving else { return }
        opened = true
        stage.motion.open(source: stage.origin?.id, origin: stage.origin?.frame,
                          sections: sectionCounts, reduced: reduced)
    }

    /// The chain runs in reverse: the lower sections lead, the words follow the picture as it
    /// shrinks back into the tile it came from, where that tile is now, and the tile catches
    /// it. When the tile has gone or scrolled away, the page fades out in place instead.
    private func leave() {
        guard !leaving else { return }
        // Back from the lower section goes up to the buttons first, as in Apple's TV app.
        if below {
            focus = "play"
            // If the focus engine doesn't take it, the next Back still closes the page.
            below = false
            return
        }
        let stage = active
        leaving = true
        let once = OneShot()
        closed = once
        let finish = { once.run(close) }
        if !reduced, stage.origin != nil, let tile = stage.currentTile() {
            stage.retarget(tile)
            stage.motion.close(then: finish)
        } else {
            stage.motion.fadeOut(reduced: reduced, then: finish)
        }
        // Only a backstop, in case no frame ever comes: the springs end the page. A page
        // turned back around in the meantime has a new one-shot, so this one is spent.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if closed === once, leaving { finish() }
        }
    }

    /// Select pressed while the page is shrinking away: it grows straight back from where
    /// it is, the way a phone reopens an app that is still closing.
    private func turnBack() {
        guard leaving else { return }
        closed.cancel()
        closed = OneShot()
        leaving = false
        active.motion.reopen()
        focus = "play"
    }
}

/// Runs its closure once, however many times it is asked.
private final class OneShot {
    private var done = false
    func run(_ f: () -> Void) {
        guard !done else { return }
        done = true
        f()
    }
    /// Spends it without running anything.
    func cancel() { done = true }
}

/// Carries the page inside the picture's frame: the first screen is mapped into the picture
/// with one uniform scale, anchored at the bottom left, so the words are already there at
/// tile size and grow out with it.
private struct PageCarrier: ViewModifier {
    @ObservedObject var stage: GamePageStage
    let origin: CGPoint

    func body(content: Content) -> some View {
        let f = stage.artFrame()
        let s = f.scale
        let screen = stage.screen
        // Each screen point p lands at b + s·p; the view scales about its own top left.
        let bx = f.rect.minX - s * screen.minX
        let by = f.rect.maxY - s * screen.maxY
        let presence = clamp01(stage.motion.presence.x)
        return content
            .scaleEffect(s, anchor: .topLeading)
            .offset(x: bx - origin.x * (1 - s), y: by - origin.y * (1 - s))
            .opacity(presence * stage.motion.sinkOpacity)
            .scaleEffect(1 - 0.035 * (1 - presence))
    }
}

/// The two lines about the game. Each line is its own piece of the chain where the system can
/// draw lines separately (tvOS 18); before that, they move as one.
private struct PageSummary: View {
    let text: String
    let motion: GamePageMotion
    @Environment(\.tvReduceMotion) private var reduced

    var body: some View {
        let base = Text(text)
            .font(TVType.body)
            .foregroundStyle(TVColor.secondary)
        Group {
            if #available(tvOS 18.0, *) {
                base.textRenderer(LineChain(
                    first: ChainMetrics(motion: motion, piece: .line1, reduced: reduced),
                    second: ChainMetrics(motion: motion, piece: .line2, reduced: reduced)))
            } else {
                base
            }
        }
        .lineSpacing(6)
        .lineLimit(2)
        .frame(maxWidth: 880, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ChainRide(motion: motion, piece: .line1))
    }
}

/// Draws the second line where its own link has it, relative to the first.
@available(tvOS 18.0, *)
private struct LineChain: TextRenderer {
    let first: ChainMetrics
    let second: ChainMetrics

    var displayPadding: EdgeInsets { EdgeInsets(top: 16, leading: 16, bottom: 48, trailing: 16) }

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        for (i, line) in layout.enumerated() {
            guard i > 0 else {
                ctx.draw(line)
                continue
            }
            var c = ctx
            c.opacity = first.opacity > 0.001 ? min(1, second.opacity / first.opacity) : 0
            let blur = (max(0, second.blur * second.blur - first.blur * first.blur)).squareRoot()
            if blur > 0.15 { c.addFilter(.blur(radius: blur)) }
            let o = line.typographicBounds.rect.origin
            c.translateBy(x: o.x, y: o.y + second.dy - first.dy)
            c.scaleBy(x: second.scaleX / first.scaleX, y: second.scaleY / first.scaleY)
            c.translateBy(x: -o.x, y: -o.y)
            c.draw(line)
        }
    }
}

// MARK: The glass button row

/// Play, End Game, the store and Stream Settings. They start as one clear drop of glass the
/// size of Play's circle, and as the row lands the drop splits: Play widens and its word
/// unclips out of a blur, the others slide out from behind it, and the glass condenses from
/// clear to frosted.
private struct PageButtons: View {
    let motion: GamePageMotion
    let running: Bool
    /// The store the game launches from, when there is more than one to pick.
    let store: String?
    let focus: FocusState<String?>.Binding
    let play: () -> Void
    let end: () -> Void
    let cycleStore: () -> Void
    let tune: () -> Void

    @Environment(\.tvReduceMotion) private var reduced
    @ScaledMetric(relativeTo: .body) private var customHeight: CGFloat = 106
    /// The label's height inside the system's glass, which adds its own padding around it.
    @ScaledMetric(relativeTo: .body) private var systemLabel: CGFloat = 58
    @State private var wordWidth: CGFloat = 64

    /// The system's own Liquid Glass buttons (tvOS 26), the same as the Home banner's Play:
    /// smooth edges, real refraction, and the system's focus light and lift. Drawing the
    /// glass by hand gave rims and masks that stair-stepped under the focus lift.
    private var system: Bool {
        if #available(tvOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        let raw = reduced ? 1 : motion.morph.x
        let p = clamp01(raw)
        let frost = reduced ? 1 : pow(clamp01(motion.glassProgress), 1.6)
        let word = running ? "Resume" : "Play"
        let height = system ? systemLabel : customHeight
        let playWidth = system ? max(150, 64 + wordWidth) : max(220, 130 + wordWidth)
        let firstLabel = lerp(height, playWidth, raw)
        let font = TVType.body.weight(.semibold)
        let style = PageGlassStyle(frost: frost)
        GlassRowLayout(morph: p, firstLabel: firstLabel, settledLabel: playWidth, spacing: 22) {
            Button(action: play) {
                HStack(spacing: 16 * p) {
                    Image(systemName: "play.fill")
                    Text(word)
                        .fixedSize()
                        .frame(width: wordWidth * p, alignment: .leading)
                        .clipped()
                        .blur(radius: 8 * (1 - p))
                        .opacity(clamp01((p - 0.35) / 0.5))
                }
                .font(font)
                .frame(width: firstLabel, height: height)
                .background {
                    Text(word).font(font).fixedSize().hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { wordWidth = $0 }
                }
            }
            .modifier(PageGlass(style: style, system: system, round: false))
            .focused(focus, equals: "play")
            .accessibilityLabel(word)
            .accessibilityIdentifier("detail-play")
            .zIndex(3)
            if running {
                Button(action: end) {
                    Label("End Game", systemImage: "stop.fill")
                        .font(font)
                        .padding(.horizontal, system ? 12 : 40)
                        .frame(height: height)
                }
                .modifier(PageGlass(style: style, system: system, round: false))
                .focused(focus, equals: "end")
                .accessibilityIdentifier("detail-end")
                .scaleEffect(lerp(0.62, 1, p))
                .zIndex(2)
            }
            if let store {
                // Which store the game launches from, for games on more than one. Each press
                // moves to the next, the way a tvOS option button does.
                Button(action: cycleStore) {
                    HStack(spacing: 12) {
                        Image(systemName: "bag")
                        Text(store)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 18, weight: .bold))
                            .opacity(0.6)
                    }
                    .font(font)
                    .padding(.horizontal, system ? 12 : 40)
                    .frame(height: height)
                }
                .modifier(PageGlass(style: style, system: system, round: false))
                .focused(focus, equals: "store")
                .accessibilityLabel("Launch from")
                .accessibilityValue(store)
                .accessibilityIdentifier("detail-store")
                .scaleEffect(lerp(0.62, 1, p))
                .zIndex(1)
            }
            Button(action: tune) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: height, height: height)
            }
            .modifier(PageGlass(style: style, system: system, round: true))
            .focused(focus, equals: "tune")
            .accessibilityLabel("Stream Settings")
            .accessibilityIdentifier("detail-tune")
            .scaleEffect(lerp(0.62, 1, p))
        }
        .focusSection()
    }
}

/// The system's Liquid Glass button on tvOS 26, the page's own glass before it.
private struct PageGlass: ViewModifier {
    let style: PageGlassStyle
    let system: Bool
    let round: Bool

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *), system {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(round ? .circle : .capsule)
                .controlSize(.large)
        } else {
            content.buttonStyle(style)
        }
    }
}

/// Lays the row out from one drop: Play at the left edge, each other button's centre moving
/// from just beside the drop to its own place. It always reports the settled row's size, so
/// the caption after it stays put while the drop splits.
private struct GlassRowLayout: Layout {
    var morph: CGFloat
    /// The first button's label width now, and once it has opened. Whatever the button adds
    /// around its label (the system glass pads it) is measured, so the row works out the
    /// settled width of the whole button.
    var firstLabel: CGFloat
    var settledLabel: CGFloat
    var spacing: CGFloat

    private func settledFirst(_ first: CGSize) -> CGFloat {
        settledLabel + max(0, first.width - firstLabel)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard let head = sizes.first else { return .zero }
        let rest = sizes.dropFirst().reduce(0) { $0 + $1.width + spacing }
        return CGSize(width: settledFirst(head) + rest, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        first.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(sizes[0]))
        // Where the drop leaves the others: tucked just behind its right side.
        let start = bounds.minX + sizes[0].height * 1.575
        var x = bounds.minX + settledFirst(sizes[0]) + spacing
        for (i, view) in subviews.enumerated().dropFirst() {
            let settled = x + sizes[i].width / 2
            view.place(at: CGPoint(x: lerp(start, settled, morph), y: bounds.midY), anchor: .center,
                       proposal: ProposedViewSize(sizes[i]))
            x += sizes[i].width + spacing
        }
    }
}

/// The page's glass: clear glass is only a hairline rim and a faint sheen; as it lands it
/// frosts (blur and tint come up, the rim quietens, a specular line appears on top), and
/// focus brings the white fill, the dark label and the lift, all scaled by the frost.
private struct PageGlassStyle: ButtonStyle {
    var frost: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        PageGlassBody(configuration: configuration, frost: frost)
    }
}

private struct PageGlassBody: View {
    let configuration: ButtonStyleConfiguration
    let frost: CGFloat
    @Environment(\.isFocused) private var focused
    @Environment(\.tvReduceMotion) private var reduced
    @Environment(\.accessibilityReduceTransparency) private var opaque

    var body: some View {
        let f: CGFloat = focused ? frost : 0
        let shape = Capsule(style: .continuous)
        let tint = 0.06 + 0.12 * frost
        configuration.label
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .foregroundStyle(Color(white: lerp(1, 0.08, f)))
            .background {
                ZStack {
                    if opaque {
                        shape.fill(Color(white: 0.2)).opacity(frost)
                    } else {
                        shape.fill(.ultraThinMaterial).opacity(frost)
                    }
                    shape.fill(LinearGradient(colors: [.white.opacity(tint + 0.05 * frost), .white.opacity(tint)],
                                              startPoint: .top, endPoint: .bottom))
                    shape.strokeBorder(.white.opacity(lerp(0.55, 0.14, frost)), lineWidth: lerp(2, 1.2, frost))
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35 * frost), .clear],
                                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.18)),
                                       lineWidth: 1.5)
                    shape.fill(Color(white: 0.94).opacity(0.93 * f))
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .scaleEffect((1 + 0.08 * f) * (configuration.isPressed ? 0.97 : 1))
            .shadow(color: .black.opacity(0.45 * f), radius: 20 * f, y: 18 * f)
            .animation(reduced ? TVMotion.reducedFade : .spring(response: 0.4, dampingFraction: 0.85), value: focused)
            .animation(reduced ? nil : .spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
}

/// Apple's own Liquid Glass button where the system has it (tvOS 26): the real refracting
/// material, with the system's focus lift and light. Older systems get the app's capsule.
struct GlassButton: ViewModifier {
    var round = false
    /// A shorter button, for the Home banner.
    var compact = false
    /// Every glass button's label is this tall, so a row of them, round or capsule, lines up.
    static let label: CGFloat = 52

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(round ? .circle : .capsule)
                .controlSize(compact ? .regular : .large)
        } else {
            content.buttonStyle(TVActionStyle(shape: .capsule, height: 86, alignment: .center))
        }
    }
}

private struct InfoRow: Identifiable {
    let name: String
    let value: String
    var id: String { name }
}

private struct Shot: Identifiable {
    let url: String
    var id: String { url }
}

/// One screenshot, full screen. Back closes it.
private struct ScreenshotViewer: View {
    let url: String
    let close: () -> Void

    var body: some View {
        TVArtwork(source: TVArtworkSource(url), title: "", titleOnPlaceholder: false, fill: false, placeholder: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .tvBackdropEntrance()
            .focusable()
            .onBack(perform: close)
            .accessibilityLabel("Screenshot")
    }
}

/// Resolution, frame rate and codec for the next launch, in a glass panel over the page.
private struct GameStreamSettings: View {
    let close: () -> Void
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @Environment(\.tvReduceMotion) private var reduced
    @State private var shown = false
    @State private var closing = false
    /// The sheet opens on the resolution in use. With no Done button there is nothing the
    /// system picks first on its own, so it is asked for, and asked again until it lands.
    @FocusState private var focused: String?

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .opacity(shown ? 1 : 0)
            VStack(alignment: .leading, spacing: 34) {
                Text("Stream Settings")
                    .font(TVType.title.weight(.bold))
                    .foregroundStyle(TVColor.primary)
                    .accessibilityAddTraits(.isHeader)
                row("Resolution") {
                    ForEach(Resolution.allCases, id: \.self) { r in
                        let mode = Self.mode(r, preferring: settings.mode.fps, membership: app.membership)
                        Button { if let mode { settings.mode = mode } } label: { Text(r.label).monospacedDigit() }
                            .buttonStyle(TVActionStyle(shape: .capsule, selected: r == settings.mode.resolution, alignment: .center))
                            .disabled(mode == nil)
                            .focused($focused, equals: "res-\(r.label)")
                            .accessibilityIdentifier("tune-res-\(r.label)")
                    }
                }
                row("Frame Rate") {
                    ForEach(StreamMode.rates, id: \.self) { fps in
                        let mode = StreamMode(resolution: settings.mode.resolution, fps: fps)
                        Button { settings.mode = mode } label: { Text("\(fps) fps").monospacedDigit() }
                            .buttonStyle(TVActionStyle(shape: .capsule, selected: fps == settings.mode.fps, alignment: .center))
                            .disabled(Capabilities.check(mode, membership: app.membership).blocked)
                    }
                }
                row("Codec") {
                    ForEach(CodecChoice.allCases, id: \.self) { c in
                        Button { settings.codec = c } label: { Text(c == .auto ? "Auto" : c.label) }
                            .buttonStyle(TVActionStyle(shape: .capsule, selected: c == settings.codec, alignment: .center))
                    }
                }
            }
            // The options float on their own, each a drop of glass over the blurred page, as
            // in the system's Control Center; a glass panel under glass buttons only clouded
            // both.
            .padding(56)
            .frame(width: 1040, alignment: .leading)
            .modifier(GlassReveal(shown: shown))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("stream-settings-sheet")
        }
        .defaultFocus($focused, "res-\(settings.mode.resolution.label)")
        .onAppear { withAnimation(reduced ? TVMotion.reducedFade : TVMotion.glassIn) { shown = true } }
        .task {
            for wait in [60, 250, 600] {
                try? await Task.sleep(for: .milliseconds(wait))
                if focused != nil || closing { return }
                focused = "res-\(settings.mode.resolution.label)"
            }
        }
        .onBack(perform: dismiss)
    }

    private func dismiss() {
        guard !closing else { return }
        closing = true
        withAnimation(reduced ? TVMotion.reducedFade : TVMotion.glassOut) { shown = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            close()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(TVType.detail.weight(.semibold))
                .tracking(1.6)
                .foregroundStyle(TVColor.tertiary)
            HStack(spacing: 14) { content() }
        }
        .focusSection()
    }

    private static func mode(_ r: Resolution, preferring fps: Int, membership: Membership?) -> StreamMode? {
        for rate in [fps, 60] {
            let m = StreamMode(resolution: r, fps: rate)
            if !Capabilities.check(m, membership: membership).blocked { return m }
        }
        return nil
    }
}

/// Black rising from the bottom and in from the left, under the words, so a bright picture
/// never washes them out; it ends in the same black as the screen.
private struct GamePageScrim: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.88), location: 0.2),
                .init(color: .black.opacity(0.5), location: 0.44),
                .init(color: .black.opacity(0.12), location: 0.66),
                .init(color: .clear, location: 0.8),
            ], startPoint: .bottom, endPoint: .top)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.72), location: 0),
                .init(color: .black.opacity(0.34), location: 0.34),
                .init(color: .clear, location: 0.62),
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.32), location: 0),
                .init(color: .clear, location: 0.16),
            ], startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}
