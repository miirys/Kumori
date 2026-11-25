import SwiftUI
import QuartzCore

// The game page's motion (approved take 5, 2026-11-25; see the motion spec in the project's
// kumori/motion folder). There are no timers or delays: one driver spring, the art's grow,
// moves the page, and every other piece follows it through springs of its own, ticked once a
// frame. Back runs the same system in reverse.

/// A damped spring, written as (response, dampingFraction) like SwiftUI's
/// `.spring(response:dampingFraction:)`, stepped by hand so pieces can chase one another.
struct MotionSpring: Equatable {
    var x: CGFloat
    var target: CGFloat
    var v: CGFloat = 0
    var response: CGFloat
    var damping: CGFloat

    init(_ x: CGFloat, _ response: CGFloat, _ damping: CGFloat) {
        self.x = x
        self.target = x
        self.response = response
        self.damping = damping
    }

    mutating func set(_ response: CGFloat, _ damping: CGFloat) {
        self.response = response
        self.damping = damping
    }

    mutating func snap(_ value: CGFloat) {
        x = value
        target = value
        v = 0
    }

    /// Twelve small steps a frame, so even the stiffest link (0.018 s) stays stable.
    mutating func step(_ dt: CGFloat) {
        if x == target && v == 0 { return }
        let n = 12
        let h = dt / CGFloat(n)
        let k = pow(2 * .pi / response, 2)
        let c = 4 * .pi * damping / response
        for _ in 0..<n {
            let a = -k * (x - target) - c * v
            v += a * h
            x += v * h
        }
    }

    var resting: Bool { abs(x - target) < 0.0004 && abs(v) < 0.0004 }

    /// Settles exactly on the target once it is close enough to be still.
    mutating func settle() {
        if resting { x = target; v = 0 }
    }
}

@inline(__always) func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// The pieces of the first screen, in the order each one follows the one before it.
enum ChainPiece: Int, CaseIterable {
    case hours, publisher, title, genres, line1, line2, buttons, caption, lower
}

/// Every spring on a game's page, and the screen under it. The screen that opens pages owns
/// one for as long as it lives, so the tile's catch can finish after the page has gone.
@Observable
final class GamePageMotion {
    enum Mode { case idle, open, close, fade }

    // MARK: Springs

    /// The driver: 0 is the tile, 1 is the full screen.
    private(set) var art = MotionSpring(0, 0.62, 0.88)
    /// One link per piece of the first screen, in `ChainPiece` order.
    private(set) var chain = Array(repeating: MotionSpring(0, 0.075, 0.92), count: ChainPiece.allCases.count)
    /// The same pieces following the page's scroll, close to rigid.
    private(set) var scrollLinks = Array(repeating: MotionSpring(0, 0.018, 0.98), count: ChainPiece.allCases.count)
    /// The glass drop splitting into the button row.
    private(set) var morph = MotionSpring(0, 0.34, 0.7)
    /// The picture dims behind the lower sections.
    private(set) var below = MotionSpring(0, 0.6, 1.0)
    /// The page as a whole, for a page that fades in place (no tile, or Reduce Motion).
    private(set) var presence = MotionSpring(1, 0.46, 1.0)
    /// The tile catching the picture as it comes home: a small dip and bounce in its scale.
    private(set) var tileCatch = MotionSpring(0, 0.4, 0.82)
    /// Lower sections: a heading and items each, tucked at 0 and shown at 1.
    private(set) var sections: [[MotionSpring]] = []

    // MARK: State

    private(set) var mode = Mode.idle
    /// The page's scroll offset, as the scroll view reports it.
    private(set) var scroll: CGFloat = 0
    /// The page's picture is on screen (the tile it covers is hidden meanwhile).
    private(set) var artVisible = false
    /// The tile the page grew from, as it was when the page opened.
    private(set) var sourceID: String?
    private(set) var originFrame: CGRect?
    /// The page came from a picture that is part of the screen's background (the Home
    /// banner's Details), not from a tile. Going back it sinks into that background, fading
    /// as it shrinks, rather than landing on top of it as a card and waiting to be caught.
    private(set) var sinks = false
    @ObservationIgnored private var landed = false
    @ObservationIgnored private var scrollDown = true
    @ObservationIgnored private var focusSection = -1
    @ObservationIgnored private var time: CGFloat = 0
    @ObservationIgnored private var pending: [(at: CGFloat, section: Int, item: Int, on: Bool)] = []
    @ObservationIgnored private var finished: (() -> Void)?
    @ObservationIgnored private var frames: FrameTicker?

