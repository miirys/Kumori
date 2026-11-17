import SwiftUI

// MARK: Resolution and refresh rate

/// Resolution and refresh rate as one row of modes that scrolls sideways, smallest to
/// largest, with the focused one kept in the middle. The mode in use is marked, and modes
/// this Apple TV or the membership can't play are dimmed with the reason underneath.
struct ModeScroller: View {
    /// What Settings asks for.
    let chosen: StreamMode
    /// What is in use: the stream on screen, or the saved choice when nothing is playing.
    let active: StreamMode
    let membership: Membership?
    let pick: (StreamMode) -> Void

    @FocusState private var focused: String?
    @State private var shaking: String?

    var body: some View {
        let note = focusedNote
        VStack(alignment: .leading, spacing: 14) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(StreamMode.all) { mode in
                            let verdict = Capabilities.check(mode, membership: membership)
                            ModeChip(
                                mode: mode,
                                state: mode == active ? .current : (verdict.blocked ? .blocked : (mode == chosen ? .asked : .open)),
                                shake: shaking == mode.id
                            ) {
                                if verdict.blocked {
                                    shaking = mode.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if shaking == mode.id { shaking = nil } }
                                } else {
                                    pick(mode)
                                }
                            }
                            .focused($focused, equals: mode.id)
                            .id(mode.id)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 26)
                }
                .scrollClipDisabled()
                .onAppear { proxy.scrollTo(active.id, anchor: .center) }
                .onChange(of: focused) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.glide) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .focusSection()
            .defaultFocus($focused, active.id)

            Group {
                if let note {
                    Text(note).id(note).transition(.opacity.combined(with: .offset(y: 8)))
                } else {
                    Text(" ")
                }
            }
            .font(.kumori(22)).foregroundStyle(Palette.tertiary)
            .padding(.horizontal, 30)
            .animation(Motion.snappy, value: note)
        }
    }

    private var focusedNote: String? {
        let mode = focused.flatMap { id in StreamMode.all.first { $0.id == id } } ?? chosen
        if mode == chosen, chosen != active { return "\(chosen.label) was asked for. GeForce NOW sent \(active.label). Press it to ask again." }
        if mode == active { return "Playing at \(mode.label)." }
        return Capabilities.check(mode, membership: membership).note
    }
}

private struct ModeChip: View {
    enum Kind { case open, current, asked, blocked }

    let mode: StreamMode
    let state: Kind
    let shake: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(mode.resolution.label)@\(mode.fps)")
                .font(.kumori(32, .bold))
                .monospacedDigit()
                .frame(width: 210, height: 96)
        }
        .buttonStyle(ChipStyle(state: state))
        .offset(x: shake ? 10 : 0)
        .animation(shake ? .spring(response: 0.08, dampingFraction: 0.2).repeatCount(3) : Motion.snappy, value: shake)
    }

    private struct ChipStyle: ButtonStyle {
        let state: Kind

        func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, state: state) }

        private struct Face: View {
            let configuration: Configuration
            let state: Kind
            @Environment(\.isFocused) private var focused

            var body: some View {
                let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
                configuration.label
                    .foregroundStyle(focused ? Palette.night : Palette.blush.opacity(state == .blocked ? 0.35 : 1))
                    .background { shape.fill(focused ? Palette.blush : (state == .current ? Palette.pink.opacity(0.28) : .clear)) }
                    .glass(shape)
                    .overlay(alignment: .topTrailing) { badge.padding(10) }
                    .overlay(shape.strokeBorder(state == .current && !focused ? Palette.pink : .clear, lineWidth: 3))
                    .shadow(color: focused ? Palette.pink.opacity(0.4) : .clear, radius: 24, y: 12)
                    .scaleEffect(configuration.isPressed ? 0.96 : (focused ? 1.12 : (state == .blocked ? 0.94 : 1)))
                    .animation(Motion.focus, value: focused)
                    .animation(Motion.press, value: configuration.isPressed)
            }

            @ViewBuilder private var badge: some View {
                switch state {
                case .current: Image(systemName: "checkmark.circle.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(focused ? Palette.night : Palette.pink)
                case .asked: Image(systemName: "clock.arrow.circlepath").font(.system(size: 20, weight: .bold)).foregroundStyle(focused ? Palette.night : Palette.blush)
                case .blocked: Image(systemName: "lock.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(focused ? Palette.night : Palette.tertiary)
                case .open: EmptyView()
                }
            }
        }
    }
}

