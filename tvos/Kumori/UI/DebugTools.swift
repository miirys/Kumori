import SwiftUI

// Settings › Debug's three tools: the HDMI chain check, Send Log and the local API.

/// A finding's mark: a filled circle that says ok, a warning or blocked at a glance.
private struct FindingMark: View {
    let level: DisplayChain.Level

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 44)
            .accessibilityLabel(level.rawValue)
    }

    private var symbol: String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch level {
        case .ok: return Color(red: 0.45, green: 0.86, blue: 0.6)
        case .warning: return Color(red: 1, green: 0.78, blue: 0.3)
        case .blocked: return TVColor.accent
        case .unknown: return TVColor.tertiary
        }
    }
}

/// A row that reads as one line of findings: the mark, what was checked, what was found,
/// and, under it, what to change.
private struct FindingRow: View {
    let finding: DisplayChain.Finding

    var body: some View {
        Button {} label: {
            HStack(alignment: .top, spacing: TVTokens.group) {
                FindingMark(level: finding.level)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(finding.title)
                        Spacer(minLength: TVTokens.group)
                        Text(finding.value).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    if let detail = finding.detail {
                        Text(detail)
                            .font(TVType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Debug › Display Chain: whether 120 Hz and HDR get from the Apple TV through a
/// receiver to the TV or projector, what is blocking them, and a live 120 Hz test.
struct DisplayChainPage: View {
    @EnvironmentObject private var player: Player
    @StateObject private var probe = DisplayProbe()
    @State private var chain = DisplayChain.read()
    @State private var testing = false
    @State private var result: String?
    @State private var resultLevel = DisplayChain.Level.unknown

    var body: some View {
        SettingsPage(symbol: "cable.connector", title: "Display Chain") {
            Section {
                ForEach(chain.findings) { f in FindingRow(finding: f) }
            } footer: {
                Text("Read from the modes the receiver and display report to the Apple TV.")
            }
            Section("Test") {
                Button { test() } label: {
                    SettingsRow(title: testing ? "Testing 120 Hz\u{2026}" : "Test 120 Hz Now", icon: "bolt.horizontal",
                                detail: "Switches to 120 Hz for 6 seconds and times the output, then switches back. The screen may go dark while it switches.")
                }
                .disabled(testing || player.active)
                .accessibilityIdentifier("settings-test-120")
                if let result {
                    Button {} label: {
                        HStack(alignment: .top, spacing: TVTokens.group) {
                            FindingMark(level: resultLevel)
                            Text(result).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                DebugRow("Refresh Now", probe.label)
            }
            if !chain.modeLines.isEmpty {
                Section("Modes Offered") {
                    ForEach(chain.modeLines, id: \.self) { line in
                        DebugRow(line, "")
                    }
                }
            }
        }
        .onAppear { probe.measure() }
        .onDisappear { probe.stop() }
        .animation(.snappy, value: result)
    }

    private func test() {
        testing = true
        result = nil
        HDMIMode.trial(hz: 120, seconds: 6, measure: { probe.measure() }) { mode in
            testing = false
            chain = DisplayChain.read()
            guard let mode else {
                resultLevel = .blocked
                result = "No 120 Hz mode is offered, so there was nothing to switch to. See 120 Hz above."
                return
            }
            let hz = probe.measuredHz
            if let hz, hz > 100 {
                resultLevel = .ok
                result = "The Apple TV sent \(mode.width) \u{00D7} \(mode.height) at \(FrameHealth.hz(hz)). If the screen stayed black during the test, the receiver or display couldn't show it: check their Enhanced HDMI settings."
            } else {
                resultLevel = .warning
                result = "The switch to \(mode.width) \u{00D7} \(mode.height) at 120 Hz was asked for, but the output was timed at \(hz.map { FrameHealth.hz($0) } ?? "an unknown rate")."
            }
            probe.measure()
        }
    }
}

/// Settings › Debug › Send Log: saves a full report and shows where to open it on a phone
/// or computer on the same network.
struct SendLogPage: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var controllers: ControllerCenter
    @ObservedObject private var api = LocalAPI.shared
    @State private var saved: LogReport.Saved?
    @State private var list = LogReport.saved()
    @State private var working = false

    var body: some View {
        SettingsPage(symbol: "doc.text", title: "Send Log") {
            Section {
                Button { send() } label: {
                    SettingsRow(title: working ? "Saving\u{2026}" : "Send Log", icon: "square.and.arrow.up",
                                detail: "Saves the build, display chain, settings, last launch, stream numbers and Kumori\u{2019}s log since it opened. No passwords, tokens or email.")
                }
                .disabled(working)
                .accessibilityIdentifier("settings-send-log")
            }
            if let saved {
                Section("Saved") {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack(alignment: .center, spacing: 40) {
                            if let url = address(saved), let qr = QRCode.image(url) {
                                Image(uiImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 260, height: 260)
                                    .padding(16)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                                    .accessibilityLabel("QR code for the report")
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Scan with a phone on the same network, or open:")
                                    .font(TVType.callout)
                                    .foregroundStyle(TVColor.secondary)
                                Text(address(saved) ?? "No network address. Is the Apple TV online?")
                                    .font(TVType.callout.weight(.semibold).monospaced())
                                    .foregroundStyle(TVColor.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(saved.name), \(ByteCountFormatter.string(fromByteCount: Int64(saved.bytes), countStyle: .file))")
                                    .font(TVType.caption)
                                    .foregroundStyle(TVColor.tertiary)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            if !list.isEmpty {
                Section("Earlier Reports") {
                    ForEach(list.prefix(10), id: \.name) { r in
                        DebugRow(r.date.formatted(date: .abbreviated, time: .shortened), ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file))
                    }
                }
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: saved?.name)
    }

    private func address(_ s: LogReport.Saved) -> String? {
        api.baseURL.map { "\($0)/logs/\(s.name)" }
    }

    private func send() {
        working = true
        // Let the button show it's working before the report is gathered.
        DispatchQueue.main.async {
            saved = LogReport.save(APIReport(app: app, player: player, settings: settings, controllers: controllers))
            list = LogReport.saved()
            working = false
        }
    }
}

/// Settings › Debug › API: that the local API exists, where, and what it answers.
struct APIPage: View {
    @ObservedObject private var api = LocalAPI.shared

    var body: some View {
        SettingsPage(symbol: "network", title: "API") {
            Section {
                DebugRow("Status", api.running ? "Running" : (api.problem ?? "Starting"))
                DebugRow("Address", api.baseURL ?? "No network address")
                DebugRow("Port", "\(LocalAPI.port)")
                DebugRow("Requests Answered", api.served.formatted())
                if let last = api.lastPath { DebugRow("Last Request", last) }
            } footer: {
                Text("Read-only JSON over HTTP, answered only on your home network while Kumori is open. GET any path below.")
            }
            Section("Endpoints") {
                ForEach(LocalAPI.endpoints, id: \.path) { e in
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.path).font(TVType.body.monospaced())
                            Text(e.what).font(TVType.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
