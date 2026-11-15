import SwiftUI

@main
struct KumoriApp: App {
    @StateObject private var settings: Settings
    @StateObject private var app: AppModel
    @StateObject private var player: Player

    init() {
        let settings = Settings()
        let app = AppModel()
        _settings = StateObject(wrappedValue: settings)
        _app = StateObject(wrappedValue: app)
        _player = StateObject(wrappedValue: Player(app: app, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(app)
                .environmentObject(player)
                .preferredColorScheme(.dark)
        }
    }
}
