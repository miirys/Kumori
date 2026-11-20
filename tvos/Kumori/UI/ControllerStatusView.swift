import GameController
import SwiftUI

/// Settings › Controllers: what tvOS has connected, whether Kumori can play with it, a live
/// test of every input, and how to pair one. Laid out like every other Settings page, and
/// reachable with the Siri Remote alone, since it matters most when no controller works.
struct ControllerStatusView: View {
    @EnvironmentObject private var center: ControllerCenter

    var body: some View {
        let summary = center.summary
        SettingsPage(symbol: Self.symbol(summary), title: summary.title, summary: summary.detail) {
            if !center.pads.isEmpty {
                Section("Connected") {
                    ForEach(center.pads) { pad in
                        // Focusable so the list can scroll to it; it does nothing when pressed.
                        Button {} label: { PadRow(pad: pad) }
                            .accessibilityIdentifier("controller-\(pad.id)")
                    }
                }
            }

            if center.pads.contains(where: { $0.profile == .extended }) {
                Section {
                    // Polled rather than hooked, so this page never takes the controller's
                    // handlers away from a stream.
                    TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                        InputReadout(report: Self.firstPad())
                    }
                } header: {
                    Text("Test")
                } footer: {
                    Text("Move the sticks and pull the triggers. Buttons also move around Settings, so they show here as you press them.")
                }
            }

            Section {
                StepRow(number: 1, text: "Put the controller in pairing mode. Xbox: hold the pair button on top. PlayStation: hold Create and PS. 8BitDo: switch to BT, turn it on, then hold Pair for 3 seconds.")
                StepRow(number: 2, text: "Open Settings › Remotes and Devices › Bluetooth on this Apple TV and choose it.")
                StepRow(number: 3, text: "Come back here. It should be listed as a full controller.")
                Button { center.search() } label: {
                    SettingsRow(title: center.searching ? "Searching…" : "Search for Controllers", icon: "magnifyingglass")
                }
                .disabled(center.searching)
                .accessibilityIdentifier("controllers-search")
            } header: {
                Text("Pair a Controller")
            } footer: {
                Text("Apple TV works with Xbox Wireless, PlayStation DualSense and DualShock 4, Nintendo Switch Pro and MFi controllers. A controller that pairs but isn't listed here, or is listed as limited, isn't one tvOS can read, and no app can change that.")
            }
        }
    }

    private static func symbol(_ s: PadSummary) -> String {
        switch s {
        case .ready: return "gamecontroller"
        case .limited: return "exclamationmark.triangle"
        case .noController: return "appletvremote.gen4"
        }
    }

    private static func firstPad() -> PadReport {
        guard let g = GCController.controllers().compactMap(\.extendedGamepad).first else { return .neutral }
        var r = Gamepads.read(g)
        // In a game Menu is a gesture. Here it is just a button.
        if g.buttonMenu.isPressed { r.buttons |= InputEncoder.start }
        return r
    }
}

/// One connected controller: what it is, what tvOS made of it, and its battery.
private struct PadRow: View {
    let pad: PadInfo

    var body: some View {
        SettingsRow(
            title: pad.name,
            icon: pad.isRemote ? "appletvremote.gen4" : "gamecontroller",
            value: pad.battery.map { "\(Int(($0 * 100).rounded()))%" },
            detail: kind
        )
    }

    private var kind: String {
        var parts: [String] = []
        switch pad.profile {
        case .extended: parts.append("Full controller")
        case .micro: parts.append(pad.isRemote ? "Remote" : "Limited: no sticks or triggers")
        case .none: parts.append("Not readable")
        }
        if pad.category != pad.name { parts.append(pad.category) }
        if pad.hasHaptics { parts.append("Rumble") }
        return parts.joined(separator: " · ")
    }
}

private struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        Button {} label: {
            HStack(alignment: .firstTextBaseline, spacing: TVTokens.group) {
                Text("\(number).").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Every input the game would see, in words and numbers. Plain rows, like the rest of
/// Settings: no chips or coloured dots.
private struct InputReadout: View {
    let report: PadReport

    private static let names: [(String, Int)] = [
        ("A", InputEncoder.a), ("B", InputEncoder.b), ("X", InputEncoder.x), ("Y", InputEncoder.y),
        ("LB", InputEncoder.leftBumper), ("RB", InputEncoder.rightBumper),
        ("L3", InputEncoder.leftStick), ("R3", InputEncoder.rightStick),
        ("Menu", InputEncoder.start), ("Options", InputEncoder.back), ("Home", InputEncoder.guide),
        ("Up", InputEncoder.up), ("Down", InputEncoder.down), ("Left", InputEncoder.left), ("Right", InputEncoder.right),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: TVTokens.medium) {
            line("Buttons", pressed)
            line("Left stick", stick(report.lx, report.ly))
            line("Right stick", stick(report.rx, report.ry))
            line("Triggers", "LT \(report.lt)   RT \(report.rt)")
        }
        .monospacedDigit()
        .padding(.vertical, TVTokens.small)
        .accessibilityElement(children: .combine)
    }

    private var pressed: String {
        let down = Self.names.filter { report.buttons & $0.1 != 0 }.map(\.0)
        return down.isEmpty ? "None" : down.joined(separator: ", ")
    }

    private func stick(_ x: Int, _ y: Int) -> String {
        String(format: "x %+.2f   y %+.2f", Double(x) / 32768, Double(y) / 32768)
    }

    private func line(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TVTokens.group) {
            Text(name).foregroundStyle(TVColor.secondary)
            Spacer(minLength: TVTokens.group)
            Text(value).foregroundStyle(TVColor.primary).lineLimit(1)
        }
    }
}
