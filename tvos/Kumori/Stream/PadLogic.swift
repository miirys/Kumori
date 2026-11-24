import Foundation

// The decisions behind controller input, kept apart from GameController and the network so
// they can be tested on any machine (see tvos/InputTests). Gamepads.swift feeds these with
// real controllers and timers; the tests feed them with numbers and a fake clock.

/// One controller's state in the form the rig reads: XInput button bits, triggers 0...255,
/// sticks -32768...32767 with up positive.
struct PadReport: Equatable {
    var buttons = 0
    var lt = 0
    var rt = 0
    var lx = 0
    var ly = 0
    var rx = 0
    var ry = 0

    static let neutral = PadReport()
}

enum PadQuantize {
    /// A stick axis from -1...1 to the full signed 16-bit range. Full left really is -32768,
    /// which a symmetric `* 32767` never reaches. Anything that isn't a number counts as centre.
    static func axis(_ v: Float) -> Int {
        guard v.isFinite else { return 0 }
        let c = max(-1, min(1, v))
        return Int((c < 0 ? c * 32768 : c * 32767).rounded())
    }

    /// A trigger from 0...1 to 0...255.
    static func trigger(_ v: Float) -> Int {
        guard v.isFinite else { return 0 }
        return Int((max(0, min(1, v)) * 255).rounded())
    }

    /// Stick travel ignored around the centre, as a share of full tilt, for the game path. A
    /// resting stick is never exactly centred, and the leftover tilt reached the rig as real
    /// input — the camera drifted and crept on its own. Console pads trim far more than this
    /// (XInput's own inner zones are about a quarter of travel), so this is conservative.
    static let stickDeadZone: Double = 0.10

    /// A radial dead zone for one stick, on the signed 16-bit scale. The two axes are judged by
    /// their combined magnitude, so a stick resting off-centre reads as centre and a small circle
    /// of play around the middle is ignored without flattening diagonals or snapping to an axis.
    /// Travel past the zone is rescaled so full tilt still reaches the ends.
    ///
    /// This sits on top of any trim the source already applied (Kumori Link trims at the box, the
    /// Siri Remote and local pads do not): a larger radial zone here simply supersedes a smaller
    /// one, and because both only ever pull toward centre they can't disagree on direction.
    static func deadzone(x: Int, y: Int, inner: Double = stickDeadZone) -> (x: Int, y: Int) {
        let fx = Double(x) / 32767, fy = Double(y) / 32767
        let mag = (fx * fx + fy * fy).squareRoot()
        guard mag > inner else { return (0, 0) }
        let scale = min(1, (mag - inner) / (1 - inner)) / mag
        return (axis(Float(fx * scale)), axis(Float(fy * scale)))
    }
}

/// Four player slots. A controller keeps its slot for as long as it stays connected, and a new
/// one takes the lowest free slot, so player 2 stays player 2 when player 1 drops out.
struct SlotTable<Key: Hashable> {
    static var capacity: Int { 4 }

    private(set) var slots: [Key: Int] = [:]

    /// The bit mask of every slot in use, as the rig expects in each report.
    var mask: Int { slots.values.reduce(0) { $0 | (1 << $1) } }

    var isEmpty: Bool { slots.isEmpty }

    func slot(for key: Key) -> Int? { slots[key] }

    /// The key's slot, giving it one if it has none. Nil when all four are taken.
    @discardableResult
    mutating func assign(_ key: Key) -> Int? {
        if let s = slots[key] { return s }
        let used = Set(slots.values)
        guard let free = (0..<Self.capacity).first(where: { !used.contains($0) }) else { return nil }
        slots[key] = free
        return free
    }

    /// Gives the slot back. Returns the slot that was freed, if the key had one.
    @discardableResult
    mutating func release(_ key: Key) -> Int? { slots.removeValue(forKey: key) }

    mutating func removeAll() { slots = [:] }
}

/// What a press of Menu on a controller means. A short tap is the game's Start button. Held
/// for `hold` seconds it opens Kumori's menu instead, and the game never sees it.
///
/// The clock is passed in, so the same code runs under a real timer and in a test.
struct MenuGesture {
    static let hold: TimeInterval = 0.6
    /// How long the game sees Start held down after a tap.
    static let startPulse: TimeInterval = 0.1
    /// The hold timer fires on time give or take float rounding; don't let that turn a hold into a tap.
    private static let slack: TimeInterval = 0.001

    enum Outcome: Equatable {
        case nothing
        /// Open Kumori's menu.
        case openMenu
        /// Press Start in the game now and release it after `startPulse`.
        case tapStart
    }

