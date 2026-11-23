import ImageIO
import SwiftUI
import UIKit

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

/// Decoded artwork kept in memory, so a picture that is already on screen somewhere (a tile,
/// the background) is there from the first frame when another view shows it: a game's page
/// growing out of its tile, the background catching up with focus.
final class TVImageCache: @unchecked Sendable {
    static let shared = TVImageCache()
    private let images = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    /// Downloads on their way, so two views asking for the same picture share one request.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    /// Its own session, with room on disk, so art seen once comes from the disk next time
    /// instead of the network, and more pictures download side by side.
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 10
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()
    /// The largest side a picture is decoded at. The catalogue sends some art at 3840
    /// pixels; decoding that in full took longer than the download.
    private static let maxPixels: CGFloat = 2560

    private init() {
        images.totalCostLimit = 320 * 1024 * 1024
        images.countLimit = 160
    }

    func image(_ url: URL) -> UIImage? { images.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let hit = image(url) { return hit }
        let session = session
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inFlight[url] { return running }
            let t = Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let (data, _) = try? await session.data(from: url) else { return nil }
                return TVImageCache.decode(data)
            }
            inFlight[url] = t
            return t
        }
        let ready = await task.value
        lock.withLock { inFlight[url] = nil }
        if let ready {
            let cost = Int(ready.size.width * ready.size.height * ready.scale * ready.scale * 4)
            images.setObject(ready, forKey: url as NSURL, cost: cost)
        }
        return ready
    }

    /// Fetches pictures before anything shows them, a few at a time, quietly.
    func prefetch(_ urls: [URL]) {
        let wanted = urls.filter { image($0) == nil }
        guard !wanted.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var it = wanted.makeIterator()
                for _ in 0..<6 {
                    guard let u = it.next() else { break }
                    group.addTask { _ = await TVImageCache.shared.load(u) }
                }
                while await group.next() != nil {
                    if let u = it.next() { group.addTask { _ = await TVImageCache.shared.load(u) } }
                }
            }
        }
    }

    /// Decoded here, off the main thread and at most `maxPixels` on a side, not on the
    /// first frame that draws it.
    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension TVArtworkSource {
    var remoteURL: URL? {
        if case .remote(let u) = self { return u }
        return nil
    }
}

/// A catalogue picture: from memory at once when it's there, otherwise faded in once loaded.
private struct TVRemoteImage: View {
    let url: URL
    var loaded: () -> Void = {}
    @Environment(\.tvReduceMotion) private var reduced
    @State private var image: UIImage?

    init(url: URL, loaded: @escaping () -> Void = {}) {
        self.url = url
        self.loaded = loaded
        _image = State(initialValue: TVImageCache.shared.image(url))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            }
        }
        .task(id: url) {
            if let hit = TVImageCache.shared.image(url) {
                image = hit
                loaded()
                return
            }
            image = nil
            let got = await TVImageCache.shared.load(url)
            if Task.isCancelled { return }
            withAnimation(TVMotion.artFade(reduced: reduced)) { image = got }
            if got != nil {
                // After the fade, so the panel underneath goes only once it is covered.
                try? await Task.sleep(for: .milliseconds(200))
                loaded()
            }
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
    /// The art has had long enough that it is missing or slow, not just on its way. Until
    /// then the placeholder carries no title, so names never flash up under arriving art.
    @State private var overdue = false
    /// The remote picture has loaded and is showing.
    @State private var arrived = false

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
            if placeholder { placeholderPanel.opacity(artReady ? 0 : 1) }
            switch source {
            case .remote(let url):
                TVRemoteImage(url: url) { arrived = true }
            case .generated(let seed, let delay):
                // With no delay it is "already downloaded": there from the first frame.
                if generatedReady || delay == 0 {
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

    /// The picture is decoded and in memory, so it is (or is about to be) on screen.
    private var artReady: Bool {
        switch source {
        case .remote(let url): return arrived || TVImageCache.shared.image(url) != nil
        case .generated: return true
        case .missing: return false
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
                    // Never over art that has arrived: during a card's or page's fade the
                    // layers below the picture show through, and the name leaked out.
                    .opacity((overdue && !artReady) || source == .missing ? 1 : 0)
            }
        }
        .task(id: source) {
            overdue = false
            guard source != .missing else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled, !artReady { withAnimation(.easeOut(duration: 0.3)) { overdue = true } }
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
