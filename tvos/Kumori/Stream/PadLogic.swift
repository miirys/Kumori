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
    /// True while the game should see Start down because of a tap.
    private(set) var startDown = false

    var isHolding: Bool { pressedAt != nil }

    mutating func press(at t: TimeInterval) {
        pressedAt = t
        opened = false
    }

    /// Called by the hold timer, or by anything that wants to check. Opens the menu once the
    /// press has lasted long enough.
    mutating func tick(at t: TimeInterval) -> Outcome {
        guard let p = pressedAt, !opened, t - p >= Self.hold - Self.slack else { return .nothing }
        opened = true
        return .openMenu
    }

    /// The button came up. A release after the hold time opens the menu if the timer was late;
    /// a release before it is a tap, unless Kumori's menu is open (the game is paused then).
    mutating func release(at t: TimeInterval, paused: Bool) -> Outcome {
        guard let p = pressedAt else { return .nothing }
        pressedAt = nil
        if opened { return .nothing }
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
        var s = "input v\(version) · \(sent) sent"
        if rejected > 0 { s += " · \(rejected) refused" }
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
}
