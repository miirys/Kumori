import SwiftUI

/// Where a piece of artwork comes from.
enum TVArtworkSource: Hashable {
    /// Catalogue art from the network.
    case remote(URL)
    /// Art drawn on the device from a seed, for fixtures and screenshots. Never touches the
    /// network. `delay` holds it back to imitate a slow download.
    case generated(seed: Int, delay: Int = 0)
    /// No artwork: the tile shows its title on a neutral panel.
    case missing

    /// Reads a catalogue URL. `fixture://art/<seed>` (optionally `?delay=<ms>`) is generated
    /// art, so fixture games can travel through the real `Game` model.
    init(_ string: String?) {
        guard let string, let url = URL(string: string) else {
            self = .missing
            return
        }
        if url.scheme == "fixture" {
            let seed = Int(url.lastPathComponent) ?? 0
            let delay = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "delay" }?.value.flatMap(Int.init) ?? 0
            self = .generated(seed: seed, delay: delay)
        } else {
            self = .remote(url)
        }
    }
}

/// Game artwork in a fixed frame.
///
/// The frame never changes size while the image loads, and the image arrives by opacity
/// alone, so focus and layout stay put (no scale-in, which moved tiles under focus before).
/// The parent sets the width; the height follows `shape`.
struct TVArtwork: View {
    let source: TVArtworkSource
    let title: String
    var shape: TVLockupShape = .landscape
    /// Show the title on the placeholder. Off for backdrops.
    var titleOnPlaceholder = true

    @Environment(\.tvReduceMotion) private var reduced
    @State private var generatedReady = false

    var body: some View {
        Color.clear
            .aspectRatio(shape.aspect, contentMode: .fit)
            .overlay { content }
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        ZStack {
            placeholder
            switch source {
            case .remote(let url):
                AsyncImage(url: url, transaction: Transaction(animation: TVMotion.artFade(reduced: reduced))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                    }
                }
            case .generated(let seed, let delay):
                if generatedReady {
                    GeneratedArt(seed: seed).transition(.opacity)
                }
                Color.clear.task(id: seed) {
                    if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                    withAnimation(TVMotion.artFade(reduced: reduced)) { generatedReady = true }
                }
            case .missing:
                EmptyView()
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            TVColor.placeholder
            if titleOnPlaceholder {
                Text(title)
                    .font(TVType.body.weight(.semibold))
                    .foregroundStyle(TVColor.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .padding(TVTokens.group)
            }
        }
    }
}

/// Deterministic stand-in key art: layered light over a two-tone ground with a large glyph,
/// so screenshots look like a real catalogue without shipping anyone's artwork.
struct GeneratedArt: View {
    let seed: Int

    private static let grounds: [(Color, Color)] = [
        (Color(red: 0.10, green: 0.18, blue: 0.42), Color(red: 0.55, green: 0.20, blue: 0.55)),
        (Color(red: 0.05, green: 0.30, blue: 0.30), Color(red: 0.10, green: 0.55, blue: 0.45)),
        (Color(red: 0.45, green: 0.12, blue: 0.10), Color(red: 0.95, green: 0.55, blue: 0.20)),
        (Color(red: 0.12, green: 0.12, blue: 0.16), Color(red: 0.40, green: 0.42, blue: 0.50)),
        (Color(red: 0.20, green: 0.08, blue: 0.30), Color(red: 0.95, green: 0.48, blue: 0.65)),
        (Color(red: 0.05, green: 0.20, blue: 0.10), Color(red: 0.60, green: 0.75, blue: 0.25)),
        (Color(red: 0.08, green: 0.10, blue: 0.25), Color(red: 0.30, green: 0.70, blue: 0.95)),
        // Deliberately bright, to test text and focus contrast over light art.
        (Color(red: 0.92, green: 0.90, blue: 0.82), Color(red: 1.00, green: 0.97, blue: 0.90)),
    ]

    private static let glyphs = [
        "mountain.2.fill", "sparkles", "flame.fill", "moon.stars.fill", "bolt.fill",
        "leaf.fill", "globe.europe.africa.fill", "sun.max.fill", "tornado", "hare.fill",
        "airplane", "car.fill",
    ]

    static func isBright(seed: Int) -> Bool { abs(seed) % grounds.count == grounds.count - 1 }

    var body: some View {
        let ground = Self.grounds[abs(seed) % Self.grounds.count]
        let glyph = Self.glyphs[abs(seed / 3 + seed) % Self.glyphs.count]
        let bright = Self.isBright(seed: seed)
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(colors: [ground.0, ground.1], startPoint: .bottomLeading, endPoint: .topTrailing)
                RadialGradient(colors: [.white.opacity(bright ? 0.6 : 0.35), .clear],
                               center: UnitPoint(x: 0.25 + 0.1 * Double(seed % 5), y: 0.2),
                               startRadius: 0, endRadius: side * 0.6)
                Circle()
                    .fill(ground.1.opacity(0.55))
                    .frame(width: side * 0.7)
                    .blur(radius: side * 0.06)
                    .offset(x: geo.size.width * 0.28, y: geo.size.height * 0.22)
                Image(systemName: glyph)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side * 0.34)
                    .foregroundStyle(bright ? Color.black.opacity(0.45) : Color.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.35), radius: side * 0.02, y: side * 0.01)
                    .offset(x: geo.size.width * 0.18, y: -geo.size.height * 0.02)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Full-bleed artwork behind a page, with a scrim on the text side. When the source changes
/// it waits for focus to rest (`TVMotion.artDwell`) and then cross-fades, so flicking across a
/// shelf doesn't strobe the background. No pan or zoom.
struct TVBackdrop: View {
    let source: TVArtworkSource
    var textEdge: Edge = .leading

    @Environment(\.tvReduceMotion) private var reduced
    @State private var shown: TVArtworkSource?

    var body: some View {
        ZStack {
            TVColor.canvas
            if let shown {
                GeometryReader { geo in
                    // Cover the whole area at 16:9, centred, cropping whichever side overflows.
                    let width = max(geo.size.width, geo.size.height * TVTokens.landscape)
                    TVArtwork(source: shown, title: "", shape: .landscape, titleOnPlaceholder: false)
                        .frame(width: width)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .clipped()
                .id(shown)
                .transition(.opacity)
            }
            TVScrim(edge: textEdge)
            // Fade the bottom into the canvas so shelves below sit on a calm ground.
            LinearGradient(colors: [.clear, TVColor.canvas], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: source) {
            if shown == nil {
                shown = source
                return
            }
            try? await Task.sleep(for: TVMotion.artDwell)
            if Task.isCancelled { return }
            withAnimation(TVMotion.artFade(reduced: reduced)) { shown = source }
        }
    }
}
