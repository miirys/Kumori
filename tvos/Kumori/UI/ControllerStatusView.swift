import GameController
import SwiftUI

/// Settings › Controllers: what's connected, a live picture of every input, and how to pair
/// one. Labels and values only, like every other Settings page, and reachable with the Siri
/// Remote alone, since it matters most when no controller works.
struct ControllerStatusView: View {
    @EnvironmentObject private var center: ControllerCenter
    @ObservedObject private var link = KumoriLink.shared

    /// Controllers relayed by a connected Kumori Link box, one row each.
    private var linkPads: Int { link.status == .connected ? link.controllers : 0 }

    var body: some View {
        SettingsPage(symbol: "gamecontroller", title: "Controllers") {
            Section("Connected") {
                ForEach(0..<linkPads, id: \.self) { i in
                    Button {} label: {
                        SettingsRow(title: linkPads == 1 ? "Kumori Link" : "Kumori Link \(i + 1)",
                                    icon: "gamecontroller", value: "Connected",
                                    detail: link.box?.name)
                    }
                    .accessibilityIdentifier("controller-link-\(i)")
                }
                if center.pads.isEmpty && linkPads == 0 {
                    Button {} label: { SettingsRow(title: "None connected") }
                } else {
                    ForEach(center.pads) { pad in
                        // Focusable so the list can scroll to it; it does nothing when pressed.
                        Button {} label: { PadRow(pad: pad) }
                            .accessibilityIdentifier("controller-\(pad.id)")
                    }
                }
            }

            if linkPads > 0 || center.pads.contains(where: { $0.profile == .extended }) {
                Section("Input Test") {
                    // Polled rather than hooked, so this page never takes the controller's
                    // handlers away from a stream.
                    TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                        InputPicture(report: Self.firstPad())
                    }
                }
            }

            KumoriLinkSection()

            Section("In a Game") {
                PairRow(brand: "Kumori Menu", how: "Hold Menu")
                PairRow(brand: "Mouse", how: "Click both sticks")
            }

            Section("Pair") {
                PairRow(brand: "Xbox", how: "Hold the pair button")
                PairRow(brand: "PlayStation", how: "Hold Create and PS")
                Button { center.search() } label: {
                    SettingsRow(title: center.searching ? "Searching\u{2026}" : "Search for Controllers", icon: "magnifyingglass")
                }
                .disabled(center.searching)
                .accessibilityIdentifier("controllers-search")
            }
        }
    }

    private static func firstPad() -> PadReport {
        if KumoriLink.shared.status == .connected,
           let r = KumoriLink.shared.reports.sorted(by: { $0.key < $1.key }).first?.value { return r }
        guard let g = GCController.controllers().compactMap(\.extendedGamepad).first else { return .neutral }
        var r = Gamepads.read(g)
        // In a game Menu is a gesture. Here it is just a button.
        if g.buttonMenu.isPressed { r.buttons |= InputEncoder.start }
        return r
    }
}

/// One connected controller: its name, what tvOS made of it, and its battery.
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
        case .micro: parts.append(pad.isRemote ? "Remote" : "Limited")
        case .none: parts.append("Not readable")
        }
        if pad.hasHaptics { parts.append("Rumble") }
        return parts.joined(separator: ", ")
    }
}

/// A label and what to do. Plain text, not a button: there is nothing to press.
private struct PairRow: View {
    let brand: String
    let how: String

