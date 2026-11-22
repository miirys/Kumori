import os
import UIKit

/// Drives Kumori's own screens with a controller relayed by Kumori Link. tvOS only lets
/// controllers it knows move focus, so this does the focus engine's part itself: a direction
/// moves focus to the nearest item that way, A selects, B goes back.
@MainActor
final class LinkNavigator {
    static let shared = LinkNavigator()

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

    private func move(_ d: Direction) {
        guard let window, let system = UIFocusSystem.focusSystem(for: window) else { return }
        guard let current = system.focusedItem else {
            Self.log.notice("link nav: nothing focused")
            return
        }
        let candidates = Self.items(in: window)
        guard let from = candidates.first(where: { $0.item === current })?.frame ?? Self.frame(of: current, in: window) else { return }
        var best: (item: UIFocusItem, score: CGFloat)?
        for c in candidates where c.item !== current && c.item.canBecomeFocused {
            guard let score = Self.score(from: from, to: c.frame, d) else { continue }
            if best == nil || score < best!.score { best = (c.item, score) }
        }
        guard let target = best?.item else {
            Self.log.notice("link nav: nothing \(String(describing: d), privacy: .public) of the focused item (\(candidates.count) items)")
            return
        }
        system.requestFocusUpdate(to: target)
    }

    /// Lower is better. Nil when `to` isn't in that direction at all.
    private static func score(from a: CGRect, to b: CGRect, _ d: Direction) -> CGFloat? {
        let slack: CGFloat = 4
        let along: CGFloat
        let across: CGFloat
        switch d {
        case .right:
            guard b.minX >= a.maxX - slack || (b.midX > a.maxX) else { return nil }
            along = max(0, b.minX - a.maxX)
            across = max(0, max(a.minY, b.minY) < min(a.maxY, b.maxY) ? 0 : abs(b.midY - a.midY))
        case .left:
            guard b.maxX <= a.minX + slack || (b.midX < a.minX) else { return nil }
            along = max(0, a.minX - b.maxX)
            across = max(0, max(a.minY, b.minY) < min(a.maxY, b.maxY) ? 0 : abs(b.midY - a.midY))
        case .down:
            guard b.minY >= a.maxY - slack || (b.midY > a.maxY) else { return nil }
            along = max(0, b.minY - a.maxY)
            across = max(0, max(a.minX, b.minX) < min(a.maxX, b.maxX) ? 0 : abs(b.midX - a.midX))
        case .up:
            guard b.maxY <= a.minY + slack || (b.midY < a.minY) else { return nil }
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

    private static func frame(of item: UIFocusItem, in window: UIWindow) -> CGRect? {
        if let v = item as? UIView { return v.convert(v.bounds, to: window) }
        return nil
    }

    // MARK: Select and back

    private func select() {
        guard let window, let item = UIFocusSystem.focusSystem(for: window)?.focusedItem else { return }
        if let o = item as? NSObject, o.accessibilityActivate() { return }
        if let c = item as? UIControl {
            c.sendActions(for: .primaryActionTriggered)
            return
        }
        // Last resort: the press the Siri Remote would send.
        press(.select, at: item)
    }

    private func back() {
        guard let window, let item = UIFocusSystem.focusSystem(for: window)?.focusedItem else { return }
        press(.menu, at: item)
    }

    /// Sends a press to the view nearest the focused item, the way the remote's would arrive.
    private func press(_ type: UIPress.PressType, at item: UIFocusItem) {
        var env: UIFocusEnvironment? = item
        while let e = env, !(e is UIView) { env = e.parentFocusEnvironment }
        guard let view = env as? UIView else { return }
        let p = Set([LinkPress(type)])
        let event = UIPressesEvent()
        view.pressesBegan(p, with: event)
        view.pressesEnded(p, with: event)
        Self.log.notice("link nav: sent \(type.rawValue) to \(String(describing: Swift.type(of: view)), privacy: .public)")
    }
}

/// A remote button press made in code, for the views that only listen for presses.
private final class LinkPress: UIPress {
    private let kind: UIPress.PressType
    init(_ kind: UIPress.PressType) {
        self.kind = kind
        super.init()
    }
    override var type: UIPress.PressType { kind }
}
