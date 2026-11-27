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
    /// The mode the interface runs in when no stream holds the TV: the user's own choice of
    /// format, HDR10 or Dolby Vision included. Read at launch and on coming back to the
    /// foreground, before any stream, because by the time a stream asks for 120 Hz the system
    /// may already have taken the TV out of HDR for the picture. Handing back that moment's
    /// mode left the interface in SDR after every 120 fps stream.
    private static var home: NSObject?
    /// The stream that wants a fast mode, while one plays.
    private static var stream: (fps: Int, width: Int)?
    private static var foreground = true
    private static var started = false

    private static let savedKey = "hdmiModeToRestore"
    private static let setCurrentMode = NSSelectorFromString("setCurrentMode:")
    /// While the TV re-syncs after a switch it lists no modes for about a second.
    private static var retries = 0
    private static var retryScheduled = false
    /// Times the stream's mode was asked for again because the TV didn't take it.
    private static var checks = 0
    /// The stream ended and the TV's own mode is still to be put back.
    private static var handBackPending = false

    /// Called once at launch. Puts the TV's own mode back if the last run ended holding one.
    static func start() {
        guard !started else { return }
        started = true
        if let saved = UserDefaults.standard.object(forKey: savedKey) as? NSNumber,
           let display = tvOut(), let modes = property(display, "availableModes") as? [NSObject] {
            // Only the very mode that was saved. The display's "preferred" mode, used here
            // before when the saved one wasn't listed, can be 4K at 50 Hz, which left the
            // whole interface running at 50 frames a second.
            if let back = modes.first(where: { id($0) == saved }) {
                apply(back)
                home = interface(back)
                log("restored the TV's mode left over from the last run")
            }
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
        keepInterfaceAtSixty()
        // Read now only when nothing was just put back: the TV's current mode lags a switch.
        if home == nil { rememberHome() }
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
                rememberHome()
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
        checks = 0
        handBackPending = false
        log("stream started at \(fps) fps, \(width) wide; TV now \(currentLabel), fastest offered \(fastestRate.map { "\($0) Hz" } ?? "unknown")")
        evaluate()
        return applied != nil
    }

    /// The stream stopped. The TV's mode isn't switched back at once: a mode change while the
    /// stream screen was being taken down stalled that screen's dismissal, and the app sat on a
    /// frozen frame with nothing focused. It goes back when the screen has gone
    /// (`streamScreenClosed`), or after a few seconds if the screen stays up, as the "stream
    /// stopped" card does.
    static func streamEnded() {
        stream = nil
        guard applied != nil else { return }
        handBackPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { finishHandBack() }
        }
    }

    /// The stream screen has been dismissed.
    static func streamScreenClosed() {
        guard handBackPending else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { finishHandBack() }
        }
    }

    private static func finishHandBack() {
        guard handBackPending, stream == nil else { return }
        handBackPending = false
        handBack()
        refocus()
    }

    /// After the TV re-syncs, makes sure something on screen has focus again.
    private static func refocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                guard let root = windows.first(where: \.isKeyWindow)?.rootViewController else { return }
                let top = sequence(first: root, next: \.presentedViewController).reversed().first ?? root
                top.setNeedsFocusUpdate()
                top.updateFocusIfNeeded()
            }
        }
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

    /// The refresh rate the TV is in now, from its HDMI mode, or nil where it can't be read.
    static var currentRefresh: Double? {
        guard let display = tvOut(), let mode = property(display, "currentMode") as? NSObject else { return nil }
        let hz = number(mode, "refreshRate")
        return hz > 0 ? hz : nil
    }

    /// One HDMI mode the display chain offers, as read from the TV's EDID through the box.
    struct ModeInfo: Hashable {
        let width: Int
        let height: Int
        let hz: Double
        /// "SDR", "HDR10", "DolbyVision" and so on, as tvOS names it.
        let range: String

        var hdr: Bool { range.uppercased() != "SDR" }
        var label: String {
            let rate = abs(hz - hz.rounded()) < 0.05 ? "\(Int(hz.rounded()))" : String(format: "%.2f", hz)
            return "\(width) \u{00D7} \(height), \(rate) Hz, \(range)"
        }
    }

    /// Every mode the connected display offers, or nil where tvOS doesn't say.
    static var offeredModes: [ModeInfo]? {
        guard let modes = tvOut().flatMap({ property($0, "availableModes") }) as? [NSObject] else { return nil }
        return modes.compactMap { info($0) }
    }

    /// The mode the TV is in now.
    static var currentMode: ModeInfo? {
        guard let display = tvOut(), let mode = property(display, "currentMode") as? NSObject else { return nil }
        return info(mode)
    }

    private static func info(_ mode: NSObject) -> ModeInfo? {
        let w = Int(number(mode, "width")), h = Int(number(mode, "height")), hz = number(mode, "refreshRate")
        guard w > 0, h > 0, hz > 0 else { return nil }
        return ModeInfo(width: w, height: h, hz: hz, range: range(mode) ?? "SDR")
    }

    /// Whether a stream holds the TV in a mode right now. A test must not take it over.
    static var streaming: Bool { stream != nil }

    /// A 120 Hz test holds the TV in its mode right now.
    static var testing: Bool { stream == nil && applied != nil }

    /// Puts the TV in the widest SDR mode at `hz` for a few seconds, so Settings can see
    /// whether the chain really carries it, then puts the TV's own mode back. Calls `done`
    /// with the mode it switched to, or nil when none was offered or a stream is running.
    static func trial(hz: Int, seconds: Double, measure: @escaping @MainActor () -> Void, done: @escaping @MainActor (ModeInfo?) -> Void) {
        guard foreground, stream == nil, applied == nil, let display = tvOut(),
              let current = property(display, "currentMode") as? NSObject,
              let modes = property(display, "availableModes") as? [NSObject] else { done(nil); return }
        let fits = modes.filter { abs(number($0, "refreshRate") - Double(hz)) < 0.5 && range($0) == "SDR" }
        guard let widest = fits.max(by: { number($0, "width") < number($1, "width") }) else { done(nil); return }
        original = current
        applied = widest
        if let saved = id(current) { UserDefaults.standard.set(saved, forKey: savedKey) }
        log("test: switching to \(label(widest)) for \(Int(seconds)) s")
        apply(widest)
        // The TV takes a moment to lock onto the new mode before the refresh can be timed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { measure() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                let tried = info(widest)
                if stream == nil { handBack() }
                log("test: put the TV's mode back")
                done(tried)
            }
        }
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
        verifyLater()
    }

    /// The TV doesn't always take a mode, for one when the system is switching it at the
    /// same moment (out of HDR, say). Looks again once it has had time to re-sync, and asks
    /// again, up to three times, while the stream still wants it.
    private static func verifyLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                guard foreground, let stream, let want = applied, checks < 3 else { return }
                let now = currentRefresh ?? 0
                guard now < Double(stream.fps) - 0.5 else { return }
                checks += 1
                log("TV is at \(now) Hz after switching; asking for \(label(want)) again (\(checks) of 3)")
                apply(want)
                verifyLater()
            }
        }
    }

    /// Puts the TV's own mode back, if one was replaced here.
    private static func handBack() {
        handBackPending = false
        // Never back to something slower than 60 Hz when the TV offers the same picture at
        // 60: a TV caught at 50 Hz kept the interface at 50 frames a second.
        if let original, applied != nil { apply(listedHome() ?? sixty(like: original) ?? original) }
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

    /// The same size and range as `mode` at 60 Hz (or 59.94), when `mode` itself is slower
    /// than that and the TV offers one. Nil when `mode` is already 60 Hz or faster.
    private static func sixty(like mode: NSObject) -> NSObject? {
        guard number(mode, "refreshRate") < 59,
              let modes = tvOut().flatMap({ property($0, "availableModes") }) as? [NSObject] else { return nil }
        let w = number(mode, "width"), h = number(mode, "height"), r = range(mode)
        let same = modes.filter { number($0, "width") == w && number($0, "height") == h && range($0) == r }
        return same.filter { abs(number($0, "refreshRate") - 60) < 0.01 }.first
            ?? same.filter { abs(number($0, "refreshRate") - 59.94) < 0.05 }.first
    }

    /// Notes the interface's mode, while nothing holds the TV and it runs at about 60 Hz.
    private static func rememberHome() {
        guard stream == nil, applied == nil, let display = tvOut(),
              let current = property(display, "currentMode") as? NSObject else { return }
        guard let mode = interface(current) else { return }
        home = mode
        log("interface mode: \(label(mode))")
    }

    /// `mode` as the interface should run it: at 60 Hz where it was slower and the TV offers
    /// that. Nil for a mode faster than 60 Hz, which a stream left behind, not the user.
    private static func interface(_ mode: NSObject) -> NSObject? {
        let m = sixty(like: mode) ?? mode
        let hz = number(m, "refreshRate")
        return hz >= 59 && hz < 61 ? m : nil
    }

    /// The interface's own mode, when the TV still offers it.
    private static func listedHome() -> NSObject? {
        guard let home, let key = id(home),
              let modes = tvOut().flatMap({ property($0, "availableModes") }) as? [NSObject] else { return nil }
        return modes.first { id($0) == key }
    }

    /// At launch: a TV left below 60 Hz (by an earlier build handing it back to 4K at 50 Hz)
    /// goes to the same mode at 60 Hz, so the interface draws at 60 frames a second.
    private static func keepInterfaceAtSixty() {
        guard stream == nil, applied == nil, let display = tvOut(),
              let current = property(display, "currentMode") as? NSObject,
              let fast = sixty(like: current) else { return }
        log("TV was at \(label(current)); switching to \(label(fast)) for the interface")
        apply(fast)
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
