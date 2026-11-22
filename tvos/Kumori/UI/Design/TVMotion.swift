import SwiftUI
import UIKit

// Motion and materials (D03).
//
// Rules, from Apple's HIG and kumori/research/01-tvos-design-guide.md section C:
// - Focus belongs to the system. Native card and borderless buttons supply lift, light and
//   parallax with the right timing. Add no extra scale, shadow, ring or sheen on top.
// - Custom motion is for things that are not focus: panels arriving, artwork cross-fading.
//   One spring, no bounce, 0.24 s.
// - Reduce Motion removes every custom pan, zoom, stagger and spring. What is left is an
//   opacity change of 0.1 s or less, or nothing.
// - Glass is for controls and overlays, never behind every label. Reduce Transparency, and
//   tvOS before 26, get an opaque neutral panel instead.

enum TVMotion {
    /// A panel, dialog or drawer arriving or leaving.
    static let panel = Animation.spring(duration: 0.24, bounce: 0)
    /// Artwork swapping after focus has rested on a new item.
    static let artFade = Animation.easeInOut(duration: 0.18)
    /// How long focus must rest on an item before the backdrop follows it.
    static let artDwell: Duration = .milliseconds(150)
    /// The only motion left when Reduce Motion is on.
    static let reducedFade = Animation.linear(duration: 0.1)
    /// Anything that follows focus (a caption stepping down, a row's platter). Matched to
    /// the system lift, so the parts of one focused item move as one.
    static let focus = Animation.spring(duration: 0.32, bounce: 0.08)
    /// A row or button lifting under focus: a little overshoot, then settled, like the
    /// system's focus lift.
    static let lift = Animation.spring(duration: 0.44, bounce: 0.16)
    /// A page arriving: a new screen opened from a tile, or a tab switched to.
    static let page = Animation.spring(duration: 0.5, bounce: 0)
    /// A Settings page replacing another on the pane: unhurried, and settling slowly at the
    /// end rather than stopping.
    static let settingsPage = Animation.spring(duration: 0.72, bounce: 0)
    /// A Home card opening into a banner under focus, and closing again when focus leaves.
    static let cardOpen = Animation.spring(duration: 0.5, bounce: 0.1)
    static let cardClose = Animation.spring(duration: 0.42, bounce: 0)
    /// One row of a Settings page arriving, after the page itself.
    static let settingsRow = Animation.spring(duration: 0.62, bounce: 0)

    /// The animation to use for a panel, honouring Reduce Motion.
    static func panel(reduced: Bool) -> Animation { reduced ? reducedFade : panel }

    /// The animation to use for an artwork swap, honouring Reduce Motion.
    static func artFade(reduced: Bool) -> Animation? { reduced ? nil : artFade }
}

// MARK: Accessibility preferences

/// Kumori reads Reduce Motion and Reduce Transparency through these keys rather than the
/// system ones, so the fixture harness can switch them on for a screenshot. In the app they
/// follow the system setting.
private struct TVReduceMotionKey: EnvironmentKey {
    static var defaultValue: Bool { UIAccessibility.isReduceMotionEnabled }
}

private struct TVReduceTransparencyKey: EnvironmentKey {
    static var defaultValue: Bool { UIAccessibility.isReduceTransparencyEnabled }
}

extension EnvironmentValues {
    var tvReduceMotion: Bool {
        get { self[TVReduceMotionKey.self] }
        set { self[TVReduceMotionKey.self] = newValue }
    }

    var tvReduceTransparency: Bool {
        get { self[TVReduceTransparencyKey.self] }
        set { self[TVReduceTransparencyKey.self] = newValue }
    }
}

/// Feeds the live system settings into the Kumori keys. Put it once at the root of the app;
/// `forced` values win, for fixtures.
struct TVAccessibilityBridge: ViewModifier {
    var forceReduceMotion: Bool?
    var forceReduceTransparency: Bool?
    @Environment(\.accessibilityReduceMotion) private var systemMotion
    @Environment(\.accessibilityReduceTransparency) private var systemTransparency

    func body(content: Content) -> some View {
        content
            .environment(\.tvReduceMotion, forceReduceMotion ?? systemMotion)
            .environment(\.tvReduceTransparency, forceReduceTransparency ?? systemTransparency)
    }
}