    var body: some View {
        HStack(spacing: 24) {
            Text(brand).font(TVType.body).foregroundStyle(TVColor.primary)
            Spacer(minLength: 24)
            Text(how).font(TVType.body).foregroundStyle(TVColor.secondary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Every input the game would see, drawn: both sticks, both triggers, and each button lit
/// while it's held. White on the glass, nothing coloured.
private struct InputPicture: View {
    let report: PadReport
    @Environment(\.tvReduceMotion) private var reduced

    private static let names: [(String, Int)] = [
        ("A", InputEncoder.a), ("B", InputEncoder.b), ("X", InputEncoder.x), ("Y", InputEncoder.y),
        ("LB", InputEncoder.leftBumper), ("RB", InputEncoder.rightBumper),
        ("\u{2191}", InputEncoder.up), ("\u{2193}", InputEncoder.down),
        ("\u{2190}", InputEncoder.left), ("\u{2192}", InputEncoder.right),
        ("Menu", InputEncoder.start), ("Options", InputEncoder.back), ("Home", InputEncoder.guide),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 36) {
            HStack(alignment: .center, spacing: 56) {
                Stick(label: "L", x: report.lx, y: report.ly, clicked: held(InputEncoder.leftStick))
                Stick(label: "R", x: report.rx, y: report.ry, clicked: held(InputEncoder.rightStick))
                VStack(alignment: .leading, spacing: 22) {
                    Trigger(label: "LT", value: report.lt)
                    Trigger(label: "RT", value: report.rt)
                }
                .frame(maxWidth: 420)
            }
            HStack(spacing: 28) {
                ForEach(Self.names, id: \.0) { item in
                    Text(item.0)
                        .font(TVType.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(held(item.1) ? 1 : 0.24))
                        .scaleEffect(held(item.1) && !reduced ? 1.12 : 1)
                        .animation(reduced ? nil : .spring(duration: 0.18, bounce: 0.2), value: held(item.1))
                }
            }
        }
        .padding(SettingsMetrics.platterOutset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Color.white.opacity(0.05)))
        .padding(.horizontal, -SettingsMetrics.platterOutset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input test")
        .accessibilityValue(pressed)
    }

    private func held(_ bit: Int) -> Bool { report.buttons & bit != 0 }

    private var pressed: String {
        let down = Self.names.filter { held($0.1) }.map(\.0)
        return down.isEmpty ? "Nothing pressed" : down.joined(separator: ", ")
    }
}

/// A stick: a disc with a dot where the stick is. The dot swells while the stick is clicked.
private struct Stick: View {
    let label: String
    let x: Int
    let y: Int
    let clicked: Bool
    @Environment(\.tvReduceMotion) private var reduced

    private let size: CGFloat = 150
    private let dot: CGFloat = 36

    var body: some View {
        let reach = (size - dot) / 2
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.white.opacity(0.07))
                Circle()
                    .fill(Color.white)
                    .frame(width: dot, height: dot)
                    .scaleEffect(clicked ? 1.3 : 1)
                    .shadow(color: .white.opacity(clicked ? 0.5 : 0.18), radius: clicked ? 16 : 8)
                    // Up on the stick is up on screen.
                    .offset(x: CGFloat(x) / 32768 * reach, y: -CGFloat(y) / 32768 * reach)
            }
            .frame(width: size, height: size)
            .animation(reduced ? nil : .interactiveSpring(response: 0.12, dampingFraction: 0.86), value: x)
            .animation(reduced ? nil : .interactiveSpring(response: 0.12, dampingFraction: 0.86), value: y)
            .animation(reduced ? nil : .spring(duration: 0.18, bounce: 0.2), value: clicked)
            Text(label)
                .font(TVType.caption.weight(.semibold))
                .foregroundStyle(TVColor.tertiary)
        }
    }
}

/// A trigger: how far it's pulled, as a bar that fills from the left.
private struct Trigger: View {
    let label: String
    let value: Int
    @Environment(\.tvReduceMotion) private var reduced

    var body: some View {
        HStack(spacing: 20) {
            Text(label)
                .font(TVType.caption.weight(.semibold))
                .foregroundStyle(TVColor.tertiary)
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(14, geo.size.width * CGFloat(value) / 255))
                        .opacity(value > 0 ? 1 : 0)
                }
            }
            .frame(height: 14)
            .animation(reduced ? nil : .interactiveSpring(response: 0.12, dampingFraction: 0.9), value: value)
        }
    }
}