    private var pressedAt: TimeInterval?
    private var opened = false
    /// The press began while Kumori's menu was open. It belongs to the menu (it may be the very
    /// press that closes it), so it is never a tap of Start or a hold that opens the menu again,
    /// even when the menu has closed by the time it is let go.
    private var beganPaused = false
    /// True while the game should see Start down because of a tap.
    private(set) var startDown = false

    var isHolding: Bool { pressedAt != nil }

    mutating func press(at t: TimeInterval, paused: Bool = false) {
        pressedAt = t
        opened = false
        beganPaused = paused
    }

    /// Called by the hold timer, or by anything that wants to check. Opens the menu once the
    /// press has lasted long enough.
    mutating func tick(at t: TimeInterval) -> Outcome {
        guard let p = pressedAt, !opened, !beganPaused, t - p >= Self.hold - Self.slack else { return .nothing }
        opened = true
        return .openMenu
    }

    /// The button came up. A release after the hold time opens the menu if the timer was late;
    /// a release before it is a tap, unless Kumori's menu is open (the game is paused then).
    mutating func release(at t: TimeInterval, paused: Bool) -> Outcome {
        guard let p = pressedAt else { return .nothing }
        pressedAt = nil
        if opened { return .nothing }
        if beganPaused {
            beganPaused = false
            return .nothing
        }
        if t - p >= Self.hold - Self.slack {
            opened = true
            return .openMenu
        }
        guard !paused else { return .nothing }
        startDown = true
        return .tapStart
    }

    /// The Start pulse is over.
    mutating func endStart() { startDown = false }

    /// The controller left, or the stream ended. Nothing pending may fire afterwards.
    mutating func cancel() {
        pressedAt = nil
        opened = false
        beganPaused = false
        startDown = false
    }
}

/// Buttons held at the moment the game gets control back are kept from it until they are let
/// go. Without this, the A that pressed Resume, or the B that closed the menu, reaches the game
/// as a fresh press.
struct HeldButtonFilter {
    private(set) var suppressed = 0

    /// The game is about to see this controller again, with these buttons down.
    mutating func resume(holding buttons: Int) { suppressed = buttons }

    /// The buttons the game may see. A suppressed button is released from suppression as soon
    /// as it comes up.
    mutating func apply(_ buttons: Int) -> Int {
        suppressed &= buttons
        return buttons & ~suppressed
    }

    mutating func reset() { suppressed = 0 }
}

/// Who gets controller presses on the stream screen. Kumori's own screens (the waiting card,
/// the menu, the ended card) take them through focus; the game takes them only while the
/// picture is up and the menu is closed.
enum InputOwner: Equatable {
    case interface
    case game

    static func forStream(live: Bool, menuOpen: Bool) -> InputOwner { live && !menuOpen ? .game : .interface }
}

/// The server's first message on the input channel carries its protocol version.
enum InputHandshake {
    /// The version, or nil when the bytes aren't a handshake.
    static func version(_ b: [UInt8]) -> Int? {
        guard b.count >= 2 else { return nil }
        let first = Int(b[0]) | (Int(b[1]) << 8)
        if first == 526 { return b.count >= 4 ? Int(b[2]) | (Int(b[3]) << 8) : 2 }
        if b[0] == 0x0e { return first }
        return nil
    }
}

/// Where one controller report goes.
enum InputRoute: Equatable {
    enum Reason: Equatable {
        /// The server hasn't said hello on the input channel yet.
        case notReady
        /// The stream is over.
        case closed
        /// Neither input channel is open.
        case noChannel
    }

    /// The unordered channel. A late report is useless, so this is the normal route.
    case partial
    /// The ordered channel, when the unordered one isn't open.
    case reliable
    case drop(Reason)

    static func choose(ready: Bool, closed: Bool, partialOpen: Bool, reliableOpen: Bool) -> InputRoute {
        if closed { return .drop(.closed) }
        if !ready { return .drop(.notReady) }
        if partialOpen { return .partial }
        if reliableOpen { return .reliable }
        return .drop(.noChannel)
    }
}

/// What happened to controller input in this stream. Shown with the stream stats, so a pad
/// that reaches Kumori but not the game can be told from one that never reaches Kumori.
struct InputStats: Equatable {
    /// The server's input protocol version, once it has said hello.
    var version: Int?
    /// Reports handed to a channel that took them.
    var sent = 0
    /// Reports sent on the ordered channel because the unordered one wasn't open.
    var reliable = 0
    /// Reports from before the server said hello. Expected while the stream starts.
    var early = 0
    /// Reports with no open channel to go on, or that a channel refused.
    var rejected = 0

