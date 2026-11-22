import AVFoundation
import SwiftUI

/// Settings › Debug: the numbers behind a stream, for working out what went wrong. Grouped
/// the way a problem is chased down: the picture, the launch that got it there, the input
/// going back, the 4K handshake, then the Apple TV and the build. Labels and values only.
struct DebugPage: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var controllers: ControllerCenter
    @Environment(\.settingsNav) private var nav
    @StateObject private var display = DisplayProbe()
    @StateObject private var ping = RegionPing()
    @ObservedObject private var link = KumoriLink.shared

    var body: some View {
        SettingsPage(symbol: "ladybug", title: "Debug") {
            streamSection
            launchSection
            regionPingSection
            inputSection
            kumoriLinkSection
            fourKSection
            deviceSection
            buildSection
        }
        .onAppear { display.measure() }
        .onDisappear { display.stop(); ping.stop() }
    }

    // MARK: Sections

    /// The stream on now, or else the last one, as it stood when it ended.
    @ViewBuilder private var streamSection: some View {
        let live = player.phase != nil && player.stats.width > 0
        let title: String = live ? "Stream Now" : "Last Stream"
        Section(title) {
            if let s = live ? Optional(player.stats) : player.lastStats {
                DebugRow("Picture", "\(s.width) \u{00D7} \(s.height)")
                    .settingsFocus(.row(.debug))
                DebugRow("Frame Rate", s.fps.map { String(format: "%.0f fps", $0) } ?? "\u{2014}")
                DebugRow("Codec", s.codec ?? "Unknown")
                if let d = s.codecDetail { DebugRow("Format", d) }
                if let hw = s.hardwareDecode { DebugRow("Decoder", hw ? "Hardware" : "Software") }
                if let t = s.transport { DebugRow("Transport", t) }
                DebugRow("Bitrate", s.bitrateMbps.map { String(format: "%.1f Mbps", $0) } ?? "\u{2014}")
                DebugRow("Round Trip", s.rttMs.map { String(format: "%.0f ms", $0) } ?? "\u{2014}")
                DebugRow("Packet Loss", s.lossPct.map { String(format: "%.2f%%", $0) } ?? "\u{2014}")
                if let lost = s.packetsLost { DebugRow("Packets Lost", lost.formatted()) }
                if let resent = s.packetsResent { DebugRow("Resend Requests", resent.formatted()) }
                if let j = s.jitterMs { DebugRow("Jitter", String(format: "%.1f ms", j)) }
                DebugRow("Decode Time", s.decodeMs.map { String(format: "%.1f ms", $0) } ?? "\u{2014}")
                DebugRow("Frames Decoded", s.framesDecoded.formatted())
                DebugRow("Packets Received", s.packetsReceived.formatted())
                if let f = s.framesReceived { DebugRow("Frames Received", f.formatted()) }
                if let f = s.framesFailed { DebugRow("Frames Failed", f.formatted()) }
                if let a = s.audio { DebugRow("Audio", a) }
            } else {
                DebugRow("Stream", "None yet")
                    .settingsFocus(.row(.debug))
            }
            DebugRow("Server", settings.region.isEmpty ? "Automatic" : settings.region)
        }
    }

    /// The round trip to every GeForce NOW region, fastest first. Run on request only.
    @ViewBuilder private var regionPingSection: some View {
        Section("Region Ping") {
            Button { ping.run(app.regions) } label: {
                SettingsRow(title: ping.running ? "Testing All Regions\u{2026}" : (ping.rows.isEmpty ? "Test All Regions" : "Test Again"))
            }
            .disabled(app.regions.isEmpty)
            .accessibilityIdentifier("settings-region-ping")
            if app.regions.isEmpty {
                DebugRow("Regions", "Sign in to list them")
            }
            ForEach(ping.sorted) { row in
                DebugRow(row.name, RegionPing.label(row.result))
            }
        }
    }

    @ViewBuilder private var launchSection: some View {
        Section("Last Launch") {
            if let t = player.trace {
                DebugRow("ID", t.id)
                DebugRow("Furthest Step", t.lastGood.map(Self.words) ?? "None")
                DebugRow("Steps", "\(t.events.count)")
                DebugRow("Time", String(format: "%.1f s", t.events.last?.at ?? 0))
                Button { nav?.open(.launchLog) } label: {
                    SettingsRow(title: "Launch Log", chevron: true)
                }
                .settingsFocus(.row(.launchLog))
                .accessibilityIdentifier("settings-launchLog")
            } else {
                DebugRow("Launch", "None yet")
            }
        }
    }

    /// What reached the game from the controller, live during a stream.
    @ViewBuilder private var inputSection: some View {
        let live = player.phase != nil
        let stats = live ? Optional(player.inputStats) : player.lastInput
        let pads = controllers.pads.filter { !$0.isRemote }
        Section("Input") {
            let names = (link.status == .connected ? Array(repeating: "Kumori Link", count: link.controllers) : []) + pads.map(\.name)
            DebugRow("Controllers", names.isEmpty ? "None" : names.joined(separator: ", "))
            DebugRow("Full Controllers", "\(pads.filter { $0.profile == .extended }.count)")
            if let stats {
                DebugRow("Input Protocol", stats.version.map { "Version \($0)" } ?? "Not ready")
                DebugRow("Reports Sent", stats.sent.formatted())
                DebugRow("Sent Ordered", stats.reliable.formatted())
                DebugRow("Before Ready", stats.early.formatted())
                DebugRow("Rejected", stats.rejected.formatted())
            } else {
                DebugRow("Reports", "None yet")
            }
        }
    }

    @ViewBuilder private var kumoriLinkSection: some View {
        let l = link
        Section("Kumori Link") {
            DebugRow("Status", l.box == nil ? "Off" : {
                switch l.status {
                case .off: return "Off"
                case .connecting: return "Connecting"
                case .connected: return "Connected"
                case .lost: return "Not Found"
                }
            }())
            DebugRow("Box", l.boxModel ?? "\u{2014}")
            DebugRow("Box Version", l.boxVersion ?? "\u{2014}")
            DebugRow("Last Sender", l.lastSender ?? "\u{2014}")
            DebugRow("Packets Received", l.received.formatted())
            DebugRow("Round Trip", l.roundTripMs.map { String(format: "%.1f ms", $0) } ?? "\u{2014}")
            DebugRow("Controllers", "\(l.controllers)")
        }
    }

    @ViewBuilder private var fourKSection: some View {
        Section("4K") {
            DebugRow("Working Route", settings.route4k.map(Self.name) ?? "None yet")
            DebugRow("Skipped Routes", settings.failedRoutes.isEmpty
                     ? "None" : settings.failedRoutes.map(Self.name).sorted().joined(separator: ", "))
            // Newest first, as a label and what happened, rather than the raw lines.
            ForEach(Array(settings.log4k.reversed().prefix(4).enumerated()), id: \.offset) { _, line in
                let attempt = Self.attempt(line)
                DebugRow(attempt.who, attempt.what)
            }
            if !settings.failedRoutes.isEmpty {
                Button { settings.retry4k() } label: { SettingsRow(title: "Reset 4K Attempts") }
                    .accessibilityIdentifier("settings-reset-4k")
            }
        }
    }

    @ViewBuilder private var deviceSection: some View {
        Section("This Apple TV") {
            DebugRow("Model", Self.model)
            DebugRow("tvOS", UIDevice.current.systemVersion)
            DebugRow("Display", DisplayInfo.summary)
            DebugRow("HDMI Mode", HDMIMode.currentLabel)
            DebugRow("HDMI Refresh Now", display.label)
            DebugRow("Fastest Mode Offered", HDMIMode.fastestRate.map { "\($0) Hz" } ?? "Unavailable")
            DebugRow("Highest Refresh Rate", "\(UIScreen.main.maximumFramesPerSecond) Hz")
            DebugRow("Stream Frame Rate", "\(settings.mode.fps) fps requested")
            DebugRow("HDR", AVPlayer.eligibleForHDRPlayback ? "Available" : "Off")
            DebugRow("Temperature", ProcessInfo.processInfo.thermalState.label)
            DebugRow("Hardware Decoding", HardwareDecoders.describe)
            DebugRow("AV1", HardwareDecoders.av1Hardware ? "Hardware" : "Software only")
        }
    }

    @ViewBuilder private var buildSection: some View {
        Section("Build") {
            DebugRow("Version", BuildInfo.current.version)
            DebugRow("Build", BuildInfo.current.build)
            DebugRow("Commit", BuildInfo.current.commit)
            #if DEBUG
            DebugRow("Configuration", "Debug")
            #else
            DebugRow("Configuration", "Release")
            #endif
        }
    }

    // MARK: Words

    /// "Asked as the TV client, playing at 1920 × 1080" → ("TV client", "Playing at 1920 × 1080").
    static func attempt(_ line: String) -> (who: String, what: String) {
        func cap(_ t: Substring) -> String { t.prefix(1).uppercased() + t.dropFirst() }
        var rest = Substring(line)
        if rest.hasPrefix("Asked as ") { rest = rest.dropFirst("Asked as ".count) }
        if rest.lowercased().hasPrefix("the ") { rest = rest.dropFirst(4) }
        if let comma = rest.range(of: ", ") {
            return (cap(rest[..<comma.lowerBound]), cap(rest[comma.upperBound...]))
        }
        if let failed = rest.range(of: " failed before the first picture") {
            return (cap(rest[..<failed.lowerBound]), "Failed before the picture")
        }
        return ("Attempt", cap(rest))
    }

    private static func name(_ r: Route) -> String {
        switch r {
        case .web: return "Web"
        case .tv: return "TV"
        case .desktop: return "PC"
        case .native: return "Native"
        }
    }

    /// "firstFrame" → "First frame".
    static func words(_ stage: LaunchStage) -> String {
        var out = ""
        for c in stage.rawValue {
            if c.isUppercase { out += " " + c.lowercased() } else { out.append(c) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    /// "AppleTV14,1".
    private static let model: String = {
        var info = utsname()
        uname(&info)
        let id = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return id.isEmpty ? "Unknown" : id
    }()
}

/// A label and its value. Focusable, so the remote can scroll the page row by row; it
/// does nothing when pressed.
private struct DebugRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        Button {} label: {
            HStack(alignment: .firstTextBaseline, spacing: TVTokens.group) {
                Text(title)
                Spacer(minLength: TVTokens.group)
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Debug › Launch Log: each step of the last launch with when it happened.
struct LaunchLogPage: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        SettingsPage(symbol: nil, title: "Launch Log") {
            Section(player.trace.map { "Launch \($0.id)" } ?? "") {
                if let t = player.trace, !t.events.isEmpty {
                    ForEach(Array(t.events.suffix(60).enumerated()), id: \.offset) { _, e in
                        Button {} label: {
                            HStack(alignment: .firstTextBaseline, spacing: TVTokens.group) {
                                Text(String(format: "%.2f s", e.at))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 130, alignment: .leading)
                                Text(DebugPage.words(e.stage))
                                Spacer(minLength: TVTokens.group)
                                if !e.fields.isEmpty {
                                    Text(e.fields.text)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                    }
                } else {
                    DebugRow("Log", "Empty")
                }
            }
        }
    }
}
