import SwiftUI

// Settings' background: true black, with a few soft pools of coloured light drifting slowly
// behind the glass panels. It takes over from the game art when Settings opens: the art
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

    /// Quiet colours, low in the frame and to the sides, so the panels sit on darkness and
    /// the light shows around and through them.
    private static let glows: [Glow] = [
        Glow(color: Color(red: 0.36, green: 0.30, blue: 0.95), alpha: 0.34, x: 0.18, y: 0.78, radius: 0.55,
             wander: CGSize(width: 0.10, height: 0.06), period: 47, phase: 0),
        Glow(color: Color(red: 0.92, green: 0.32, blue: 0.62), alpha: 0.24, x: 0.84, y: 0.22, radius: 0.48,
             wander: CGSize(width: 0.08, height: 0.08), period: 59, phase: 1.7),
        Glow(color: Color(red: 0.10, green: 0.62, blue: 0.72), alpha: 0.22, x: 0.62, y: 0.92, radius: 0.5,
             wander: CGSize(width: 0.12, height: 0.05), period: 71, phase: 3.1),
        Glow(color: Color(red: 0.55, green: 0.35, blue: 0.90), alpha: 0.16, x: 0.40, y: 0.10, radius: 0.42,
             wander: CGSize(width: 0.09, height: 0.05), period: 83, phase: 4.4),
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
                .init(color: color.opacity(alpha * 0.45 * Double(bloom)), location: 0.45),
                .init(color: color.opacity(0), location: 1),
            ]),
            center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r
        )
        ctx.fill(Path(ellipseIn: rect), with: shading)
    }
}
