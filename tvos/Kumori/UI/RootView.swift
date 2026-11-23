import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @Environment(\.tvReduceMotion) private var reduced

    var body: some View {
        ZStack {
            TVColor.canvas.ignoresSafeArea()
            if app.loading {
                Splash().transition(.opacity)
            } else if app.signedIn {
                MainView().transition(.opacity)
            } else {
                SignInView().transition(.opacity)
            }
        }
        // One quiet cross-fade between the three states. No zoom.
        .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: 0.25), value: app.loading)
        .animation(reduced ? TVMotion.reducedFade : .easeInOut(duration: 0.25), value: app.signedIn)
        .task { await app.start() }
        .onChange(of: player.active) { _, active in
            if active { StreamPresenter.show(player: player, settings: settings, app: app) } else { StreamPresenter.hide() }
        }
    }
}

/// The four places in the app, on the system tab bar so the Siri Remote works as people expect.
struct MainView: View {
    enum Tab: Hashable { case home, library, search, settings }

    @State private var tab: Tab
    @State private var detail: Game?
    /// The tile or hero the open game's page grew out of. It outlasts the page by a moment,
    /// so that tile stays open while focus finds its way back to it.
    @State private var detailSource: String?
    /// The open game's picture, drawn here under its page so it grows out of the tile.
    @State private var gameStage: GamePageStage?
    /// Stands in for the page's stage while no page is open, so the screen's depth modifier
    /// always has one to watch and the tabs keep their identity.
    @StateObject private var idleStage = GamePageStage(game: Game.placeholder, origin: nil)
    /// The last page is still being dismissed.
    @State private var closing = false
    /// The column focus is in on each page, so Up and Down go straight up and down.
    @State private var homeColumn = TVShelfColumn()
    @State private var libraryColumn = TVShelfColumn()
    @State private var searchColumn = TVShelfColumn()
    /// Every tile's place on screen, for the page to grow from.
    @State private var zoomSources = TVZoomSources()
    /// The blurred art behind every tab: the game that last had focus.
    @StateObject private var ambient = TVAmbient()
    @EnvironmentObject private var app: AppModel
    /// Where Search and Settings start. Only fixtures set these.
    private let searchText: String
    private let settingsPath: [SettingsRoute]

    init(tab: Tab = .home, searchText: String = "", settingsPath: [SettingsRoute] = []) {
        _tab = State(initialValue: tab)
        self.searchText = searchText
        self.settingsPath = settingsPath
    }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(ambient: ambient)
            // Settings sits on black with drifting light instead of a game's art.
            TVGlowBackdrop(visible: tab == .settings)
            tabs
                // The screen behind sinks back as a game's page grows over it, and comes
                // forward again as the page leaves, so opening and closing read as one motion
                // in depth rather than a picture sliding over a still screen.
                .modifier(StageDepth(stage: gameStage ?? idleStage))
            if let gameStage { GamePageStageView(stage: gameStage) }
        }
        .environment(\.tvAmbient, ambient)
        // Something to show from the first frame, before anything has focus, and once the
        // library arrives.
        .onAppear(perform: seedAmbient)
        .onChange(of: app.loaded) { _, _ in seedAmbient() }
    }

    private func seedAmbient() {
        guard ambient.source == .missing else { return }
        let running = app.sessions.first.flatMap { app.game(for: $0) }
        let first: Game? = running ?? app.recent.first ?? app.shelves.first?.games.first ?? app.library.first
        if let first { ambient.set(first.tvHero) }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            HomeView(open: open, browse: { tab = .search })
                .environment(\.tvShelfColumn, homeColumn)
                .tvTabEntrance(active: tab == .home)
                .tabItem { Text("Home") }.tag(Tab.home)
            LibraryView(open: open, browse: { tab = .search })
                .environment(\.tvShelfColumn, libraryColumn)
                .tvTabEntrance(active: tab == .library)
                .tabItem { Text("Library") }.tag(Tab.library)
            SearchView(open: open, initialText: searchText)
                .environment(\.tvShelfColumn, searchColumn)
                .tvTabEntrance(active: tab == .search)
                .tabItem { Text("Search") }.tag(Tab.search)
            SettingsView(path: settingsPath)
                .tvTabEntrance(active: tab == .settings)
                .tabItem { Text("Settings") }.tag(Tab.settings)
        }
        .environment(\.tvZoomSources, zoomSources)
        .environment(\.tvZoomHeldSource, detailSource)
        .fullScreenCover(item: $detail) { g in
            // The page draws its own arrival: it grows out of the tile that opened it, over
            // this screen, and shrinks back into that tile on Back. So the cover itself is
            // clear and comes and goes without the system's animation.
            DetailView(game: g, stage: gameStage) { closeDetail() }
                .presentationBackground(.clear)
        }
    }

    private func open(_ g: Game, from source: String) {
        // A page still closing can't be replaced yet: presenting while the last one is being
        // dismissed is dropped by the system, which left only the picture on screen, no words,
        // and nothing to press Back on.
        guard detail == nil, gameStage == nil, !closing else { return }
        let stage = GamePageStage(game: g, origin: zoomSources.sources[source])
        withTransaction(\.disablesAnimations, true) {
            detailSource = source
            gameStage = stage
            detail = g
        }
        // Backstop: if the page still hasn't come up, take its picture away again.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard gameStage === stage, !stage.presented else { return }
            withTransaction(\.disablesAnimations, true) {
                detail = nil
                gameStage = nil
            }
        }
    }

    private func closeDetail() {
        withTransaction(\.disablesAnimations, true) {
            detail = nil
            gameStage = nil
        }
        closing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            closing = false
        }
        // Let focus land back on the tile before it may close.
        let source = detailSource
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if detail == nil, detailSource == source { detailSource = nil }
        }
    }
}

