import SwiftUI

/// Kumori's colours: a dark plum night with blush for anything lit, and pink kept for the
/// few places that need to stand out.
enum Palette {
    static let night = Color(red: 0x16 / 255, green: 0x11 / 255, blue: 0x1B / 255)
    static let plum = Color(red: 0x1E / 255, green: 0x17 / 255, blue: 0x24 / 255)
    static let raised = Color(red: 0x2A / 255, green: 0x20 / 255, blue: 0x30 / 255)
    static let blush = Color(red: 1, green: 0xF3 / 255, blue: 0xF7 / 255)
    static let pink = Color(red: 0xF2 / 255, green: 0x7B / 255, blue: 0xA6 / 255)
    static let violet = Color(red: 0x7A / 255, green: 0x4E / 255, blue: 0xC8 / 255)
    static let dusk = Color(red: 0x3B / 255, green: 0x1F / 255, blue: 0x4A / 255)
    static let deep = Color(red: 0x0C / 255, green: 0x09 / 255, blue: 0x12 / 255)
    static let secondary = blush.opacity(0.66)
    static let tertiary = blush.opacity(0.42)
    static let glass = blush.opacity(0.08)
    static let hairline = blush.opacity(0.14)
}

extension Font {
    static func kumori(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// How the app moves. Things the player drives (focus) run on lively springs that settle
/// fast. Changes of place glide on softer springs, and parts of a new screen follow one
/// after another.
enum Motion {
    static let focus = Animation.spring(response: 0.3, dampingFraction: 0.66)
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.6)
    static let glide = Animation.spring(response: 0.46, dampingFraction: 0.84)
    static let snappy = Animation.spring(response: 0.34, dampingFraction: 0.8)
    static let arrive = Animation.spring(response: 0.6, dampingFraction: 0.86)
    static let leave = Animation.easeIn(duration: 0.16)
    static let fade = Animation.easeInOut(duration: 0.3)
    static let stagger = 0.045
    static let staggerSteps = 8
}

private struct Reveal: ViewModifier {
    let index: Int
    let dx: CGFloat
    let dy: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 10)
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .offset(x: shown ? 0 : dx, y: shown ? 0 : dy)
            .onAppear {
                withAnimation(Motion.arrive.delay(0.06 + Motion.stagger * Double(min(index, Motion.staggerSteps)))) { shown = true }
            }
    }
}

extension View {
    /// Staggered entrance: the view waits its turn, then fades and sharpens while it glides
    /// the last few points into place.
    func reveal(_ index: Int, dx: CGFloat = 0, dy: CGFloat = 24) -> some View {
        modifier(Reveal(index: index, dx: dx, dy: dy))
    }

    /// Liquid Glass on tvOS 26 and later, frosted material before that.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(tvOS 26.0, *) {
            self.glassEffect(Glassy.make(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.35), in: shape)
                .overlay(shape.stroke(Palette.hairline, lineWidth: 1))
        }
    }

    /// Glass shaped as a rounded rectangle, the most common case.
    func glassCard(_ radius: CGFloat = 32, tint: Color? = nil) -> some View {
        glass(RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }

    /// Groups glass shapes so neighbours blend into each other on tvOS 26 and later.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 20) -> some View {
        if #available(tvOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

@available(tvOS 26.0, *)
private enum Glassy {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// The living background behind every screen: a dark plum sky with slow drifting light,
/// like clouds lit from below. It stops moving while a game is streaming.
struct Aurora: View {
    var paused = false

    var body: some View {
        if #available(tvOS 18.0, *) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { ctx in
                mesh(ctx.date.timeIntervalSinceReferenceDate)
            }
            .ignoresSafeArea()
        } else {
            fallback.ignoresSafeArea()
        }
    }

    @available(tvOS 18.0, *)
    private func mesh(_ t: TimeInterval) -> some View {
        func wave(_ speed: Double, _ phase: Double, _ amount: Double) -> Float {
            Float(sin(t * speed + phase) * amount)
        }
        let points: [SIMD2<Float>] = [
            [0, 0], [0.5 + wave(0.05, 0, 0.12), 0], [1, 0],
            [0, 0.5 + wave(0.07, 1, 0.14)], [0.5 + wave(0.06, 2, 0.18), 0.5 + wave(0.08, 3, 0.16)], [1, 0.5 + wave(0.05, 4, 0.14)],
            [0, 1], [0.5 + wave(0.04, 5, 0.16), 1], [1, 1],
        ]
        let glow = 0.5 + 0.5 * sin(t * 0.09)
        let colors: [Color] = [
            Palette.deep, Palette.dusk.opacity(0.9), Palette.night,
            Palette.night, Palette.violet.opacity(0.28 + 0.12 * glow), Palette.deep,
            Palette.dusk, Palette.pink.opacity(0.16 + 0.1 * (1 - glow)), Palette.deep,
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: colors, smoothsColors: true)
            .background(Palette.deep)
    }

    private var fallback: some View {
        ZStack {
            Palette.deep
            RadialGradient(colors: [Palette.violet.opacity(0.3), .clear], center: .init(x: 0.6, y: 0.45), startRadius: 0, endRadius: 1100)
            RadialGradient(colors: [Palette.pink.opacity(0.18), .clear], center: .init(x: 0.35, y: 1), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Palette.dusk.opacity(0.8), .clear], center: .init(x: 0.1, y: 0), startRadius: 0, endRadius: 1000)
        }
    }
}

