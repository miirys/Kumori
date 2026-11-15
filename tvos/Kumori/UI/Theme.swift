import SwiftUI

/// Kumori's colours: a dark plum night with blush for anything lit, and pink kept for the
/// few places that need to stand out.
enum Palette {
    static let night = Color(red: 0x16 / 255, green: 0x11 / 255, blue: 0x1B / 255)
    static let plum = Color(red: 0x1E / 255, green: 0x17 / 255, blue: 0x24 / 255)
    static let raised = Color(red: 0x2A / 255, green: 0x20 / 255, blue: 0x30 / 255)
    static let blush = Color(red: 1, green: 0xF3 / 255, blue: 0xF7 / 255)
    static let pink = Color(red: 0xF2 / 255, green: 0x7B / 255, blue: 0xA6 / 255)
    static let secondary = blush.opacity(0.62)
    static let tertiary = blush.opacity(0.4)
    static let glass = blush.opacity(0.08)
    static let hairline = blush.opacity(0.12)
}

extension Font {
    static func kumori(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// How the app moves. Things the player drives (focus) run on springs. Changes of place are
/// timed: the old view leaves quickly, the new one arrives a little slower on a long
/// ease-out, and its parts follow one after another.
enum Motion {
    static let focus = Animation.spring(response: 0.32, dampingFraction: 0.72)
    static let glide = Animation.spring(response: 0.4, dampingFraction: 0.9)
    static let arrive = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.44)
    static let leave = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.15)
    static let stagger = 0.042
    static let staggerSteps = 7
}

private struct Reveal: ViewModifier {
    let index: Int
    let dx: CGFloat
    let dy: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(x: shown ? 0 : dx, y: shown ? 0 : dy)
            .onAppear {
                withAnimation(Motion.arrive.delay(0.09 + Motion.stagger * Double(min(index, Motion.staggerSteps)))) { shown = true }
            }
    }
}

extension View {
    /// Staggered entrance: the view waits its turn, then fades up while it travels the last
    /// few points into place. No scaling and no bounce.
    func reveal(_ index: Int, dx: CGFloat = 0, dy: CGFloat = 18) -> some View {
        modifier(Reveal(index: index, dx: dx, dy: dy))
    }
}

/// A pill button: glass at rest, blush with dark text under focus.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: prominent)
    }

    private struct Pill: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.kumori(26, .semibold))
                .foregroundStyle(focused ? Palette.night : (prominent ? Palette.pink : Palette.blush))
                .padding(.horizontal, 30)
                .padding(.vertical, 16)
                .background(focused ? Palette.blush : Palette.glass, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: focused ? 0 : 1))
                .scaleEffect(configuration.isPressed ? 0.97 : (focused ? 1.05 : 1))
                .opacity(enabled ? 1 : 0.4)
                .animation(Motion.focus, value: focused)
                .animation(Motion.focus, value: configuration.isPressed)
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
                .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                .background(focused ? Palette.blush : Color.clear, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(Motion.focus, value: focused)
        }
    }
}

/// Artwork tiles: the picture lifts and gets a blush ring under focus.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration)
    }

    private struct Card: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.blush, lineWidth: focused ? 4 : 0))
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 14)
                .scaleEffect(configuration.isPressed ? 1.02 : (focused ? 1.07 : 1))
                .animation(Motion.focus, value: focused)
                .animation(Motion.focus, value: configuration.isPressed)
        }
    }
}

/// Artwork from the catalog, with the title on plum until it loads or when there is none.
struct Art: View {
    let url: String?
    let title: String

    var body: some View {
        ZStack {
            Palette.raised
            Text(title)
                .font(.kumori(24, .semibold))
                .foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center)
                .padding(16)
            if let url, let u = URL(string: url) {
                AsyncImage(url: u, transaction: Transaction(animation: .easeOut(duration: 0.3))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }
}
