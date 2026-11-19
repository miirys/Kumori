import GameController
import SwiftUI

/// The Controllers page: what tvOS has connected, whether Kumori can play with it, a live
/// readout to check every button, and how to pair one. Reachable with the Siri Remote alone,
/// so it helps most when no controller works.
struct ControllerStatusView: View {
    @EnvironmentObject private var center: ControllerCenter

    var body: some View {
        summaryCard.reveal(0)

        if !center.pads.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Connected").padding(.leading, 30)
                VStack(spacing: 0) {
                    ForEach(Array(center.pads.enumerated()), id: \.element.id) { i, pad in
                        if i > 0 { Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 96) }
                        PadRow(pad: pad)
                    }
                }
                .padding(.vertical, 8)
                .glassCard(34)
            }
            .reveal(1)
        }

        if center.pads.contains(where: { $0.profile == .extended }) {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Try it").padding(.leading, 30)
                // Polled rather than hooked, so this page never fights the stream for the
                // controller's handlers.
                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                    InputReadout(report: Self.firstPad())
                }
                .padding(30)
                .glassCard(34)
                Text("Sticks and triggers light up here. Buttons also move around Settings, so use the sticks if a button press takes you away.")
                    .font(.kumori(21)).foregroundStyle(Palette.tertiary).padding(.horizontal, 30)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .reveal(2)
        }

        pairing.reveal(3)
    }

    private static func firstPad() -> PadReport {
        guard let g = GCController.controllers().compactMap(\.extendedGamepad).first else { return .neutral }
        var r = Gamepads.read(g)
        // Menu is a gesture in a game. Here it is just a button.
        if g.buttonMenu.isPressed { r.buttons |= InputEncoder.start }
        return r
    }

    private var summaryCard: some View {
        let s = center.summary
        let icon: String
        let tint: Color
        switch s {
        case .ready: icon = "gamecontroller.fill"; tint = Palette.pink
        case .limited: icon = "exclamationmark.triangle.fill"; tint = Palette.pink
        case .noController: icon = "appletvremote.gen4.fill"; tint = Palette.blush
        }
        return HStack(alignment: .top, spacing: 28) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 96, height: 96)
                .background(Circle().fill(Palette.glass))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 10) {
                Text(s.title).font(.kumori(38, .bold)).foregroundStyle(Palette.blush)
                Text(s.detail).font(.kumori(24)).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(30)
        .glassCard(38)
        .animation(Motion.snappy, value: s)
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Pair a controller").padding(.leading, 30)
            VStack(alignment: .leading, spacing: 18) {
                step(1, "Put the controller in Bluetooth pairing mode. Xbox: hold the pair button on top. PlayStation: hold Create and PS. 8BitDo: switch to BT, turn it on, then hold Pair for 3 seconds.")
                step(2, "On the Apple TV, open Settings › Remotes and Devices › Bluetooth and pick it from the list.")
                step(3, "Come back here. It should show as a full controller.")
                Button {
                    center.search()
                } label: {
                    Text(center.searching ? "Searching…" : "Search from here")
                }
                .buttonStyle(PillButtonStyle(icon: center.searching ? "dot.radiowaves.left.and.right" : "magnifyingglass"))
                .disabled(center.searching)
                .padding(.top, 6)
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(34)
            Text("Apple TV works with Xbox Wireless, PlayStation DualSense and DualShock 4, Nintendo Switch Pro and MFi controllers. A controller that pairs but shows here as limited, or not at all, isn't one tvOS can read, and no app can change that.")
                .font(.kumori(21)).foregroundStyle(Palette.tertiary).padding(.horizontal, 30)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text("\(n)").font(.kumori(24, .bold)).foregroundStyle(Palette.night)
                .frame(width: 40, height: 40).background(Circle().fill(Palette.pink))
            Text(text).font(.kumori(24)).foregroundStyle(Palette.blush)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PadRow: View {
    let pad: PadInfo

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: pad.isRemote ? "appletvremote.gen4.fill" : "gamecontroller.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(pad.profile == .extended ? Palette.pink : Palette.secondary)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(pad.name).font(.kumori(28, .semibold)).foregroundStyle(Palette.blush).lineLimit(1)
                Text(kind).font(.kumori(21)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            Spacer()
            if let b = pad.battery { Battery(level: b) }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
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

private struct Battery: View {
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24))
            Text("\(Int((level * 100).rounded()))%").font(.kumori(21, .medium)).monospacedDigit()
        }
        .foregroundStyle(level < 0.2 ? Palette.pink : Palette.secondary)
    }

    private var symbol: String {
        switch level {
        case ..<0.15: return "battery.0percent"
        case ..<0.4: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Every input the game would see, lit when pressed.
private struct InputReadout: View {
    let report: PadReport

    private static let buttons: [(String, Int)] = [
        ("A", InputEncoder.a), ("B", InputEncoder.b), ("X", InputEncoder.x), ("Y", InputEncoder.y),
        ("LB", InputEncoder.leftBumper), ("RB", InputEncoder.rightBumper),
        ("L3", InputEncoder.leftStick), ("R3", InputEncoder.rightStick),
        ("☰", InputEncoder.start), ("⧉", InputEncoder.back), ("Home", InputEncoder.guide),
        ("↑", InputEncoder.up), ("↓", InputEncoder.down), ("←", InputEncoder.left), ("→", InputEncoder.right),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 40) {
            Stick(label: "Left", x: report.lx, y: report.ly)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 18) {
                    TriggerBar(label: "LT", value: report.lt)
                    TriggerBar(label: "RT", value: report.rt)
                }
                FlowChips(items: Self.buttons.map { ($0.0, report.buttons & $0.1 != 0) })
            }
            Stick(label: "Right", x: report.rx, y: report.ry)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Stick: View {
    let label: String
    let x: Int
    let y: Int

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Palette.glass)
                Circle().stroke(Palette.hairline, lineWidth: 2)
                Circle().fill(moved ? Palette.pink : Palette.blush.opacity(0.5))
                    .frame(width: 26, height: 26)
                    .offset(x: CGFloat(x) / 32768 * 47, y: -CGFloat(y) / 32768 * 47)
            }
            .frame(width: 120, height: 120)
            Text(label).font(.kumori(20)).foregroundStyle(Palette.tertiary)
        }
    }

    private var moved: Bool { abs(x) > 4000 || abs(y) > 4000 }
}

private struct TriggerBar: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.kumori(20, .semibold)).foregroundStyle(Palette.secondary).frame(width: 40, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.glass)
                Capsule().fill(Palette.pink).frame(width: 180 * CGFloat(value) / 255)
            }
            .frame(width: 180, height: 14)
            Text("\(value)").font(.system(size: 20, weight: .medium, design: .monospaced)).foregroundStyle(Palette.tertiary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private struct FlowChips: View {
    let items: [(String, Bool)]

    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 8).map { Array(items[$0..<min($0 + 8, items.count)]) }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 10) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        let (name, on) = rows[r][i]
                        Text(name)
                            .font(.kumori(20, .bold))
                            .foregroundStyle(on ? Palette.night : Palette.secondary)
                            .frame(minWidth: 44).padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Capsule().fill(on ? Palette.pink : Palette.glass))
                    }
                }
            }
        }
    }
}
