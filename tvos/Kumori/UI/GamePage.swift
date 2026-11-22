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
    /// The picture is drawn at all. It fades in over the tile and out into it.
    @Published var shown = false

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
        GeometryReader { geo in
            let screen = CGRect(origin: .zero, size: geo.size)
            let me = geo.frame(in: .global)
            let tile = origin.map { $0.frame.offsetBy(dx: -me.minX, dy: -me.minY) }
            let rect = grown ? screen : (tile ?? screen)
            let radius = grown ? 0 : (origin?.radius ?? 0)
            ZStack {
                Color.black.opacity(origin == nil ? (shown ? 1 : 0) : (grown ? 1 : 0))
                ZStack {
                    TVArtwork(source: stage.game.tvHero, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                    // A poster or banner tile hands over to the wide picture as it grows.
                    if let origin, origin.art != stage.game.tvHero {
                        TVArtwork(source: origin.art, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                            .opacity(grown ? 0 : 1)
                    }
                    GamePageScrim().opacity(grown ? 1 : 0)
                }
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .position(x: rect.midX, y: rect.midY)
                .opacity(shown ? 1 : 0)
                // Arriving without a tile, it settles from a touch of zoom instead.
                .scaleEffect(origin == nil && !shown && !reduced ? 1.04 : 1)
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
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 92
    @StateObject private var ownStage: GamePageStage
    @State private var confirming = false
    @FocusState private var focus: String?

    /// The words and buttons are up.
    @State private var revealed = false
    @State private var leaving = false

    private static let grow = Animation.spring(duration: 0.58, bounce: 0.08)
    private static let shrink = Animation.spring(duration: 0.46, bounce: 0)

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
        ZStack(alignment: .bottomLeading) {
            if stage == nil { GamePageStageView(stage: ownStage) }
            page(running: running)
                .padding(.bottom, TVTokens.safeY)
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
        // `.contain` first, so the identifier names the page and doesn't replace the
        // buttons' own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-\(game.id)")
    }

    // MARK: The words

    private func page(running: ActiveSession?) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: TVTokens.section))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: TVTokens.section))
        return layout {
            VStack(alignment: .leading, spacing: 0) {
                if running != nil {
                    RunningTag()
                        .padding(.bottom, 20)
                        .modifier(Reveal(shown: revealed, delay: delay(0)))
                }
                Text(game.title)
                    .font(.system(size: titleSize, weight: .bold))
                    .kerning(-1.2)
                    .foregroundStyle(TVColor.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 6)
                    .accessibilityAddTraits(.isHeader)
                    .modifier(Reveal(shown: revealed, delay: delay(0)))
                if !facts.isEmpty {
                    Text(facts)
                        .font(TVType.callout.weight(.semibold))
                        .foregroundStyle(TVColor.secondary)
                        .lineLimit(1)
                        .padding(.top, 14)
                        .modifier(Reveal(shown: revealed, delay: delay(1)))
                }
                if let summary = game.summary, !summary.isEmpty {
                    Text(summary)
                        .font(TVType.body)
                        .foregroundStyle(TVColor.secondary)
                        .lineLimit(3)
                        .lineSpacing(4)
                        .padding(.top, 24)
                        .modifier(Reveal(shown: revealed, delay: delay(2)))
                }
                actions(running: running)
                    .padding(.top, 44)
                    .modifier(Reveal(shown: revealed, delay: delay(3)))
            }
            .frame(maxWidth: 960, alignment: .leading)

            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }

            info
                .modifier(Reveal(shown: revealed, delay: delay(4)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(running: ActiveSession?) -> some View {
        HStack(spacing: 22) {
            Button { player.play(game) } label: {
                Label(running != nil ? "Resume" : "Play", systemImage: "play.fill")
                    .frame(minWidth: 170)
            }
            .buttonStyle(TVActionStyle(shape: .capsule, height: 84, alignment: .center))
            .fixedSize()
            .focused($focus, equals: "play")
            .accessibilityIdentifier("detail-play")
            if running != nil {
                Button { confirming = true } label: {
                    Label("End Game", systemImage: "xmark")
                }
                .buttonStyle(TVActionStyle(shape: .capsule, height: 84, alignment: .center))
                .fixedSize()
                .focused($focus, equals: "end")
                .accessibilityIdentifier("detail-end")
            }
        }
        .focusSection()
    }

    /// "Kuro Games · Action · Adventure"
    private var facts: String {
        var parts: [String] = []
        if let publisher = game.publisher, !publisher.isEmpty, publisher != game.store { parts.append(publisher) }
        parts += game.genres.prefix(2).map(Game.genreLabel)
        return parts.joined(separator: "  \u{00B7}  ")
    }

    /// Where it launches from and how it will stream, as labels and values.
    private var info: some View {
        Grid(alignment: .leading, horizontalSpacing: 64, verticalSpacing: 30) {
            GridRow {
                InfoItem(label: "Store", value: game.store ?? "Unknown")
                InfoItem(label: "Stream", value: "\(settings.mode.resolution.label) \u{00B7} \(settings.mode.fps) fps")
            }
            GridRow {
                InfoItem(label: "Codec", value: settings.codec == .auto ? "Auto" : settings.codec.label)
                InfoItem(label: "Last Played", value: lastPlayed)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var lastPlayed: String {
        guard let date = game.lastPlayed else { return "Never" }
        let words = date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Each line comes up a beat after the one above it, once the picture has landed.
    private func delay(_ step: Int) -> Double {
        (origin == nil ? 0.1 : 0.26) + Double(step) * 0.05
    }

    // MARK: Arriving and leaving

    private func arrive() {
        let stage = active
        guard !stage.shown else { return }
        if reduced {
            withAnimation(TVMotion.reducedFade) {
                stage.shown = true
                stage.grown = true
            }
        } else if stage.origin != nil {
            // Over the tile at once (it is the same picture), then out to the edges.
            withAnimation(.easeOut(duration: 0.12)) { stage.shown = true }
            withAnimation(Self.grow) { stage.grown = true }
        } else {
            stage.grown = true
            withAnimation(.easeOut(duration: 0.6)) { stage.shown = true }
        }
        revealed = true
    }

    private func leave() {
        guard !leaving else { return }
        let stage = active
        leaving = true
        revealed = false
        if reduced || stage.origin == nil {
            withAnimation(reduced ? TVMotion.reducedFade : .easeIn(duration: 0.28)) { stage.shown = false }
            finish(after: 0.3)
        } else {
            // Back into the tile, then a short fade so the tile's own title comes back softly.
            withAnimation(Self.shrink.delay(0.05)) { stage.grown = false }
            withAnimation(.easeIn(duration: 0.14).delay(0.38)) { stage.shown = false }
            finish(after: 0.54)
        }
    }

    private func finish(after seconds: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            close()
        }
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

/// A label over its value.
private struct InfoItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(TVType.detail.weight(.semibold))
                .tracking(1.6)
                .foregroundStyle(TVColor.tertiary)
            Text(value)
                .font(TVType.callout.weight(.medium))
                .foregroundStyle(TVColor.primary)
                .lineLimit(1)
        }
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

/// Opacity and a soft blur, after `delay`. Away at once, together.
private struct Reveal: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.tvReduceMotion) private var reduced

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown || reduced ? 0 : 12)
            .animation(
                reduced ? TVMotion.reducedFade
                    : (shown ? .easeOut(duration: 0.5).delay(delay) : .easeIn(duration: 0.12)),
                value: shown
            )
    }
}