extension View {
    func tvAccessibilityBridge(reduceMotion: Bool? = nil, reduceTransparency: Bool? = nil) -> some View {
        modifier(TVAccessibilityBridge(forceReduceMotion: reduceMotion, forceReduceTransparency: reduceTransparency))
    }
}

// MARK: Surfaces

/// What a surface is for. Each has one material treatment.
enum TVSurfaceKind {
    /// A dialog or drawer floating over the page or a paused game.
    case overlay
    /// A grouped block sitting on the page (a status message, a settings group).
    case grouped
}

private struct TVSurface<S: Shape>: ViewModifier {
    let kind: TVSurfaceKind
    let shape: S
    @Environment(\.tvReduceTransparency) private var opaque

    @ViewBuilder
    func body(content: Content) -> some View {
        if opaque {
            content.background(TVColor.panel, in: shape)
        } else if kind == .grouped {
            // A quiet translucent fill: enough to group, not enough to compete with artwork.
            content.background(Color.white.opacity(0.06), in: shape)
        } else if #available(tvOS 26.0, *) {
            // A dark tint keeps text on the glass readable over bright artwork.
            content.glassEffect(.regular.tint(Color.black.opacity(0.45)), in: shape)
        } else {
            content
                .background(TVColor.panel.opacity(0.55), in: shape)
                .background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// The one way to put a panel behind content.
    func tvSurface(_ kind: TVSurfaceKind, radius: CGFloat = TVTokens.panelRadius) -> some View {
        modifier(TVSurface(kind: kind, shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }

    /// A dark scrim on the side of artwork that carries text, so text stays at 4.5:1 or better
    /// whatever the picture. `edge` is where the text is.
    func tvTextScrim(_ edge: Edge = .leading) -> some View {
        overlay {
            TVScrim(edge: edge).allowsHitTesting(false)
        }
    }
}

/// A gradient from `scrimNear` black at the text edge to `scrimFar` at the far side.
struct TVScrim: View {
    var edge: Edge = .leading

    var body: some View {
        let (start, end): (UnitPoint, UnitPoint) = {
            switch edge {
            case .leading: return (.leading, .trailing)
            case .trailing: return (.trailing, .leading)
            case .top: return (.top, .bottom)
            case .bottom: return (.bottom, .top)
            }
        }()
        LinearGradient(
            stops: [
                .init(color: .black.opacity(TVColor.scrimNear), location: 0),
                .init(color: .black.opacity(TVColor.scrimNear * 0.8), location: 0.35),
                .init(color: .black.opacity(TVColor.scrimFar), location: 1),
            ],
            startPoint: start, endPoint: end
        )
        .accessibilityHidden(true)
    }
}

// MARK: Appearing

private struct TVAppear: ViewModifier {
    @Environment(\.tvReduceMotion) private var reduced
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduced ? 0 : 12)
            .onAppear {
                withAnimation(TVMotion.panel(reduced: reduced)) { shown = true }
            }
    }
}

extension View {
    /// A single, quick arrival for a panel. No stagger and no blur: content that the person is
    /// about to read should be there, not performing.
    func tvAppear() -> some View { modifier(TVAppear()) }

    /// A page arriving. The page rises a little and settles while a veil in the canvas colour
    /// lifts off it. The page itself is never transparent, so the focus engine can put focus
    /// on it from the first frame; only the veil fades.
    /// `veil: false` keeps only the rise, for content arriving over a picture that has its
    /// own entrance.
    func tvPageEntrance(rise: CGFloat = 24, veil: Bool = true) -> some View {
        modifier(TVPageEntrance(rise: rise, veil: veil))
    }

