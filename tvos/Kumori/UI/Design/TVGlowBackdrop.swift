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

}
