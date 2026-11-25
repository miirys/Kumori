import CoreImage
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
    /// The picture for `source`, already downloaded, shrunk and frosted, so the background
    /// never fades in to an empty frame and then pops the art in. Nil if it couldn't load.
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

    /// Downloads (or reads from the shared cache), shrinks and frosts a picture, once, off
    /// the main thread. The background then only moves a finished picture: before, it
    /// blurred the art again on the GPU on every frame of every crossfade.
    private static func load(_ source: TVArtworkSource) async -> UIImage? {
        let small: CGImage?
        switch source {
        case .remote(let url):
            // Through the shared image cache: the cards and the hero have usually decoded this
            // picture already (off the main thread), so it is there at once, and otherwise it
            // is fetched once with a disk cache instead of again on every focus change.
            guard let full = await TVImageCache.shared.load(url) else { return nil }
            let w = full.size.width, h = full.size.height
            guard w > 0, h > 0 else { return nil }
            let thumb = w > 640 ? await full.byPreparingThumbnail(ofSize: CGSize(width: 640, height: (640 * h / w).rounded())) : nil
            small = thumb?.cgImage ?? full.cgImage
        case .generated(let seed, _):
            // Fixture art, drawn here so screenshots show the same frosted picture.
            let renderer = ImageRenderer(content: GeneratedArt(seed: seed).frame(width: 640, height: 360))
            renderer.scale = 1
            small = renderer.cgImage
        case .missing:
            return nil
        }
        guard let small else { return nil }
        return await Task.detached(priority: .userInitiated) { AmbientFrost.frost(small) }.value
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

/// One game's art as frosted glass: the picture frosted once at load (`AmbientFrost`),
/// scaled up to cover the screen and drifting very slowly. The drift is a Core Animation
/// animation, so it runs on the system's render server and costs the app nothing per frame;
/// as a SwiftUI animation it stepped every layer on the main thread sixty times a second,
/// forever, behind every screen.
private struct TVAmbientArt: View {
    let source: TVArtworkSource
    let image: UIImage?
    let drifting: Bool
    @State private var drift = false

    private static let small = AmbientFrost.small
    private static let cover = AmbientFrost.cover

    var body: some View {
        if let image {
            AmbientDrift(image: image, drifting: drifting)
        } else {
            // Nothing frosted to show (the picture failed to load): draw what there is the
            // old way, blurred live.
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
                    withAnimation(.easeInOut(duration: 28).repeatForever(autoreverses: true)) { drift = true }
                }
        }
    }
}

/// Frosts a picture the way the background used to live: filled into 480 × 270, blurred
/// with its edges held (radius 14), and a touch more saturated.
enum AmbientFrost {
    /// The art is blurred at this size, then scaled up to cover the screen with room to drift.
    static let small = CGSize(width: 480, height: 270)
    static let cover: CGFloat = 4.4
    /// Blurred in the same encoded sRGB the screen's own blur works in, so the picture
    /// keeps the same light and dark as when it was blurred live.
    private static let context: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return CIContext(options: [.cacheIntermediates: false, .workingColorSpace: srgb, .outputColorSpace: srgb])
    }()

    static func frost(_ picture: CGImage) -> UIImage? {
        let size = small
        let input = CIImage(cgImage: picture)
        let w = input.extent.width, h = input.extent.height
        guard w > 0, h > 0 else { return nil }
        // Aspect fill, centred.
        let scale = max(size.width / w, size.height / h)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2 + scaled.extent.minX
        let dy = (scaled.extent.height - size.height) / 2 + scaled.extent.minY
        let target = CGRect(origin: .zero, size: size)
        let filled = scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy)).cropped(to: target)
        let blurred = filled.clampedToExtent()
            .applyingGaussianBlur(sigma: 14)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.05])
            .cropped(to: target)
        guard let out = context.createCGImage(blurred, from: target) else { return nil }
        return UIImage(cgImage: out)
    }
}

/// The frosted picture, covering its frame with room to drift, moved by Core Animation.
private struct AmbientDrift: UIViewRepresentable {
    let image: UIImage
    let drifting: Bool

    func makeUIView(context: Context) -> AmbientDriftView {
        let view = AmbientDriftView()
        view.show(image, drifting: drifting)
        return view
    }

    func updateUIView(_ view: AmbientDriftView, context: Context) {
        view.show(image, drifting: drifting)
    }
}

final class AmbientDriftView: UIView {
    private let art = UIImageView()
    private var drifting = false
    private static let key = "drift"
    /// The ends of the drift, as the SwiftUI version had them: scale 1 nudged right and up,
    /// and scale 1.07 nudged left and down.
    private static let from = CATransform3DMakeTranslation(36, -14, 0)
    private static let to = CATransform3DConcat(CATransform3DMakeScale(1.07, 1.07, 1), CATransform3DMakeTranslation(-36, 14, 0))

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.layer.transform = Self.from
        addSubview(art)
        // The system takes running animations off layers when the app goes to the
        // background; start the drift again on the way back.
        NotificationCenter.default.addObserver(self, selector: #selector(resume),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: UIImage, drifting: Bool) {
        if art.image !== image { art.image = image }
        guard drifting != self.drifting else { return }
        self.drifting = drifting
        if drifting { start() } else { art.layer.removeAnimation(forKey: Self.key) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let small = AmbientFrost.small, cover = AmbientFrost.cover
        art.bounds = CGRect(x: 0, y: 0, width: small.width * cover, height: small.height * cover)
        art.center = CGPoint(x: bounds.midX, y: bounds.midY)
        start()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { start() }
    }

    @objc private func resume() { start() }

    /// Starts the drift unless it is already running.
    private func start() {
        guard drifting, window != nil, art.layer.animation(forKey: Self.key) == nil else { return }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: Self.from)
        a.toValue = NSValue(caTransform3D: Self.to)
        // One slow breath across half a minute, back and forth: there, but never something
        // the eye follows.
        a.duration = 28
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isRemovedOnCompletion = false
        art.layer.add(a, forKey: Self.key)
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
