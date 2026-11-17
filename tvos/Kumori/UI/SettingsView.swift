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

/// The pages of Settings, as on Android: one page of rows at a time.
enum SettingsPage: String, CaseIterable, Identifiable {
    case stream = "Stream", dlss = "DLSS", account = "Account", about = "About"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .stream: "play.tv"
        case .dlss: "cpu"
        case .account: "person.crop.circle"
        case .about: "info.circle"
        }
    }
}

/// Settings fills the screen: the title and a row of page tabs at the top, and the chosen
/// page's rows in one wide card below. Moving along the tabs switches the page; moving down
/// goes into its rows, where left and right step each value.
struct SettingsView: View {
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @State private var page: SettingsPage = .stream
    @Namespace private var tabs

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            HStack(alignment: .firstTextBaseline, spacing: 50) {
                Text("Settings").font(.kumori(54, .bold)).foregroundStyle(Palette.text)
                HStack(spacing: 14) {
                    ForEach(SettingsPage.allCases) { p in
                        PageTab(page: p, selected: page == p, namespace: tabs) {
                            withAnimation(Motion.glide) { page = p }
                        }
                    }
                }
                .focusSection()
            }
            .reveal(0)

            ScrollView {
                VStack(spacing: 6) { rows }
                    .padding(12)
                    .glassCard(34)
                    .id(page)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 24)), removal: .opacity))
                    .padding(.bottom, 80)
            }
            .scrollClipDisabled()
            .focusSection()
            .reveal(1)
        }
        .padding(.horizontal, Layout.inset)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.6).ignoresSafeArea())
        .animation(Motion.glide, value: page)
    }

    @ViewBuilder private var rows: some View {
        switch page {
        case .stream:
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
        case .dlss:
            ValueRow(label: "Model", icon: "cpu", options: DlssModel.allCases, title: \.label, selection: settings.dlssModel) { settings.dlssModel = $0 }
            ValueRow(label: "Quality", icon: "dial.medium", options: DlssQuality.allCases, title: \.label, selection: settings.dlssQuality) { settings.dlssQuality = $0 }
            ValueRow(label: "Ray Reconstruction", icon: "light.max", options: [false, true], title: { $0 ? "Recommended" : "Game's choice" }, selection: settings.dlssRays) { settings.dlssRays = $0 }
            ValueRow(label: "Frame generation", icon: "square.stack.3d.up.fill", options: DlssFrames.allCases, title: \.label, selection: settings.dlssFrames) { settings.dlssFrames = $0 }
        case .account:
            InfoRow(label: app.profile?.name ?? "Player", value: app.membership?.tier ?? app.profile?.tier ?? "")
            if let m = app.membership, !m.unlimited, let h = m.hoursLeft {
                InfoRow(label: "Time left this month", value: String(format: "%.0f hours", h))
            }
            ActionRow(icon: "arrow.clockwise", label: "Reload library") { Task { await app.load() } }
            ActionRow(icon: "rectangle.portrait.and.arrow.right", label: "Sign out") { app.signOut() }
        case .about:
            InfoRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            InfoRow(label: "Output", value: "\(Int(UIScreen.main.nativeBounds.width)) × \(Int(UIScreen.main.nativeBounds.height)) at \(UIScreen.main.maximumFramesPerSecond) Hz")
            InfoRow(label: "Hardware decoding", value: HardwareDecoders.describe)
        }
    }
}

/// One page tab. Focus picks the page, so moving along the tabs flips through them; the
/// chosen page keeps a soft pill that slides between tabs.
private struct PageTab: View {
    let page: SettingsPage
    let selected: Bool
    let namespace: Namespace.ID
    let choose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                Image(systemName: page.icon).font(.system(size: 24, weight: .semibold))
                Text(page.rawValue)
            }
        }
        .buttonStyle(TabStyle(selected: selected, namespace: namespace))
        .focused($focused)
        .onChange(of: focused) { _, f in if f, !selected { choose() } }
    }

    private struct TabStyle: ButtonStyle {
        let selected: Bool
        let namespace: Namespace.ID

        func makeBody(configuration: Configuration) -> some View {
            Face(configuration: configuration, selected: selected, namespace: namespace)
        }

        private struct Face: View {
            let configuration: Configuration
            let selected: Bool
            let namespace: Namespace.ID
            @Environment(\.isFocused) private var focused

            var body: some View {
                configuration.label
                    .font(.kumori(28, .semibold))
                    .foregroundStyle(focused ? Palette.onFocus : (selected ? Palette.text : Palette.secondary))
                    .padding(.horizontal, 30)
                    .frame(height: 68)
                    .background {
                        ZStack {
                            if selected {
                                Capsule().fill(Palette.raised).matchedGeometryEffect(id: "tab", in: namespace)
                            }
                            Capsule().fill(Palette.focus).opacity(focused ? 1 : 0)
                                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 18, y: 10)
                        }
                    }
                    .scaleEffect(configuration.isPressed ? 0.96 : (focused ? 1.06 : 1))
                    .animation(Motion.focus, value: focused)
                    .animation(Motion.press, value: configuration.isPressed)
            }
        }
    }
}
