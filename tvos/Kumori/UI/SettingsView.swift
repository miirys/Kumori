import SwiftUI

/// Resolution and frame rate in one table. The mode in use is greyed and can't be picked
/// again. Modes that can't be used here are greyed too, with the reason underneath.
struct ModePicker: View {
    /// What Settings asks for.
    let chosen: StreamMode
    /// What is in use: the stream on screen, or the saved choice when nothing is playing.
    let active: StreamMode
    let membership: Membership?
    let pick: (StreamMode) -> Void

    var body: some View {
        let notes = Resolution.allCases.flatMap { r in StreamMode.rates.map { Capabilities.check(StreamMode(resolution: r, fps: $0), membership: membership) } }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Resolution.allCases, id: \.rawValue) { r in
                HStack(spacing: 12) {
                    Text(r.label).font(.kumori(25, .semibold)).foregroundStyle(Palette.secondary).frame(width: 110, alignment: .leading)
                    ForEach(StreamMode.rates, id: \.self) { fps in
                        let mode = StreamMode(resolution: r, fps: fps)
                        let verdict = Capabilities.check(mode, membership: membership)
                        ModeCell(
                            text: "\(fps) fps",
                            tag: mode == active ? "NOW" : (mode == chosen ? "ASKED" : nil),
                            dim: mode == active || verdict.blocked
                        ) { pick(mode) }
                        .disabled(mode == active || verdict.blocked)
                    }
                }
            }
            if chosen != active {
                Text("\(chosen.label) was asked for. GeForce NOW sent \(active.label).").font(.kumori(21)).foregroundStyle(Palette.pink)
            }
            // Why the greyed modes are greyed, each reason once.
            ForEach(Array(Set(notes.filter(\.blocked).compactMap(\.note))).sorted(), id: \.self) { note in
                Text(note).font(.kumori(21)).foregroundStyle(Palette.tertiary)
            }
            if let note = Capabilities.check(chosen, membership: membership).note, !Capabilities.check(chosen, membership: membership).blocked {
                Text(note).font(.kumori(21)).foregroundStyle(Palette.tertiary)
            }
        }
        .focusSection()
    }
}

private struct ModeCell: View {
    let text: String
    let tag: String?
    let dim: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(text)
                Spacer()
                if let tag { Text(tag).font(.kumori(17, .bold)).kerning(1) }
            }
            .frame(width: 210)
        }
        .buttonStyle(CellStyle(dim: dim))
    }

    private struct CellStyle: ButtonStyle {
        let dim: Bool

        func makeBody(configuration: Configuration) -> some View { Body(configuration: configuration, dim: dim) }

        private struct Body: View {
            let configuration: Configuration
            let dim: Bool
            @Environment(\.isFocused) private var focused

            var body: some View {
                configuration.label
                    .font(.kumori(25, .semibold))
                    .foregroundStyle(dim ? Palette.blush.opacity(0.3) : (focused ? Palette.night : Palette.blush))
                    .padding(.horizontal, 22).padding(.vertical, 14)
                    .background(focused ? Palette.blush : Palette.blush.opacity(dim ? 0.03 : 0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .scaleEffect(focused ? 1.05 : 1)
                    .animation(Motion.focus, value: focused)
            }
        }
    }
}

/// A row that steps through a short list of values each time it is pressed.
private struct ChoiceRow: View {
    let label: String
    let value: String
    let next: () -> Void

    var body: some View {
        Button(action: next) {
            HStack {
                Text(label)
                Spacer()
                Text(value).opacity(0.7)
            }
        }
        .buttonStyle(RowButtonStyle())
    }
}

private struct GroupTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.kumori(19, .bold)).kerning(1.6).foregroundStyle(Palette.tertiary).padding(.leading, 28).padding(.top, 14)
    }
}

struct SettingsView: View {
    private enum Page: Int, CaseIterable {
        case stream, account, about

        var label: String {
            switch self {
            case .stream: return "Stream"
            case .account: return "Account"
            case .about: return "About"
            }
        }
    }

