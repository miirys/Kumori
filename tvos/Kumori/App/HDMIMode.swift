import Foundation
import OSLog
import UIKit

/// Switches the TV to a 120 Hz HDMI mode while a 120 fps stream plays, and hands the TV's
/// own mode back afterwards.
///
/// tvOS has no public way to do this: `AVDisplayCriteria` asking for 120 Hz leaves the
/// display at 60 Hz. The fourth-generation Apple TV 4K does list 120 Hz modes below 4K
/// (2560 × 1440 and 1920 × 1080), and QuartzCore's private `CADisplay` switches to them.
/// Found by u/Lacrowx on r/appletv; the approach follows their OpenNOW port
/// (github.com/Lacrowx/OpenNOW, MIT). It only works in sideloaded builds, and every
/// private call is checked at runtime first, so a tvOS that renames them just stays at 60 Hz.
///
/// tvOS keeps a mode set this way even after the app quits or crashes, so the TV's own mode
/// is saved before switching and put back when the stream ends, when the app leaves the
/// foreground, and at the next launch if the app died while holding a mode.
@MainActor
enum HDMIMode {
    /// The TV's own mode while the display is held in a 120 Hz one.
    private static var original: NSObject?
    /// The mode set here, if any.
    private static var applied: NSObject?
    /// The stream that wants a fast mode, while one plays.
    private static var stream: (fps: Int, width: Int)?
    private static var foreground = true
    private static var started = false

    private static let savedKey = "hdmiModeToRestore"
    private static let setCurrentMode = NSSelectorFromString("setCurrentMode:")
    /// While the TV re-syncs after a switch it lists no modes for about a second.
    private static var retries = 0
    private static var retryScheduled = false