    var ready: Bool { version != nil }

    mutating func record(_ route: InputRoute, accepted: Bool = true) {
        switch route {
        case .partial, .reliable:
            if accepted {
                sent += 1
                if route == .reliable { reliable += 1 }
            } else {
                rejected += 1
            }
        case .drop(.notReady): early += 1
        case .drop(.closed): break
        case .drop(.noChannel): rejected += 1
        }
    }

    /// A short line for the stats bar.
    var summary: String {
        guard let version else { return "input waiting" }
        var s = "input v\(version), \(sent) sent"
        if rejected > 0 { s += ", \(rejected) refused" }
        return s
    }
}

/// What kind of controller something is, as far as Kumori is concerned.
enum PadProfile: Equatable {
    /// Two sticks, two triggers, the lot: a game controller.
    case extended
    /// A clickpad and a couple of buttons: the Siri Remote, or a pad tvOS only half knows.
    case micro
    /// Connected, but tvOS offers no profile Kumori can read.
    case none
}

/// One connected controller, without the GameController object, so it can be shown and tested.
struct PadInfo: Equatable, Identifiable {
    var id: String
    var name: String
    var category: String
    var profile: PadProfile
    var isRemote: Bool
    /// 0...1, when the controller reports it.
    var battery: Float?
    var hasHaptics = false
}

/// The one-line verdict the Controllers page and the stream lead with.
enum PadSummary: Equatable {
    /// Nothing connected but, possibly, the Siri Remote.
    case noController
    /// Game controllers Kumori can play with.
    case ready(Int)
    /// Something besides the Siri Remote is connected, but not as a full game controller.
    case limited(String)

    static func of(_ pads: [PadInfo]) -> PadSummary {
        let full = pads.filter { $0.profile == .extended }
        if !full.isEmpty { return .ready(full.count) }
        if let odd = pads.first(where: { !$0.isRemote }) { return .limited(odd.name) }
        return .noController
    }

    var title: String {
        switch self {
        case .noController: return "No game controller"
        case .ready(1): return "Controller ready"
        case .ready(let n): return "\(n) controllers ready"
        case .limited(let name): return "\(name) isn't a full controller here"
        }
    }

    var detail: String {
        switch self {
        case .noController:
            return "The Siri Remote can play simple games. For everything else, pair a controller in Settings › Remotes and Devices › Bluetooth."
        case .ready:
            return "Hold Menu (☰) during a game to open Kumori's menu. A short tap is the game's Start button."
        case .limited:
            return "tvOS didn't give it sticks and triggers, so games will only see a few buttons. Try an Xbox or PlayStation controller, or a model on 8BitDo's Apple list."
        }
    }
}

/// The notice the stream shows when it starts without a game controller.
enum PadNotice {
    static func atStart(_ summary: PadSummary) -> String? {
        switch summary {
        case .noController: return "No controller found. The Siri Remote works for simple games."
        case .limited(let name): return "\(name) is connected without sticks and triggers. Games may not respond to it."
        case .ready: return nil
        }
    }

    static func connected(_ name: String, slot: Int) -> String { "\(name) connected as player \(slot + 1)" }
    static func disconnected(_ name: String) -> String { "\(name) disconnected" }
    static let pointerOn = "Mouse mode on. Left stick moves, right stick scrolls, A clicks, B right-clicks. Click both sticks to go back."
    static let pointerOff = "Mouse mode off"
}

/// What goes on the wire for one controller report, and on which channel.
///
/// GeForce NOW reads a pad only after it has been *registered*: a neutral report, sent on the
/// ordered channel, whose bitmap lists every connected pad. Each slot shows up in that bitmap
/// twice: bit `slot` says it's connected, and bit `slot + 8` says it's an XInput (Xbox) pad.
/// One pad in slot 0 is `0x0101`, not `0x0001`. A bitmap without the XInput bits, or state
/// sent before any registration, is accepted on the channel and then ignored by the game.
/// This matches the official PC client and OpenNOW (docs/native-gamepad-input.md there).
///
/// When a pad leaves, its slot is first released with a neutral report under the *old* bitmap,
/// then the new bitmap is registered, all on the ordered channel, so a held button can't stick.
struct PadWire {
    enum Channel: Equatable {
        /// `input_channel_v1`: ordered and reliable.
        case reliable
        /// `input_channel_partially_reliable`: unordered; late reports are dropped.
        case partial
    }

