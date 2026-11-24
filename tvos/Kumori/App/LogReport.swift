import Foundation
import OSLog

/// One text file with everything needed to work out what went wrong: the build, the Apple
/// TV and its display chain, the settings, the last launch, the stream's numbers, the past
/// streams and Kumori's own log lines since it opened. No tokens, no addresses of the rig,
/// no email. Saved reports live in Caches/Reports, newest ten kept.
@MainActor
enum LogReport {
    struct Saved {
        let name: String
        let date: Date
        let bytes: Int
    }

    private static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func build(_ r: APIReport, withLog: Bool = true) -> String {
        var out: [String] = []
        func section(_ title: String, _ object: Any) {
            out.append("== \(title)")
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                out.append(String(decoding: data, as: UTF8.self))
            }
            out.append("")
        }
        out.append("Kumori report, \(APIReport.iso(Date()))")
        out.append("Build \(BuildInfo.current.display)")
        out.append("")
        section("Status", r.status)
        section("Stats", r.stats)
        section("Device and display chain", r.device)
        section("Settings", r.settingsJSON)
        section("Account", r.account.filter { $0.key != "name" })
        section("Input", r.input)
        if let t = r.player.trace {
            out.append("== Last launch")
            out.append(contentsOf: t.lines)
            out.append("")
        }
        section("Past streams", r.history)
        section("This stream, per second", r.statsHistory)
        if withLog { out.append(logSection(logLines())) }
        return out.joined(separator: "\n")
    }

    /// The log's section of the report.
    nonisolated static func logSection(_ lines: [String]) -> String {
        (["== Kumori log since it opened"] + lines).joined(separator: "\n")
    }

    /// Kumori's own os_log lines from this run, oldest first, at most the last 4000.
    /// Safe off the main thread.
    nonisolated static func logLines() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["(the system log can't be read here)"] }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        var lines: [String] = []
        do {
            // Filtered by the store itself rather than by walking every line the process logged.
            let entries = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", "app.kumori.tv"))
            for case let e as OSLogEntryLog in entries where e.subsystem == "app.kumori.tv" {
                lines.append("\(f.string(from: e.date)) [\(e.category)] \(e.composedMessage)")
            }
        } catch {
            return ["(the system log can't be read: \(error.localizedDescription))"]
        }
        return Array(lines.suffix(4000))
    }

    /// Builds a report and saves it. Returns its name.
    @discardableResult
    static func save(_ r: APIReport) -> Saved? {
        guard let folder else { return nil }
        let text = build(r)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "kumori-\(f.string(from: Date())).txt"
        let url = folder.appendingPathComponent(name)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        // Keep the newest ten.
        for old in saved().dropFirst(10) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.name)) }
        return Saved(name: name, date: Date(), bytes: text.utf8.count)
    }

    /// Saved reports, newest first.
    static func saved() -> [Saved] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { $0.hasPrefix("kumori-") && $0.hasSuffix(".txt") }.compactMap { name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            guard let date = attrs?[.modificationDate] as? Date else { return nil }
            return Saved(name: name, date: date, bytes: (attrs?[.size] as? Int) ?? 0)
        }.sorted { $0.date > $1.date }
    }

    static func read(_ name: String) -> String? {
        // Only names this app wrote, never a path.
        guard let folder, name.hasPrefix("kumori-"), name.hasSuffix(".txt"), !name.contains("/"), !name.contains("..") else { return nil }
        return try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }
}
