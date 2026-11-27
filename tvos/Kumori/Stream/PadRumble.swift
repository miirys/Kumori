import CoreHaptics
import Foundation
import GameController
import os

/// One controller's motors, driven by the game's rumble. A pad that reports separate handles
/// (Xbox, DualSense) gets the heavy motor on the left and the light one on the right, as a
/// console does. Others get the stronger of the two on their one actuator.
///
/// Main queue only, like Gamepads.
final class PadRumble {
    private final class Motor {
        let engine: CHHapticEngine
        let sharpness: Float
        var player: CHHapticAdvancedPatternPlayer?
        var level: Float = 0
        init(engine: CHHapticEngine, sharpness: Float) { self.engine = engine; self.sharpness = sharpness }
    }

    private let motors: [Motor]
    private var stopWork: DispatchWorkItem?
    private static let log = Logger(subsystem: "app.kumori.tv", category: "controller")

    init?(_ haptics: GCDeviceHaptics) {
        let localities = haptics.supportedLocalities
        let split = localities.contains(.leftHandle) && localities.contains(.rightHandle)
        let plan: [(GCHapticsLocality, Float)] = split ? [(.leftHandle, 0.25), (.rightHandle, 0.75)] : [(.default, 0.5)]
        var made: [Motor] = []
        for (locality, sharpness) in plan {
            guard let engine = haptics.createEngine(withLocality: locality) else { continue }
            engine.playsHapticsOnly = true
            let motor = Motor(engine: engine, sharpness: sharpness)
            // The system stops an engine when the app goes to the background or the pad
            // sleeps. Its players die with it, so the next rumble makes new ones.
            engine.stoppedHandler = { [weak motor] _ in DispatchQueue.main.async { motor?.player = nil; motor?.level = 0 } }
            engine.resetHandler = { [weak motor] in DispatchQueue.main.async { motor?.player = nil; motor?.level = 0 } }
            made.append(motor)
        }
        guard !made.isEmpty else { return nil }
        motors = made
    }

    /// Runs the motors at `low` (heavy) and `high` (light), each 0...1, for `seconds`, after
    /// which they stop unless the game sends another rumble first. Zero and zero stops them.
    func set(low: Double, high: Double, seconds: Double) {
        let levels: [Double] = motors.count >= 2 ? [low, high] : [max(low, high)]
        for (motor, level) in zip(motors, levels) { drive(motor, Float(min(max(level, 0), 1))) }
        stopWork?.cancel()
        stopWork = nil
        guard low > 0 || high > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(max(seconds, 0.01), 5), execute: work)
    }

    /// Stops the motors at once.
    func stop() {
        stopWork?.cancel()
        stopWork = nil
        for motor in motors { drive(motor, 0) }
    }

    /// Stops the motors and lets the engines go. Called when the stream ends or the pad leaves.
    func close() {
        stop()
        for motor in motors { motor.engine.stop(completionHandler: nil) }
    }

    private func drive(_ motor: Motor, _ level: Float) {
        guard level != motor.level || (level > 0 && motor.player == nil) else { return }
        motor.level = level
        if level <= 0 {
            try? motor.player?.stop(atTime: CHHapticTimeImmediate)
            motor.player = nil
            return
        }
        let intensity = CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level, relativeTime: 0)
        if let player = motor.player {
            // Already running: change its strength without a gap.
            do { try player.sendParameters([intensity], atTime: CHHapticTimeImmediate); return } catch { motor.player = nil }
        }
        do {
            try motor.engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: motor.sharpness),
            ], relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
            let player = try motor.engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.sendParameters([intensity], atTime: CHHapticTimeImmediate)
            try player.start(atTime: CHHapticTimeImmediate)
            motor.player = player
        } catch {
            motor.level = 0
            Self.log.notice("rumble failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