    enum Kind: Equatable {
        /// A neutral report that announces the bitmap. Framed as a single event (0x22).
        case registration
        /// A neutral report for a slot that is leaving, under the old bitmap. Framed as a
        /// single event (0x22).
        case release
        /// Live state. Partial framing (0x26) on the unordered channel, sized framing (0x21)
        /// on the ordered one.
        case state
    }

    struct Frame: Equatable {
        var kind: Kind
        var channel: Channel
        var slot: Int
        /// The bitmap as it goes on the wire, XInput bits included.
        var bitmap: Int
        var report: PadReport
    }

    /// The bitmap the server last accepted, or nil before the first registration.
    private(set) var announced: Int?

    /// Kumori's slot mask (bit per slot) as the wire bitmap.
    static func bitmap(_ slots: Int) -> Int {
        let m = slots & 0x0f
        return m | (m << 8)
    }

    /// The frames for one report from `slot`, given every slot now connected. Send them in
    /// order, then call `accept(_:)` with the plan's `bitmap` once the ordered ones went out.
    func plan(slot: Int, connected: Int, report: PadReport, partialOpen: Bool) -> [Frame] {
        let now = Self.bitmap(connected)
        var frames: [Frame] = []
        if announced != now {
            let before = announced ?? 0
            let gone = (before & 0x0f) & ~(now & 0x0f)
            for s in 0..<4 where gone & (1 << s) != 0 {
                frames.append(Frame(kind: .release, channel: .reliable, slot: s, bitmap: before, report: .neutral))
            }
            let first = (0..<4).first { now & (1 << $0) != 0 } ?? 0
            frames.append(Frame(kind: .registration, channel: .reliable, slot: first, bitmap: now, report: .neutral))
        }
        if connected & (1 << (slot & 3)) != 0 {
            frames.append(Frame(kind: .state, channel: partialOpen ? .partial : .reliable, slot: slot & 3, bitmap: now, report: report))
        }
        return frames
    }

    /// The registration in a plan reached the ordered channel.
    mutating func accept(_ bitmap: Int) { announced = bitmap }

    /// A new stream starts with nothing registered.
    mutating func reset() { announced = nil }
}

/// The controller as a mouse, for launchers and menus that only take a pointer. The left stick
/// moves the pointer, A is the left button, B the right, X the middle, and the right stick
/// scrolls. Clicking both sticks in turns it on and off (see `ChordToggle`).
struct PointerMode {
    /// Pointer speed at full tilt, in mouse counts per second.
    static let topSpeed: Double = 1600
    /// Wheel notches per second at full tilt; one notch is 120.
    static let topScroll: Double = 12
    /// Stick travel ignored around the centre, as a share of full tilt.
    static let deadZone: Double = 0.16

    /// Buttons as the rig numbers them.
    static let left = 1, middle = 2, right = 3

    /// A multiple of the default speed, so a player can slow a twitchy stick down. Scrolling
    /// moves with it; the dead zone and curve don't, so precision near centre is unchanged.
    var sensitivity: Double = 1

    private var carry = (x: 0.0, y: 0.0, wheel: 0.0)
    private(set) var down: Set<Int> = []

    struct Step: Equatable {
        var dx = 0
        var dy = 0
        var wheel = 0
        /// (button, pressed) changes, in order.
        var buttons: [Pair] = []

        struct Pair: Equatable {
            var button: Int
            var pressed: Bool
        }

        var isEmpty: Bool { dx == 0 && dy == 0 && wheel == 0 && buttons.isEmpty }
    }

    /// A stick axis after the dead zone, with a curve so small tilts are precise.
    static func shape(_ v: Int) -> Double {
        let f = max(-1, min(1, Double(v) / 32767))
        let a = abs(f)
        guard a > deadZone else { return 0 }
        let t = (a - deadZone) / (1 - deadZone)
        return (f < 0 ? -1 : 1) * t * t
    }

    /// Advances `dt` seconds with the pad in state `r`. Movement below one count carries over
    /// to the next step, so slow drags still move.
    mutating func step(_ r: PadReport, dt: Double) -> Step {
        var s = Step()
        let dt = max(0, min(dt, 0.1))
        // Screen y grows downward; the stick's y grows upward.
        carry.x += Self.shape(r.lx) * Self.topSpeed * sensitivity * dt
        carry.y -= Self.shape(r.ly) * Self.topSpeed * sensitivity * dt
        carry.wheel += Self.shape(r.ry) * Self.topScroll * 120 * sensitivity * dt
        s.dx = Int(carry.x.rounded(.towardZero))
        s.dy = Int(carry.y.rounded(.towardZero))
        s.wheel = Int(carry.wheel.rounded(.towardZero))
        carry.x -= Double(s.dx)
        carry.y -= Double(s.dy)
        carry.wheel -= Double(s.wheel)
        for (bit, button) in [(InputEncoder.a, Self.left), (InputEncoder.b, Self.right), (InputEncoder.x, Self.middle)] {
            let pressed = r.buttons & bit != 0
            if pressed != down.contains(button) {
                if pressed { down.insert(button) } else { down.remove(button) }
                s.buttons.append(.init(button: button, pressed: pressed))
            }
        }
        return s
    }