    private var ticker: FrameTicker {
        if let frames { return frames }
        let t = FrameTicker { [weak self] stamp in self?.advance(at: stamp) ?? false }
        frames = t
        return t
    }

    /// From the banner, the driver's last stretch (below `sunk`) is cut off and everything is
    /// at rest by then: a critically damped spring creeps the last tenth of the way, and the
    /// shade and scrim used to fade over that creep, which read as a wait at the end of Back.
    var g: CGFloat { sinks ? clamp01((art.x - Self.sunk) / (1 - Self.sunk)) : art.x }

    /// How much of the page and its picture shows when it comes from the background: none
    /// near the banner's size, all of it once well on its way. Tied to the picture's size
    /// alone, both ways, so turning back halfway can't make it jump.
    /// How small the sinking picture gets (as the driver's value) before it has gone: it
    /// fades out over the last stretch, once it is back at rest, and is done here.
    static let sunk: CGFloat = 0.1

    var sinkOpacity: CGFloat {
        guard sinks else { return 1 }
        let t = clamp01(g / Self.settled)
        return t * t * (3 - 2 * t)
    }

    /// Below this the banner's picture is back at rest, exactly where the banner draws it, so
    /// the page can fade into the banner over the last stretch without any doubling.
    static let settled: CGFloat = 0.12

    /// How far the picture behind a page from the banner has moved: 0 where the banner draws
    /// it, 1 with the page open. Tied to the driver's value alone and on a spring with no
    /// overshoot both ways, so Back plays the opening exactly in reverse.
    var sinkZoom: CGFloat {
        guard sinks else { return 0 }
        let t = clamp01((g - Self.settled) / (1 - Self.settled))
        return t * t * (3 - 2 * t)
    }

    /// How much of the sinking picture's lower half still covers what is under it: all of it
    /// until the page's words have gone (below 0.4), then dissolving into the banner's own
    /// fade. Dissolved any earlier, the banner's title and buttons showed through while the
    /// page's own were still fading, and the title read twice.
    var sinkCover: CGFloat {
        guard sinks else { return 1 }
        let t = clamp01((art.x - Self.sunk) / (0.4 - Self.sunk))
        return t * t * (3 - 2 * t)
    }

    /// The one spring for a page from the banner, opening and closing alike.
    static let sinkSpring: (response: CGFloat, damping: CGFloat) = (0.8, 1.0)

    /// The page's words, coming from the background: they go in the first half of the way
    /// back, while the picture is still large, so the page's title never shows doubled over
    /// the banner's own as the picture fades into it. Opening, they come up in the second half.
    var sinkWordsOpacity: CGFloat {
        guard sinks else { return 1 }
        let t = clamp01((art.x - 0.4) / 0.45)
        return t * t * (3 - 2 * t)
    }

    /// Something is moving. A backstop (`GamePageMotionPulse`) watches it, so the page can
    /// never stall partway if the display link stops.
    private(set) var moving = false
    @ObservationIgnored private var lastTime: CFTimeInterval = 0
    /// When the display link last stepped the motion.
    @ObservationIgnored private var lastLinkFrame: CFTimeInterval = 0

    /// Steps everything to `stamp`: the time the frame being drawn will be on screen, from
    /// the display link, so every frame moves by exactly the time between frames. Stepping
    /// by whenever the callback happened to run made the motion uneven, and a second driver
    /// stepping the same frame drew the page twice for one frame.
    @discardableResult
    func advance(at stamp: CFTimeInterval? = nil) -> Bool {
        let now = stamp ?? CACurrentMediaTime()
        if stamp != nil { lastLinkFrame = CACurrentMediaTime() }
        if lastTime == 0 || now - lastTime > 0.5 { lastTime = now - 1.0 / 60 }
        let dt = now - lastTime
        guard dt >= 0.004 else { return moving }
        lastTime = now
        let still = tick(CGFloat(min(dt, 1.0 / 30)))
        if moving != still { moving = still }
        return still
    }

    /// The backstop: steps the motion only when the display link has gone quiet while
    /// something is still moving, and starts the link again.
    func pulse() {
        guard moving, CACurrentMediaTime() - lastLinkFrame > 0.05 else { return }
        advance()
        ticker.start()
    }

    /// Starts frames if they aren't running.
    private func kick() {
        if !moving { moving = true }
        // The link's first frame is on its way: the backstop has nothing to catch yet.
        lastLinkFrame = CACurrentMediaTime()
        ticker.start()
    }
    var glassProgress: CGFloat { chain[ChainPiece.buttons.rawValue].x }

