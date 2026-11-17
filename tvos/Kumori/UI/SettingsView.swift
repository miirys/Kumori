import SwiftUI

/// The resolution and frame rate as one value, "1440p@120", stepped with left and right.
struct ModeRow: View {
    let selection: StreamMode
    let membership: Membership?
    let pick: (StreamMode) -> Void

    var body: some View {
        var options = StreamMode.playable(membership)
        if !options.contains(selection) { options.append(selection) }
        options.sort { ($0.height, $0.fps) < ($1.height, $1.fps) }
        return ValueRow(label: "Resolution", icon: "rectangle.on.rectangle", options: options, title: \.short, selection: selection, pick: pick)
    }
}

/// Settings: one centred column of rows on glass, over the dimmed game art. Every choice
/// is a row stepped with left and right; nothing opens on top of anything else.
struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 46) {
                Text("Settings").font(.kumori(54, .bold)).foregroundStyle(Palette.text).reveal(0)

                Panel(title: "Stream") {
                    ModeRow(selection: settings.mode, membership: app.membership) { settings.mode = $0 }
                    ValueRow(label: "Video codec", icon: "film.stack", options: CodecChoice.allCases, title: \.label, selection: settings.codec) { settings.codec = $0 }
                    ValueRow(label: "Bitrate", icon: "speedometer", options: Settings.bitrates, title: { "\($0) Mbps" }, selection: settings.bitrateMbps) { settings.bitrateMbps = $0 }
                    if !app.regions.isEmpty {
                        ValueRow(label: "Server", icon: "globe", options: [""] + app.regions.map(\.name), title: { $0.isEmpty ? "Automatic" : $0 }, selection: settings.region) { settings.region = $0 }
                    }
                    ValueRow(label: "Stats while playing", icon: "chart.bar.xaxis", options: [false, true], title: { $0 ? "On" : "Off" }, selection: settings.showStats) { settings.showStats = $0 }
                    if !settings.failedRoutes.isEmpty {
                        ActionRow(icon: "arrow.counterclockwise", label: "Try 4K again") { settings.retry4k() }
                    }
                }
                .reveal(1)

                Panel(title: "DLSS") {
                    ValueRow(label: "Model", icon: "cpu", options: DlssModel.allCases, title: \.label, selection: settings.dlssModel) { settings.dlssModel = $0 }
                    ValueRow(label: "Quality", icon: "dial.medium", options: DlssQuality.allCases, title: \.label, selection: settings.dlssQuality) { settings.dlssQuality = $0 }
                    ValueRow(label: "Ray Reconstruction", icon: "light.max", options: [false, true], title: { $0 ? "Recommended" : "Game's choice" }, selection: settings.dlssRays) { settings.dlssRays = $0 }
                    ValueRow(label: "Frame generation", icon: "square.stack.3d.up.fill", options: DlssFrames.allCases, title: \.label, selection: settings.dlssFrames) { settings.dlssFrames = $0 }
                }
                .reveal(2)

                Panel(title: "Account") {
                    InfoRow(label: app.profile?.name ?? "Player", value: app.membership?.tier ?? app.profile?.tier ?? "")
                    if let m = app.membership, !m.unlimited, let h = m.hoursLeft {
                        InfoRow(label: "Time left this month", value: String(format: "%.0f hours", h))
                    }
                    ActionRow(icon: "arrow.clockwise", label: "Reload library") { Task { await app.load() } }
                    ActionRow(icon: "rectangle.portrait.and.arrow.right", label: "Sign out") { app.signOut() }
                }
                .reveal(3)

                Panel(title: "About") {
                    InfoRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    InfoRow(label: "Output", value: "\(Int(UIScreen.main.nativeBounds.width)) × \(Int(UIScreen.main.nativeBounds.height)) at \(UIScreen.main.maximumFramesPerSecond) Hz")
                    InfoRow(label: "Hardware decoding", value: HardwareDecoders.describe)
                }
                .reveal(4)
            }
            .frame(width: 1240, alignment: .leading)
            .padding(.top, 20)
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        // Settings takes the whole screen: one centred column over the art, dimmed so the
        // rows read as the page and the picture stays in the background.
        .background(Color.black.opacity(0.55).ignoresSafeArea())
    }
}
