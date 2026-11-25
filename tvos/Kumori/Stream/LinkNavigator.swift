import ObjectiveC
import os
import UIKit

/// Drives Kumori's own screens with a controller relayed by Kumori Link. tvOS only lets
/// controllers it knows move focus, so this does the focus engine's part itself: a direction
/// moves focus to the nearest item that way, A selects, B goes back.
@MainActor
final class LinkNavigator: ObservableObject {
    static let shared = LinkNavigator()

    /// The last few things the navigator did, newest last, for the debug page and UI tests.
    @Published private(set) var trace: [String] = []

    enum Direction { case up, down, left, right }

    private static let log = Logger(subsystem: "app.kumori.tv", category: "link")
    /// A direction held this long starts repeating, every `repeatEvery` after that.
    /// The Siri Remote's own rhythm: a pause, then steady steps.
    private static let repeatAfter = 0.45
    private static let repeatEvery = 0.14
    /// How far a stick must tilt to count as a direction, out of 32767.
    private static let tilt = 16000

    private var held: Direction?
    private var buttons = 0
    private var repeatTimer: Timer?
    /// When the box last sent any state. It resends everything every 500 ms, so a held
    /// direction with nothing heard for longer was let go and the release got lost.
    private var lastHeard = Date()
    /// Bumped on every release and new direction, so a move still working through its
    /// fallbacks can't land after the stick was let go.
    private var generation = 0
    /// The last direction let go, and when: a stick springing back can overshoot the
    /// centre and read as a flick the other way.
    private var released: (Direction, Date)?

    /// A focused game card's own action, so A opens exactly the card that has focus rather
    /// than whatever accessibility element overlaps it while cards are still resizing.
    private var focusedAction: (id: String, run: () -> Void)?

    func cardFocused(_ id: String, _ run: @escaping () -> Void) { focusedAction = (id, run) }
    func cardUnfocused(_ id: String) { if focusedAction?.id == id { focusedAction = nil } }

    /// Every STATE packet, changed or not.
    func heard() { lastHeard = Date() }

    /// A move is still working through its fallbacks. A held direction waits for it instead of
    /// piling up moves, which lagged the app.
    private var moving = false

    /// Takes over from the game: what is held right now (the buttons that opened the menu)
    /// counts as already pressed, so it doesn't also select or go back.
    func adopt(_ r: PadReport?) {
        reset()
        let r = r ?? .neutral
        buttons = r.buttons
        held = Self.direction(r)
    }

