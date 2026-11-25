import SwiftUI

// Settings' background: a dark, slowly flowing field of colour behind the glass panels, like
// the system's own wallpapers. A mesh of deep blues, violet and teal whose points drift and
// whose colours breathe, so the glass always has something soft and moving to bend. It takes
// over from the game art when Settings opens: the art fades down while the colour comes up.
// Before tvOS 18 (no mesh gradients) a few soft pools of light stand in.

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
                let t = reduced ? 0 : context.date.timeIntervalSinceReferenceDate
                if #available(tvOS 18.0, *) {
                    FlowField(time: t)
                        .opacity(Double(bloom))
                        .scaleEffect(1.08 - 0.08 * bloom)
                } else {
                    Canvas(rendersAsynchronously: true) { ctx, size in
                        for glow in Self.glows {
                            glow.draw(in: &ctx, size: size, time: t, bloom: bloom)
                        }
                    }
                }
            }
            // Darker toward the bottom, where the longest lists sit, and a soft vignette so the
            // colour pools in the middle of the screen behind the glass.
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 420, endRadius: 1250)
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

/// The colour field: a 4 × 3 mesh whose inner points wander on slow, unrelated loops and
/// whose colours breathe between two palettes, so it never visibly repeats. Edge points
/// slide only along their edge, so the field always covers the screen.
@available(tvOS 18.0, *)
private struct FlowField: View {
    let time: Double

    private static let a: [Color] = [
        Color(red: 0.03, green: 0.04, blue: 0.10), Color(red: 0.07, green: 0.06, blue: 0.20), Color(red: 0.05, green: 0.10, blue: 0.22), Color(red: 0.02, green: 0.03, blue: 0.08),
        Color(red: 0.12, green: 0.07, blue: 0.30), Color(red: 0.06, green: 0.20, blue: 0.36), Color(red: 0.22, green: 0.10, blue: 0.34), Color(red: 0.04, green: 0.12, blue: 0.20),
        Color(red: 0.02, green: 0.02, blue: 0.05), Color(red: 0.05, green: 0.14, blue: 0.22), Color(red: 0.10, green: 0.05, blue: 0.18), Color(red: 0.01, green: 0.01, blue: 0.04),
    ]
    private static let b: [Color] = [
        Color(red: 0.02, green: 0.05, blue: 0.09), Color(red: 0.10, green: 0.05, blue: 0.22), Color(red: 0.03, green: 0.12, blue: 0.20), Color(red: 0.03, green: 0.02, blue: 0.08),
        Color(red: 0.05, green: 0.16, blue: 0.32), Color(red: 0.20, green: 0.09, blue: 0.36), Color(red: 0.06, green: 0.18, blue: 0.30), Color(red: 0.08, green: 0.06, blue: 0.20),
        Color(red: 0.03, green: 0.02, blue: 0.06), Color(red: 0.12, green: 0.06, blue: 0.20), Color(red: 0.04, green: 0.12, blue: 0.18), Color(red: 0.01, green: 0.02, blue: 0.04),
    ]

    var body: some View {
        let t = time
        func w(_ speed: Double, _ phase: Double, _ amp: Double) -> Float { Float(amp * sin(t * speed + phase)) }
        func p(_ x: Float, _ y: Float) -> SIMD2<Float> { SIMD2<Float>(x, y) }
        var points: [SIMD2<Float>] = []
        points.append(p(0, 0))
        points.append(p(0.33 + w(0.050, 0.0, 0.08), 0))
        points.append(p(0.66 + w(0.043, 1.3, 0.08), 0))
        points.append(p(1, 0))
        points.append(p(0, 0.5 + w(0.037, 2.1, 0.14)))
        points.append(p(0.33 + w(0.061, 0.7, 0.13), 0.5 + w(0.047, 3.3, 0.16)))
        points.append(p(0.66 + w(0.053, 4.1, 0.13), 0.5 + w(0.041, 1.9, 0.16)))
        points.append(p(1, 0.5 + w(0.033, 5.2, 0.14)))
        points.append(p(0, 1))
        points.append(p(0.33 + w(0.045, 2.8, 0.08), 1))
        points.append(p(0.66 + w(0.039, 0.4, 0.08), 1))
        points.append(p(1, 1))
        let mix = 0.5 + 0.5 * sin(t * 0.035)
        var colors: [Color] = []
        for i in Self.a.indices { colors.append(Self.a[i].mix(with: Self.b[i], by: mix)) }
        return MeshGradient(width: 4, height: 3, points: points, colors: colors, smoothsColors: true)
    }
}
