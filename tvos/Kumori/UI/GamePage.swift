import SwiftUI

// A game's page (U06). It grows out of the tile that opened it: the tile's picture swells to
// fill the screen while the screen behind goes dark, then the words come up out of a soft
// blur. Back runs it in reverse, into the same tile.

/// The picture behind a game's page and the dark that comes up behind it. The screen that
/// opens the page draws it, under the page and over its own tiles, so the picture grows out
/// of a tile in the same coordinates the tile was measured in.
final class GamePageStage: ObservableObject {
    let game: Game
    /// The tile the page grows out of. Without one the page fades up in place.
    let origin: TVZoomSources.Source?
    /// The picture fills the screen (otherwise it sits in the tile's frame).
    @Published var grown = false
    /// The picture is drawn at all. It fades in over the tile, and out in place on Back.
    @Published var shown = false
    /// Back was pressed: the picture settles back a touch as it fades.
    @Published var receding = false
    /// The page itself came up. The screen that opened it checks this, so a page that never
    /// appeared can't leave its picture over everything with nothing to press Back on.
    var presented = false

    init(game: Game, origin: TVZoomSources.Source?) {
        self.game = game
        self.origin = origin
    }
}

/// Draws a `GamePageStage`.
struct GamePageStageView: View {
    @ObservedObject var stage: GamePageStage
    @Environment(\.tvReduceMotion) private var reduced

