import SwiftUI

// Settings' background: true black, with a few soft white orbs drifting slowly behind the
// glass panels. It takes over from the game art when Settings opens: the art
// fades down to black while the light comes up and spreads.

struct TVGlowBackdrop: View {
    /// Whether Settings is on screen. The glow only animates while it is.
    let visible: Bool
    @Environment(\.tvReduceMotion) private var reduced
    /// When Settings last opened. The light spreads over the second and a half after it.
    @State private var openedAt = Date.distantPast

    var body: some View {
        ZStack {
            Color.black
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible || reduced)) { context in
                let bloom = reduced ? 1 : Self.ease(context.date.timeIntervalSince(openedAt) / 1.6)
                Canvas(rendersAsynchronously: true) { ctx, size in
                    let t = context.date.timeIntervalSinceReferenceDate
                    for glow in Self.glows {
                        glow.draw(in: &ctx, size: size, time: reduced ? 0 : t, bloom: bloom)
                    }
                }
            }
        }
        .opacity(visible ? 1 : 0)
        .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: visible ? 0.7 : 0.5), value: visible)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: visible) { _, now in if now { openedAt = .now } }
        .onAppear { if visible { openedAt = .now } }
    }

    /// Ease-out from 0 to 1 over `progress` 0...1: quick to start, long to settle.
    private static func ease(_ progress: Double) -> CGFloat {
        let p = min(max(progress, 0), 1)
        return CGFloat(1 - pow(1 - p, 3))
    }

    /// A few soft white orbs, small against the screen, so most of it stays true black and
    /// the light only shows around and through the glass.
    private static let glows: [Glow] = [
        Glow(color: .white, alpha: 0.13, x: 0.16, y: 0.80, radius: 0.24,
             wander: CGSize(width: 0.12, height: 0.08), period: 47, phase: 0),
        Glow(color: .white, alpha: 0.10, x: 0.86, y: 0.18, radius: 0.20,
             wander: CGSize(width: 0.08, height: 0.10), period: 59, phase: 1.7),
        Glow(color: .white, alpha: 0.08, x: 0.58, y: 0.94, radius: 0.22,
             wander: CGSize(width: 0.14, height: 0.05), period: 71, phase: 3.1),
        Glow(color: .white, alpha: 0.06, x: 0.42, y: 0.06, radius: 0.16,
             wander: CGSize(width: 0.10, height: 0.05), period: 83, phase: 4.4),
    ]
}

/// One pool of light: a radial fade from `color` to nothing, wandering on a slow Lissajous
/// path so the drift never visibly repeats.
private struct Glow {
    let color: Color
    let alpha: Double
    /// Centre and radius as fractions of the screen width (radius) and size (centre).
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let wander: CGSize
    /// Seconds for one loop along x; y runs at a different rate.
    let period: Double
    let phase: Double

    func draw(in ctx: inout GraphicsContext, size: CGSize, time: Double, bloom: CGFloat) {
        let a = time / period * 2 * .pi + phase
        let cx = (x + wander.width * CGFloat(sin(a))) * size.width
        let cy = (y + wander.height * CGFloat(sin(a * 1.37 + 0.8))) * size.height
        // Breathing, a few percent either way.
        let r = radius * size.width * (0.72 + 0.28 * bloom) * CGFloat(1 + 0.05 * sin(a * 0.73))
        let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        let shading = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: color.opacity(alpha * Double(bloom)), location: 0),
                .init(color: color.opacity(alpha * 0.4 * Double(bloom)), location: 0.4),
                .init(color: color.opacity(alpha * 0.1 * Double(bloom)), location: 0.75),
                .init(color: color.opacity(0), location: 1),
            ]),
            center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r
        )
        ctx.fill(Path(ellipseIn: rect), with: shading)
    }
}
