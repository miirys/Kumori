import Foundation

/// Which build is installed, so a report can be matched to the code it came from.
struct BuildInfo: Equatable {
    let version: String
    let build: String
    /// Short commit hash, or "dev" for a local build.
    let commit: String

    init(info: [String: Any]?) {
        version = (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        build = (info?["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        let raw = (info?["KumoriCommit"] as? String) ?? ""
        // An unexpanded build setting means a build outside CI.
        let clean = raw.hasPrefix("$(") || raw.isEmpty ? "dev" : raw
        commit = String(clean.prefix(7))
    }

    static let current = BuildInfo(info: Bundle.main.infoDictionary)

    /// "1.3.1 (10301) · 1a2b3c4"
    var display: String { "\(version) (\(build)) · \(commit)" }
}
