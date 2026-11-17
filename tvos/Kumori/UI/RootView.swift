import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings

    var body: some View {
        ZStack {
            Aurora(paused: player.active)
            if app.loading {
                Splash().transition(.opacity.combined(with: .scale(scale: 1.06)))
            } else if app.signedIn {
                MainView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                SignInView().transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(Motion.arrive, value: app.loading)
        .animation(Motion.arrive, value: app.signedIn)
        .task { await app.start() }
        .onChange(of: player.active) { _, active in
            if active { StreamPresenter.show(player: player, settings: settings, app: app) } else { StreamPresenter.hide() }
        }
    }
}

/// The four places in the app, on the system tab bar so the Siri Remote works as people expect.
struct MainView: View {
    private enum Tab: Hashable { case home, library, search, settings }
    @State private var tab = Tab.home
    @State private var detail: Game?
    @EnvironmentObject private var player: Player

    var body: some View {
        TabView(selection: $tab) {
            HomeView(open: open).tabItem { Label("Home", systemImage: "house.fill") }.tag(Tab.home)
            LibraryView(open: open).tabItem { Label("Library", systemImage: "square.grid.2x2.fill") }.tag(Tab.library)
            SearchView(open: open).tabItem { Label("Search", systemImage: "magnifyingglass") }.tag(Tab.search)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(Tab.settings)
        }
        .fullScreenCover(item: $detail) { g in
            DetailView(game: g) { detail = nil }
        }
    }

    private func open(_ g: Game) { detail = g }
}

/// The wordmark while the saved sign-in is checked, breathing gently.
private struct Splash: View {
    @State private var breathe = false

    var body: some View {
        Image("Wordmark").resizable().scaledToFit().frame(width: 440)
            .scaleEffect(breathe ? 1.03 : 0.98)
            .opacity(breathe ? 1 : 0.75)
            .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true } }
    }
}

struct SignInView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 80) {
            VStack(alignment: .leading, spacing: 24) {
                Image("Wordmark").resizable().scaledToFit().frame(width: 360).reveal(0)
                Text("Sign in with your NVIDIA account")
                    .font(.kumori(46, .bold)).foregroundStyle(Palette.blush).reveal(1)
                Text("Scan the code with your phone, or open the address on any device and type the code.")
                    .font(.kumori(27)).foregroundStyle(Palette.secondary).frame(maxWidth: 640, alignment: .leading).reveal(2)
                Group {
                    if let c = app.challenge {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(c.verificationUri.replacingOccurrences(of: "https://", with: ""))
                                .font(.kumori(30, .semibold)).foregroundStyle(Palette.pink)
                            Text(c.userCode).font(.system(size: 76, weight: .bold, design: .monospaced)).foregroundStyle(Palette.blush)
                                .contentTransition(.numericText())
                        }
                        .padding(.horizontal, 36).padding(.vertical, 28)
                        .glassCard(36)
                    } else {
                        Spinner(size: 60).padding(.top, 20)
                    }
                }
                .padding(.top, 10).reveal(3)
                if let note = app.signInNote {
                    Text(note).font(.kumori(24)).foregroundStyle(Palette.secondary).transition(.opacity)
                }
            }
            if let c = app.challenge, let qr = QRCode.image(c.verificationUriComplete) {
                Image(uiImage: qr)
                    .interpolation(.none).resizable().frame(width: 380, height: 380)
                    .padding(28).background(Palette.blush, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .padding(18)
                    .glassCard(50)
                    .reveal(2, dx: 40, dy: 0)
            }
        }
        .padding(90)
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