    /// Called with the first relayed controller's state whenever the game doesn't own input.
    func handle(_ r: PadReport?) {
        let r = r ?? .neutral
        // Any use of the controller counts as someone being there, like a remote press, so
        // the screen saver doesn't start while Kumori is driven from a Link controller.
        if r != .neutral { Awake.shared.poke() }
        let pressed = r.buttons & ~buttons
        buttons = r.buttons
        if pressed & InputEncoder.a != 0 { select() }
        if pressed & InputEncoder.b != 0 { back() }
        let d = Self.direction(r, holding: held)
        guard d != held else { return }
        if let was = held, d == nil { released = (was, Date()) }
        held = d
        generation += 1
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard let d else { return }
        // The rebound of a released stick, not a real flick the other way.
        if let rel = released, d == Self.opposite(rel.0), Date().timeIntervalSince(rel.1) < 0.15,
           r.buttons & (InputEncoder.up | InputEncoder.down | InputEncoder.left | InputEncoder.right) == 0 {
            note("ignored \(d): stick rebound")
            return
        }
        move(d)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startRepeat(d) }
        }
    }

    /// Lets go of everything, for when the game takes input back.
    func reset() {
        held = nil
        generation += 1
        buttons = 0
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func startRepeat(_ d: Direction) {
        guard held == d else { return }
        move(d)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.held == d else { return }
                // Nothing from the box for a while: the release was lost. Stop.
                if Date().timeIntervalSince(self.lastHeard) > 0.8 {
                    self.note("released \(d): nothing heard")
                    self.reset()
                    return
                }
                guard !self.moving else { return }
                self.move(d)
            }
        }
    }

    private static func opposite(_ d: Direction) -> Direction {
        switch d {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }

    /// A held stick counts until it falls back under `letGo`, well inside `tilt`, so a stick
    /// hovering at the edge doesn't flicker between held and released and step again.
    private static let letGo = 9000

    private static func direction(_ r: PadReport, holding: Direction? = nil) -> Direction? {
        let b = r.buttons
        if b & InputEncoder.up != 0 { return .up }
        if b & InputEncoder.down != 0 { return .down }
        if b & InputEncoder.left != 0 { return .left }
        if b & InputEncoder.right != 0 { return .right }
        // Sticks: up is positive.
        if abs(r.lx) > tilt || abs(r.ly) > tilt {
            if abs(r.lx) > abs(r.ly) { return r.lx > 0 ? .right : .left }
            return r.ly > 0 ? .up : .down
        }
        if let h = holding {
            let v: Int
            switch h {
            case .right: v = r.lx
            case .left: v = -r.lx
            case .up: v = r.ly
            case .down: v = -r.ly
            }
            if v > letGo { return h }
        }
        return nil
    }

    // MARK: Focus

    private var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    private func note(_ s: String) {
        Self.log.notice("link nav: \(s, privacy: .public)")
        trace.append(s)
        if trace.count > 30 { trace.removeFirst(trace.count - 30) }
    }

    private static func name(_ item: UIFocusItem?) -> String {
        guard let item else { return "nil" }
        let o = item as? NSObject
        let id = (item as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
        let label = o?.accessibilityLabel ?? ""
        return "\(type(of: item))[\(id.isEmpty ? label : id)]"
    }

    private func move(_ d: Direction) {
        guard let window, let system = UIFocusSystem.focusSystem(for: window) else {
            note("no window")
            return
        }
        guard let current = system.focusedItem else {
            // A screen that just appeared may not have focus yet: let the engine pick its default.
            system.requestFocusUpdate(to: window)
            system.updateFocusIfNeeded()
            note("nothing focused, now \(Self.name(system.focusedItem))")
            return
        }
        dumpFocusSelectorsOnce()
        // The remote's arrow press, sent to the window itself. A press sent to the focused SwiftUI
        // view stops in its hosting view, but the window's focus recognizer acts on it the same way
        // it does for the remote, so focus sections, defaults and scrolling all apply.
        let ways: [(String, () -> Bool)] = [
            ("app event", { Self.appArrow(window, d) }),
            ("window arrow", { Self.windowArrow(window, d) }),
            ("view arrow", { [weak self] in self?.press(Self.arrow(d), at: current, quiet: true); return true }),
        ]
        // Kumori's own pick first: the nearest item straight that way, focused through the
        // engine. The arrow routes are for when that finds nothing, like leaving a tab bar.
        if geometricMove(d, from: current, in: window, system: system) { return }
        moving = true
        attempt(ways[...], d, from: current, in: window, system: system, generation: generation)
    }

    private static func arrow(_ d: Direction) -> UIPress.PressType {
        switch d {
        case .up: return .upArrow
        case .down: return .downArrow
        case .left: return .leftArrow
        case .right: return .rightArrow
        }
    }

    /// The arrow as an event through UIApplication.sendEvent, the path a real press takes,
    /// so the window's gesture recognizers, the focus engine's among them, see it.
    private static func appArrow(_ window: UIWindow, _ d: Direction) -> Bool {
        let type = arrow(d)
        UIApplication.shared.sendEvent(LinkPressesEvent(LinkPress(type, .began, window: window)))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            UIApplication.shared.sendEvent(LinkPressesEvent(LinkPress(type, .ended, window: window)))
        }
        return true
    }

    private static func windowArrow(_ window: UIWindow, _ d: Direction) -> Bool {
        let type = arrow(d)
        window.pressesBegan([LinkPress(type, .began)], with: UIPressesEvent())
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            window.pressesEnded([LinkPress(type, .ended)], with: UIPressesEvent())
        }
        return true
    }

    private func attempt(_ ways: ArraySlice<(String, () -> Bool)>, _ d: Direction, from current: UIFocusItem,
                         in window: UIWindow, system: UIFocusSystem, generation: Int) {
        // Turned another way since this move began: don't keep going. A plain release
        // still lets the press finish (a quick tap is often let go before it lands).
        guard held == nil || held == d else {
            moving = false
            return
        }
        guard let way = ways.first else {
            note("\(d) from \(Self.name(current)): nothing moved")
            moving = false
            return
        }
        let label = way.0
        guard way.1() else {
            attempt(ways.dropFirst(), d, from: current, in: window, system: system, generation: generation)
            return
        }
        system.updateFocusIfNeeded()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self else { return }
            if let now = system.focusedItem, now !== current {
                self.note("\(d) via \(label) to \(Self.name(now))")
                self.moving = false
                return
            }
            self.attempt(ways.dropFirst(), d, from: current, in: window, system: system, generation: generation)
        }
    }

    private var dumped = false

    /// Which focus movement calls this tvOS has, once, for the log.
    private func dumpFocusSelectorsOnce() {
        guard !dumped else { return }
        dumped = true
        var names: [String] = []
        var classes: [AnyClass] = [UIFocusSystem.self, UIApplication.self, UIWindow.self, UIWindowScene.self]
        for n in ["_UIFocusEngine", "_UIFocusMovementInfo", "_UIFocusSystemSceneComponent", "UIFocusSystemSceneComponent",
                  "_UIFocusMovementRequest", "_UIFocusEnvironmentContainerTuple", "_UIFocusEngineJoystickGestureRecognizer",
                  "_UIFocusEngineRemoteGestureRecognizer", "_UIFocusPressGestureRecognizer", "_UIFocusFastScrollingController"] {
            if let c = NSClassFromString(n) { classes.append(c) }
        }
        for cls in classes {
            var count: UInt32 = 0
            guard let list = class_copyMethodList(cls, &count) else { continue }
            for i in 0..<Int(count) {
                let n = NSStringFromSelector(method_getName(list[i]))
                let l = n.lowercased()
                if l.contains("heading") || l.contains("move") || l.contains("direction") {
                    names.append("\(cls).\(n)")
                }
            }
            free(list)
        }
        Self.log.notice("link nav: selectors \(names.joined(separator: " "), privacy: .public)")
        Self.log.notice("link nav: focus selectors: \(names.joined(separator: " "), privacy: .public)")
    }

    @discardableResult
    private func geometricMove(_ d: Direction, from current: UIFocusItem, in window: UIWindow, system: UIFocusSystem) -> Bool {
        let candidates = Self.items(in: window, around: current)
        guard let from = candidates.first(where: { $0.item === current })?.frame ?? Self.frame(of: current, in: window) else {
            note("\(d) from \(Self.name(current)): no frame for it")
            return false
        }
        var best: (item: UIFocusItem, score: CGFloat, frame: CGRect)?
        // The focused item can show up under another object, so its frame rules it out too.
        // Skip anything around the focused item, like a bar or section that holds it. A
        // neighbour can overlap it a little while the focused one is lifted, so that's allowed.
        for c in candidates where c.item !== current && !Self.same(c.frame, from) && c.item.canBecomeFocused
            && !c.frame.contains(CGPoint(x: from.midX, y: from.midY)) && !(c.item is UITabBar) {
            guard let score = Self.score(from: from, to: c.frame, d) else { continue }
            if best == nil || score < best!.score { best = (c.item, score, c.frame) }
        }
        guard let target = best?.item else {
            note("\(d) from \(Self.name(current)) at \(Int(from.minX)),\(Int(from.minY)),\(Int(from.width))x\(Int(from.height)): nothing that way (\(candidates.count) items: \(Self.describe(candidates)))")
            return false
        }
        system.requestFocusUpdate(to: target)
        system.updateFocusIfNeeded()
        var how = "request"
        if system.focusedItem === current {
            how = "root"
            guideFocus(to: target, in: window, system: system)
        }
        let now = system.focusedItem
        let result = (now === target ? "moved by \(how)" : (now === current ? "stayed" : "went to \(Self.name(now)) by \(how)"))
            + " [\(Int(from.minX)),\(Int(from.minY)) to \(Int(best!.frame.minX)),\(Int(best!.frame.minY)) of \(candidates.count)]"
        note("\(d) from \(Self.name(current)) to \(Self.name(target)): \(result)")
        if now !== current { FocusClick.shared.move() }
        return now !== current
    }

    /// A focus request the engine takes for a SwiftUI item: one to an invisible view whose
    /// preferred focus is that item, so the engine resolves the item itself.
    private func guideFocus(to target: UIFocusItem, in window: UIWindow, system: UIFocusSystem) {
        // The engine takes a request only for an environment that holds the focused item, so
        // ask through the root view controller, with its preferred focus pointed at the target
        // for this one request.
        guard let root = Self.top(window) else { return }
        Self.hookPreferred(on: root)
        Self.preferredOverride = [target]
        system.requestFocusUpdate(to: root)
        system.updateFocusIfNeeded()
        Self.preferredOverride = nil
    }

    nonisolated(unsafe) private static var preferredOverride: [UIFocusEnvironment]?
    private static var hooked = Set<ObjectIdentifier>()

    /// Lets `preferredOverride` answer the root view controller's preferredFocusEnvironments.
    private static func hookPreferred(on vc: UIViewController) {
        let cls: AnyClass = type(of: vc)
        guard hooked.insert(ObjectIdentifier(cls)).inserted else { return }
        let sel = #selector(getter: UIViewController.preferredFocusEnvironments)
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let original = method_getImplementation(method)
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSArray
        let call = unsafeBitCast(original, to: Getter.self)
        let block: @convention(block) (AnyObject) -> NSArray = { me in
            if let o = LinkNavigator.preferredOverride { return o as NSArray }
            return call(me, sel)
        }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    /// Lower is better. Nil when `to` isn't in that direction at all.
    private static func score(from a: CGRect, to b: CGRect, _ d: Direction) -> CGFloat? {
        let slack: CGFloat = 4
        let along: CGFloat
        let across: CGFloat
        switch d {
        case .right:
            guard b.minX >= a.maxX - slack else { return nil }
            along = max(0, b.minX - a.maxX)
            across = max(0, max(a.minY, b.minY) < min(a.maxY, b.maxY) ? 0 : abs(b.midY - a.midY))
        case .left:
            guard b.maxX <= a.minX + slack else { return nil }
            along = max(0, a.minX - b.maxX)
            across = max(0, max(a.minY, b.minY) < min(a.maxY, b.maxY) ? 0 : abs(b.midY - a.midY))
        case .down:
            guard b.minY >= a.maxY - slack else { return nil }
            along = max(0, b.minY - a.maxY)
            across = max(0, max(a.minX, b.minX) < min(a.maxX, b.maxX) ? 0 : abs(b.midX - a.midX))
        case .up:
            guard b.maxY <= a.minY + slack else { return nil }
            along = max(0, a.minY - b.maxY)
            across = max(0, max(a.minX, b.minX) < min(a.maxX, b.maxX) ? 0 : abs(b.midX - a.midX))
        }
        // Items that overlap the focused one sideways win over closer ones that don't.
        return along + across * 3
    }

    /// Every focus item in the window, with its frame in window coordinates.
    private static func items(in window: UIWindow, around current: UIFocusItem? = nil) -> [(item: UIFocusItem, frame: CGRect)] {
        var out: [(item: UIFocusItem, frame: CGRect)] = []
        var seen = Set<ObjectIdentifier>()
        // SwiftUI nests its items: a focus section or a stack is an item that is itself a
        // container, so each container is walked down to the buttons inside it.
        func walk(_ container: UIFocusItemContainer, depth: Int) {
            guard depth < 12 else { return }
            let space: UICoordinateSpace = container.coordinateSpace
            // Past the visible edge too, so a shelf can move on to the item it will scroll to.
            for item in container.focusItems(in: space.bounds.insetBy(dx: -1920, dy: -1080)) {
                guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
                let f = space.convert(item.frame, to: window)
                let kind = String(describing: type(of: item))
                if f.width > 1, f.height > 1, !kind.contains("Filler"), item.canBecomeFocused {
                    out.append((item, f))
                }
                if !(item is UIView), let inner = item.focusItemContainer {
                    walk(inner, depth: depth + 1)
                }
            }
        }
        func visit(_ v: UIView) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            if let container: UIFocusItemContainer = v.focusItemContainer { walk(container, depth: 0) }
            for s in v.subviews { visit(s) }
        }
        // Only the screen on top: the stream and a game's page are presented over Home, and
        // walking the screens underneath sent focus to buttons hidden behind them (the in-game
        // menu didn't move at all) and made every held press slow.
        if let screen = Self.top(window), let v = screen.viewIfLoaded { visit(v) } else { visit(window) }
        // Containers above the focused item too. A presented page or a tab's content can sit
        // where the view walk doesn't reach its items, but the focused item's own ancestors
        // always lead to its neighbours.
        if let current {
            let screen = Self.top(window)
            var env: UIFocusEnvironment? = current.parentFocusEnvironment
            var hops = 0
            while let e = env, hops < 40 {
                if let c = e.focusItemContainer { walk(c, depth: 0) }
                if let vc = e as? UIViewController {
                    // The screen on top has been walked; above it are the screens behind.
                    if vc === screen { break }
                    if let v = vc.viewIfLoaded { visit(v) }
                }
                env = e.parentFocusEnvironment
                hops += 1
            }
        }
        return out
    }

    /// The view controller on top: the root, or the last one presented over it that isn't
    /// on its way out.
    static func top(_ window: UIWindow) -> UIViewController? {
        var vc = window.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    /// A short list of what the walk found, for the trace when nothing fits.
    private static func describe(_ items: [(item: UIFocusItem, frame: CGRect)]) -> String {
        items.prefix(12).map { "\(name($0.item))@\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .joined(separator: " ")
    }

    /// The item's frame in window coordinates. SwiftUI's items aren't views: their frame is in
    /// the coordinate space of the nearest container above them.
    private static func frame(of item: UIFocusItem, in window: UIWindow) -> CGRect? {
        if let v = item as? UIView { return v.convert(v.bounds, to: window) }
        var env = item.parentFocusEnvironment
        while let e = env {
            if let container = e.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            env = e.parentFocusEnvironment
        }
        return nil
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The nearest view at or above the item in the focus tree.
    private static func view(for item: UIFocusItem) -> UIView? {
        var env: UIFocusEnvironment? = item
        while let e = env, !(e is UIView) { env = e.parentFocusEnvironment }
        return env as? UIView
    }

    /// The accessibility element that sits where the item is: SwiftUI's buttons activate
    /// through it, the way VoiceOver presses them.
    private static func element(for item: UIFocusItem, in window: UIWindow) -> NSObject? {
        guard let frame = frame(of: item, in: window), let root = view(for: item) else { return nil }
        let target = window.convert(frame, to: nil)
        var best: (o: NSObject, area: CGFloat)?
        var loose: (o: NSObject, area: CGFloat)?
        var visited = 0
        func visit(_ o: NSObject, depth: Int) {
            visited += 1
            guard depth < 40, visited < 4000 else { return }
            let f = o.accessibilityFrame
            let overlap = f.intersection(target)
            // Only an element centred inside the focused item: a neighbour still resizing
            // (an opening card, a button lifting) overlaps it a lot and was picked instead.
            if !overlap.isNull, o.isAccessibilityElement, target.insetBy(dx: -2, dy: -2).contains(CGPoint(x: f.midX, y: f.midY)) {
                // The one that matches the item best: shared area over the two together.
                let shared = overlap.width * overlap.height
                let union = f.width * f.height + target.width * target.height - shared
                let score = union > 0 ? shared / union : 0
                if best == nil || score > best!.area { best = (o, score) }
            } else if !overlap.isNull, o.isAccessibilityElement {
                // Kept only for when nothing is centred on the item.
                let score = overlap.width * overlap.height - 0.5 * max(0, f.width * f.height - overlap.width * overlap.height)
                if loose == nil || score > loose!.area { loose = (o, score) }
            }
            if let kids = o.accessibilityElements as? [NSObject] {
                for k in kids { visit(k, depth: depth + 1) }
            } else {
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) {
                        if let k = o.accessibilityElement(at: i) as? NSObject { visit(k, depth: depth + 1) }
                    }
                }
            }
            if let v = o as? UIView {
                for sub in v.subviews where !sub.isHidden { visit(sub, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return best?.o ?? loose?.o
    }

    // MARK: Select and back

    private func select() {
        guard let window, let item = UIFocusSystem.focusSystem(for: window)?.focusedItem else {
            note("select: nothing focused")
            return
        }
        FocusClick.shared.select()
        // A game card on the screen underneath everything: its own action, exactly.
        if let card = focusedAction, Self.top(window) === window.rootViewController {
            note("select card \(card.id)")
            card.run()
            return
        }
        if let o = item as? NSObject, o.accessibilityActivate() {
            note("select \(Self.name(item)): activated")
            return
        }
        if let c = item as? UIControl {
            c.sendActions(for: .primaryActionTriggered)
            note("select \(Self.name(item)): control action")
            return
        }
        if let e = Self.element(for: item, in: window) {
            let ok = e.accessibilityActivate()
            note("select \(Self.name(item)): element \(type(of: e))[\(e.accessibilityLabel ?? "")] \(ok ? "activated" : "refused")")
            if ok { return }
        } else {
            note("select \(Self.name(item)): no element")
        }
        // Last resort: the press the Siri Remote would send.
        press(.select, at: item)
    }

    private func back() {
        guard let window, let item = UIFocusSystem.focusSystem(for: window)?.focusedItem else {
            note("back: nothing focused")
            return
        }
        // Screens register what Menu does on them (`onBack`); the innermost one under focus wins.
        if let action = LinkBack.shared.action(around: Self.frame(of: item, in: window)) {
            action()
            note("back: screen handler")
            return
        }
        // Navigation and sheets are UIKit underneath SwiftUI: step back the way Menu would.
        var responder: UIResponder? = Self.view(for: item)
        while let r = responder, !(r is UIViewController) { responder = r.next }
        var vc = responder as? UIViewController
        while let c = vc {
            if let nav = c as? UINavigationController ?? c.navigationController, nav.viewControllers.count > 1 {
                nav.popViewController(animated: true)
                note("back: popped \(type(of: nav))")
                return
            }
            if c.presentingViewController != nil, c.parent == nil {
                c.dismiss(animated: true)
                note("back: dismissed \(type(of: c))")
                return
            }
            vc = c.parent ?? c.presentingViewController
        }
        if let e = Self.element(for: item, in: window) {
            var o: NSObject? = e
            while let x = o {
                if x.accessibilityPerformEscape() {
                    note("back: escape on \(type(of: x))")
                    return
                }
                o = (x as? UIAccessibilityElement)?.accessibilityContainer as? NSObject ?? (x as? UIView)?.superview
            }
        }
        // No fake Menu press here: one that nothing takes reaches the system and closes the app.
        note("back: nowhere to go from \(Self.name(item))")
    }

    /// Sends a press to the view nearest the focused item, the way the remote's would arrive.
    private func press(_ type: UIPress.PressType, at item: UIFocusItem, quiet: Bool = false) {
        var env: UIFocusEnvironment? = item
        while let e = env, !(e is UIView) { env = e.parentFocusEnvironment }
        guard let view = env as? UIView else {
            note("press \(type.rawValue): no view above \(Self.name(item))")
            return
        }
        let event = UIPressesEvent()
        view.pressesBegan([LinkPress(type, .began)], with: event)
        view.pressesEnded([LinkPress(type, .ended)], with: event)
        if quiet { return }
        note("press \(type.rawValue) sent to \(Swift.type(of: view)) for \(Self.name(item))")
    }
}

/// A remote button press made in code, for the views that only listen for presses.
private final class LinkPress: UIPress {
    private let kind: UIPress.PressType
    private let stage: UIPress.Phase
    private weak var home: UIWindow?
    init(_ kind: UIPress.PressType, _ stage: UIPress.Phase, window: UIWindow? = nil) {
        self.kind = kind
        self.stage = stage
        self.home = window
        super.init()
    }
    override var type: UIPress.PressType { kind }
    override var phase: UIPress.Phase { stage }
    override var window: UIWindow? { home }
    override var responder: UIResponder? { home }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// An event that carries one made-up press, for UIApplication.sendEvent.
private final class LinkPressesEvent: UIPressesEvent {
    private let press: LinkPress
    init(_ press: LinkPress) {
        self.press = press
        super.init()
    }
    override var type: UIEvent.EventType { .presses }
    override var allPresses: Set<UIPress> { [press] }
    override func presses(for gesture: UIGestureRecognizer) -> Set<UIPress> { [press] }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