    func link(_ p: ChainPiece) -> MotionSpring { chain[p.rawValue] }
    func scrollLink(_ p: ChainPiece) -> MotionSpring { scrollLinks[p.rawValue] }

    // MARK: Driving it

    /// The page comes up: out of `origin` when there is one, in place otherwise.
    func open(source: String?, origin: CGRect?, sections counts: [Int], reduced: Bool) {
        sourceID = source
        originFrame = origin
        sinks = source?.hasPrefix("hero|") ?? false
        artVisible = true
        landed = false
        finished = nil
        time = 0
        pending = []
        focusSection = -1
        scroll = 0
        scrollDown = true
        sections = counts.map { Array(repeating: MotionSpring(0, 0.5, 0.9), count: $0 + 1) }
        tileCatch.snap(0)
        below.snap(0)
        for i in scrollLinks.indices { scrollLinks[i].snap(0) }
        mode = .open
        if reduced {
            art.snap(1)
            for i in chain.indices { chain[i].snap(1) }
            morph.snap(1)
            presence.set(0.12, 1)
            presence.snap(0)
            presence.target = 1
        } else {
            art.snap(0)
            if sinks { art.set(Self.sinkSpring.response, Self.sinkSpring.damping) } else { art.set(0.62, 0.88) }
            art.target = 1
            for i in chain.indices { chain[i].snap(0) }
            morph.snap(0)
            presence.snap(1)
        }
        kick()
    }

    /// Back: the page shrinks into the tile it came from, carrying its words.
    func close(then done: @escaping () -> Void) {
        finished = done
        mode = .close
        // Sinking runs slower and without any overshoot. On the faster spring the page was
        // back in the banner a third of a second after Back, and the fade at its end lasted
        // a fifth of one: the banner seemed to snap back on, and the picture's last move
        // (from the full screen's crop to the banner's, 140 points) read as a jump.
        if sinks { art.set(Self.sinkSpring.response, Self.sinkSpring.damping) } else { art.set(0.6, 0.96) }
        art.target = 0
        kick()
    }

    /// Turned around while leaving: the page grows back out from wherever it has got to,
    /// on the opening springs, as if it had never left.
    func reopen() {
        finished = nil
        landed = false
        mode = .open
        artVisible = true
        if sinks { art.set(Self.sinkSpring.response, Self.sinkSpring.damping) } else { art.set(0.62, 0.88) }
        art.target = 1
        presence.set(0.46, 1)
        presence.target = 1
        kick()
    }

    /// Back with no tile to go to (or Reduce Motion): the page fades and sinks in place.
    func fadeOut(reduced: Bool, then done: @escaping () -> Void) {
        finished = done
        mode = .fade
        presence.set(reduced ? 0.12 : 0.46, 1)
        presence.target = 0
        kick()
    }

    func setScroll(_ y: CGFloat) {
        guard abs(y - scroll) > 0.01 else { return }
        scroll = y
        kick()
    }

    /// Focus moved to section `k` of the page (-1 is the first screen). The sections fill in
    /// one step ahead of focus, and tuck away again behind it on the way up.
    func setFocusSection(_ k: Int) {
        focusSection = k
        below.target = k >= 0 ? 1 : 0
        for (j, springs) in sections.enumerated() {
            let on = k >= 0 && j <= k + 1
            guard (springs[0].target == 1) != on else { continue }
            sections[j][0].target = on ? 1 : 0
            let n = springs.count - 1
            for i in 0..<n {
                let start = on ? 0.05 + 0.055 * CGFloat(i) : 0.035 * CGFloat(n - 1 - i)
                pending.append((time + start, j, i + 1, on))
            }
        }
        kick()
    }

    func reveal(section j: Int, item i: Int) -> CGFloat {
        guard j < sections.count, i + 1 < sections[j].count else { return 1 }
        return sections[j][i + 1].x
    }

    func revealHead(section j: Int) -> CGFloat {
        guard j < sections.count else { return 1 }
        return sections[j][0].x
    }

    // MARK: One frame