/// A pill button: glass at rest, blush with dark text under focus.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var icon: String?

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: prominent, icon: icon)
    }

    private struct Pill: View {
        let configuration: Configuration
        let prominent: Bool
        let icon: String?
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            HStack(spacing: 12) {
                if let icon { Image(systemName: icon).font(.system(size: 24, weight: .bold)) }
                configuration.label
            }
            .font(.kumori(27, .semibold))
            .foregroundStyle(focused ? Palette.night : (prominent ? Palette.blush : Palette.blush))
            .padding(.horizontal, 34)
            .padding(.vertical, 18)
            .background {
                Capsule()
                    .fill(focused ? Palette.blush : (prominent ? Palette.pink.opacity(0.32) : .clear))
                    .shadow(color: focused ? Palette.pink.opacity(0.45) : .clear, radius: 22, y: 10)
            }
            .glass(Capsule(), tint: prominent && !focused ? Palette.pink.opacity(0.35) : nil)
            .scaleEffect(configuration.isPressed ? 0.95 : (focused ? 1.08 : 1))
            .opacity(enabled ? 1 : 0.4)
            .animation(Motion.focus, value: focused)
            .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// A settings row: label on the left, value on the right, one blush highlight under focus.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.kumori(27, .medium))
                .foregroundStyle(focused ? Palette.night : Palette.blush)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(focused ? Palette.blush : Color.clear)
                        .shadow(color: focused ? .black.opacity(0.35) : .clear, radius: 18, y: 8)
                }
                .scaleEffect(configuration.isPressed ? 0.98 : (focused ? 1.025 : 1))
                .animation(Motion.focus, value: focused)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// Artwork tiles: the picture lifts, catches a moving sheen and gets a blush ring under focus.
struct CardButtonStyle: ButtonStyle {
    var radius: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration, radius: radius)
    }

    private struct Card: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isFocused) private var focused
        @State private var sheen = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: sheen ? geo.size.width * 1.2 : -geo.size.width * 0.8)
                            .opacity(focused ? 1 : 0)
                    }
                    .allowsHitTesting(false)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Palette.blush.opacity(focused ? 0.95 : 0.08), lineWidth: focused ? 4 : 1))
                .shadow(color: .black.opacity(focused ? 0.55 : 0.2), radius: focused ? 34 : 12, y: focused ? 22 : 6)
                .scaleEffect(configuration.isPressed ? 1.02 : (focused ? 1.09 : 1))
                .animation(Motion.focus, value: focused)
                .animation(Motion.press, value: configuration.isPressed)
                .onChange(of: focused) { _, now in
                    sheen = false
                    if now { withAnimation(.easeInOut(duration: 0.9).delay(0.08)) { sheen = true } }
                }
        }
    }
}

/// Artwork from the catalog, with the title on plum until it loads or when there is none.
struct Art: View {
    let url: String?
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.raised, Palette.dusk], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(title)
                .font(.kumori(24, .semibold))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
            if let url, let u = URL(string: url) {
                AsyncImage(url: u, transaction: Transaction(animation: .easeOut(duration: 0.45))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill).transition(.opacity.combined(with: .scale(scale: 1.04)))
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }
}

/// A small uppercase heading over a group of settings or a rail.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.kumori(19, .bold)).kerning(1.8).foregroundStyle(Palette.tertiary)
    }
}

/// A spinning ring of light, for waiting.
struct Spinner: View {
    var size: CGFloat = 86
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Palette.blush.opacity(0.12), lineWidth: 8)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(AngularGradient(colors: [Palette.pink.opacity(0), Palette.pink, Palette.blush], center: .center), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { turning = true } }
    }
}
