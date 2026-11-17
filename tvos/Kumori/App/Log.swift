import Foundation
import os

/// Kumori's messages in the system log, under the subsystem app.kumori.tv. They carry
/// what the service answered, never sign-in tokens.
enum Log {
    private static let logger = Logger(subsystem: "app.kumori.tv", category: "app")

    static func info(_ text: String) { logger.notice("\(text, privacy: .public)") }
    static func error(_ text: String) { logger.error("\(text, privacy: .public)") }
}

/// Launch arguments for checking screens on a real Apple TV without a remote in hand.
enum Debug {
    private static let args = ProcessInfo.processInfo.arguments

    static func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: "-kumori.\(key)"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

import GameController

extension Log {
    private static var watching: [NSObjectProtocol] = []

    /// Notes every controller the Apple TV hands to the app, to tell a controller tvOS never
    /// connected from one the app ignores.
    static func watchControllers() {
        guard watching.isEmpty else { return }
        func describe(_ c: GCController) -> String {
            "\(c.vendorName ?? "unknown") (\(c.productCategory)) extended \(c.extendedGamepad != nil) micro \(c.microGamepad != nil)"
        }
        info("Controllers at start: \(GCController.controllers().map(describe))")
        let center = NotificationCenter.default
        watching = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
                if let c = n.object as? GCController { info("Controller connected: \(describe(c))") }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { n in
                if let c = n.object as? GCController { info("Controller disconnected: \(describe(c))") }
            },
        ]
    }
}