    /// Returns whether anything is still moving.
    private func tick(_ dt: CGFloat) -> Bool {
        time += dt
        var art = self.art
        var chain = self.chain
        var links = self.scrollLinks
        var morph = self.morph
        var below = self.below
        var presence = self.presence
        var tileCatch = self.tileCatch
        var sections = self.sections
        let n = chain.count

        for (k, e) in pending.enumerated().reversed() where e.at <= time {
            if e.section < sections.count, e.item < sections[e.section].count {
                sections[e.section][e.item].set(0.5 + 0.06 * CGFloat(e.item - 1), 0.9)
                sections[e.section][e.item].target = e.on ? 1 : 0
            }
            pending.remove(at: k)
        }

        // The chain: each piece chases the one before it. Leaving, the lower sections lead and
        // the words follow the art home in reverse.
        let lead = mode == .fade ? presence.x : art.x
        if mode == .close || mode == .fade {
            chain[n - 1].target = lead
            for i in stride(from: n - 2, through: 0, by: -1) { chain[i].target = chain[i + 1].x }
        } else {
            chain[0].target = lead
            for i in 1..<n { chain[i].target = chain[i - 1].x }
        }

        // Scroll: whichever way the page is moving, the piece in front leads, so the block
        // spreads and draws back together instead of folding over itself.
        if scroll > links[0].x + 0.01 { scrollDown = true } else if scroll < links[n - 1].x - 0.01 { scrollDown = false }
        if scrollDown {
            links[0].target = scroll
            for i in 1..<n { links[i].target = links[i - 1].x }
        } else {
            links[n - 1].target = scroll
            for i in stride(from: n - 2, through: 0, by: -1) { links[i].target = links[i + 1].x }
        }

        let leaving = mode == .close || mode == .fade
        morph.set(leaving ? 0.22 : 0.34, leaving ? 0.9 : 0.7)
        morph.target = clamp01((chain[ChainPiece.buttons.rawValue].x - 0.6) / 0.4)

        // The tile catches the picture as it comes home.
        if mode == .close, !landed, !sinks, art.x < 0.03 {
            landed = true
            tileCatch.v -= 3.2
        }

        art.step(dt)
        for i in 0..<n { chain[i].step(dt); links[i].step(dt) }
        morph.step(dt)
        below.step(dt)
        presence.step(dt)
        tileCatch.step(dt)
        for j in sections.indices { for i in sections[j].indices { sections[j][i].step(dt) } }
        art.settle(); morph.settle(); below.settle(); presence.settle(); tileCatch.settle()
        for i in 0..<n { chain[i].settle(); links[i].settle() }
        for j in sections.indices { for i in sections[j].indices { sections[j][i].settle() } }

        var done = false
        switch mode {
        case .close:
            // Sinking, it has faded out completely well before it reaches the banner's size.
            done = sinks ? art.x < Self.sunk : chain.allSatisfy { $0.x < 0.01 } && art.x < 0.004 && abs(art.v) < 0.05
        case .fade:
            done = presence.x < 0.01
        default:
            break
        }
        if done {
            mode = .idle
            artVisible = false
            art.snap(0)
            for i in chain.indices { chain[i].snap(0) }
            morph.snap(0)
            below.snap(0)
            presence.snap(1)
        }

        // Only what changed, so views watching a spring at rest aren't redrawn.
        if self.art != art { self.art = art }
        if self.chain != chain { self.chain = chain }
        if self.scrollLinks != links { self.scrollLinks = links }
        if self.morph != morph { self.morph = morph }
        if self.below != below { self.below = below }
        if self.presence != presence { self.presence = presence }
        if self.tileCatch != tileCatch { self.tileCatch = tileCatch }
        if self.sections != sections { self.sections = sections }

        if done, let f = finished {
            finished = nil
            f()
        }

        let moving = !art.resting || chain.contains { !$0.resting } || links.contains { !$0.resting }
            || !morph.resting || !below.resting || !presence.resting || !tileCatch.resting
            || sections.contains { $0.contains { !$0.resting } } || !pending.isEmpty
            || mode == .close || mode == .fade
        return moving
    }
}

/// Calls back once a display frame while there is anything to move.
private final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private let onFrame: (CFTimeInterval) -> Bool

    init(_ onFrame: @escaping (CFTimeInterval) -> Bool) {
        self.onFrame = onFrame
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        // Never below 60 a second, whatever the system would rather save power on.
        let top = Float(max(60, UIScreen.main.maximumFramesPerSecond))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: top, preferred: top)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ l: CADisplayLink) {
        if !onFrame(l.targetTimestamp) { stop() }
    }

    deinit { link?.invalidate() }
}

private struct GamePageMotionKey: EnvironmentKey {
    static let defaultValue: GamePageMotion? = nil
}

extension EnvironmentValues {
    /// The motion of the game page open over this screen, for the tiles under it.
    var gamePageMotion: GamePageMotion? {
        get { self[GamePageMotionKey.self] }
        set { self[GamePageMotionKey.self] = newValue }
    }
}

// MARK: Pieces

