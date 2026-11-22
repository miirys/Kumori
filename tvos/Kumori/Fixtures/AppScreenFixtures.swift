#if DEBUG
import SwiftUI

/// The real app screens (RootView, Browse, SettingsView, StreamView) with the real models,
/// seeded from `CatalogueFixtures`. Fixtures named `app-…` show these, so CI can photograph
/// every screen a person sees without an account, a network or an Apple TV.
///
/// Nothing here draws its own UI: each case builds the same view the app shows and only
/// decides what the models hold.
@MainActor
struct AppScreenFixture: View {
    let name: String
    @StateObject private var settings: Settings
    @StateObject private var app: AppModel
    @StateObject private var player: Player
    @StateObject private var controllers = ControllerCenter()

    static var all: [String] { AppScreenNames.all }


    init(name: String) {
        self.name = name
        let settings = Settings()
        let app = AppModel()
        let player = Player(app: app, settings: settings)
        Self.seed(name, settings: settings, app: app, player: player)
        _settings = StateObject(wrappedValue: settings)
        _app = StateObject(wrappedValue: app)
        _player = StateObject(wrappedValue: player)
    }

    var body: some View {
        screen
            .environmentObject(settings)
            .environmentObject(app)
            .environmentObject(player)
            .environmentObject(controllers)
    }

    @ViewBuilder private var screen: some View {
        switch name {
        case "app-splash": ZStack { TVColor.canvas.ignoresSafeArea(); Splash() }
        case "app-signin", "app-signin-waiting", "app-signin-declined": SignInView()
        case "app-home", "app-home-running", "app-home-loading", "app-home-empty", "app-home-error":
            MainView(tab: .home)
        case "app-library", "app-library-empty": MainView(tab: .library)
        case "app-search": MainView(tab: .search, searchText: "lantern")
        case "app-search-start": MainView(tab: .search)
        case "app-search-none": MainView(tab: .search, searchText: "zephyr")
        case "app-search-error": MainView(tab: .search, searchText: "hollow")
        case "app-detail": detail("fx-lanternfall")
        case "app-detail-running": detail("fx-tidebreaker")
        case "app-detail-long": detail("fx-long-title")
        case "app-settings": MainView(tab: .settings)
        case "app-settings-stream": MainView(tab: .settings, settingsPath: [.stream])
        case "app-settings-mode": MainView(tab: .settings, settingsPath: [.stream, .mode])
        case "app-settings-codec": MainView(tab: .settings, settingsPath: [.stream, .codec])
        case "app-settings-dlss": MainView(tab: .settings, settingsPath: [.dlss])
        case "app-settings-account": MainView(tab: .settings, settingsPath: [.account])
        case "app-settings-about": MainView(tab: .settings, settingsPath: [.about])
        case "app-settings-controllers": MainView(tab: .settings, settingsPath: [.controllers])
        case "app-settings-debug": MainView(tab: .settings, settingsPath: [.debug])
        default:
            // The stream screens: the overlay over a stand-in for the video.
            ZStack {
                Color.black.ignoresSafeArea()
                if player.phase == .live, let g = player.game {
                    TVArtwork(source: g.tvHero, title: "", titleOnPlaceholder: false, fill: true)
                        .ignoresSafeArea()
                }
                StreamOverlay()
            }
        }
    }

    @ViewBuilder private func detail(_ id: String) -> some View {
        if let g = CatalogueFixtures.game(id: id) {
            DetailView(game: g) {}
        }
    }

    // MARK: Seeding

    private static let membership = Membership(
        tier: "Ultimate",
        modes: [AllowedMode(width: 3840, height: 2160, fps: 120), AllowedMode(width: 2560, height: 1440, fps: 120)],
        hoursLeft: 86, unlimited: false
    )

    private static let regions = [
        Region(name: "US West", url: "https://us-west.example.invalid"),
        Region(name: "US Central", url: "https://us-central.example.invalid"),
        Region(name: "Europe West", url: "https://eu-west.example.invalid"),
    ]

    private static let challenge = DeviceChallenge(
        deviceCode: "fixture-device-code", userCode: "KMRI7Q4X",
        verificationUri: "https://login.example.com/device",
        verificationUriComplete: "https://login.example.com/device?code=KMRI7Q4X",
        interval: 5, expiresAt: CatalogueFixtures.now.addingTimeInterval(600)
    )

    private static func session(_ appId: String) -> ActiveSession {
        ActiveSession(sessionId: "fx-session-\(appId)", appId: appId, base: "https://example.invalid", host: nil)
    }