// MARK: Building blocks

/// A row that opens a list of choices underneath it, like a drop-down menu. Picking one
/// closes it; so do Back and moving focus away.
struct Dropdown<Value: Hashable>: View {
    let label: String
    var icon: String?
    let options: [Value]
    let title: (Value) -> String
    var detail: ((Value) -> String?)?
    @Binding var selection: Value

    @State private var open = false
    @FocusState private var focus: Slot?

    private enum Slot: Hashable {
        case header
        case option(Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                toggle()
            } label: {
                HStack(spacing: 18) {
                    if let icon { Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 34) }
                    Text(label)
                    Spacer()
                    Text(title(selection)).opacity(0.72)
                        .id(title(selection))
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity.combined(with: .offset(y: -10))))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .opacity(0.7)
                }
            }
            .buttonStyle(RowButtonStyle())
            .focused($focus, equals: .header)

            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                        Button {
                            withAnimation(Motion.snappy) { selection = o }
                            close(refocus: true)
                        } label: {
                            HStack(alignment: .center, spacing: 16) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 22, weight: .bold))
                                    .opacity(o == selection ? 1 : 0)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(o))
                                    if let d = detail?(o) {
                                        Text(d).font(.kumori(20)).opacity(0.65).lineLimit(2)
                                    }
                                }
                            }
                            .padding(.vertical, detail == nil ? 0 : 10)
                        }
                        .buttonStyle(RowButtonStyle())
                        .focused($focus, equals: .option(i))
                        .reveal(min(i, 6), dy: -10)
                    }
                }
                .padding(12)
                .glassCard(30)
                .padding(.leading, 40)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top)).combined(with: .offset(y: -16)),
                    removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                ))
                .onExitCommand { close(refocus: true) }
            }
        }
        .focusSection()
        .onChange(of: focus) { _, now in
            // Focus moved out of the list (up past the row, or down out of the options).
            if open, now == nil { close(refocus: false) }
        }
    }

    private func toggle() {
        if open {
            close(refocus: true)
            return
        }
        withAnimation(Motion.glide) { open = true }
        let index = options.firstIndex(of: selection) ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .option(index) }
    }

    private func close(refocus: Bool) {
        withAnimation(Motion.snappy) { open = false }
        if refocus { focus = .header }
    }
}

/// A switch that sits at the end of a row.
struct GlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(Motion.snappy) { configuration.isOn.toggle() }
        } label: {
            HStack {
                configuration.label
                Spacer()
                Knob(on: configuration.isOn)
            }
        }
    }

    private struct Knob: View {
        let on: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Palette.pink : Palette.blush.opacity(focused ? 0.0 : 0.16))
                    .overlay(Capsule().strokeBorder(focused ? Palette.night.opacity(0.35) : .clear, lineWidth: 2))
                Circle().fill(on || !focused ? Palette.blush : Palette.night).padding(5).shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
            .frame(width: 76, height: 42)
            .animation(Motion.focus, value: on)
        }
    }
}

