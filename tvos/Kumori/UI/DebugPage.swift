import AVFoundation
import SwiftUI

/// Settings › Debug: the numbers behind a stream, for working out what went wrong. Grouped
/// the way a problem is chased down: the picture, the launch that got it there, the input
/// going back, the 4K handshake, then the Apple TV and the build. Labels and values only.
struct DebugPage: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var controllers: ControllerCenter
    @Environment(\.settingsNav) private var nav
    @StateObject private var display = DisplayProbe()

    var body: some View {
        SettingsPage(symbol: "ladybug", title: "Debug") {
            streamSection
            launchSection
            inputSection
            fourKSection
            deviceSection
            buildSection
        }
        .onAppear { display.measure() }
        .onDisappear { display.stop() }
    }

    // MARK: Sections

    /// The stream on now, or else the last one, as it stood when it ended.
    @ViewBuilder private var streamSection: some View {
        let live = player.phase != nil && player.stats.width > 0
        let title: String = live ? "Stream Now" : "Last Stream"
        Section(title) {
            if let s = live ? Optional(player.stats) : player.lastStats {
                DebugRow("Picture", "\(s.width) \u{00D7} \(s.height)" + (s.fps.map { String(format: " \u{00B7} %.0f fps", $0) } ?? ""))
                    .settingsFocus(.row(.debug))
                DebugRow("Codec", s.codec ?? "Unknown")
                DebugRow("Bitrate", s.bitrateMbps.map { String(format: "%.1f Mbps", $0) } ?? "\u{2014}")
                DebugRow("Round Trip", s.rttMs.map { String(format: "%.0f ms", $0) } ?? "\u{2014}")
                DebugRow("Packet Loss", s.lossPct.map { String(format: "%.2f%%", $0) } ?? "\u{2014}")
                DebugRow("Decode Time", s.decodeMs.map { String(format: "%.1f ms", $0) } ?? "\u{2014}")
                DebugRow("Frames Decoded", s.framesDecoded.formatted())
                DebugRow("Packets Received", s.packetsReceived.formatted())
            } else {
                DebugRow("Stream", "None yet")
                    .settingsFocus(.row(.debug))
            }
            DebugRow("Server", settings.region.isEmpty ? "Automatic" : settings.region)
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
            DebugRow("Controllers", pads.isEmpty ? "None" : pads.map(\.name).joined(separator: ", "))
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

    @ViewBuilder private var fourKSection: some View {
        Section("4K") {
            DebugRow("Working Route", settings.route4k.map(Self.name) ?? "None yet")
            DebugRow("Skipped Routes", settings.failedRoutes.isEmpty
                     ? "None" : settings.failedRoutes.map(Self.name).sorted().joined(separator: ", "))
            ForEach(Array(settings.log4k.reversed().enumerated()), id: \.offset) { _, line in
                DebugLine(text: line)
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
            DebugRow("HDMI Refresh Now", display.label)
            DebugRow("Highest Refresh Rate", "\(UIScreen.main.maximumFramesPerSecond) Hz")
            DebugRow("Stream Frame Rate", "\(settings.mode.fps) fps requested")
            DebugRow("HDR", AVPlayer.eligibleForHDRPlayback ? "Available" : "Off")
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

    private static func name(_ r: Route) -> String {
        switch r {
        case .web: return "Web"
        case .tv: return "TV"
        case .desktop: return "PC"
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

/// One line of a log, as written.
private struct DebugLine: View {
    let text: String

    var body: some View {
        Button {} label: {
            Text(text)
                .font(.system(size: 22, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
