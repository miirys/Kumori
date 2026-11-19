import SwiftUI

// Settings (U07–U09), laid out the way tvOS Settings is: a picture of where you are on the
// left, a native list on the right, and a choice opening its own list with a checkmark.
// Native lists give the system focus platter, deterministic focus and Back that returns to
// the row that opened a page, so nothing here draws its own focus.

/// Every page Settings can show. Fixtures open a page directly by passing a path.
enum SettingsRoute: Hashable {
    case stream, dlss, account, about
    case mode, codec, bitrate, region
    case dlssModel, dlssQuality, dlssRays, dlssFrames
}

struct SettingsView: View {
    @State private var path: [SettingsRoute]
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel

    init(path: [SettingsRoute] = []) {
        _path = State(initialValue: path)
    }

    var body: some View {
        NavigationStack(path: $path) {
            SettingsPage(symbol: nil, title: "Settings", summary: "Kumori \(AppVersion.display)") {
                Section {
                    link(.stream, "Stream", "play.tv", value: settings.mode.label)
                    link(.dlss, "DLSS", "wand.and.stars", value: dlssSummary)
                }
                Section {
                    link(.account, "Account", "person.crop.circle", value: app.profile?.name)
                    link(.about, "About", "info.circle", value: nil)
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsDestination(route: route)
            }
        }
    }

    private var dlssSummary: String {
        settings.dlssModel == .game && settings.dlssQuality == .game && !settings.dlssRays && settings.dlssFrames == .game
            ? "Game\u{2019}s choice" : "Custom"
    }

    private func link(_ route: SettingsRoute, _ title: String, _ icon: String, value: String?) -> some View {
        NavigationLink(value: route) {
            SettingsRow(title: title, icon: icon, value: value)
        }
        .accessibilityIdentifier("settings-\(route)")
    }
}

// MARK: Layout

/// One Settings page: a large symbol and a line about the page on the left, the list on the
/// right. Both columns sit inside the safe edge.
struct SettingsPage<Content: View>: View {
    /// An SF Symbol for the page, or nil for the app icon.
    let symbol: String?
    let title: String
    var summary: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 96) {
            VStack(spacing: TVTokens.group) {
                Group {
                    if let symbol {
                        Image(systemName: symbol)
                            .resizable()
                            .scaledToFit()
                            .fontWeight(.light)
                            .foregroundStyle(TVColor.secondary)
                            .padding(36)
                    } else {
                        Image("Icon")
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    }
                }
                .frame(width: 280, height: 280)
                .accessibilityHidden(true)
                Text(title)
                    .font(TVType.section)
                    .foregroundStyle(TVColor.primary)
                    .accessibilityAddTraits(.isHeader)
                if let summary {
                    Text(summary)
                        .font(TVType.callout)
                        .foregroundStyle(TVColor.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 600)
            .frame(maxHeight: .infinity)

            List { content() }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, TVTokens.safeX)
    }
}

/// A list row: an optional symbol, a title, and the current value at the end.
struct SettingsRow: View {
    let title: String
    var icon: String?
    var value: String?
    var detail: String?