/// One piece of the first screen riding in the art: it hangs a little below where it should be
/// while it lags the piece ahead, stretches along the motion, blurs only while it lags, and
/// fades up with its own link.
struct ChainRide: ViewModifier {
    let motion: GamePageMotion
    let piece: ChainPiece
    var blurs = true
    /// Kept faintly there, so the focus engine always has something to land on.
    var floor: CGFloat = 0
    @Environment(\.tvReduceMotion) private var reduced

    func body(content: Content) -> some View {
        let m = ChainMetrics(motion: motion, piece: piece, reduced: reduced)
        let opacity = piece == .lower ? clamp01((m.q - 0.3) / 0.5) : m.opacity
        return content
            .scaleEffect(x: m.scaleX, y: m.scaleY, anchor: .topLeading)
            .offset(y: m.dy)
            .blur(radius: blurs && m.blur > 0.15 ? m.blur : 0)
            .opacity(max(floor, opacity))
    }
}

struct ChainMetrics {
    let q: CGFloat
    let dy: CGFloat
    let scaleX: CGFloat
    let scaleY: CGFloat
    let blur: CGFloat
    let opacity: CGFloat

    init(motion: GamePageMotion, piece: ChainPiece, reduced: Bool) {
        if reduced {
            q = 1; dy = 0; scaleX = 1; scaleY = 1; blur = 0; opacity = 1
            return
        }
        let link = motion.link(piece)
        let sy = motion.scrollLink(piece)
        q = link.x
        let lag = motion.g - link.x
        let stretch = min(0.035, max(-0.025, lag * 0.18))
        dy = lag * 70 + (motion.scroll - sy.x)
        scaleX = 1 - abs(stretch) * 0.25
        scaleY = 1 + stretch
        blur = min(3, abs(lag) * 7 + abs(sy.v) * 0.0003)
        opacity = min(1, q * 2.2)
    }
}

/// A lower-section item tucked until focus comes near: dim, grey, a little low, small and soft.
struct SectionReveal: ViewModifier {
    let motion: GamePageMotion
    let section: Int
    /// nil for the section's heading.
    let item: Int?
    @Environment(\.tvReduceMotion) private var reduced

    func body(content: Content) -> some View {
        let p = reduced ? 1 : (item.map { motion.reveal(section: section, item: $0) } ?? motion.revealHead(section: section))
        let c = clamp01(p)
        return content
            .saturation(item == nil ? 1 : c)
            .brightness(item == nil ? 0 : -0.3 * (1 - c))
            .blur(radius: item == nil ? 0 : 8 * pow(1 - c, 1.3))
            .scaleEffect(item == nil ? 1 : lerp(0.96, 1, p))
            .offset(y: (1 - p) * (item == nil ? 70 : 110))
            .opacity(lerp(0.28, 1, c))
    }
}

// MARK: The screen underneath

/// On a tile under a game's page: the tiles beside the one the page grew from are pushed aside
/// as it grows (less the further away they are), that tile hides while the picture covers it,
/// and it catches the picture with a small dip and bounce when the page comes home.
struct StagePush: ViewModifier {
    /// The tile's zoom source name.
    let source: String
    @Environment(\.gamePageMotion) private var motion
    @Environment(\.tvZoomSources) private var sources
    @Environment(\.tvReduceMotion) private var reduced

    func body(content: Content) -> some View {
        var dx: CGFloat = 0
        var scale: CGFloat = 1
        var hidden = false
        if let motion, !reduced {
            if source == motion.sourceID {
                hidden = motion.artVisible
                scale = 1 + 0.1 * motion.tileCatch.x
            } else if motion.artVisible, let o = motion.originFrame, let f = sources?.sources[source]?.frame,
                      abs(f.midY - o.midY) < o.height / 2 {
                // How many tiles away, in the same row.
                let pitch = max(1, f.width + TVExpandingCard.gap)
                let right = f.minX >= o.midX
                let gap = right ? f.minX - o.maxX : o.minX - f.maxX
                let d = 1 + max(0, ((gap - TVExpandingCard.gap) / pitch).rounded())
                dx = (right ? 1 : -1) * 70 * clamp01(motion.g) / max(1, d * 0.7)
            }
        }
        return content
            .offset(x: dx)
            .scaleEffect(scale)
            .opacity(hidden ? 0 : 1)
    }
}


/// The backstop: SwiftUI's own animation clock, running whenever the motion says something
/// is moving, which steps it only if the display link has stopped. Put it in any view that
/// is on screen while the page is.
struct GamePageMotionPulse: View {
    let motion: GamePageMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !motion.moving)) { context in
            Color.clear
                .onChange(of: context.date) { _, _ in motion.pulse() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
