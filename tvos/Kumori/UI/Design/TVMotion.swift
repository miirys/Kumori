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
            content.glassEffect(.regular, in: shape)
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
}
