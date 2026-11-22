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
    /// Fill whatever frame the parent gives, cropping the art, instead of keeping `shape`.
    /// For backdrops.
    var fill = false
    /// Show the neutral panel while the art loads. Off for the blurred background, which
    /// keeps the art it has until the new one is ready.
    var placeholder = true

    @Environment(\.tvReduceMotion) private var reduced
    @State private var generatedReady = false

    var body: some View {
        Group {
            if fill {
                Color.clear.overlay { content }
            } else {
                Color.clear.aspectRatio(shape.aspect, contentMode: .fit).overlay { content }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        ZStack {
            if placeholder { placeholderPanel }
            switch source {
            case .remote(let url):
                AsyncImage(url: url, transaction: Transaction(animation: TVMotion.artFade(reduced: reduced))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                    }
                }
            case .generated(let seed, let delay):
                if generatedReady {
                    GeneratedArt(seed: seed, title: title).transition(.opacity)
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

    private var placeholderPanel: some View {
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

/// Full-bleed artwork behind a page, with a scrim on the text side. When the source changes
/// it waits for focus to rest (`TVMotion.artDwell`) and then cross-fades, so flicking across a
/// shelf doesn't strobe the background. No pan or zoom. Its bottom dissolves into whatever
/// is behind it: the canvas on a game's page, the blurred background on Home.
struct TVBackdrop: View {
    let source: TVArtworkSource
    var textEdge: Edge = .leading

    @Environment(\.tvReduceMotion) private var reduced
    @State private var shown: TVArtworkSource?

    var body: some View {
        ZStack {
            if let shown {
                TVArtwork(source: shown, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
                    .id(shown)
                    .transition(.opacity)
            }
            TVScrim(edge: textEdge)
        }
        // Dissolve the bottom away so shelves below sit on a calm ground.
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
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