    /// Lets go of every button, for leaving pointer mode or pausing.
    mutating func releaseAll() -> Step {
        var s = Step()
        for b in down.sorted() { s.buttons.append(.init(button: b, pressed: false)) }
        down = []
        carry = (0, 0, 0)
        return s
    }
}

/// Clicking both sticks in together switches mouse mode on or off. Once it fires, it waits
/// until both sticks are let go before it can fire again, so holding the chord toggles once.
struct ChordToggle {
    static let chord = InputEncoder.leftStick | InputEncoder.rightStick
    private var armed = true

    /// True when this report completes the chord.
    mutating func update(_ buttons: Int) -> Bool {
        if buttons & Self.chord == Self.chord {
            guard armed else { return false }
            armed = false
            return true
        }
        if buttons & Self.chord == 0 { armed = true }
        return false
    }

    mutating func reset() { armed = true }
}

/// Which Kumori Link STATE packets to take, and which relayed controllers have gone quiet.
///
/// The box numbers every STATE packet, sends a change at once and repeats it for 150 ms, and
/// sends every controller's state every 500 ms (docs/kumori-link-protocol.md). So:
/// - an older packet than the newest taken for its slot is dropped, but one far behind means
///   the box app restarted and counts from 1 again, and is taken;
/// - a slot not heard for `staleAfter` lost its packets (Wi-Fi dropped, the box froze): the
///   game must see it let go instead of holding the last stick and buttons;
/// - a slot not heard for `goneAfter` has left, even if its "left" packet, which the box sends
///   only once, was lost.
struct LinkFreshness {
    /// A sequence this far behind the newest is a box that started counting again.
    static let restartGap: UInt32 = 1000
    static let staleAfter: TimeInterval = 1.2
    static let goneAfter: TimeInterval = 3.5

    private(set) var lastSeq: [Int: UInt32] = [:]
    private var newestSeq: UInt32?
    private var heardAt: [Int: TimeInterval] = [:]
    private var staled: Set<Int> = []

    struct Verdict: Equatable {
        /// Take this packet.
        var take: Bool
        /// It is the newest packet from the box so far, so its slot mask is current.
        var newest: Bool
    }

    /// True when `seq` comes after `last`, or so far before it that the box restarted.
    static func isAfter(_ seq: UInt32, _ last: UInt32) -> Bool {
        let d = Int32(bitPattern: seq &- last)
        return d > 0 || d <= -Int32(restartGap)
    }

    mutating func receive(slot: Int, seq: UInt32, at t: TimeInterval) -> Verdict {
        if let last = lastSeq[slot], !Self.isAfter(seq, last) { return Verdict(take: false, newest: false) }
        lastSeq[slot] = seq
        heardAt[slot] = t
        staled.remove(slot)
        let newest = newestSeq.map { Self.isAfter(seq, $0) } ?? true
        if newest { newestSeq = seq }
        return Verdict(take: true, newest: newest)
    }

    /// Slots that just went quiet for `staleAfter`, each reported once until heard again.
    mutating func stale(at t: TimeInterval) -> [Int] {
        let quiet = heardAt.filter { t - $0.value > Self.staleAfter && !staled.contains($0.key) }.keys.sorted()
        staled.formUnion(quiet)
        return quiet
    }

    /// Slots quiet for `goneAfter`. They are forgotten here; the next packet starts afresh.
    mutating func gone(at t: TimeInterval) -> [Int] {
        let quiet = heardAt.filter { t - $0.value > Self.goneAfter }.keys.sorted()
        for s in quiet { forget(s) }
        return quiet
    }

    /// The slot left. Its sequence is kept, so a late copy of its last state can't bring it back.
    mutating func forget(_ slot: Int) {
        heardAt[slot] = nil
        staled.remove(slot)
    }

    /// The box said goodbye or the connection was replaced: start over.
    mutating func reset() { self = LinkFreshness() }
}