    private static func seed(_ name: String, settings: Settings, app: AppModel, player: Player) {
        settings.mode = StreamMode(resolution: .qhd, fps: 60)
        settings.codec = .auto
        settings.bitrateMbps = 50
        settings.region = ""
        settings.showStats = name == "app-stream-live"
        settings.dlssModel = .recommended
        settings.dlssQuality = .quality
        settings.dlssRays = false
        settings.dlssFrames = .game

        var s = AppModel.FixtureState()
        s.profile = CatalogueFixtures.profile
        s.membership = membership
        s.library = CatalogueFixtures.games
        s.shelves = CatalogueFixtures.shelves
        s.regions = regions

        switch name {
        case "app-splash":
            s.loading = true
            s.signedIn = false
        case "app-signin":
            s.signedIn = false
            s.challenge = challenge
        case "app-signin-waiting":
            s.signedIn = false
        case "app-signin-declined":
            s.signedIn = false
            s.challenge = challenge
            s.signInNote = "The sign-in was declined. Here is a new code."
        case "app-home-running", "app-detail-running", "app-library":
            s.sessions = [session("fx-tidebreaker")]
        case "app-home-loading":
            s.loaded = false
            s.library = []
            s.shelves = []
        case "app-home-empty", "app-library-empty":
            s.library = []
            s.shelves = []
        case "app-home-error":
            s.loaded = false
            s.library = []
            s.shelves = []
            s.problem = "The request timed out."
        case "app-search-error":
            s.searchFails = true
        default:
            break
        }
        app.applyFixture(s)

        let game = CatalogueFixtures.game(id: "fx-lanternfall")
        switch name {
        case "app-stream-starting":
            player.applyFixture(phase: .starting("Asking GeForce NOW for a rig"), game: game)
        case "app-stream-queued":
            player.applyFixture(phase: .queued(7), game: game)
        case "app-stream-connecting":
            player.applyFixture(phase: .connecting("Waiting for the first picture"), game: game)
        case "app-stream-live":
            var stats = StreamStats()
            stats.width = 2560
            stats.height = 1440
            stats.fps = 59.9
            stats.codec = "AV1"
            stats.bitrateMbps = 38.4
            stats.rttMs = 21
            stats.decodeMs = 3.2
            player.applyFixture(phase: .live, game: game, stats: stats,
                                notice: "Playing at 1440p at 60 fps, the most your Performance membership includes.", liveFor: 1_560)
        case "app-stream-menu":
            player.applyFixture(phase: .live, game: game, menuOpen: true, liveFor: 2_700)
        case "app-stream-ended":
            player.applyFixture(phase: .ended("You played for 45 minutes. Lanternfall is closed on GeForce NOW.", error: false), game: game)
        case "app-stream-error":
            player.applyFixture(phase: .ended("The connection to the rig dropped and didn\u{2019}t come back. Your game may still be running in the cloud.", error: true), game: game)
        case "app-settings-debug":
            var last = StreamStats()
            last.width = 2560
            last.height = 1440
            last.fps = 59.9
            last.codec = "H265"
            last.bitrateMbps = 44.6
            last.rttMs = 19
            last.lossPct = 0.04
            last.decodeMs = 2.8
            last.framesDecoded = 184_212
            last.packetsReceived = 1_402_377
            var input = InputStats()
            input.version = 3
            input.sent = 52_118
            input.early = 12
            player.applyFixture(phase: nil, game: nil, lastStats: last, lastInput: input)
        default:
            break
        }
    }
}

/// The `app-…` fixture names, outside the main actor so the router's list can use them.
enum AppScreenNames {
    static let all = [
        "app-splash", "app-signin", "app-signin-waiting", "app-signin-declined",
        "app-home", "app-home-running", "app-home-loading", "app-home-empty", "app-home-error",
        "app-library", "app-library-empty",
        "app-search", "app-search-start", "app-search-none", "app-search-error",
        "app-detail", "app-detail-running", "app-detail-long",
        "app-settings", "app-settings-stream", "app-settings-mode", "app-settings-codec",
        "app-settings-dlss", "app-settings-account", "app-settings-about", "app-settings-controllers",
        "app-settings-debug",
        "app-stream-starting", "app-stream-queued", "app-stream-connecting",
        "app-stream-live", "app-stream-menu", "app-stream-ended", "app-stream-error",
    ]
}
#endif
