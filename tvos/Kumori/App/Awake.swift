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
        // A stream's audio sets the session up its own way and deactivates it at the end,
        // which stops this engine. Playing a node on a stopped engine raises an exception
        // that ends the app, so start it again first.
        if !engine.isRunning {
            guard (try? engine.start()) != nil else { return }
        }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
    }

    private func prepare() {
        guard !ready else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        // Deeper and warmer than before: lower fundamentals, a rounder decay, and a soft onset.
        // The old 2.9k/1.7k tones read as bright and plasticky; these sit about an octave down.
        tick = Self.sound(format, seconds: 0.020, pitch: 1_050, level: 0.085, decay: 300)
        click = Self.sound(format, seconds: 0.055, pitch: 540, level: 0.20, decay: 115)
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
            // A gentler onset softens the attack transient that made the old tone sound bright.
            let attack = min(1, t / 0.0020)
            let envelope = attack * exp(-t * decay)
            // Fundamental with a sub-octave for body and only a little second harmonic for
            // definition — the warmth comes from the sub-octave, not a bright inharmonic partial.
            let tone = sin(2 * .pi * pitch * t)
                + 0.42 * sin(2 * .pi * pitch * 0.5 * t)
                + 0.12 * sin(2 * .pi * pitch * 2 * t)
            out[i] = Float(tone * envelope) * level
        }
        return b
    }
}