    var body: some View {
        let origin = stage.origin
        let grown = stage.grown
        let shown = stage.shown
        let receding = stage.receding
        GeometryReader { geo in
            let screen = CGRect(origin: .zero, size: geo.size)
            let me = geo.frame(in: .global)
            let tile = origin.map { $0.frame.offsetBy(dx: -me.minX, dy: -me.minY) }
            let rect = grown ? screen : (tile ?? screen)
            let radius = grown ? 0 : (origin?.radius ?? 0)
            ZStack {
                Color.black.opacity(shown && (origin == nil || grown) ? 1 : 0)
                ZStack {
                    // The tile's own picture underneath, there from the first frame; the full
                    // size picture covers it as soon as it has loaded.
                    if let origin, origin.art != stage.game.tvHero {
                        TVArtwork(source: origin.art, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                    }
                    TVArtwork(source: stage.game.tvHero, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                    GamePageScrim().opacity(grown ? 1 : 0)
                }
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .position(x: rect.midX, y: rect.midY)
                .opacity(shown ? 1 : 0)
                // Arriving without a tile, it settles from a touch of zoom instead; leaving,
                // it sinks back a touch as it fades.
                .scaleEffect(reduced ? 1 : receding ? 0.965 : (origin == nil && !shown ? 1.04 : 1))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct DetailView: View {
    let game: Game
    /// The picture behind the page, when the screen that opened it draws it. Without one
    /// the page draws its own and fades up in place.
    let stage: GamePageStage?
    let close: () -> Void

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @Environment(\.tvReduceMotion) private var reduced
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 100
    @StateObject private var ownStage: GamePageStage
    @State private var confirming = false
    @State private var tuning = false
    @State private var viewing: String?
    /// Focus is below the first screen: the picture dims behind the lower section.
    @State private var below = false
    @FocusState private var focus: String?

    /// The words and buttons are up.
    @State private var revealed = false
    @State private var leaving = false

    /// Critically damped: the picture glides out to the edges and settles without a bounce
    /// or a hard stop, the way a card opens in Apple's TV app.
    static let grow = Animation.spring(response: 0.56, dampingFraction: 0.92)
    /// Leaving: one smooth ease for the picture, the dark and the screen coming forward.
    static let recede = Animation.timingCurve(0.32, 0.72, 0.24, 1, duration: 0.46)

    init(game: Game, stage: GamePageStage? = nil, close: @escaping () -> Void) {
        self.game = game
        self.stage = stage
        self.close = close
        _ownStage = StateObject(wrappedValue: GamePageStage(game: game, origin: nil))
    }

    private var active: GamePageStage { stage ?? ownStage }
    private var origin: TVZoomSources.Source? { active.origin }

    var body: some View {
        let running = app.session(for: game)
        ZStack(alignment: .topLeading) {
            if stage == nil { GamePageStageView(stage: ownStage) }
            // One even dim over the whole screen, edge to edge, while the lower section is
            // up, instead of a gradient that only spanned the safe area and left one side
            // of the picture uncovered.
            Color.black
                .opacity(below ? 0.74 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: 0.45), value: below)
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            // The first screen ends a little short, so the next section peeks
                            // in under the buttons and says there is more below.
                            page(running: running)
                                .frame(height: max(600, geo.size.height - Self.peek))
                                .id("top")
                            details(width: geo.size.width - 2 * TVTokens.safeX)
                                .id("details")
                        }
                        .padding(.horizontal, TVTokens.safeX)
                    }
                    .scrollClipDisabled()
                    .onChange(of: focus) { _, now in
                        below = now.map { !Self.topFocus.contains($0) } ?? true
                        // Back on the buttons: the whole first screen again, not just enough
                        // of it to show the focused one.
                        guard let now, Self.topFocus.contains(now) else { return }
                        withAnimation(reduced ? TVMotion.reducedFade : .spring(response: 0.5, dampingFraction: 0.95)) {
                            proxy.scrollTo("top", anchor: .top)
                        }
                    }
                }
            }
            hoursLeft
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .padding(.trailing, TVTokens.safeX)
                .padding(.top, 10)
                .modifier(Reveal(shown: revealed, delay: delay(1)))
        }
        .onAppear(perform: arrive)
        .defaultFocus($focus, "play")
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
        .fullScreenCover(item: Binding(get: { viewing.map(Shot.init) }, set: { viewing = $0?.url })) { shot in
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

    // MARK: The first screen

    /// Refined layout A: everything anchored low on the left, the way the Apple TV app sets a
    /// show. A small uppercase kicker, the title, one quiet line of facts, the description,
    /// then the button row, with the stream's settings as plain text at its right end.
    private func page(running: ActiveSession?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            if running != nil {
                RunningTag()
                    .padding(.bottom, 22)
                    .modifier(Reveal(shown: revealed, delay: delay(0)))
            }
            if let kicker {
                Text(kicker.uppercased())
                    .font(TVType.caption.weight(.bold))
                    .tracking(2.6)
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 10)
                    .modifier(Reveal(shown: revealed, delay: delay(0)))
            }
            Text(game.title)
                .font(.system(size: titleSize, weight: .heavy))
                .kerning(-2.2)
                .foregroundStyle(TVColor.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 6)
                .frame(maxWidth: 1300, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .modifier(Reveal(shown: revealed, delay: delay(0)))
            if !facts.isEmpty {
                Text(facts.joined(separator: "  \u{00B7}  "))
                    .font(TVType.callout.weight(.medium))
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(1)
                    .padding(.top, 20)
                    .modifier(Reveal(shown: revealed, delay: delay(1)))
            }
            if let summary = game.summary, !summary.isEmpty {
                Text(summary)
                    .font(TVType.body)
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(3)
                    .lineSpacing(6)
                    .frame(maxWidth: 880, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
                    .modifier(Reveal(shown: revealed, delay: delay(2)))
            }

            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: TVTokens.group))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 40))
            layout {
                actions(running: running)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 40) }
                specs
                    .modifier(Reveal(shown: revealed, delay: delay(3)))
            }
            .padding(.top, 38)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private func actions(running: ActiveSession?) -> some View {
        HStack(spacing: 18) {
            Button { player.play(game) } label: {
                Label(running != nil ? "Resume" : "Play", systemImage: "play.fill")
                    .fontWeight(.semibold)
                    .frame(minWidth: 150, minHeight: GlassButton.label)
            }
            .modifier(GlassButton())
            .fixedSize()
            .focused($focus, equals: "play")
            .accessibilityIdentifier("detail-play")
            if running != nil {
                Button { confirming = true } label: {
                    Label("End Game", systemImage: "stop.fill")
                        .frame(minHeight: GlassButton.label)
                }
                .modifier(GlassButton())
                .fixedSize()
                .focused($focus, equals: "end")
                .accessibilityIdentifier("detail-end")
            }
            if game.variants.count > 1, running == nil {
                // Which store the game launches from, for games on more than one. Each press
                // moves to the next, the way a tvOS option button does.
                Button { settings.cycleStore(for: game) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bag")
                        Text(storeName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 18, weight: .bold))
                            .opacity(0.6)
                    }
                    .frame(minHeight: GlassButton.label)
                }
                .modifier(GlassButton())
                .fixedSize()
                .focused($focus, equals: "store")
                .accessibilityLabel("Launch from")
                .accessibilityValue(storeName)
                .accessibilityIdentifier("detail-store")
            }
            Button { tuning = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 30, weight: .semibold))
                    // Square, at the label height the capsules use, so the circle comes out
                    // exactly as tall as the buttons beside it.
                    .frame(width: GlassButton.label, height: GlassButton.label)
            }
            .modifier(GlassButton(round: true))
            .fixedSize()
            .focused($focus, equals: "tune")
            .accessibilityLabel("Stream Settings")
            .accessibilityIdentifier("detail-tune")
        }
        .focusSection()
        // Rises and blurs in with the rest, but keeps a faint presence while away so the focus
        // engine always has Play to land on.
        .modifier(Reveal(shown: revealed, delay: delay(3), keepsFocus: true))
    }

    /// How this game will stream, and when it was last played, as quiet words in a row.
    private var specs: some View {
        HStack(alignment: .firstTextBaseline, spacing: 26) {
            Text(settings.mode.resolution.label)
            Text("\(settings.mode.fps) fps")
            Text(settings.codec == .auto ? "Auto" : settings.codec == .hevc ? "HEVC" : settings.codec.label)
            if game.lastPlayed != nil { Text(lastPlayed).opacity(0.8) }
        }
        .font(TVType.callout.weight(.semibold).monospacedDigit())
        .foregroundStyle(TVColor.tertiary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
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

    /// Screenshots, when the catalogue has them, then the description in full and the facts,
    /// on a dark glass sheet so they read over any picture.
    /// One three-column grid for the whole section: the screenshots and the three text
    /// columns under them share the same column width and gutter, so they line up, with the
    /// same margin on both sides.
    private func details(width: CGFloat) -> some View {
        let gutter: CGFloat = 48
        let column = max(300, (width - 2 * gutter) / 3)
        return VStack(alignment: .leading, spacing: 44) {
            if !game.screenshots.isEmpty {
                VStack(alignment: .leading, spacing: 22) {
                    sectionTitle("Screenshots")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: gutter) {
                            ForEach(game.screenshots, id: \.self) { url in
                                Button { viewing = url } label: {
                                    TVArtwork(source: TVArtworkSource(url), title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                                        .frame(width: column, height: column * 9 / 16)
                                }
                                .buttonStyle(.card)
                                .accessibilityLabel("Screenshot")
                            }
                        }
                        .padding(.vertical, 24)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                }
            }
            HStack(alignment: .top, spacing: gutter) {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("About")
                    Text(game.summary ?? "No description yet.")
                        .font(TVType.callout)
                        .foregroundStyle(TVColor.secondary)
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: column, alignment: .leading)
                infoColumn(column, "Information", [
                    ("Publisher", game.publisher),
                    ("Genres", game.genres.isEmpty ? nil : game.genres.map(Game.genreLabel).joined(separator: ", ")),
                ])
                infoColumn(column, "On GeForce NOW", [
                    ("Launches from", storeLine),
                    ("Your stream", "\(settings.mode.resolution.label) \u{00B7} \(settings.mode.fps) fps \u{00B7} \(settings.codec == .auto ? "Auto" : settings.codec.label)"),
                    ("Last played", lastPlayed),
                ])
            }
            // Focusable, so the remote can reach this far down and the page scrolls to it.
            .focusable()
        }
        .padding(.top, 34)
        .padding(.bottom, 120)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Reveal(shown: revealed, delay: delay(4)))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(TVType.callout.weight(.bold))
            .foregroundStyle(TVColor.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func infoColumn(_ width: CGFloat, _ title: String, _ rows: [(String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle(title)
            ForEach(rows.compactMap { r in r.1.map { InfoRow(name: r.0, value: $0) } }) { row in
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

    /// The publisher, or the store when there is none.
    private var kicker: String? {
        if let p = game.publisher, !p.isEmpty { return p }
        return nil
    }

    private var storeName: String {
        settings.variant(for: game).map { Stores.label($0.store, publisher: game.publisher) } ?? (game.store ?? "")
    }

    /// "Steam · also Epic Games Store".
    private var storeLine: String? {
        let chosen = storeName
        guard !chosen.isEmpty else { return nil }
        let others = Set(game.variants.map { Stores.label($0.store, publisher: game.publisher) }).subtracting([chosen]).sorted()
        return others.isEmpty ? chosen : "\(chosen) \u{00B7} also \(others.joined(separator: ", "))"
    }

    /// "Action · Adventure · Steam".
    private var facts: [String] {
        var parts = game.genres.prefix(3).map(Game.genreLabel)
        if !storeName.isEmpty { parts.append(storeName) }
        return parts
    }

    private var lastPlayed: String {
        guard let date = game.lastPlayed else { return "Not played yet" }
        return "Played " + date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// Each line comes up a beat after the one above it, while the picture is still settling,
    /// so the page builds in one motion rather than picture first, then words.
    private func delay(_ step: Int) -> Double {
        (origin == nil ? 0.08 : 0.2) + Double(step) * 0.06
    }

    // MARK: Arriving and leaving

    private func arrive() {
        let stage = active
        stage.presented = true
        guard !stage.shown else { return }
        if reduced {
            withAnimation(TVMotion.reducedFade) {
                stage.shown = true
                stage.grown = true
            }
        } else if stage.origin != nil {
            // Over the tile at once (it is the same picture), then out to the edges.
            withAnimation(.easeOut(duration: 0.1)) { stage.shown = true }
            withAnimation(Self.grow) { stage.grown = true }
        } else {
            stage.grown = true
            withAnimation(.easeOut(duration: 0.5)) { stage.shown = true }
        }
        revealed = true
    }

    /// The words blur away, and in the same motion the picture and the dark fade out in place,
    /// sinking back a touch, while the screen underneath comes forward to full size. It no
    /// longer flies back into the tile, which has moved by then and made it snap.
    private func leave() {
        guard !leaving else { return }
        let stage = active
        leaving = true
        revealed = false
        if reduced {
            withAnimation(TVMotion.reducedFade) { stage.shown = false }
            finish(after: 0.3)
        } else if stage.origin != nil {
            // The opening, run backwards on the same spring: the words sink into the art
            // and the art draws back into the card it came from, which is still open and
            // where it was, so the page lands on the card and becomes it.
            withAnimation(Self.grow) { stage.grown = false }
            finish(after: 0.6)
        } else {
            withAnimation(Self.recede.delay(0.04)) {
                stage.shown = false
                stage.receding = true
            }
            finish(after: 0.52)
        }
    }

    private func finish(after seconds: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            close()
        }
    }
}

/// Apple's own Liquid Glass button where the system has it (tvOS 26): the real refracting
/// material, with the system's focus lift and light. Older systems get the app's capsule.
struct GlassButton: ViewModifier {
    var round = false
    /// Every glass button's label is this tall, so a row of them, round or capsule, lines up.
    static let label: CGFloat = 52

    func body(content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(round ? .circle : .capsule)
                .controlSize(.large)
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
                Button(action: dismiss) { Label("Done", systemImage: "checkmark") }
                    .buttonStyle(TVActionStyle(shape: .capsule, height: 80, alignment: .center))
                    .fixedSize()
                    .padding(.top, 6)
            }
            .padding(56)
            .frame(width: 1040, alignment: .leading)
            .tvLiquidGlass(radius: 48)
            .shadow(color: .black.opacity(0.4), radius: 50, y: 24)
            .modifier(GlassReveal(shown: shown))
        }
        .onAppear { withAnimation(reduced ? TVMotion.reducedFade : TVMotion.glassIn) { shown = true } }
        .onBack(perform: dismiss)
    }

    private func dismiss() {
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

/// "Still running", with a dot that breathes, for a game still running in the cloud.
private struct RunningTag: View {
    @Environment(\.tvReduceMotion) private var reduced
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulse ? 2.8 : 1)
                    .opacity(pulse ? 0 : 0.45)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .white.opacity(0.6), radius: 6)
            }
            Text("Still running")
                .font(TVType.callout.weight(.semibold))
                .foregroundStyle(TVColor.primary)
        }
        .onAppear {
            guard !reduced else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// The words come up out of a soft blur: each element rises a little, sharpens from a blur
/// and fades in, after `delay`. Away together, blurring back out — so nothing lingers while the
/// page closes. `keepsFocus` (the buttons) holds a faint, still-visible presence while away
/// instead of going fully clear, so the focus engine always has something to land on; it still
/// blurs and dims, so Play no longer snaps in ahead of the page or hangs on as it closes.
private struct Reveal: ViewModifier {
    let shown: Bool
    let delay: Double
    var keepsFocus = false
    @Environment(\.tvReduceMotion) private var reduced

    func body(content: Content) -> some View {
        let on = shown || reduced
        return content
            .blur(radius: on ? 0 : 18)
            .opacity(on ? 1 : (keepsFocus ? 0.12 : 0))
            .offset(y: on ? 0 : 30)
            .scaleEffect(on ? 1 : 0.97, anchor: .bottomLeading)
            .animation(
                reduced ? TVMotion.reducedFade
                    : (shown ? .spring(response: 0.62, dampingFraction: 0.9).delay(delay) : .spring(response: 0.34, dampingFraction: 1)),
                value: shown
            )
    }
}
