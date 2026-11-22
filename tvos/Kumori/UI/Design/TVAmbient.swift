import SwiftUI

// The living background behind Home, Library, Search and Settings: the art of the game that
// has focus, blurred into soft glass, darkened so text on it stays readable, and drifting
// very slowly. When focus rests on another game the new art blooms in over the old one.

/// Which game's art the background shows. One per `MainView`; anything that puts focus on a
/// game tells it, and only the background itself watches it, so moving focus redraws nothing
/// else.
@MainActor
final class TVAmbient: ObservableObject {
    @Published private(set) var source: TVArtworkSource = .missing
    private var pending: Task<Void, Never>?

    /// Show `source` once focus has rested on it for a moment, so flicking along a shelf
    /// doesn't strobe the whole screen.
    func show(_ source: TVArtworkSource) {
        pending?.cancel()
        guard source != self.source, source != .missing else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: TVAmbient.dwell)
            guard !Task.isCancelled else { return }
            self?.source = source
        }
    }

    /// Show `source` straight away, without waiting. For the first frame of a screen.
    func set(_ source: TVArtworkSource) {
        pending?.cancel()
        self.source = source
    }

    nonisolated static let dwell: Duration = .milliseconds(260)
}

private struct TVAmbientKey: EnvironmentKey {
    static let defaultValue: TVAmbient? = nil
}

extension EnvironmentValues {
    /// The background to tell when a game gets focus. Nil outside `MainView`.
    var tvAmbient: TVAmbient? {
        get { self[TVAmbientKey.self] }
        set { self[TVAmbientKey.self] = newValue }
    }
}

/// The background itself. Put it behind the tab view, full bleed.
struct TVAmbientBackdrop: View {
    @ObservedObject var ambient: TVAmbient
    @Environment(\.tvReduceMotion) private var reduced
    @Environment(\.tvReduceTransparency) private var opaque

    var body: some View {
        ZStack {
            TVColor.canvas
            if !opaque, ambient.source != .missing {
                TVAmbientArt(source: ambient.source, drifting: !reduced)
                    .id(ambient.source)
                    .transition(reduced
                        ? .opacity
                        : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.05)),
                                      removal: .opacity))
            }
            // The veil: dark enough that secondary text clears 4.5:1 on the brightest art,
            // darker still at the bottom where shelves and captions sit.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .black.opacity(0.52), location: 0.45),
                    .init(color: .black.opacity(0.78), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            // A soft vignette, so the screen's edges sit back and the middle glows.
            RadialGradient(colors: [.clear, .black.opacity(0.42)], center: .center,
                           startRadius: 380, endRadius: 1200)
        }
        .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: 0.9), value: ambient.source)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One game's art as frosted glass. Blurred small and drawn large, which looks the same as a
/// full-size blur at a fraction of the cost, and leaves the GPU free for focus motion.
private struct TVAmbientArt: View {
    let source: TVArtworkSource
    let drifting: Bool
    @State private var drift = false

    /// The art is blurred at this size, then scaled up to cover the screen with room to drift.
    private static let small = CGSize(width: 480, height: 270)
    private static let cover: CGFloat = 4.4

    var body: some View {
        TVArtwork(source: source, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
            .frame(width: Self.small.width, height: Self.small.height)
            .blur(radius: 14, opaque: true)
            .saturation(1.3)
            .drawingGroup()
            .scaleEffect(Self.cover * (drift ? 1.07 : 1))
            .offset(x: drift ? -36 : 36, y: drift ? 14 : -14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear {
                guard drifting else { return }
                // One slow breath across half a minute, back and forth: there, but never
                // something the eye follows.
                withAnimation(.easeInOut(duration: 28).repeatForever(autoreverses: true)) { drift = true }
            }
    }
}
