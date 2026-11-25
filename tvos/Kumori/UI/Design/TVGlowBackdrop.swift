import SwiftUI

// Settings' background: white light moving through dark smoke on black, only shades of
// white (SettingsLight.metal). The light wanders on paths taken from noise, so it never runs
// on a loop. It is drawn by the GPU at a third of the screen's size and scaled up, which a
// field this soft can't tell apart from full size, at the screen's full frame rate, and only
// while Settings is on screen. It takes over from the game art when Settings opens: the art
// fades down while the light comes up.

struct TVGlowBackdrop: View {
    /// Whether Settings is on screen. The light only moves while it is.
    let visible: Bool
    @Environment(\.tvReduceMotion) private var reduced
    /// When Settings last opened. The light spreads over the second and a half after it.
    @State private var openedAt = Date.distantPast

    /// The size the light is drawn at, before it is scaled to the screen.
    private static let field = CGSize(width: 640, height: 360)
    /// Seconds count from here, so the shader's clock stays small and smooth.
    private static let epoch = Date()
    /// Where the light starts: a moment that looks good as a still frame (Reduce Motion).
    private static let start: Double = 40

    var body: some View {
        ZStack {
            Color.black
            TimelineView(.animation(minimumInterval: nil, paused: !visible || reduced)) { context in
                let bloom = reduced ? 1 : Self.ease(context.date.timeIntervalSince(openedAt) / 1.6)
                let t = reduced ? Self.start : Self.start + context.date.timeIntervalSince(Self.epoch)
                    .truncatingRemainder(dividingBy: 20_000)
                light(time: t)
                    .opacity(Double(bloom))
                    .scaleEffect(1.08 - 0.08 * bloom)
            }
            // A faint fixed grain, drawn once, so the long dark gradients don't band.
            Rectangle()
                .fill(Color.black)
                .colorEffect(ShaderLibrary.kumoriSettingsGrain())
                .blendMode(.plusLighter)
            // Darker toward the bottom, where the longest lists sit, and a soft vignette so the
            // light pools in the middle of the screen behind the glass.
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: 420, endRadius: 1250)
        }
        .opacity(visible ? 1 : 0)
        .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: visible ? 0.7 : 0.5), value: visible)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: visible) { _, now in if now { openedAt = .now } }
        .onAppear { if visible { openedAt = .now } }
    }

    /// The light at `time`, drawn small and scaled up to cover the screen.
    private func light(time: Double) -> some View {
        let f = Self.field
        let scale = TVTokens.stage.width / f.width
        return Rectangle()
            .fill(Color.black)
            .colorEffect(ShaderLibrary.kumoriSettingsLight(.float2(f), .float(Float(time))))
            .frame(width: f.width, height: f.height)
            .scaleEffect(scale)
            .frame(width: TVTokens.stage.width, height: TVTokens.stage.height)
    }

    /// Ease-out from 0 to 1 over `progress` 0...1: quick to start, long to settle.
    private static func ease(_ progress: Double) -> CGFloat {
        let p = min(max(progress, 0), 1)
        return CGFloat(1 - pow(1 - p, 3))
    }
}