/// The wordmark, still, while the saved sign-in is checked. It is on screen for a moment, so
/// it doesn't perform.
struct Splash: View {
    var body: some View {
        Image("Wordmark")
            .resizable()
            .scaledToFit()
            .frame(width: 420)
            .accessibilityLabel("Kumori")
    }
}

/// Device-code sign-in: instructions and the code on the left, the QR code on the right.
/// Both columns have their final size from the first frame, so nothing moves when the code
/// arrives.
struct SignInView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.tvReduceMotion) private var reduced

    private static let qrSide: CGFloat = 400

    var body: some View {
        HStack(alignment: .center, spacing: 120) {
            VStack(alignment: .leading, spacing: TVTokens.group) {
                Image("Wordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, alignment: .leading)
                    .accessibilityLabel("Kumori")
                Text("Sign in to GeForce NOW")
                    .font(TVType.title)
                    .foregroundStyle(TVColor.primary)
                    .accessibilityAddTraits(.isHeader)
                Text("Scan the code, or enter it at the address below.")
                    .font(TVType.body)
                    .foregroundStyle(TVColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                codeBox.padding(.top, TVTokens.medium)
                Text(app.signInNote ?? " ")
                    .font(TVType.callout)
                    .foregroundStyle(TVColor.secondary)
                    .lineLimit(2)
                    .opacity(app.signInNote == nil ? 0 : 1)
                Button { app.beginSignIn() } label: { Label("Get a New Code", systemImage: "arrow.clockwise") }
                    .accessibilityIdentifier("signin-new-code")
            }
            .frame(width: 860, alignment: .leading)

            VStack(spacing: TVTokens.medium) {
                qr
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, TVTokens.safeX)
        .animation(reduced ? nil : TVMotion.artFade, value: app.challenge?.userCode)
        .onAppear { app.beginSignIn() }
    }

    /// The address and code, in a box that keeps its size while the code is fetched.
    private var codeBox: some View {
        VStack(alignment: .leading, spacing: TVTokens.medium) {
            if let c = app.challenge {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Go to").font(TVType.detail).foregroundStyle(TVColor.tertiary)
                    Text(c.verificationUri.replacingOccurrences(of: "https://", with: ""))
                        .font(TVType.shelf)
                        .foregroundStyle(TVColor.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter code").font(TVType.detail).foregroundStyle(TVColor.tertiary)
                    Text(Self.spaced(c.userCode))
                        .font(TVType.hero.monospaced())
                        .foregroundStyle(TVColor.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityLabel(c.userCode.map(String.init).joined(separator: " "))
                }
            } else {
                HStack(spacing: TVTokens.group) {
                    ProgressView()
                    Text("Getting a sign-in code\u{2026}")
                        .font(TVType.body)
                        .foregroundStyle(TVColor.secondary)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 32)
        .frame(width: 860, height: 260, alignment: .leading)
        .tvSurface(.grouped)
    }

    @ViewBuilder private var qr: some View {
        let shape = RoundedRectangle(cornerRadius: TVTokens.panelRadius, style: .continuous)
        ZStack {
            if let c = app.challenge, let image = QRCode.image(c.verificationUriComplete) {
                shape.fill(Color.white)
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    // The quiet zone the scanner needs.
                    .padding(32)
                    .accessibilityLabel("QR code for signing in")
                    .transition(.opacity)
            } else {
                shape.fill(TVColor.placeholder)
            }
        }
        .frame(width: Self.qrSide, height: Self.qrSide)
    }

    /// "ABCD1234" as "ABCD 1234", easier to read across a room.
    static func spaced(_ code: String) -> String {
        guard code.count == 8, !code.contains(" "), !code.contains("-") else { return code }
        return String(code.prefix(4)) + " " + String(code.suffix(4))
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}


/// Scales and dims the screen under a game's page while the page's picture is up. A transform
/// and an opacity only, so it costs nothing to draw however much is on screen.
private struct StageDepth: ViewModifier {
    @ObservedObject var stage: GamePageStage
    @Environment(\.tvReduceMotion) private var reduced

    func body(content: Content) -> some View {
        let back = stage.grown && stage.shown && !reduced
        content
            .scaleEffect(back ? 0.93 : 1)
            .opacity(back ? 0.4 : 1)
    }
}
