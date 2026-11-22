import SwiftUI
import UIKit

// The living background behind Home, Library, Search and Settings: the art of the game that
// has focus, blurred into soft glass, darkened so text on it stays readable, and drifting
// very slowly. When focus rests on another game the new art blooms in over the old one.

/// Which game's art the background shows. One per `MainView`; anything that puts focus on a
/// game tells it, and only the background itself watches it, so moving focus redraws nothing
/// else.
@MainActor
final class TVAmbient: ObservableObject {
    @Published private(set) var source: TVArtworkSource = .missing
    /// The picture for `source`, already downloaded and shrunk, so the background never fades
    /// in to an empty frame and then pops the art in. Nil for generated art.
    private(set) var image: UIImage?
    private var pending: Task<Void, Never>?

    /// Show `source` once focus has rested on it for a moment, so flicking along a shelf
    /// doesn't strobe the whole screen, and once its picture is ready.
    func show(_ source: TVArtworkSource) {
        pending?.cancel()
        guard source != self.source, source != .missing else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: TVAmbient.dwell)
            guard !Task.isCancelled else { return }
            let image = await TVAmbient.load(source)
            guard !Task.isCancelled else { return }
            self?.image = image
            self?.source = source
        }
    }

    /// Show `source` as soon as its picture is ready, without the dwell. For the first frame
    /// of a screen.
    func set(_ source: TVArtworkSource) {
        pending?.cancel()
        guard source != self.source else { return }
        pending = Task { [weak self] in
            let image = await TVAmbient.load(source)
            guard !Task.isCancelled else { return }
            self?.image = image
            self?.source = source
        }
    }

    /// Downloads (or reads from the shared cache) and shrinks a remote picture. The
    /// background blurs it at 480 points wide, so nothing bigger is kept.
    private static func load(_ source: TVArtworkSource) async -> UIImage? {
        guard case .remote(let url) = source,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let full = UIImage(data: data) else { return nil }
        let w = full.size.width, h = full.size.height
        guard w > 640, h > 0 else { return full }
        return await full.byPreparingThumbnail(ofSize: CGSize(width: 640, height: (640 * h / w).rounded())) ?? full
    }

    nonisolated static let dwell: Duration = .milliseconds(260)
}

private struct TVAmbientKey: EnvironmentKey {
    static let defaultValue: TVAmbient? = nil
}

extension EnvironmentValues {
    /// The background to tell when a game gets focus. Nil outside `MainView`.
    var tvAmbient: TVAmbient? {
        get { self[TVAmbientKey.self] }
        set { self[TVAmbientKey.self] = newValue }
    }
}

/// The background itself. Put it behind the tab view, full bleed.
///
/// A new game's art fades in on top of the old one, which stays fully drawn underneath until
/// the new one has covered it. Fading one out while the other fades in would let the black
/// canvas show through halfway, and the whole screen would dim and brighten on every move.
struct TVAmbientBackdrop: View {
    @ObservedObject var ambient: TVAmbient
    @Environment(\.tvReduceMotion) private var reduced
    @Environment(\.tvReduceTransparency) private var opaque
    @State private var layers: [AmbientLayer] = []

    var body: some View {
        ZStack {
            TVColor.canvas
            if !opaque {
                ForEach(layers) { layer in
                    TVAmbientArt(source: layer.source, image: layer.image, drifting: !reduced)
                        .modifier(AmbientFadeIn(duration: reduced ? 0.1 : Self.fade))
                }
            }
            // The veil: dark enough that secondary text clears 4.5:1 on the brightest art,
            // darker still at the bottom where shelves and captions sit.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .black.opacity(0.6), location: 0.45),
                    .init(color: .black.opacity(0.84), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            // A soft vignette, so the screen's edges sit back and the middle glows.
            RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center,
                           startRadius: 360, endRadius: 1200)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { add(ambient.source) }
        .onChange(of: ambient.source) { _, now in add(now) }
    }

    /// How long a new picture takes to cover the old one.
    static let fade: Double = 1.1

    private func add(_ source: TVArtworkSource) {
        guard source != .missing, layers.last?.source != source else { return }
        let layer = AmbientLayer(source: source, image: ambient.image)
        layers.append(layer)
        // Older pictures go once the new one covers them. Keep at most three while focus
        // is moving quickly, so nothing piles up.
        if layers.count > 3 { layers.removeFirst(layers.count - 3) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade + 0.1) {
            guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
            layers.removeFirst(index)
        }
    }
}

private struct AmbientLayer: Identifiable {
    let id = UUID()
    let source: TVArtworkSource
    let image: UIImage?
}

/// Fades a picture in once, when it is added.
private struct AmbientFadeIn: ViewModifier {
    let duration: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: duration)) { shown = true }
            }
    }
}

/// One game's art as frosted glass. Blurred small and drawn large, which looks the same as a
/// full-size blur at a fraction of the cost, and leaves the GPU free for focus motion.
private struct TVAmbientArt: View {
    let source: TVArtworkSource
    let image: UIImage?
    let drifting: Bool
    @State private var drift = false

    /// The art is blurred at this size, then scaled up to cover the screen with room to drift.
    private static let small = CGSize(width: 480, height: 270)
    private static let cover: CGFloat = 4.4

    var body: some View {
        picture
            .frame(width: Self.small.width, height: Self.small.height)
            .clipped()
            .blur(radius: 14, opaque: true)
            .saturation(1.05)
            .drawingGroup()
            .scaleEffect(Self.cover * (drift ? 1.07 : 1))
            .offset(x: drift ? -36 : 36, y: drift ? 14 : -14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onAppear {
                guard drifting else { return }
                // One slow breath across half a minute, back and forth: there, but never
                // something the eye follows.
                withAnimation(.easeInOut(duration: 28).repeatForever(autoreverses: true)) { drift = true }
            }
    }
}

private extension TVAmbientArt {
    @ViewBuilder var picture: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            TVArtwork(source: source, title: "", titleOnPlaceholder: false, fill: true, placeholder: false)
        }
    }
}
