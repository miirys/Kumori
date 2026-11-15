import SwiftUI

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var settings: Settings

    var body: some View {
        ZStack {
            Palette.night.ignoresSafeArea()
            if app.loading {
                Image("Wordmark").resizable().scaledToFit().frame(width: 420).transition(.opacity)
            } else if app.signedIn {
                MainView().transition(.opacity)
            } else {
                SignInView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: app.loading)
        .animation(.easeInOut(duration: 0.35), value: app.signedIn)
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
            HomeView(open: open).tabItem { Text("Home") }.tag(Tab.home)
            LibraryView(open: open).tabItem { Text("Library") }.tag(Tab.library)
            SearchView(open: open).tabItem { Text("Search") }.tag(Tab.search)
            SettingsView().tabItem { Text("Settings") }.tag(Tab.settings)
        }
        .fullScreenCover(item: $detail) { g in
            DetailView(game: g) { detail = nil }
        }
    }

    private func open(_ g: Game) { detail = g }
}

struct SignInView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 90) {
            VStack(alignment: .leading, spacing: 22) {
                Image("Wordmark").resizable().scaledToFit().frame(width: 360).reveal(0)
                Text("Sign in with your NVIDIA account")
                    .font(.kumori(44, .bold)).foregroundStyle(Palette.blush).reveal(1)
                Text("Scan the code with your phone, or open the address on any device and type the code.")
                    .font(.kumori(27)).foregroundStyle(Palette.secondary).frame(maxWidth: 640, alignment: .leading).reveal(2)
                if let c = app.challenge {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(c.verificationUri.replacingOccurrences(of: "https://", with: ""))
                            .font(.kumori(30, .semibold)).foregroundStyle(Palette.pink)
                        Text(c.userCode).font(.system(size: 76, weight: .bold, design: .monospaced)).foregroundStyle(Palette.blush)
                    }
                    .padding(.top, 14).reveal(3)
                } else {
                    ProgressView().padding(.top, 20)
                }
                if let note = app.signInNote {
                    Text(note).font(.kumori(24)).foregroundStyle(Palette.secondary)
                }
            }
            if let c = app.challenge, let qr = QRCode.image(c.verificationUriComplete) {
                Image(uiImage: qr)
                    .interpolation(.none).resizable().frame(width: 380, height: 380)
                    .padding(26).background(Palette.blush, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                    .reveal(2, dx: 30, dy: 0)
            }
        }
        .padding(90)
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
