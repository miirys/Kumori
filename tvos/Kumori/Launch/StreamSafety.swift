import Foundation

// The judgements behind the stats warning, the idle timer and the time left, kept apart
// from the UI so they can be tested without a stream. Foundation only.

/// Why a stream is below what it was set up for. Each case points at a different place to
/// fix it, so the overlay says which.
public enum BelowTargetReason: String, Codable, Equatable {
    /// The TV's refresh rate is lower than the stream's frame rate (a 50 Hz mode, say).
    case display
    /// Frames arrive from the rig slower than asked: the network or the rig.
    case arriving
    /// Frames arrive in time, but this Apple TV doesn't get them all onto the screen.
    case dropping
}

/// Watches the frame rate on screen against the stream's target, and only calls it low once
/// it has stayed low for a few seconds, so a single hitch doesn't light the warning.
public struct FrameHealth: Equatable {
    /// How long a shortfall has to last before it counts.
    public static let hold: Double = 5
    /// Below this share of the expected rate counts as low. 60 fps target, 54 or less.
    public static let share: Double = 0.9

    public private(set) var lowSince: Double?
    public private(set) var reason: BelowTargetReason?

    public init() {}

    /// The rate a stream at `target` fps can show on a display refreshing at `refresh` Hz.
    public static func expected(target: Int, refresh: Double?) -> Double {
        guard let refresh, refresh > 1 else { return Double(target) }
        return min(Double(target), refresh)
    }

    /// Feeds one measurement. `now` is seconds on any steady clock. Returns the reason the
    /// stream is low, or nil while it is fine (or hasn't been low for long enough yet).
    @discardableResult
    public mutating func update(now: Double, target: Int, shown: Double?, decoded: Double?, refresh: Double?) -> BelowTargetReason? {
        guard target > 0 else { reset(); return nil }
        let cause = Self.cause(target: target, shown: shown, decoded: decoded, refresh: refresh)
        guard let cause else { reset(); return nil }
        if lowSince == nil { lowSince = now }
        guard now - (lowSince ?? now) >= Self.hold else { return nil }
        reason = cause
        return cause
    }

    public mutating func reset() {
        lowSince = nil
        reason = nil
    }

    /// What is wrong right now, ignoring how long it has lasted.
    public static func cause(target: Int, shown: Double?, decoded: Double?, refresh: Double?) -> BelowTargetReason? {
        // A display below 60 Hz (or below a slower stream's own rate) caps what can be seen,
        // whatever arrives. A 120 fps stream on a 60 Hz TV is a choice, not a fault: it cuts
        // a little lag, so that alone isn't called low.
        if let refresh, refresh > 1, refresh < Double(min(target, 60)) - 1.5 { return .display }
        let want = expected(target: target, refresh: refresh) * share
        guard let rate = shown ?? decoded, rate < want else { return nil }
        if let decoded, decoded < Double(target) * share { return .arriving }
        return shown == nil ? .arriving : .dropping
    }

    /// One sentence for the overlay, with the numbers in it.
    public static func words(_ reason: BelowTargetReason, target: Int, shown: Double?, decoded: Double?, refresh: Double?) -> String {
        switch reason {
        case .display:
            let hz = refresh.map { Self.hz($0) } ?? "a lower rate"
            return "The TV is running at \(hz), so it can't show \(target) fps."
        case .arriving:
            let got = decoded.map { String(format: "%.0f", $0) } ?? "fewer"
            return "Frames arrive at \(got) fps. The connection or the rig is behind."
        case .dropping:
            return "Frames arrive in time, but some don't make it to the screen."
        }
    }

    /// "50 Hz", "59.94 Hz".
    public static func hz(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.05 ? "\(Int(v.rounded())) Hz" : String(format: "%.2f Hz", v)
    }
}

/// The idle timer: how long since anyone touched a controller, and when that ends the session.
public struct IdleClock: Equatable {
    /// The choices offered in Settings, in minutes. 0 is off.
    public static let choices = [0, 15, 30, 60]
    public static let standard = 30
    /// The warning comes up this long before the end.
    public static let warning: Double = 120

    public let limit: Double
    public private(set) var lastInput: Double

    /// `minutes` 0 turns it off.
    public init(minutes: Int, now: Double) {
        limit = Double(max(0, minutes)) * 60
        lastInput = now
    }

    public var on: Bool { limit > 0 }

    public mutating func touched(at now: Double) { lastInput = max(lastInput, now) }

    /// Seconds until the session is ended, never below zero. Nil when the timer is off.
    public func left(at now: Double) -> Double? {
        guard on else { return nil }
        return max(0, limit - (now - lastInput))
    }

    public func warning(at now: Double) -> Bool {
        guard let left = left(at: now) else { return false }
        return left <= Self.warning && left > 0
    }

    public func expired(at now: Double) -> Bool { left(at: now) == 0 }

    /// "Off", "15 minutes", "1 hour".
    public static func label(_ minutes: Int) -> String {
        switch minutes {
        case ...0: return "Off"
        case 60: return "1 hour"
        default: return "\(minutes) minutes"
        }
    }
}

/// The membership's play time left, counted down while a stream plays. NVIDIA reports it
/// when asked; between asks, time spent streaming is taken off.
public struct TimeLeft: Equatable {
    public let seconds: Double
    public let unlimited: Bool

    /// `reported` is what NVIDIA said, `at` when. `liveSince` is when the current stream's
    /// picture came up, if one is playing: only time after both counts against it.
    public static func estimate(reportedHours: Double?, unlimited: Bool, at reportedAt: Date?, liveSince: Date?, now: Date) -> TimeLeft? {
        if unlimited { return TimeLeft(seconds: .infinity, unlimited: true) }
        guard let hours = reportedHours else { return nil }
        var used = 0.0
        if let live = liveSince {
            let from = max(live, reportedAt ?? live)
            used = max(0, now.timeIntervalSince(from))
        }
        return TimeLeft(seconds: max(0, hours * 3600 - used), unlimited: false)
    }

    /// "12 h 40 min", "35 min", "Unlimited".
    public var label: String {
        if unlimited { return "Unlimited" }
        let m = Int(seconds / 60)
        return m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }
}

/// Running totals over one stream, for the past streams list.
public struct StreamTally: Equatable {
    public private(set) var samples = 0
    public private(set) var fpsSum = 0.0
    public private(set) var fpsMin: Double?
    public private(set) var rttSum = 0.0
    public private(set) var rttCount = 0
    public private(set) var mbpsSum = 0.0
    public private(set) var mbpsCount = 0
    public private(set) var lowSeconds = 0.0

    public init() {}

    /// One stats sample. `interval` is the seconds since the last one.
    public mutating func add(fps: Double?, rtt: Double?, mbps: Double?, low: Bool, interval: Double) {
        if let fps {
            samples += 1
            fpsSum += fps
            fpsMin = min(fpsMin ?? fps, fps)
        }
        if let rtt { rttSum += rtt; rttCount += 1 }
        if let mbps { mbpsSum += mbps; mbpsCount += 1 }
        if low { lowSeconds += max(0, min(interval, 5)) }
    }

    public var averageFps: Double? { samples > 0 ? fpsSum / Double(samples) : nil }
    public var averageRtt: Double? { rttCount > 0 ? rttSum / Double(rttCount) : nil }
    public var averageMbps: Double? { mbpsCount > 0 ? mbpsSum / Double(mbpsCount) : nil }
}
