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
    private static let repeatAfter = 0.4
    private static let repeatEvery = 0.12
    /// How far a stick must tilt to count as a direction, out of 32767.
    private static let tilt = 16000

    private var held: Direction?
    private var buttons = 0
    private var repeatTimer: Timer?

    /// Called with the first relayed controller's state whenever the game doesn't own input.
    func handle(_ r: PadReport?) {
        let r = r ?? .neutral
        let pressed = r.buttons & ~buttons
        buttons = r.buttons
        if pressed & InputEncoder.a != 0 { select() }
        if pressed & InputEncoder.b != 0 { back() }
        let d = Self.direction(r)
        guard d != held else { return }
        held = d
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard let d else { return }
        move(d)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.startRepeat(d) }
        }
    }

    /// Lets go of everything, for when the game takes input back.
    func reset() {
        held = nil
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
                self.move(d)
            }
        }
    }

    private static func direction(_ r: PadReport) -> Direction? {
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
        attempt(ways[...], d, from: current, in: window, system: system)
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
                         in window: UIWindow, system: UIFocusSystem) {
        guard let way = ways.first else {
            geometricMove(d, from: current, in: window, system: system)
            return
        }
        let label = way.0
        guard way.1() else {
            attempt(ways.dropFirst(), d, from: current, in: window, system: system)
            return
        }
        system.updateFocusIfNeeded()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self else { return }
            if let now = system.focusedItem, now !== current {
                self.note("\(d) via \(label) to \(Self.name(now))")
                return
            }
            self.attempt(ways.dropFirst(), d, from: current, in: window, system: system)
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

    private func geometricMove(_ d: Direction, from current: UIFocusItem, in window: UIWindow, system: UIFocusSystem) {
        let candidates = Self.items(in: window)
        guard let from = candidates.first(where: { $0.item === current })?.frame ?? Self.frame(of: current, in: window) else {
            note("\(d) from \(Self.name(current)): no frame for it")
            return
        }
        var best: (item: UIFocusItem, score: CGFloat)?
        // The focused item can show up under another object, so its frame rules it out too.
        // Skip anything around the focused item, like a bar or section that holds it. A
        // neighbour can overlap it a little while the focused one is lifted, so that's allowed.
        for c in candidates where c.item !== current && !Self.same(c.frame, from) && c.item.canBecomeFocused
            && !c.frame.contains(CGPoint(x: from.midX, y: from.midY)) && !(c.item is UITabBar) {
            guard let score = Self.score(from: from, to: c.frame, d) else { continue }
            if best == nil || score < best!.score { best = (c.item, score) }
        }
        guard let target = best?.item else {
            note("\(d) from \(Self.name(current)): nothing that way (\(candidates.count) items)")
            return
        }
        system.requestFocusUpdate(to: target)
        system.updateFocusIfNeeded()
        var how = "request"
        if system.focusedItem === current {
            how = "root"
            guideFocus(to: target, in: window, system: system)
        }
        let now = system.focusedItem
        let result = now === target ? "moved by \(how)" : (now === current ? "stayed" : "went to \(Self.name(now)) by \(how)")
        note("\(d) from \(Self.name(current)) to \(Self.name(target)): \(result)")
    }

    /// A focus request the engine takes for a SwiftUI item: one to an invisible view whose
    /// preferred focus is that item, so the engine resolves the item itself.
    private func guideFocus(to target: UIFocusItem, in window: UIWindow, system: UIFocusSystem) {
        // The engine takes a request only for an environment that holds the focused item, so
        // ask through the root view controller, with its preferred focus pointed at the target
        // for this one request.
        guard let root = window.rootViewController else { return }
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
    private static func items(in window: UIWindow) -> [(item: UIFocusItem, frame: CGRect)] {
        var out: [(item: UIFocusItem, frame: CGRect)] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ v: UIView) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            if let container: UIFocusItemContainer = v.focusItemContainer {
                let space: UICoordinateSpace = container.coordinateSpace
                for item in container.focusItems(in: space.bounds) {
                    guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
                    let f = space.convert(item.frame, to: window)
                    guard f.width > 1, f.height > 1 else { continue }
                    out.append((item, f))
                }
            }
            for s in v.subviews { visit(s) }
        }
        visit(window)
        return out
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
        var visited = 0
        func visit(_ o: NSObject, depth: Int) {
            visited += 1
            guard depth < 40, visited < 4000 else { return }
            let f = o.accessibilityFrame
            let overlap = f.intersection(target)
            if !overlap.isNull, o.isAccessibilityElement {
                // Most overlap with the item, and least spill past it.
                let score = overlap.width * overlap.height - 0.5 * max(0, f.width * f.height - overlap.width * overlap.height)
                if best == nil || score > best!.area { best = (o, score) }
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
        return best?.o
    }

    // MARK: Select and back

    private func select() {
        guard let window, let item = UIFocusSystem.focusSystem(for: window)?.focusedItem else {
            note("select: nothing focused")
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
