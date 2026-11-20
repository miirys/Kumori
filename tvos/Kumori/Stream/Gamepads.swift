import Foundation
import GameController
import os

/// Reads controllers and the Siri Remote while a stream runs and turns them into the reports
/// the rig expects. The decisions themselves (slots, the Menu gesture, held buttons) live in
/// PadLogic.swift, where they are tested without a controller.
///
/// Everything here runs on the main queue: GameController calls its handlers there, and the
/// timers are main run loop timers.
final class Gamepads {
    /// Called with every report while a stream is running.
    var send: ((_ slot: Int, _ connected: Int, _ buttons: Int, _ lt: Int, _ rt: Int, _ lx: Int, _ ly: Int, _ rx: Int, _ ry: Int) -> Void)?

    /// Called when the player asks for the in-stream menu: Menu held on a controller, or the
    /// Back button on the Siri Remote.
    var onMenu: (() -> Void)?

    /// Called with a short line when a controller comes or goes during a stream.
    var onChange: ((String) -> Void)?

    /// While Kumori's own menu is open the game sees every controller at rest. When the game
    /// gets control back, buttons still held from the menu stay hidden from it until let go.
    var paused = false {
        didSet {
            if oldValue && !paused { holdBackHeldButtons() }
            reportAll()
        }
    }

    /// Seconds on a monotonic clock. Replaced in tests.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private(set) var running = false
    private var slots = SlotTable<ObjectIdentifier>()
    private var gestures: [ObjectIdentifier: MenuGesture] = [:]
    private var filters: [ObjectIdentifier: HeldButtonFilter] = [:]
    private var holdTimers: [ObjectIdentifier: Timer] = [:]
    private var pulseTimers: [ObjectIdentifier: Timer] = [:]
    private var observers: [NSObjectProtocol] = []
    private var keepAlive: Timer?
    /// Every controller this object put a handler on, so `stop()` can take them all off, even
    /// from a controller that has since left `GCController.controllers()`.
    private let hooked = NSHashTable<GCController>.weakObjects()
    /// The Siri Remote's own setting, put back on `stop()`.
    private var absoluteBefore: [ObjectIdentifier: Bool] = [:]
    /// Bumped on every start and stop. A timer from an earlier stream sees a different number
    /// and does nothing.
    private var generation = 0

    private static let log = Logger(subsystem: "app.kumori.tv", category: "controller")

