import SwiftUI
import UIKit

/// Kumori's colours: true black for an OLED screen, white for anything lit, and greys in
/// between. The only colour on screen comes from the games themselves.
enum Palette {
    static let black = Color.black
    static let text = Color.white
    static let secondary = Color.white.opacity(0.64)
    static let tertiary = Color.white.opacity(0.4)
    /// Resting surfaces: rows, cards and placeholders.
    static let surface = Color.white.opacity(0.08)
    static let raised = Color.white.opacity(0.16)
    static let hairline = Color.white.opacity(0.12)
    /// What a focused control is filled with, and what sits on it.
    static let focus = Color.white
    static let onFocus = Color.black
}

/// Where things line up. Every screen starts its content at the same distance from the
/// left edge, so titles, rails and buttons share one line from page to page.
enum Layout {
    static let inset: CGFloat = 96
    static let tileWidth: CGFloat = 384
    static let tileSpacing: CGFloat = 40
}

extension Font {
    static func kumori(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// How the app moves. Focus answers at once on a firm spring that settles without a
/// wobble. Content glides on softer, longer springs. Nothing bounces.
enum Motion {
    static let focus = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.75)
    static let snappy = Animation.spring(response: 0.34, dampingFraction: 0.88)
    static let glide = Animation.spring(response: 0.5, dampingFraction: 0.9)
    static let arrive = Animation.spring(response: 0.7, dampingFraction: 0.92)
    static let leave = Animation.easeIn(duration: 0.18)
    static let fade = Animation.easeInOut(duration: 0.35)
    /// Backgrounds change slowly, so moving along a rail feels calm.
    static let crossfade = Animation.easeInOut(duration: 0.8)
    static let stagger = 0.055
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
                guard !shown else { return }
                withAnimation(Motion.arrive.delay(0.04 + Motion.stagger * Double(min(index, Motion.staggerSteps)))) { shown = true }
            }
    }
}

extension View {
    /// Staggered entrance: the view waits its turn, then fades in while it glides the last
    /// few points into place.
    func reveal(_ index: Int, dx: CGFloat = 0, dy: CGFloat = 22) -> some View {
        modifier(Reveal(index: index, dx: dx, dy: dy))
    }

    /// Liquid Glass on tvOS 26 and later, a dark frosted material before that.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(tvOS 26.0, *) {
            self.glassEffect(Glassy.make(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.5), in: shape)
                .overlay(shape.stroke(Palette.hairline, lineWidth: 1))
        }
    }

    /// Glass shaped as a rounded rectangle, the most common case.
    func glassCard(_ radius: CGFloat = 32, tint: Color? = nil) -> some View {
        glass(RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
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

// MARK: Images

/// Downloads artwork once and keeps it, decoded at the size it is shown, so scrolling back
/// over a rail or changing the background never waits for the network again.
@MainActor
final class Images {
    static let shared = Images()
    private let cache = NSCache<NSString, UIImage>()
    private var loading: [String: Task<UIImage?, Never>] = [:]

    init() { cache.countLimit = 400 }

    private static func key(_ url: String, _ width: Int) -> NSString { "\(width)|\(url)" as NSString }

    func cached(_ url: String, width: Int) -> UIImage? { cache.object(forKey: Self.key(url, width)) }

    func load(_ url: String, width: Int) async -> UIImage? {
        let k = Self.key(url, width)
        if let hit = cache.object(forKey: k) { return hit }
        if let running = loading[k as String] { return await running.value }
        let task = Task<UIImage?, Never> {
            guard let u = URL(string: url), let answer = try? await URLSession.shared.data(from: u) else { return nil }
            let data = answer.0
            return await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let image = UIImage(data: data) else { return nil }
                // Decoded here, off the main thread, at no more than the size it is drawn.
                let w = CGFloat(width)
                if image.size.width > w {
                    let size = CGSize(width: w, height: (image.size.height * w / image.size.width).rounded())
                    return await image.byPreparingThumbnail(ofSize: size) ?? image
                }
                return await image.byPreparingForDisplay() ?? image
            }.value
        }
        loading[k as String] = task
        let image = await task.value
        loading[k as String] = nil
        if let image { cache.setObject(image, forKey: k) }
        return image
    }
}

/// Artwork from the catalog. It fades in once it has loaded. Until then, or when there is
/// none, a dark card shows the title.
struct Art: View {
    let url: String?
    let title: String
    /// The widest it will be drawn, in pixels.
    var width = 800
    var placeholder = true

    @State private var image: UIImage?

    var body: some View {
        // The frame is whatever the parent gives. The picture fills it and is cut to it, so a
        // wide picture can never push the layout past the edges of the screen.
        Rectangle()
            .fill(placeholder ? Palette.surface : Color.clear)
            .overlay {
                if placeholder, image == nil, !title.isEmpty {
                    Text(title)
                        .font(.kumori(24, .semibold))
                        .foregroundStyle(Palette.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(18)
                }
            }
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = Images.shared.cached(url, width: width) {
                image = hit
                return
            }
            image = nil
            let loaded = await Images.shared.load(url, width: width)
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.45)) { image = loaded }
        }
    }
}

