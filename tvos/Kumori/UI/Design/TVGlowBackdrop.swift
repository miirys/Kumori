import SwiftUI

// Settings' background: threads and veils of white silk flowing on black, lit by soft
// lights that wander the whole screen (SettingsLight.metal). Only shades of white, and the
// paths come from noise, so nothing runs on a loop or settles in the middle. It is drawn by
// the GPU at a third of the screen's size and scaled up, which a field this soft can't tell
// apart from full size, at the screen's full frame rate, and only while Settings is on
// screen or fading.

struct TVGlowBackdrop: View {
    /// Whether Settings is on screen. The light only moves while it is (and while it fades).
    let visible: Bool
    @Environment(\.tvReduceMotion) private var reduced
    /// The black ground, which hides the game art behind it.
    @State private var ground: Double = 0
    /// The light itself, added on top of whatever is below.
    @State private var glow: Double = 0
    /// The light is moving: from when Settings opens until it has faded out after leaving.
    @State private var running = false

    /// The size the light is drawn at, before it is scaled to the screen.
    private static let field = CGSize(width: 640, height: 360)
    /// Seconds count from here, so the shader's clock stays small and smooth.
    private static let epoch = Date()
    /// Where the light starts: a moment that looks good as a still frame (Reduce Motion).
    private static let start: Double = 30

    var body: some View {
        ZStack {
            // The ground comes up a moment after the light and goes first, so on the way in
            // the light washes over the game's art before the art sinks away under it, and on
            // the way out the art comes up under the light before the light lets go. One
            // dissolves into the other instead of the screen dipping to black between them.
            Color.black.opacity(ground)
            ZStack {
                TimelineView(.animation(minimumInterval: nil, paused: !running || reduced)) { context in
                    let t = reduced ? Self.start : Self.start + context.date.timeIntervalSince(Self.epoch)
                        .truncatingRemainder(dividingBy: 20_000)
                    light(time: t)
                }
                // A faint fixed grain, drawn once, so the long dark gradients don't band.
                Rectangle()
                    .fill(Color.black)
                    .colorEffect(ShaderLibrary.kumoriSettingsGrain())
                    .blendMode(.plusLighter)
            }
            .blendMode(.plusLighter)
            .opacity(glow)
            .scaleEffect(reduced ? 1 : 1.03 - 0.03 * glow)
            // A little darker toward the bottom, where the longest lists sit.
            LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                .opacity(ground)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard visible else { return }
            running = true
            ground = 1
            glow = 1
        }
        .onChange(of: visible) { _, now in
            let fade = reduced ? 0.25 : 0.9
            if now {
                running = true
                withAnimation(.easeInOut(duration: fade)) { glow = 1 }
                withAnimation(.easeInOut(duration: fade).delay(reduced ? 0 : 0.2)) { ground = 1 }
            } else {
                withAnimation(.easeInOut(duration: reduced ? fade : 0.7)) { ground = 0 }
                withAnimation(.easeInOut(duration: fade).delay(reduced ? 0 : 0.15)) { glow = 0 }
            }
        }
        // Stops the light once it has faded out, so nothing is drawn behind the other tabs.
        .task(id: visible) {
            guard !visible else { return }
            try? await Task.sleep(for: .milliseconds(1200))
            if !Task.isCancelled, !visible { running = false }
        }
    }

    /// Compiles Settings' shaders in the background at launch. Left to first use, SwiftUI
    /// compiled them on the main thread as Settings opened, which held the screen for a
    /// fraction of a second.
    static func prewarm() {
        guard #available(tvOS 18.0, *) else { return }
        Task.detached(priority: .utility) {
            try? await ShaderLibrary.kumoriSettingsLight(.float2(CGSize(width: 640, height: 360)), .float(0),
                                                         .float4(0, 0, 0, 0), .float4(0, 0, 0, 0)).compile(as: .colorEffect)
            try? await ShaderLibrary.kumoriSettingsGrain().compile(as: .colorEffect)
        }
    }

    /// The light at `time`, drawn small and scaled up to cover the screen.
    private func light(time: Double) -> some View {
        let f = Self.field
        let scale = TVTokens.stage.width / f.width
        let l0 = Self.lightPath(time, 0), l1 = Self.lightPath(time, 1)
        let l2 = Self.lightPath(time, 2), l3 = Self.lightPath(time, 3)
        return Rectangle()
            .fill(Color.black)
            .colorEffect(ShaderLibrary.kumoriSettingsLight(.float2(f), .float(Float(time)),
                                                           .float4(l0.x, l0.y, l1.x, l1.y),
                                                           .float4(l2.x, l2.y, l3.x, l3.y)))
            .frame(width: f.width, height: f.height)
            .scaleEffect(scale)
            .frame(width: TVTokens.stage.width, height: TVTokens.stage.height)
    }

    // MARK: Light paths
    // The same noise as SettingsLight.metal's, so the lights wander as they did when the
    // shader worked their paths out for every pixel.

    private static func fract(_ x: Float) -> Float { x - x.rounded(.down) }

    private static func hash(_ x: Float, _ y: Float) -> Float {
        var px = fract(x * 123.34), py = fract(y * 456.21)
        let d = px * (px + 45.32) + py * (py + 45.32)
        px += d; py += d
        return fract(px * py)
    }

    private static func noise(_ x: Float, _ y: Float) -> Float {
        let ix = x.rounded(.down), iy = y.rounded(.down)
        let fx = x - ix, fy = y - iy
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy), b = hash(ix + 1, iy), c = hash(ix, iy + 1), d = hash(ix + 1, iy + 1)
        let top = a + (b - a) * ux, bottom = c + (d - c) * ux
        return top + (bottom - top) * uy
    }

    private static func ease(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Where light `k` is at time `t`, as fractions of the field: two layers of noise, slow and
    /// quicker, stretched so the light reaches every edge and a little past it.
    static func lightPath(_ time: Double, _ k: Float) -> SIMD2<Float> {
        let t = Float(time)
        let nx = noise(t * 0.031 + k * 13.7, k * 7.1) * 0.6 + noise(t * 0.083 + k * 3.3, k * 1.9 + 5) * 0.4
        let ny = noise(k * 4.3 + 2, t * 0.027 + k * 11.1) * 0.6 + noise(k * 9.7, t * 0.071 + k * 2.3 + 8) * 0.4
        return SIMD2(ease(0.25, 0.75, nx) * 1.3 - 0.15, ease(0.25, 0.75, ny) * 1.3 - 0.15)
    }

}