    @State private var page = Page.stream
    @State private var direction: CGFloat = 1
    @FocusState private var focusedPage: Page?
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            VStack(spacing: 8) {
                ForEach(Page.allCases, id: \.rawValue) { p in
                    Button { open(p) } label: { Text(p.label) }
                        .buttonStyle(RowButtonStyle())
                        .focused($focusedPage, equals: p)
                        .overlay(alignment: .leading) {
                            // Marks the open page while focus is in the page itself.
                            Capsule().fill(Palette.pink).frame(width: 5, height: 30).opacity(p == page && focusedPage == nil ? 1 : 0)
                                .animation(Motion.glide, value: page)
                        }
                }
            }
            .frame(width: 340)
            .focusSection()
            .reveal(0, dx: -24, dy: 0)
            // Moving down the list opens each page as it is passed, like the Android app.
            .onChange(of: focusedPage) { _, p in if let p { open(p) } }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch page {
                    case .stream: streamPage
                    case .account: accountPage
                    case .about: aboutPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 60)
                .id(page)
                // Pages move up and down like the list beside them. The old one leaves
                // quickly, the new one follows on a long ease-out.
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 46 * direction)).animation(Motion.arrive.delay(0.09)),
                    removal: .opacity.combined(with: .offset(y: -30 * direction)).animation(Motion.leave)
                ))
            }
            .focusSection()
        }
        .padding(.horizontal, 80).padding(.top, 30)
    }

    private func open(_ p: Page) {
        guard p != page else { return }
        direction = p.rawValue > page.rawValue ? 1 : -1
        withAnimation { page = p }
    }

    @ViewBuilder private var streamPage: some View {
        GroupTitle(text: "Resolution and frame rate").reveal(0)
        ModePicker(chosen: settings.mode, active: settings.mode, membership: app.membership) { settings.mode = $0 }
            .padding(.horizontal, 28).padding(.vertical, 10).reveal(1)
        if let last = settings.log4k.last {
            Text("Last 4K try: \(last)").font(.kumori(21)).foregroundStyle(Palette.tertiary).padding(.horizontal, 28).reveal(2)
        }
        if !settings.failedRoutes.isEmpty {
            ChoiceRow(label: "Try 4K from scratch", value: "") { settings.retry4k() }.reveal(2)
        }

        GroupTitle(text: "Picture").reveal(3)
        ChoiceRow(label: "Video codec", value: settings.codec.label) {
            settings.codec = CodecChoice.allCases[(CodecChoice.allCases.firstIndex(of: settings.codec)! + 1) % CodecChoice.allCases.count]
        }
        .reveal(4)
        ChoiceRow(label: "Bitrate", value: "\(settings.bitrateMbps) Mbps") {
            let i = Settings.bitrates.firstIndex(of: settings.bitrateMbps) ?? 0
            settings.bitrateMbps = Settings.bitrates[(i + 1) % Settings.bitrates.count]
        }
        .reveal(5)
        ChoiceRow(label: "Show stats while playing", value: settings.showStats ? "On" : "Off") { settings.showStats.toggle() }.reveal(6)

        if !app.regions.isEmpty {
            GroupTitle(text: "Server").reveal(7)
            ChoiceRow(label: "Location", value: settings.region.isEmpty ? "Automatic" : settings.region) {
                let names = [""] + app.regions.map(\.name)
                settings.region = names[((names.firstIndex(of: settings.region) ?? 0) + 1) % names.count]
            }
            .reveal(7)
        }
        Text("Automatic picks HEVC, which Apple TV decodes in hardware. H.264 is there if a game looks wrong.")
            .font(.kumori(21)).foregroundStyle(Palette.tertiary).padding(.horizontal, 28).padding(.top, 12).reveal(7)
    }

    @ViewBuilder private var accountPage: some View {
        GroupTitle(text: "Signed in as").reveal(0)
        VStack(alignment: .leading, spacing: 6) {
            Text(app.profile?.name ?? "Player").font(.kumori(36, .bold)).foregroundStyle(Palette.blush)
            if let email = app.profile?.email { Text(email).font(.kumori(24)).foregroundStyle(Palette.secondary) }
        }
        .padding(.horizontal, 28).padding(.vertical, 10).reveal(1)

        GroupTitle(text: "Membership").reveal(2)
        VStack(alignment: .leading, spacing: 6) {
            Text(app.membership?.tier ?? app.profile?.tier ?? "Unknown").font(.kumori(29, .semibold)).foregroundStyle(Palette.blush)
            if let best = app.membership?.modes.first {
                Text("Up to \(best.height >= 2160 ? "4K" : "\(best.height)p") at \(best.fps) fps").font(.kumori(24)).foregroundStyle(Palette.secondary)
            }
            if let m = app.membership, !m.unlimited, let h = m.hoursLeft {
                Text(String(format: "%.0f hours left this month", h)).font(.kumori(24)).foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 10).reveal(3)

        ChoiceRow(label: "Reload library", value: "") { Task { await app.load() } }.padding(.top, 14).reveal(4)
        ChoiceRow(label: "Sign out", value: "") { app.signOut() }.reveal(5)
    }

    @ViewBuilder private var aboutPage: some View {
        HStack(spacing: 28) {
            Image("Icon").resizable().frame(width: 130, height: 130).clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Image("Wordmark").resizable().scaledToFit().frame(height: 62)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.kumori(24)).foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 10).reveal(0)
        Text("Game streaming for your TV. Kumori plays your GeForce NOW library. It is not made by or connected to NVIDIA.")
            .font(.kumori(24)).foregroundStyle(Palette.secondary).frame(maxWidth: 900, alignment: .leading).padding(.horizontal, 28).reveal(1)
        GroupTitle(text: "This Apple TV").reveal(2)
        VStack(alignment: .leading, spacing: 6) {
            Text("Output \(Int(UIScreen.main.nativeBounds.width)) × \(Int(UIScreen.main.nativeBounds.height)) at \(UIScreen.main.maximumFramesPerSecond) Hz")
            Text("Hardware decoders: \(HardwareDecoders.names.sorted().joined(separator: ", "))")
        }
        .font(.kumori(24)).foregroundStyle(Palette.secondary).padding(.horizontal, 28).padding(.vertical, 10).reveal(3)
    }
}