// MARK: Background

/// The game whose art fills the background: the one in focus, or the last one played.
@MainActor
final class Spotlight: ObservableObject {
    @Published private(set) var game: Game?
    private var pending: Task<Void, Never>?

    /// Moves the spotlight once focus has rested a moment, so sweeping along a rail
    /// doesn't flash every picture on the way.
    func focus(_ g: Game?) {
        pending?.cancel()
        guard let g, g.id != game?.id else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 240_000_000)
            if Task.isCancelled { return }
            withAnimation(Motion.crossfade) { self?.game = g }
        }
    }

    /// Sets the spotlight straight away, when nothing is in it yet.
    func settle(_ g: Game?) {
        guard game == nil, let g else { return }
        game = g
    }
}

/// The background behind every screen: the spotlit game's art, sharp at the top right and
/// fading into black towards the text, over a soft wash of the same picture. New art
/// cross-fades in while it settles from a slight zoom.
struct Backdrop: View {
    let url: String?

    var body: some View {
        ZStack {
            Palette.black
            if let url {
                BackdropArt(url: url).id(url).transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(Motion.crossfade, value: url)
        .allowsHitTesting(false)
    }
}

private struct BackdropArt: View {
    let url: String
    @State private var settled = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                // A small copy, blown up and blurred: the game's colour, everywhere.
                Art(url: url, title: "", width: 480, placeholder: false)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: 60, opaque: true)
                    .opacity(0.4)
                Art(url: url, title: "", width: 1920, placeholder: false)
                    .frame(width: geo.size.width * 0.76, height: geo.size.height * 0.84)
                    .clipped()
                    .scaleEffect(settled ? 1 : 1.05, anchor: .topTrailing)
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.85), location: 0.45), .init(color: .black, location: 1)], startPoint: .leading, endPoint: .trailing)
                            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    }
                // Keeps text on the left and at the bottom readable on any art.
                LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0.15), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { withAnimation(.easeOut(duration: 2.6)) { settled = true } }
    }
}

/// Artwork that drifts and zooms very slowly, for full-screen backgrounds.
struct KenBurns: View {
    let url: String?
    @State private var moving = false

    var body: some View {
        Art(url: url, title: "", width: 1920, placeholder: false)
            .scaleEffect(moving ? 1.07 : 1.0)
            .offset(x: moving ? -24 : 0, y: moving ? -10 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 30).repeatForever(autoreverses: true)) { moving = true } }
            .clipped()
    }
}

// MARK: Controls

/// A capsule button: glass at rest, white with black text under focus.
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
            HStack(spacing: 14) {
                if let icon { Image(systemName: icon).font(.system(size: 24, weight: .bold)) }
                configuration.label
            }
            .font(.kumori(28, .semibold))
            .foregroundStyle(focused ? Palette.onFocus : Palette.text)
            .padding(.horizontal, 38)
            .frame(height: 76)
            .background {
                Capsule()
                    .fill(focused ? Palette.focus : (prominent ? Palette.raised : .clear))
                    .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 14)
            }
            .glass(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : (focused ? 1.07 : 1))
            .opacity(enabled ? 1 : 0.4)
            .animation(Motion.focus, value: focused)
            .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// A full-width row, lit white under focus.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.kumori(28, .medium))
                .foregroundStyle(focused ? Palette.onFocus : Palette.text)
                .padding(.horizontal, 30)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(focused ? Palette.focus : Color.clear)
                        .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 20, y: 10)
                }
                .scaleEffect(configuration.isPressed ? 0.985 : (focused ? 1.02 : 1))
                .animation(Motion.focus, value: focused)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

