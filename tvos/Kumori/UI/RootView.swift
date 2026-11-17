import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @StateObject private var spotlight = Spotlight()

    var body: some View {
        ZStack {
            Backdrop(url: app.signedIn && !app.loading ? (spotlight.game?.hero ?? spotlight.game?.banner) : nil)
            if app.loading {
                Splash().transition(.opacity)
            } else if app.signedIn {
                MainView().transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                SignInView().transition(.opacity)
            }
        }
        .environmentObject(spotlight)
        .animation(Motion.arrive, value: app.loading)
        .animation(Motion.arrive, value: app.signedIn)
        .task { await app.start() }
        .onChange(of: app.library) { _, _ in spotlight.settle(app.recent.first ?? app.library.first) }
        .onChange(of: player.active) { _, active in
            if active { StreamPresenter.show(player: player, settings: settings, app: app) } else { StreamPresenter.hide() }
        }
    }
}

/// The four places in the app, on the system tab bar so the remote and controllers move
/// through it the way they do everywhere else on the Apple TV.
struct MainView: View {
    enum Tab: String, Hashable { case home, library, search, settings }
    @State private var tab = Tab(rawValue: Debug.value("tab") ?? "") ?? .home
    @State private var detail: Game?
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings
    @EnvironmentObject private var spotlight: Spotlight

    var body: some View {
        TabView(selection: $tab) {
            HomeView(open: open).tabItem { Label("Home", systemImage: "house.fill") }.tag(Tab.home)
            LibraryView(open: open).tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }.tag(Tab.library)
            SearchView(open: open).tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(Tab.settings)
        }
        .fullScreenCover(item: $detail) { g in
            DetailView(game: g) { detail = nil }
                .environmentObject(app)
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(spotlight)
        }
        .task(id: app.library.count) {
            // For checking screens on a real Apple TV: open a game's page or start it.
            guard let first = app.recent.first ?? app.library.first else { return }
            if Debug.value("detail") != nil, detail == nil { detail = first }
            if Debug.value("play") != nil, !player.active { player.play(first) }
        }
    }

    private func open(_ g: Game) { detail = g }
}

/// The wordmark while the saved sign-in is checked, breathing gently.
private struct Splash: View {
    @State private var shown = false
    @State private var breathe = false

    var body: some View {
        Image("Wordmark").resizable().scaledToFit().frame(width: 420)
            .opacity(shown ? (breathe ? 1 : 0.7) : 0)
            .scaleEffect(shown ? 1 : 0.94)
            .onAppear {
                withAnimation(Motion.arrive) { shown = true }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(0.7)) { breathe = true }
            }
    }
}

struct SignInView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 90) {
            VStack(alignment: .leading, spacing: 26) {
                Image("Wordmark").resizable().scaledToFit().frame(width: 340).reveal(0)
                Text("Sign in with your NVIDIA account")
                    .font(.kumori(52, .bold)).foregroundStyle(Palette.text).reveal(1)
                Text("Scan the code with your phone, or go to the address on any device and enter the code.")
                    .font(.kumori(28)).foregroundStyle(Palette.secondary).frame(maxWidth: 680, alignment: .leading).reveal(2)
                Group {
                    if let c = app.challenge {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(c.verificationUri.replacingOccurrences(of: "https://", with: ""))
                                .font(.kumori(30, .semibold)).foregroundStyle(Palette.secondary)
                            Text(c.userCode).font(.system(size: 80, weight: .bold, design: .monospaced)).foregroundStyle(Palette.text)
                                .contentTransition(.numericText())
                        }
                        .padding(.horizontal, 40).padding(.vertical, 30)
                        .glassCard(36)
                    } else {
                        Spinner(size: 56).padding(.top, 20)
                    }
                }
                .padding(.top, 10).reveal(3)
                if let note = app.signInNote {
                    Text(note).font(.kumori(24)).foregroundStyle(Palette.secondary).transition(.opacity)
                }
            }
            if let c = app.challenge, let qr = QRCode.image(c.verificationUriComplete) {
                Image(uiImage: qr)
                    .interpolation(.none).resizable().frame(width: 360, height: 360)
                    .padding(30).background(Color.white, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .reveal(2, dx: 40, dy: 0)
            }
        }
        .padding(Layout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.glide, value: app.challenge?.userCode)
        .onAppear { app.beginSignIn() }
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