    /// A full-bleed picture arriving: it fades up from black while it settles from a slight
    /// zoom, the way a backdrop does in Apple's TV app.
    func tvBackdropEntrance() -> some View { modifier(TVBackdropEntrance()) }
}

private struct TVPageEntrance: ViewModifier {
    let rise: CGFloat
    let veil: Bool
    @Environment(\.tvReduceMotion) private var reduced
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .offset(y: shown || reduced ? 0 : rise)
            .overlay {
                TVColor.canvas
                    .opacity(shown || !veil ? 0 : 1)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear {
                withAnimation(reduced ? TVMotion.reducedFade : TVMotion.page) { shown = true }
            }
    }
}

private struct TVBackdropEntrance: ViewModifier {
    @Environment(\.tvReduceMotion) private var reduced
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || reduced ? 1 : 1.06)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(reduced ? TVMotion.reducedFade : .easeOut(duration: 0.7)) { shown = true }
            }
    }
}

// MARK: Tabs

extension View {
    /// A tab's page arriving: it comes into focus out of frosted glass (a soft blur and a
    /// fade over the background) rather than appearing at once. Nothing slides.
    func tvTabEntrance(active: Bool) -> some View { modifier(TVTabEntrance(active: active)) }
}

private struct TVTabEntrance: ViewModifier {
    let active: Bool
    @Environment(\.tvReduceMotion) private var reduced
    @State private var clear = true

    func body(content: Content) -> some View {
        content
            .opacity(clear ? 1 : 0)
            .blur(radius: clear || reduced ? 0 : 22)
            .onChange(of: active) { _, now in
                guard now else { return }
                // Frosted at once, then clearing.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { clear = false }
                withAnimation(reduced ? TVMotion.reducedFade : .easeOut(duration: 0.42)) { clear = true }
            }
    }
}

// MARK: Navigation

/// Where each game tile sits on screen and what it shows, so a game's page can grow out of
/// the tile that opened it and shrink back into it. Tiles write here as they lay out; nothing
/// redraws when they do.
final class TVZoomSources {
    struct Source: Equatable {
        /// The tile's frame on screen, as drawn (focus lift included).
        var frame: CGRect
        /// The picture the tile shows, so the page starts from the same picture.
        var art: TVArtworkSource
        var radius: CGFloat
    }

    var sources: [String: Source] = [:]
}

private struct TVZoomSourcesKey: EnvironmentKey {
    static let defaultValue: TVZoomSources? = nil
}

private struct TVZoomHeldKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

private struct TVZoomIsHeldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Where tiles record themselves, set by the screen that opens game pages.
    var tvZoomSources: TVZoomSources? {
        get { self[TVZoomSourcesKey.self] }
        set { self[TVZoomSourcesKey.self] = newValue }
    }

    /// The source a game's page is open from. That tile keeps its focused look underneath,
    /// so the page shrinks back into the same shape it grew from.
    var tvZoomHeldSource: String? {
        get { self[TVZoomHeldKey.self] }
        set { self[TVZoomHeldKey.self] = newValue }
    }

    /// True inside the tile a game's page is open from.
    var tvZoomIsHeld: Bool {
        get { self[TVZoomIsHeldKey.self] }
        set { self[TVZoomIsHeldKey.self] = newValue }
    }
}

extension View {
    /// Marks this view as where a game's page opens from: the page grows out of it and
    /// shrinks back into it on Back. `lift` and `anchor` describe the scale the view draws
    /// with while focused, so the page lines up with what is on screen, not the layout box.
    func tvZoomSource(_ id: String, art: TVArtworkSource, radius: CGFloat = TVTokens.artRadius,
                      lift: CGFloat = 1, anchor: UnitPoint = .center) -> some View {
        modifier(TVZoomSourceMark(id: id, art: art, radius: radius, lift: lift, anchor: anchor))
    }
}

private struct TVZoomSourceMark: ViewModifier {
    let id: String
    let art: TVArtworkSource
    let radius: CGFloat
    let lift: CGFloat
    let anchor: UnitPoint
    @Environment(\.tvZoomSources) private var sources
    @Environment(\.tvZoomHeldSource) private var held

    func body(content: Content) -> some View {
        content
            .environment(\.tvZoomIsHeld, held == id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                // Grow the box the way the focused view does, about its anchor.
                let w = frame.width * lift, h = frame.height * lift
                let drawn = CGRect(x: frame.minX - (w - frame.width) * anchor.x,
                                   y: frame.minY - (h - frame.height) * anchor.y,
                                   width: w, height: h)
                sources?.sources[id] = .init(frame: drawn, art: art, radius: radius * lift)
            }
    }
}
