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
