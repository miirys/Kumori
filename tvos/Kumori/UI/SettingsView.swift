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

/// The part of Settings that has focus, so the left side can show it.
enum SettingsSection: String {
    case stream = "Stream", dlss = "DLSS", account = "Account", about = "About"

    var icon: String {
        switch self {
        case .stream: "play.tv.fill"
        case .dlss: "cpu.fill"
        case .account: "person.crop.circle.fill"
        case .about: "info.circle.fill"
        }
    }
}

private struct SettingsSectionKey: FocusedValueKey { typealias Value = SettingsSection }
extension FocusedValues {
    var settingsSection: SettingsSection? {
        get { self[SettingsSectionKey.self] }
        set { self[SettingsSectionKey.self] = newValue }
    }
}

/// Settings the way the Apple TV lays its own out: the left half names the part that has
/// focus with a large symbol, and the rows run down the right half over the dimmed art.
/// Every choice is a row stepped with left and right; nothing opens on top of anything.
struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @FocusedValue(\.settingsSection) private var focused
    @State private var shown: SettingsSection = .stream

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Aside(section: shown, account: app.profile?.name, tier: app.membership?.tier ?? app.profile?.tier)
                .frame(width: 700)
                .frame(maxHeight: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 54) {
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
                    .focusedValue(\.settingsSection, .stream)
                    .reveal(1)

                    Panel(title: "DLSS") {
                        ValueRow(label: "Model", icon: "cpu", options: DlssModel.allCases, title: \.label, selection: settings.dlssModel) { settings.dlssModel = $0 }
                        ValueRow(label: "Quality", icon: "dial.medium", options: DlssQuality.allCases, title: \.label, selection: settings.dlssQuality) { settings.dlssQuality = $0 }
                        ValueRow(label: "Ray Reconstruction", icon: "light.max", options: [false, true], title: { $0 ? "Recommended" : "Game's choice" }, selection: settings.dlssRays) { settings.dlssRays = $0 }
                        ValueRow(label: "Frame generation", icon: "square.stack.3d.up.fill", options: DlssFrames.allCases, title: \.label, selection: settings.dlssFrames) { settings.dlssFrames = $0 }
                    }
                    .focusedValue(\.settingsSection, .dlss)
                    .reveal(2)

                    Panel(title: "Account") {
                        InfoRow(label: app.profile?.name ?? "Player", value: app.membership?.tier ?? app.profile?.tier ?? "")
                        if let m = app.membership, !m.unlimited, let h = m.hoursLeft {
                            InfoRow(label: "Time left this month", value: String(format: "%.0f hours", h))
                        }
                        ActionRow(icon: "arrow.clockwise", label: "Reload library") { Task { await app.load() } }
                        ActionRow(icon: "rectangle.portrait.and.arrow.right", label: "Sign out") { app.signOut() }
                    }
                    .focusedValue(\.settingsSection, .account)
                    .reveal(3)

                    Panel(title: "About") {
                        InfoRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                        InfoRow(label: "Output", value: "\(Int(UIScreen.main.nativeBounds.width)) × \(Int(UIScreen.main.nativeBounds.height)) at \(UIScreen.main.maximumFramesPerSecond) Hz")
                        InfoRow(label: "Hardware decoding", value: HardwareDecoders.describe)
                    }
                    .reveal(4)
                }
                .padding(.top, 30)
                .padding(.bottom, 120)
                .padding(.trailing, Layout.inset)
            }
            .scrollClipDisabled()
        }
        .ignoresSafeArea(edges: .horizontal)
        .background {
            // Dark behind the rows, clearer behind the left side, so the art still shows.
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.78), .black.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()
        }
        .onChange(of: focused) { _, s in
            // About has nothing to focus, so scrolling past Account keeps Account named.
            if let s, s != shown { withAnimation(Motion.glide) { shown = s } }
        }
    }
}

/// The left half of Settings: a large symbol for the part that has focus, which turns
/// over as focus moves between parts.
private struct Aside: View {
    let section: SettingsSection
    let account: String?
    let tier: String?

    var body: some View {
        VStack(spacing: 34) {
            Spacer()
            ZStack {
                Circle().fill(Palette.surface).frame(width: 300, height: 300)
                    .overlay { Circle().strokeBorder(Palette.hairline, lineWidth: 1) }
                Image(systemName: section.icon)
                    .font(.system(size: 130, weight: .regular))
                    .foregroundStyle(Palette.text)
                    .id(section)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7).combined(with: .opacity),
                        removal: .scale(scale: 1.2).combined(with: .opacity)
                    ))
            }
            VStack(spacing: 10) {
                Text("Settings").font(.kumori(30, .semibold)).foregroundStyle(Palette.secondary)
                Text(section.rawValue).font(.kumori(56, .bold)).foregroundStyle(Palette.text)
                    .id(section).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .reveal(0)
            Spacer()
            if let account {
                Text([account, tier].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.kumori(24)).foregroundStyle(Palette.tertiary).lineLimit(1)
                    .padding(.bottom, 70)
            }
        }
        .padding(.horizontal, 60)
    }
}
