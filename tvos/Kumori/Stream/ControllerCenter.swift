import Combine
import Foundation
import GameController

/// Which controllers tvOS has handed Kumori, for the Controllers page. It only watches: the
/// stream's `Gamepads` is the one that puts handlers on controllers.
@MainActor
final class ControllerCenter: ObservableObject {
    @Published private(set) var pads: [PadInfo] = []
    @Published private(set) var searching = false

    var summary: PadSummary { PadSummary.of(pads) }

    private var observers: [NSObjectProtocol] = []
    private var batteryTimer: Timer?
    private var searchEnds: Task<Void, Never>?

    init() {
        let center = NotificationCenter.default
        // Listen before the first look, so nothing connects in the gap.
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            })
        }
        reload()
        // Battery levels change slowly and send no notification.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        batteryTimer?.invalidate()
    }

    func reload() {
        let now = Self.current()
        if now != pads { pads = now }
    }

    /// Looks for controllers that are in pairing mode and tvOS can take directly. Most
    /// Bluetooth controllers still pair in Settings › Remotes and Devices.
    func search() {
        guard !searching else { return }
        searching = true
        GCController.startWirelessControllerDiscovery { [weak self] in
            Task { @MainActor in self?.searching = false }
        }
        searchEnds?.cancel()
        searchEnds = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            GCController.stopWirelessControllerDiscovery()
            self?.searching = false
            self?.reload()
        }
    }

    static func current() -> [PadInfo] {
        GCController.controllers().map(info).sorted { a, b in
            // Game controllers first, the remote last.
            if a.isRemote != b.isRemote { return !a.isRemote }
            return a.name < b.name
        }
    }

    static func info(_ c: GCController) -> PadInfo {
        let profile: PadProfile = c.extendedGamepad != nil ? .extended : c.microGamepad != nil ? .micro : .none
        let category = c.productCategory
        let remote = profile != .extended && category.localizedCaseInsensitiveContains("remote")
        var battery: Float?
        if let b = c.battery, b.batteryState != .unknown { battery = b.batteryLevel }
        return PadInfo(
            id: String(UInt(bitPattern: ObjectIdentifier(c).hashValue), radix: 16),
            name: Gamepads.name(c), category: category, profile: profile, isRemote: remote,
            battery: battery, hasHaptics: c.haptics != nil
        )
    }
}
