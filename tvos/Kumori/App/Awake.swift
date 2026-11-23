import AVFoundation
import UIKit

/// Keeps the screen saver away while someone is using Kumori.
///
/// tvOS restarts its screen-saver countdown for the Siri Remote and for controllers it knows,
/// but not for a controller relayed by Kumori Link, so browsing with one let the screen saver
/// start mid-use. Each Link input holds the screen awake for a short while; after that the
/// system's own countdown starts over, the same as after a remote press.
@MainActor
final class Awake {
    static let shared = Awake()

    private var streaming = false
    private var lastPoke: Date?
    private var release: Timer?
    /// How long one input keeps the screen awake before the system's countdown takes over.
    private static let hold: TimeInterval = 30

    /// Someone used a relayed controller.
    func poke() {
        lastPoke = Date()
        apply()
        guard release == nil else { return }
        release = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
    }

    /// A stream keeps the screen awake from start to end.
    func stream(_ on: Bool) {
        streaming = on
        apply()
    }

    private func apply() {
        let recent = lastPoke.map { Date().timeIntervalSince($0) < Self.hold } ?? false
        if !recent {
            release?.invalidate()
            release = nil
        }
        let want = streaming || recent
        if UIApplication.shared.isIdleTimerDisabled != want { UIApplication.shared.isIdleTimerDisabled = want }
    }
}

/// The short tick the Siri Remote makes as focus moves and the click when something is chosen,
/// for moves and selections made with a Kumori Link controller, which tvOS doesn't sound.
@MainActor
final class FocusClick {
    static let shared = FocusClick()

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var tick: AVAudioPCMBuffer?
    private var click: AVAudioPCMBuffer?
    private var ready = false
    private var lastMove = Date.distantPast

    func move() {
        // Held directions step quickly; one tick per step, but never a buzz.
        let now = Date()
        guard now.timeIntervalSince(lastMove) > 0.06 else { return }
        lastMove = now
        play(tick)
    }

    func select() { play(click) }

    private func play(_ buffer: AVAudioPCMBuffer?) {
        prepare()
        guard ready, let buffer else { return }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
    }

    private func prepare() {
        guard !ready else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        tick = Self.sound(format, seconds: 0.012, pitch: 2_900, level: 0.10, decay: 420)
        click = Self.sound(format, seconds: 0.03, pitch: 1_700, level: 0.22, decay: 170)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            ready = true
        } catch {
            ready = false
        }
    }

    /// A short decaying tone with a soft attack, like a remote's click.
    private static func sound(_ format: AVAudioFormat, seconds: Double, pitch: Double, level: Float, decay: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let out = b.floatChannelData?[0] else { return nil }
        b.frameLength = frames
        let rate = format.sampleRate
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let attack = min(1, t / 0.0008)
            let envelope = attack * exp(-t * decay)
            let tone = sin(2 * .pi * pitch * t) + 0.35 * sin(2 * .pi * pitch * 2.02 * t)
            out[i] = Float(tone * envelope) * level
        }
        return b
    }
}
