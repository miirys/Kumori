import Foundation
import GameController

/// Reads controllers and the Siri Remote and turns them into the reports the rig expects.
final class Gamepads {
    /// Called with every report while a stream is running.
    var send: ((_ slot: Int, _ connected: Int, _ buttons: Int, _ lt: Int, _ rt: Int, _ lx: Int, _ ly: Int, _ rx: Int, _ ry: Int) -> Void)?

    /// Called when the player asks for the in-stream menu: Menu held on a controller, or the
    /// Back button on the Siri Remote.
    var onMenu: (() -> Void)?

    /// While Kumori's own menu is open the game sees every controller at rest.
    var paused = false { didSet { reportAll() } }

    private var slots: [ObjectIdentifier: Int] = [:]
    private var observers: [NSObjectProtocol] = []
    private var keepAlive: Timer?
    private var menuHeld: [ObjectIdentifier: Timer] = [:]

    private static let holdSeconds = 0.6

    func start() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() },
        ]
        refresh()
        // A controller at rest reports nothing, so say it is still there now and then.
        keepAlive = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.reportAll() }
    }

    func stop() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        keepAlive?.invalidate()
        keepAlive = nil
        menuHeld.values.forEach { $0.invalidate() }
        menuHeld = [:]
        for c in GCController.controllers() {
            c.extendedGamepad?.valueChangedHandler = nil
            c.microGamepad?.valueChangedHandler = nil
        }
        slots = [:]
    }

    /// Real controllers take the player slots. The Siri Remote only plays when there is no
    /// controller, so a remote lying on the sofa can't press buttons in the game.
    private func refresh() {
        let all = GCController.controllers()
        let pads = all.filter { $0.extendedGamepad != nil }
        slots = [:]
        for (i, c) in pads.prefix(4).enumerated() {
            slots[ObjectIdentifier(c)] = i
            c.extendedGamepad?.valueChangedHandler = { [weak self, weak c] _, _ in
                if let c { self?.report(c) }
            }
            c.extendedGamepad?.buttonMenu.pressedChangedHandler = { [weak self, weak c] _, _, pressed in
                if let c { self?.menu(c, pressed) }
            }
        }
        for c in all where c.extendedGamepad == nil {
            guard let micro = c.microGamepad else { continue }
            micro.reportsAbsoluteDpadValues = false
            micro.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.onMenu?() }
            }
            if pads.isEmpty {
                slots[ObjectIdentifier(c)] = 0
                micro.valueChangedHandler = { [weak self, weak c] _, _ in
                    if let c { self?.report(c) }
                }
            } else {
                micro.valueChangedHandler = nil
            }
        }
        reportAll()
    }

    /// Menu is the game's Start button. Held a little longer, it opens Kumori's menu instead.
    private func menu(_ c: GCController, _ pressed: Bool) {
        let id = ObjectIdentifier(c)
        menuHeld[id]?.invalidate()
        menuHeld[id] = nil
        if pressed {
            menuHeld[id] = Timer.scheduledTimer(withTimeInterval: Self.holdSeconds, repeats: false) { [weak self] _ in
                self?.menuHeld[id] = nil
                self?.onMenu?()
            }
        }
    }

    private func reportAll() {
        for c in GCController.controllers() where slots[ObjectIdentifier(c)] != nil { report(c) }
    }

    private func report(_ c: GCController) {
        guard let slot = slots[ObjectIdentifier(c)], let send else { return }
        let connected = slots.values.reduce(0) { $0 | (1 << $1) }
        func axis(_ v: Float) -> Int { Int((max(-1, min(1, v)) * 32767).rounded()) }
        func trigger(_ v: Float) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        if paused {
            send(slot, connected, 0, 0, 0, 0, 0, 0, 0)
            return
        }
        var buttons = 0
        func set(_ pressed: Bool, _ bit: Int) { if pressed { buttons |= bit } }

        if let g = c.extendedGamepad {
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
            set(g.buttonMenu.isPressed, InputEncoder.start)
            set(g.buttonOptions?.isPressed ?? false, InputEncoder.back)
            set(g.buttonHome?.isPressed ?? false, InputEncoder.guide)
            send(
                slot, connected, buttons, trigger(g.leftTrigger.value), trigger(g.rightTrigger.value),
                axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value),
                axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value)
            )
        } else if let m = c.microGamepad {
            // The remote's touch surface is a d-pad, a click is A and Play/Pause is B.
            set(m.dpad.up.isPressed, InputEncoder.up)
            set(m.dpad.down.isPressed, InputEncoder.down)
            set(m.dpad.left.isPressed, InputEncoder.left)
            set(m.dpad.right.isPressed, InputEncoder.right)
            set(m.buttonA.isPressed, InputEncoder.a)
            set(m.buttonX.isPressed, InputEncoder.b)
            send(slot, connected, buttons, 0, 0, 0, 0, 0, 0)
        }
    }
}