    /// True when at least one full game controller is connected.
    static var hasGameController: Bool { GCController.controllers().contains { $0.extendedGamepad != nil } }

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        let center = NotificationCenter.default
        // Listen before looking, so a controller that connects in between is not missed.
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                self?.arrived(note.object as? GCController)
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                self?.gone(note.object as? GCController)
            },
        ]
        for c in GCController.controllers() { Self.log.info("present: \(Self.describe(c), privacy: .public)") }
        refresh(announce: false)
        // A controller at rest reports nothing, so say it is still there now and then.
        keepAlive = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.reportAll() }
    }

    /// Ends the stream's hold on the controllers. The game is told every player let go, while
    /// `send` can still reach it, then every handler and timer this object set is removed.
    func stop() {
        guard running else { return }
        let mask = slots.mask
        for slot in slots.slots.values.sorted() { send?(slot, mask, 0, 0, 0, 0, 0, 0, 0) }

        running = false
        generation += 1
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        keepAlive?.invalidate()
        keepAlive = nil
        (Array(holdTimers.values) + Array(pulseTimers.values)).forEach { $0.invalidate() }
        holdTimers = [:]
        pulseTimers = [:]
        for c in hooked.allObjects { unhook(c) }
        hooked.removeAllObjects()
        absoluteBefore = [:]
        gestures = [:]
        filters = [:]
        slots.removeAll()
        paused = false
    }

    /// Sends every controller's current state now. Called when the server says hello on the
    /// input channel, so a stick already held reaches the game without waiting for it to move.
    func reportAll() {
        guard running else { return }
        for c in GCController.controllers() where slots.slot(for: ObjectIdentifier(c)) != nil { report(c) }
    }

    // MARK: Arrivals and departures

    private func arrived(_ c: GCController?) {
        if let c { Self.log.info("connected: \(Self.describe(c), privacy: .public)") }
        refresh(announce: true)
    }

    /// A controller left. The game is told its slot is at rest and empty, and the other
    /// players keep their numbers.
    private func gone(_ c: GCController?) {
        if let c {
            let id = ObjectIdentifier(c)
            Self.log.info("disconnected: \(Self.describe(c), privacy: .public)")
            forgetGesture(id)
            filters[id] = nil
            if let slot = slots.release(id) {
                send?(slot, slots.mask, 0, 0, 0, 0, 0, 0, 0)
                if c.extendedGamepad != nil { onChange?(PadNotice.disconnected(Self.name(c))) }
            }
            unhook(c)
            hooked.remove(c)
        }
        refresh(announce: false)
    }

    /// Real controllers take the player slots. The Siri Remote only plays when there is no
    /// controller, so a remote lying on the sofa can't press buttons in the game.
    private func refresh(announce: Bool) {
        let all = GCController.controllers()
        let pads = all.filter { $0.extendedGamepad != nil }
        // Keep the slot of every controller that is still here. Forget the ones that left.
        let present = Set(all.map { ObjectIdentifier($0) })
        for (id, _) in slots.slots where !present.contains(id) {
            forgetGesture(id)
            filters[id] = nil
            if let slot = slots.release(id) { send?(slot, slots.mask, 0, 0, 0, 0, 0, 0, 0) }
        }
        if !pads.isEmpty {
            // A controller arrived: the remote hands over its slot.
            for c in all where c.extendedGamepad == nil {
                if let slot = slots.release(ObjectIdentifier(c)) { send?(slot, slots.mask, 0, 0, 0, 0, 0, 0, 0) }
            }
        }
        for c in pads {
            let id = ObjectIdentifier(c)
            let isNew = slots.slot(for: id) == nil
            guard let slot = slots.assign(id) else {
                Self.log.notice("no free slot for \(Self.describe(c), privacy: .public)")
                continue
            }
            if isNew {
                Self.log.info("slot \(slot): \(Self.describe(c), privacy: .public)")
                if announce { onChange?(PadNotice.connected(Self.name(c), slot: slot)) }
            }
            hooked.add(c)
            c.extendedGamepad?.valueChangedHandler = { [weak self, weak c] _, _ in
                if let c { self?.report(c) }
            }
            c.extendedGamepad?.buttonMenu.pressedChangedHandler = { [weak self, weak c] _, _, pressed in
                if let c { self?.menu(c, pressed) }
            }
        }
        for c in all where c.extendedGamepad == nil {
            guard let micro = c.microGamepad else { continue }
            let id = ObjectIdentifier(c)
            hooked.add(c)
            if absoluteBefore[id] == nil { absoluteBefore[id] = micro.reportsAbsoluteDpadValues }
            // Absolute values say where on the clickpad the thumb is, which is what tells a
            // click on the ring's edge (a direction) from a click in the middle (A).
            micro.reportsAbsoluteDpadValues = true
            micro.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.onMenu?() }
            }
            if pads.isEmpty {
                slots.assign(id)
                micro.valueChangedHandler = { [weak self, weak c] _, _ in
                    if let c { self?.report(c) }
                }
            } else {
                micro.valueChangedHandler = nil
            }
        }
        reportAll()
    }

    private func unhook(_ c: GCController) {
        if let g = c.extendedGamepad {
            g.valueChangedHandler = nil
            g.buttonMenu.pressedChangedHandler = nil
        }
        if let m = c.microGamepad {
            m.valueChangedHandler = nil
            m.buttonMenu.pressedChangedHandler = nil
            if let before = absoluteBefore[ObjectIdentifier(c)] { m.reportsAbsoluteDpadValues = before }
        }
    }

    // MARK: Menu

    /// Menu is the game's Start button, but only as a short tap. Held a little longer, it
    /// opens Kumori's menu instead and the game never sees it.
    private func menu(_ c: GCController, _ pressed: Bool) {
        guard running else { return }
        let id = ObjectIdentifier(c)
        var g = gestures[id] ?? MenuGesture()
        holdTimers.removeValue(forKey: id)?.invalidate()
        let gen = generation
        if pressed {
            g.press(at: clock())
            holdTimers[id] = Timer.scheduledTimer(withTimeInterval: MenuGesture.hold, repeats: false) { [weak self] _ in
                guard let self, self.generation == gen, var g = self.gestures[id] else { return }
                self.holdTimers[id] = nil
                let outcome = g.tick(at: self.clock())
                self.gestures[id] = g
                if outcome == .openMenu { self.onMenu?() }
            }
            gestures[id] = g
            return
        }
        let outcome = g.release(at: clock(), paused: paused)
        gestures[id] = g
        switch outcome {
        case .nothing: break
        case .openMenu: onMenu?()
        case .tapStart:
            report(c)
            pulseTimers.removeValue(forKey: id)?.invalidate()
            pulseTimers[id] = Timer.scheduledTimer(withTimeInterval: MenuGesture.startPulse, repeats: false) { [weak self, weak c] _ in
                guard let self, self.generation == gen else { return }
                self.pulseTimers[id] = nil
                self.gestures[id]?.endStart()
                if let c { self.report(c) }
            }
        }
    }

    private func forgetGesture(_ id: ObjectIdentifier) {
        holdTimers.removeValue(forKey: id)?.invalidate()
        pulseTimers.removeValue(forKey: id)?.invalidate()
        gestures[id] = nil
    }

    private func holdBackHeldButtons() {
        for c in GCController.controllers() {
            let id = ObjectIdentifier(c)
            guard slots.slot(for: id) != nil, let r = Self.read(c) else { continue }
            var f = filters[id] ?? HeldButtonFilter()
            f.resume(holding: r.buttons)
            filters[id] = f
        }
    }

    // MARK: Reports

    private func report(_ c: GCController) {
        let id = ObjectIdentifier(c)
        guard running, let slot = slots.slot(for: id), let send else { return }
        let connected = slots.mask
        if paused {
            send(slot, connected, 0, 0, 0, 0, 0, 0, 0)
            return
        }
        guard var r = Self.read(c, startDown: gestures[id]?.startDown ?? false) else { return }
        var f = filters[id] ?? HeldButtonFilter()
        r.buttons = f.apply(r.buttons)
        filters[id] = f
        send(slot, connected, r.buttons, r.lt, r.rt, r.lx, r.ly, r.rx, r.ry)
    }

    /// A controller's state as the rig wants it. Menu itself is never a button here: its tap
    /// arrives as `startDown`.
    static func read(_ c: GCController, startDown: Bool = false) -> PadReport? {
        if let g = c.extendedGamepad { return read(g, startDown: startDown) }
        if let m = c.microGamepad { return read(m) }
        return nil
    }

    static func read(_ g: GCExtendedGamepad, startDown: Bool = false) -> PadReport {
        var buttons = 0
        func set(_ pressed: Bool, _ bit: Int) { if pressed { buttons |= bit } }
        set(g.dpad.up.isPressed, InputEncoder.up)
        set(g.dpad.down.isPressed, InputEncoder.down)
        set(g.dpad.left.isPressed, InputEncoder.left)
        set(g.dpad.right.isPressed, InputEncoder.right)
        set(g.buttonA.isPressed, InputEncoder.a)
        set(g.buttonB.isPressed, InputEncoder.b)
        set(g.buttonX.isPressed, InputEncoder.x)
        set(g.buttonY.isPressed, InputEncoder.y)
        set(g.leftShoulder.isPressed, InputEncoder.leftBumper)
        set(g.rightShoulder.isPressed, InputEncoder.rightBumper)
        set(g.leftThumbstickButton?.isPressed ?? false, InputEncoder.leftStick)
        set(g.rightThumbstickButton?.isPressed ?? false, InputEncoder.rightStick)
        set(startDown, InputEncoder.start)
        set(g.buttonOptions?.isPressed ?? false, InputEncoder.back)
        set(g.buttonHome?.isPressed ?? false, InputEncoder.guide)
        return PadReport(
            buttons: buttons,
            lt: PadQuantize.trigger(g.leftTrigger.value), rt: PadQuantize.trigger(g.rightTrigger.value),
            lx: PadQuantize.axis(g.leftThumbstick.xAxis.value), ly: PadQuantize.axis(g.leftThumbstick.yAxis.value),
            rx: PadQuantize.axis(g.rightThumbstick.xAxis.value), ry: PadQuantize.axis(g.rightThumbstick.yAxis.value)
        )
    }

    /// The Siri Remote. A click near the edge of the clickpad is a direction, a click in the
    /// middle is A, and Play/Pause is B. A thumb only resting on the surface presses nothing.
    static func read(_ m: GCMicroGamepad) -> PadReport {
        var buttons = 0
        func set(_ pressed: Bool, _ bit: Int) { if pressed { buttons |= bit } }
        let x = m.dpad.xAxis.value
        let y = m.dpad.yAxis.value
        let clicked = m.buttonA.isPressed
        let edge = max(abs(x), abs(y)) > 0.5
        if clicked && edge {
            if abs(x) > abs(y) {
                set(x < 0, InputEncoder.left)
                set(x > 0, InputEncoder.right)
            } else {
                set(y > 0, InputEncoder.up)
                set(y < 0, InputEncoder.down)
            }
        }
        set(clicked && !edge, InputEncoder.a)
        set(m.buttonX.isPressed, InputEncoder.b)
        return PadReport(buttons: buttons)
    }

    // MARK: Names

    static func name(_ c: GCController) -> String {
        if let v = c.vendorName, !v.isEmpty { return v }
        return c.productCategory
    }

    /// For the log: what the controller says it is and which profiles tvOS gave it. Nothing
    /// that identifies the person.
    static func describe(_ c: GCController) -> String {
        let profile = c.extendedGamepad != nil ? "extended" : c.microGamepad != nil ? "micro" : "none"
        return "\(name(c)) [\(c.productCategory)] profile=\(profile) haptics=\(c.haptics != nil)"
    }
}
