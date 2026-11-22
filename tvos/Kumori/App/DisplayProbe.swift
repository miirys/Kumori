import Combine
import QuartzCore
import UIKit

/// Measures the rate the Apple TV is really sending to the TV, by timing the display's own
/// refreshes. `UIScreen.maximumFramesPerSecond` only says what the box allows; this says
/// what the HDMI link is running at right now (60, 50, 24 and so on), so the Debug page can
/// show whether a 120 Hz mode ever appears.
@MainActor
final class DisplayProbe: ObservableObject {
    @Published private(set) var measuredHz: Double?

    private var link: CADisplayLink?
    private var intervals: [CFTimeInterval] = []
    private var last: CFTimeInterval?

    /// Times about half a second of refreshes, then stops. Call again to refresh the value.
    func measure() {
        stop()
        intervals.removeAll()
        last = nil
        let link = CADisplayLink(target: Target(self), selector: #selector(Target.tick(_:)))
        // Ask for as fast as the display goes, so a 120 Hz mode would show as 120.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 240, preferred: 240)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if let last { intervals.append(link.timestamp - last) }
        last = link.timestamp
        guard intervals.count >= 30 else { return }
        // The median ignores the odd dropped or late frame.
        let sorted = intervals.sorted()
        let mid = sorted[sorted.count / 2]
        measuredHz = mid > 0 ? 1 / mid : nil
        stop()
    }

    /// "60 Hz", "59.94 Hz", or "Measuring…".
    var label: String {
        guard let hz = measuredHz else { return "Measuring…" }
        let whole = hz.rounded()
        return abs(hz - whole) < 0.05 ? "\(Int(whole)) Hz" : String(format: "%.2f Hz", hz)
    }

    /// The display link holds its target strongly, so it points at this instead of the probe.
    private final class Target: NSObject {
        weak var probe: DisplayProbe?
        init(_ probe: DisplayProbe) { self.probe = probe }
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { probe?.tick(link) }
        }
    }
}