    /// Called once at launch. Puts the TV's own mode back if the last run ended holding one.
    static func start() {
        guard !started else { return }
        started = true
        if let saved = UserDefaults.standard.object(forKey: savedKey) as? NSNumber,
           let display = tvOut(), let modes = property(display, "availableModes") as? [NSObject] {
            let back = modes.first { id($0) == saved } ?? property(display, "preferredMode") as? NSObject
            if let back { apply(back) }
            log("restored the TV's mode left over from the last run")
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
        let center = NotificationCenter.default
        // Background, not inactive: a system alert over the app shouldn't switch modes twice.
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                foreground = false
                handBack()
            }
        }
        _ = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !foreground else { return }
                foreground = true
                original = nil
                applied = nil
                evaluate()
            }
        }
    }

    /// A stream started showing pictures. Returns whether the TV is now held at the
    /// stream's rate, in which case the system's own frame-rate matching should stay off.
    @discardableResult
    static func streamStarted(fps: Int, width: Int) -> Bool {
        stream = (fps, width)
        retries = 0
        log("stream started at \(fps) fps, \(width) wide; TV now \(currentLabel), fastest offered \(fastestRate.map { "\($0) Hz" } ?? "unknown")")
        evaluate()
        return applied != nil
    }

    static func streamEnded() {
        stream = nil
        handBack()
    }

    /// Whether a mode set here is in force.
    static var holding: Bool { applied != nil }

    /// The fastest rate the connected TV offers in SDR, or nil if it can't be read.
    static var fastestRate: Int? {
        guard let modes = tvOut().flatMap({ property($0, "availableModes") }) as? [NSObject] else { return nil }
        return modes.filter { range($0) == "SDR" }.map { Int(number($0, "refreshRate").rounded()) }.max()
    }

    /// The largest 120 Hz mode the TV offers, as "2560 × 1440", or nil.
    static var fastModeSize: String? {
        guard let modes = tvOut().flatMap({ property($0, "availableModes") }) as? [NSObject] else { return nil }
        let fast = modes.filter { number($0, "refreshRate") > 100 && range($0) == "SDR" }
        guard let best = fast.max(by: { number($0, "width") < number($1, "width") }) else { return nil }
        return "\(Int(number(best, "width"))) × \(Int(number(best, "height")))"
    }

    /// The mode the TV is in now, as "2560 × 1440 · 120 Hz · SDR", for the Debug page.
    static var currentLabel: String {
        guard let display = tvOut() else { return "Unavailable" }
        guard let mode = property(display, "currentMode") as? NSObject else { return "Unavailable" }
        return label(mode)
    }

    // MARK: Switching

    private static func evaluate() {
        guard foreground, let stream else { return }
        guard stream.fps > 60 else {
            log("stream is \(stream.fps) fps; leaving the TV's mode alone")
            handBack()
            return
        }
        let display = tvOut()
        let modes = display.flatMap { property($0, "availableModes") } as? [NSObject]
        guard let display, let current = property(display, "currentMode") as? NSObject, let modes, !modes.isEmpty else {
            if retries == 0 {
                log(display == nil ? "no TVOut display found (CADisplay unavailable?)" : "TVOut lists \(modes?.count ?? 0) modes; waiting for it")
            }
            if retries == 39 { log("gave up waiting for the TV's modes") }
            retryLater()
            return
        }
        let system = original ?? current
        // Already fast enough, as on a TV left in a 120 Hz mode.
        guard number(system, "refreshRate") < Double(stream.fps) - 0.5 else {
            log("TV already at \(label(system)); nothing to switch")
            return
        }
        // The widest SDR mode at the stream's rate that isn't wider than the stream: a 4K
        // stream gets 1440p, which is the largest the box offers at 120 Hz.
        let fits = modes.filter {
            abs(number($0, "refreshRate") - Double(stream.fps)) < 0.5 && range($0) == "SDR"
                && number($0, "width") <= Double(max(stream.width, 1920))
        }
        guard let widest = fits.max(by: { number($0, "width") < number($1, "width") }) else {
            log("the TV lists no \(stream.fps) Hz mode; staying at \(label(current))")
            return
        }
        original = system
        if let saved = id(system) { UserDefaults.standard.set(saved, forKey: savedKey) }
        guard !same(applied, widest) else { return }
        applied = widest
        apply(widest)
    }

    /// Puts the TV's own mode back, if one was replaced here.
    private static func handBack() {
        if let original, applied != nil { apply(original) }
        original = nil
        applied = nil
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// The TV lists no modes while it re-syncs. Ask again shortly, for up to 10 seconds.
    private static func retryLater() {
        guard !retryScheduled, retries < 40 else { return }
        retries += 1
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated {
                retryScheduled = false
                evaluate()
            }
        }
    }

    private static func apply(_ mode: NSObject) {
        guard let display = tvOut(), display.responds(to: setCurrentMode) else { return }
        log("HDMI mode -> \(label(mode))")
        _ = display.perform(setCurrentMode, with: mode)
    }

    // MARK: Private API access

    private static func tvOut() -> NSObject? {
        let displays = NSSelectorFromString("displays")
        guard let type = NSClassFromString("CADisplay") as AnyObject?, type.responds(to: displays),
              let all = type.perform(displays)?.takeUnretainedValue() as? [NSObject] else { return nil }
        return all.first { (property($0, "name") as? String) == "TVOut" }
    }

    private static func label(_ mode: NSObject) -> String {
        let w = Int(number(mode, "width")), h = Int(number(mode, "height"))
        guard w > 0, h > 0 else { return "Unavailable" }
        let hz = number(mode, "refreshRate")
        let rate = abs(hz - hz.rounded()) < 0.05 ? "\(Int(hz.rounded()))" : String(format: "%.2f", hz)
        return "\(w) × \(h), \(rate) Hz, \(range(mode) ?? "?")"
    }

    private static func same(_ a: NSObject?, _ b: NSObject?) -> Bool {
        guard let a, let b else { return false }
        if a.isEqual(b) { return true }
        guard let x = id(a) else { return false }
        return x == id(b)
    }

    private static func id(_ mode: NSObject) -> NSNumber? { property(mode, "internalRepresentation") as? NSNumber }
    private static func range(_ mode: NSObject) -> String? { property(mode, "hdrMode") as? String }
    private static func number(_ object: NSObject, _ key: String) -> Double {
        (property(object, key) as? NSNumber)?.doubleValue ?? -1
    }

    /// Reads a private property by name, or nil if this tvOS doesn't have it. Key-value access
    /// to a missing key raises an Objective-C exception that ends the app, so check first.
    nonisolated static func property(_ object: NSObject, _ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    private static let logger = Logger(subsystem: "app.kumori.tv", category: "hdmi")
    /// Public, so the line shows in the TV's syslog: "hdmi: ..."
    private static func log(_ text: String) { logger.notice("hdmi: \(text, privacy: .public)") }
}

extension ProcessInfo.ThermalState {
    /// "Normal", "Warm", "Hot" or "Critical".
    var label: String {
        switch self {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}