/// A row for an action, with an optional value at the end.
private struct ActionRow: View {
    let icon: String
    let label: String
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 34)
                Text(label)
                Spacer()
                if let value { Text(value).opacity(0.7) }
            }
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// A titled glass panel that holds a group of rows.
private struct Panel<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: title).padding(.leading, 30)
            VStack(alignment: .leading, spacing: 4) { content }
                .toggleStyle(GlassToggleStyle())
                .buttonStyle(RowButtonStyle())
                .padding(12)
                .glassCard(34)
            if let footnote {
                Text(footnote).font(.kumori(21)).foregroundStyle(Palette.tertiary).padding(.horizontal, 30).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: The Settings screen

struct SettingsView: View {
    private enum Page: Int, CaseIterable {
        case stream, picture, account, about

        var label: String {
            switch self {
            case .stream: return "Stream"
            case .picture: return "DLSS"
            case .account: return "Account"
            case .about: return "About"
            }
        }

        var icon: String {
            switch self {
            case .stream: return "play.tv.fill"
            case .picture: return "wand.and.stars"
            case .account: return "person.crop.circle.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    @State private var page = Page.stream
    @State private var direction: CGFloat = 1
    @FocusState private var focusedPage: Page?
    @Namespace private var pill
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 56) {
            VStack(spacing: 8) {
                ForEach(Page.allCases, id: \.rawValue) { p in
                    Button { open(p) } label: {
                        HStack(spacing: 16) {
                            Image(systemName: p.icon).font(.system(size: 24, weight: .semibold)).frame(width: 34)
                            Text(p.label)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                    .focused($focusedPage, equals: p)
                    .background {
                        if p == page {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(Palette.pink.opacity(focusedPage == nil ? 0.26 : 0.12))
                                .matchedGeometryEffect(id: "page", in: pill)
                        }
                    }
                }
            }
            .padding(14)
            .glassCard(36)
            .frame(width: 380)
            .focusSection()
            .reveal(0, dx: -30, dy: 0)
            // Moving down the list opens each page as it is passed, like the Android app.
            .onChange(of: focusedPage) { _, p in if let p { open(p) } }

            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    switch page {
                    case .stream: streamPage
                    case .picture: dlssPage
                    case .account: accountPage
                    case .about: aboutPage
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 80)
                .padding(.top, 4)
                .id(page)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 60 * direction)).animation(Motion.arrive.delay(0.06)),
                    removal: .opacity.combined(with: .offset(y: -36 * direction)).animation(Motion.leave)
                ))
            }
            .scrollClipDisabled()
            .focusSection()
        }
        .padding(.horizontal, 80).padding(.top, 30)
    }

    private func open(_ p: Page) {
        guard p != page else { return }
        direction = p.rawValue > page.rawValue ? 1 : -1
        withAnimation(Motion.glide) { page = p }
    }

    // MARK: Pages

    @ViewBuilder private var streamPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Resolution").padding(.leading, 30)
            ModeScroller(chosen: settings.mode, active: settings.mode, membership: app.membership) { m in
                withAnimation(Motion.snappy) { settings.mode = m }
            }
            .glassCard(38)
        }
        .reveal(0)

        if let last = settings.log4k.last {
            Panel(title: "4K", footnote: "Last 4K try: \(last)") {
                if !settings.failedRoutes.isEmpty {
                    ActionRow(icon: "arrow.counterclockwise", label: "Try 4K from scratch") { settings.retry4k() }
                }
            }
            .reveal(1)
        }

        Panel(title: "Picture", footnote: "Automatic picks AV1 where this Apple TV decodes it in hardware, then HEVC. H.264 is there if a game looks wrong.") {
            Dropdown(label: "Video codec", icon: "film.stack", options: CodecChoice.allCases, title: \.label, detail: { $0.detail }, selection: $settings.codec)
            Dropdown(label: "Bitrate", icon: "speedometer", options: Settings.bitrates, title: { "\($0) Mbps" }, detail: { Self.bitrateNote($0) }, selection: $settings.bitrateMbps)
            Toggle(isOn: $settings.showStats) { label("chart.bar.xaxis", "Show stats while playing") }
        }
        .reveal(2)

        if !app.regions.isEmpty {
            Panel(title: "Server") {
                Dropdown(label: "Location", icon: "globe.europe.africa.fill", options: [""] + app.regions.map(\.name), title: { $0.isEmpty ? "Automatic" : $0 }, selection: $settings.region)
            }
            .reveal(3)
        }
    }

    @ViewBuilder private var dlssPage: some View {
        Panel(title: "DLSS", footnote: "The cloud rig forces these on games that have DLSS turned on, from the next game you start. Ray Reconstruction needs Performance or Ultimate, and dynamic frame generation needs an Ultimate RTX 5080 rig.") {
            Dropdown(label: "Model", icon: "cpu", options: DlssModel.allCases, title: \.label, selection: $settings.dlssModel)
            Dropdown(label: "Quality", icon: "dial.medium", options: DlssQuality.allCases, title: \.label, selection: $settings.dlssQuality)
            Dropdown(label: "Ray Reconstruction", icon: "light.max", options: [false, true], title: { $0 ? "Recommended model" : "Game's choice" }, selection: $settings.dlssRays)
            Dropdown(label: "Frame generation", icon: "square.stack.3d.up.fill", options: DlssFrames.allCases, title: \.label, selection: $settings.dlssFrames)
        }
        .reveal(0)
    }

    @ViewBuilder private var accountPage: some View {
        HStack(spacing: 28) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Palette.pink, Palette.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(String((app.profile?.name ?? "P").prefix(1)).uppercased()).font(.kumori(52, .bold)).foregroundStyle(Palette.blush)
            }
            .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.profile?.name ?? "Player").font(.kumori(40, .bold)).foregroundStyle(Palette.blush)
                if let email = app.profile?.email { Text(email).font(.kumori(24)).foregroundStyle(Palette.secondary) }
            }
            Spacer()
        }
        .padding(30)
        .glassCard(38)
        .reveal(0)

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Membership").padding(.leading, 30)
            VStack(alignment: .leading, spacing: 8) {
                Text(app.membership?.tier ?? app.profile?.tier ?? "Unknown").font(.kumori(32, .bold)).foregroundStyle(Palette.blush)
                if let best = app.membership?.modes.first {
                    Text("Up to \(best.height >= 2160 ? "4K" : "\(best.height)p") at \(best.fps) fps").font(.kumori(24)).foregroundStyle(Palette.secondary)
                }
                if let m = app.membership, !m.unlimited, let h = m.hoursLeft {
                    Text(String(format: "%.0f hours left this month", h)).font(.kumori(24)).foregroundStyle(Palette.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(30)
            .glassCard(34)
        }
        .reveal(1)

        Panel(title: "Account") {
            ActionRow(icon: "arrow.clockwise", label: "Reload library") { Task { await app.load() } }
            ActionRow(icon: "rectangle.portrait.and.arrow.right", label: "Sign out") { app.signOut() }
        }
        .reveal(2)
    }

    @ViewBuilder private var aboutPage: some View {
        HStack(spacing: 28) {
            Image("Icon").resizable().frame(width: 130, height: 130).clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Image("Wordmark").resizable().scaledToFit().frame(height: 62)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.kumori(24)).foregroundStyle(Palette.secondary)
            }
            Spacer()
        }
        .padding(30)
        .glassCard(38)
        .reveal(0)

        Text("Game streaming for your TV. Kumori plays your GeForce NOW library. It is not made by or connected to NVIDIA.")
            .font(.kumori(24)).foregroundStyle(Palette.secondary).frame(maxWidth: 900, alignment: .leading).padding(.horizontal, 30).reveal(1)

        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "This Apple TV").padding(.leading, 30)
            VStack(alignment: .leading, spacing: 10) {
                info("Output", "\(Int(UIScreen.main.nativeBounds.width)) × \(Int(UIScreen.main.nativeBounds.height)) at \(UIScreen.main.maximumFramesPerSecond) Hz")
                info("Hardware decoders", HardwareDecoders.describe)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(30)
            .glassCard(34)
        }
        .reveal(2)
    }

    private func label(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 24, weight: .semibold)).frame(width: 34)
            Text(text)
        }
    }

    private func info(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(Palette.secondary)
            Spacer()
            Text(value).foregroundStyle(Palette.blush)
        }
        .font(.kumori(24))
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