    var body: some View {
        HStack(spacing: TVTokens.group) {
            if let icon {
                Image(systemName: icon).frame(width: 44).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail {
                    Text(detail).font(TVType.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: TVTokens.group)
            if let value {
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// The note under a group: small and quiet, so it reads as a note and not as a row.
private struct SettingsFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TVType.detail)
            .foregroundStyle(TVColor.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, TVTokens.small)
    }
}

/// A row that shows a value and can't be selected.
private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TVTokens.group) {
            Text(title).foregroundStyle(TVColor.secondary)
            Spacer(minLength: TVTokens.group)
            Text(value).foregroundStyle(TVColor.primary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A list of choices with a checkmark on the one in use. Choosing one keeps the list open,
/// so the person sees it took; Back returns to the row that opened it.
struct ChoiceList<Value: Hashable>: View {
    let symbol: String
    let title: String
    var summary: String?
    let options: [Value]
    let label: (Value) -> String
    var detail: (Value) -> String? = { _ in nil }
    /// A reason a choice can't be used here, shown under it. Blocked choices can't be focused.
    var blocked: (Value) -> String? = { _ in nil }
    var footer: String?
    @Binding var selection: Value

    var body: some View {
        SettingsPage(symbol: symbol, title: title, summary: summary) {
            Section {
                ForEach(options, id: \.self) { option in
                    let reason = blocked(option)
                    Button {
                        selection = option
                    } label: {
                        HStack(spacing: TVTokens.group) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label(option))
                                if let note = reason ?? detail(option) {
                                    Text(note).font(TVType.detail).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: TVTokens.group)
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .opacity(option == selection ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                    }
                    .disabled(reason != nil)
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
                }
            } footer: {
                if let footer { SettingsFooter(text: footer) }
            }
        }
    }
}

// MARK: Pages

private struct SettingsDestination: View {
    let route: SettingsRoute
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel
    @State private var signingOut = false

    var body: some View {
        switch route {
        case .stream: streamPage
        case .dlss: dlssPage
        case .account: accountPage
        case .about: aboutPage
        case .mode:
            ChoiceList(
                symbol: "rectangle.on.rectangle", title: "Resolution",
                summary: "What Kumori asks GeForce NOW for. The rig may send less, and the game says so when it does.",
                options: Array(StreamMode.all.reversed()), label: { $0.label },
                detail: { Capabilities.check($0, membership: app.membership).note },
                blocked: { m in
                    let v = Capabilities.check(m, membership: app.membership)
                    return v.blocked ? v.note ?? "Not available here." : nil
                },
                footer: "Applies from the next game you start. While playing, change it from the in-game menu.",
                selection: $settings.mode
            )
        case .codec:
            ChoiceList(
                symbol: "film.stack", title: "Video Codec",
                options: CodecChoice.allCases, label: \.label, detail: { $0.detail },
                footer: "Automatic picks AV1 where this Apple TV decodes it in hardware, then HEVC.",
                selection: $settings.codec
            )
        case .bitrate:
            ChoiceList(
                symbol: "speedometer", title: "Bitrate",
                summary: "The most data a second the stream may use. Higher looks sharper on a fast connection.",
                options: Settings.bitrates, label: { "\($0) Mbps" }, detail: Self.bitrateNote,
                selection: $settings.bitrateMbps
            )
        case .region:
            ChoiceList(
                symbol: "globe", title: "Server Location",
                options: [""] + app.regions.map(\.name), label: { $0.isEmpty ? "Automatic" : $0 },
                detail: { $0.isEmpty ? "The nearest location GeForce NOW picks for your account." : nil },
                selection: $settings.region
            )
        case .dlssModel:
            ChoiceList(symbol: "cpu", title: "DLSS Model", options: DlssModel.allCases, label: \.label,
                       footer: Self.dlssFooter, selection: $settings.dlssModel)
        case .dlssQuality:
            ChoiceList(symbol: "dial.medium", title: "DLSS Quality", options: DlssQuality.allCases, label: \.label,
                       footer: Self.dlssFooter, selection: $settings.dlssQuality)
        case .dlssRays:
            ChoiceList(symbol: "light.max", title: "Ray Reconstruction", options: [false, true],
                       label: { $0 ? "Recommended model" : "Game\u{2019}s choice" },
                       detail: { $0 ? "Needs a Performance or Ultimate membership." : nil },
                       footer: Self.dlssFooter, selection: $settings.dlssRays)
        case .dlssFrames:
            ChoiceList(symbol: "square.stack.3d.up", title: "Frame Generation", options: DlssFrames.allCases, label: \.label,
                       detail: { $0.multiplier > 0 ? "Needs an Ultimate RTX 5080 rig." : nil },
                       footer: Self.dlssFooter, selection: $settings.dlssFrames)
        }
    }

    private static let dlssFooter = "Applies from the next game you start, on games that have DLSS turned on."

    private func link(_ route: SettingsRoute, _ title: String, value: String) -> some View {
        NavigationLink(value: route) { SettingsRow(title: title, value: value) }
            .accessibilityIdentifier("settings-\(route)")
    }

    @ViewBuilder private var streamPage: some View {
        SettingsPage(symbol: "play.tv", title: "Stream",
                     summary: "How games are streamed to this Apple TV. Changes apply from the next game you start.") {
            Section("Picture") {
                link(.mode, "Resolution", value: settings.mode.label)
                link(.codec, "Video Codec", value: settings.codec.label)
                link(.bitrate, "Bitrate", value: "\(settings.bitrateMbps) Mbps")
                Toggle("Show Stats While Playing", isOn: $settings.showStats)
            }
            if !app.regions.isEmpty {
                Section("Server") {
                    link(.region, "Location", value: settings.region.isEmpty ? "Automatic" : settings.region)
                }
            }
            if let last = settings.log4k.last {
                Section {
                    InfoRow(title: "Last 4K try", value: last)
                    if !settings.failedRoutes.isEmpty {
                        Button("Try 4K From Scratch") { settings.retry4k() }
                    }
                } header: {
                    Text("4K")
                } footer: {
                    SettingsFooter(text: "Kumori asks for 4K in a few ways and remembers the one that gave a real 4K picture.")
                }
            }
        }
    }

    @ViewBuilder private var dlssPage: some View {
        SettingsPage(symbol: "wand.and.stars", title: "DLSS",
                     summary: "The cloud rig forces these on games that have DLSS turned on. Game\u{2019}s choice leaves the game alone.") {
            Section {
                link(.dlssModel, "Model", value: settings.dlssModel.label)
                link(.dlssQuality, "Quality", value: settings.dlssQuality.label)
                link(.dlssRays, "Ray Reconstruction", value: settings.dlssRays ? "Recommended model" : "Game\u{2019}s choice")
                link(.dlssFrames, "Frame Generation", value: settings.dlssFrames.label)
            } footer: {
                SettingsFooter(text: Self.dlssFooter)
            }
        }
    }

    @ViewBuilder private var accountPage: some View {
        SettingsPage(symbol: "person.crop.circle", title: app.profile?.name ?? "Account",
                     summary: app.profile?.email) {
            Section("Membership") {
                InfoRow(title: "Plan", value: app.membership?.tier ?? app.profile?.tier ?? "Unavailable")
                InfoRow(title: "Time left this month", value: timeLeft)
            }
            Section {
                Button { Task { await app.load() } } label: { SettingsRow(title: "Reload Library") }
                Button { signingOut = true } label: { SettingsRow(title: "Sign Out") }
                    .accessibilityIdentifier("settings-sign-out")
            }
        }
        .alert("Sign out of GeForce NOW?", isPresented: $signingOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { app.signOut() }
        } message: {
            Text("Games running in the cloud keep running. Sign in again with a new code.")
        }
    }

    private var timeLeft: String {
        guard let m = app.membership else { return "Unavailable" }
        if m.unlimited { return "Unlimited" }
        guard let h = m.hoursLeft else { return "Unavailable" }
        return String(format: "%.0f hours", h)
    }

    @ViewBuilder private var aboutPage: some View {
        SettingsPage(symbol: nil, title: "Kumori",
                     summary: "Game streaming for your TV. Kumori plays your GeForce NOW library. It is not made by or connected to NVIDIA.") {
            Section {
                InfoRow(title: "Version", value: AppVersion.display)
            }
            Section("This Apple TV") {
                InfoRow(title: "Output", value: "\(Int(UIScreen.main.nativeBounds.width)) × \(Int(UIScreen.main.nativeBounds.height))")
                InfoRow(title: "Highest refresh rate", value: "\(UIScreen.main.maximumFramesPerSecond) Hz")
                InfoRow(title: "Hardware decoders", value: HardwareDecoders.describe)
            }
        }
    }

    private static func bitrateNote(_ mbps: Int) -> String? {
        switch mbps {
        case ..<25: return "Fine for 1080p."
        case 25..<45: return "Good for 1440p."
        case 45..<75: return "Good for 4K."
        default: return "For a fast, wired connection."
        }
    }
}

/// "1.3.0 (10300)", from the bundle.
enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