/// Artwork tiles: the picture lifts, a soft light passes over it once, and a white edge
/// is drawn just inside it.
struct TileButtonStyle: ButtonStyle {
    var radius: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, radius: radius)
    }

    private struct Tile: View {
        let configuration: Configuration
        let radius: CGFloat
        @Environment(\.isFocused) private var focused
        @State private var sheen = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .frame(width: geo.size.width * 0.7)
                            .offset(x: sheen ? geo.size.width * 1.3 : -geo.size.width * 0.9)
                            .opacity(focused ? 1 : 0)
                    }
                    .allowsHitTesting(false)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(focused ? 0.9 : 0), lineWidth: 3))
                .shadow(color: .black.opacity(focused ? 0.7 : 0.3), radius: focused ? 30 : 10, y: focused ? 20 : 6)
                .scaleEffect(configuration.isPressed ? 1.03 : (focused ? 1.1 : 1))
                .animation(Motion.focus, value: focused)
                .animation(Motion.press, value: configuration.isPressed)
                .onChange(of: focused) { _, now in
                    sheen = false
                    if now { withAnimation(.easeInOut(duration: 1.1).delay(0.12)) { sheen = true } }
                }
        }
    }
}

/// A heading over a group of rows or a rail.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.kumori(30, .bold)).foregroundStyle(Palette.text)
    }
}

/// A ring of light that turns, for waiting.
struct Spinner: View {
    var size: CGFloat = 72
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(AngularGradient(colors: [.white.opacity(0), .white], center: .center), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true } }
    }
}

/// A grey block that breathes, standing in for a tile while the library loads.
struct Placeholder: View {
    var radius: CGFloat = 22
    var index = 0
    @State private var lit = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(lit ? 0.1 : 0.04))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true).delay(Double(index) * 0.12)) { lit = true }
            }
    }
}

// MARK: Rows

/// A setting picked with left and right, like on Android: the name on the left and
/// "‹ value ›" on the right. The value slides in from the side it was moved towards.
/// Pressing the row moves on to the next value, so a click on the remote works too.
struct ValueRow<Value: Hashable>: View {
    let label: String
    var icon: String?
    let options: [Value]
    let title: (Value) -> String
    let selection: Value
    let pick: (Value) -> Void

    @State private var forward = true
    @State private var bump: CGFloat = 0

    var body: some View {
        Button { step(1, pressed: true) } label: {
            RowFace(
                label: label, icon: icon, value: title(selection), forward: forward, bump: bump,
                atStart: index == 0, atEnd: index >= options.count - 1
            )
        }
        .buttonStyle(RowButtonStyle())
        .onMoveCommand { d in
            switch d {
            case .left: step(-1, pressed: false)
            case .right: step(1, pressed: false)
            default: break
            }
        }
    }

    private var index: Int { options.firstIndex(of: selection) ?? 0 }

    private func step(_ by: Int, pressed: Bool) {
        guard options.count > 1 else { return nudge(by) }
        var next = index + by
        if next >= options.count {
            guard pressed else { return nudge(by) }
            next = 0
        }
        if next < 0 { return nudge(by) }
        forward = by > 0 && !(pressed && next == 0)
        withAnimation(Motion.snappy) { pick(options[next]) }
    }

    /// At either end the arrow pushes out and springs back, so the press is still felt.
    private func nudge(_ by: Int) {
        withAnimation(.spring(response: 0.12, dampingFraction: 0.6)) { bump = by > 0 ? 10 : -10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { bump = 0 }
        }
    }
}

private struct RowFace: View {
    let label: String
    let icon: String?
    let value: String
    let forward: Bool
    let bump: CGFloat
    let atStart: Bool
    let atEnd: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        HStack(spacing: 18) {
            if let icon { Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 36) }
            Text(label).lineLimit(1)
            Spacer(minLength: 24)
            HStack(spacing: 12) {
                Image(systemName: "chevron.left")
                    .opacity(atStart ? 0.18 : (focused ? 0.9 : 0.4))
                    .offset(x: min(bump, 0))
                ZStack {
                    Text(value)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .id(value)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                        ))
                }
                .frame(width: 280)
                .clipped()
                Image(systemName: "chevron.right")
                    .opacity(atEnd ? 0.18 : (focused ? 0.9 : 0.4))
                    .offset(x: max(bump, 0))
            }
            .font(.kumori(26, .medium))
        }
    }
}

/// A row that only shows something: a name and its value.
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 24) {
            Text(label).foregroundStyle(Palette.secondary)
            Spacer(minLength: 24)
            Text(value).foregroundStyle(Palette.text).multilineTextAlignment(.trailing)
        }
        .font(.kumori(26))
        .padding(.horizontal, 30)
        .frame(minHeight: 70)
    }
}

/// A row that does something when pressed.
struct ActionRow: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 36)
                Text(label)
            }
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// Rows grouped on one sheet of glass, under a heading.
struct Panel<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let title { SectionTitle(text: title).padding(.leading, 30) }
            VStack(spacing: 6) { content }
                .padding(12)
                .glassCard(34)
        }
    }
}
