import SwiftUI

@main
struct KumoriApp: App {
    @StateObject private var settings: Settings
    @StateObject private var app: AppModel
    @StateObject private var player: Player
    @StateObject private var controllers = ControllerCenter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = Settings()
        let app = AppModel()
        _settings = StateObject(wrappedValue: settings)
        _app = StateObject(wrappedValue: app)
        _player = StateObject(wrappedValue: Player(app: app, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Debug builds launched with -fixture show one synthetic screen instead of the app.
            // See Fixtures/FixtureRouter.swift. Release builds don't contain this branch.
            if let fixture = FixtureConfig.launched {
                FixtureRoot(config: fixture)
            } else {
                root
            }
            #else
            root
            #endif
        }
        // Pressing Home suspends the app, which would freeze the stream with the last
        // controller state still held on the rig. Leave cleanly instead; the game keeps
        // running in the cloud and shows up on Home to resume.
        .onChange(of: scenePhase) { _, now in
            if now == .background, player.active { player.background() }
        }
    }

    private var root: some View {
        RootView()
            .environmentObject(settings)
            .environmentObject(app)
            .environmentObject(player)
            .environmentObject(controllers)
            .preferredColorScheme(.dark)
    }
}
