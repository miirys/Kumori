import Foundation

/// Settings › Debug › Region Ping: how far each GeForce NOW region is from this Apple TV.
///
/// Each region's address is asked for its server info, with no sign-in, over one kept-open
/// connection. The first answer pays for the connection and TLS, so it is left out; the
/// fastest of the next three is the region's round trip. The answer itself is not read, so
/// a refusal times the same as a reply. Nothing here touches the account or a session.
@MainActor
final class RegionPing: ObservableObject {
    enum Result: Equatable {
        case waiting
        case ms(Double)
        case failed
    }

    struct Row: Identifiable, Equatable {
        let name: String
        let url: String
        var result: Result
        var id: String { url }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var running = false
    private var job: Task<Void, Never>?

    /// Fastest first, unreachable regions last.
    var sorted: [Row] {
        rows.sorted { a, b in
            switch (a.result, b.result) {
            case let (.ms(x), .ms(y)): return x < y
            case (.ms, _): return true
            case (_, .ms): return false
            default: return a.name < b.name
            }
        }
    }

    func run(_ regions: [Region]) {
        job?.cancel()
        rows = regions.map { Row(name: $0.name, url: $0.url, result: .waiting) }
        guard !regions.isEmpty else { return }
        running = true
        job = Task { [weak self] in
            await withTaskGroup(of: (String, Result).self) { group in
                for r in regions {
                    group.addTask { (r.url, await Self.measure(r.url)) }
                }
                for await (url, result) in group {
                    guard let self, !Task.isCancelled else { return }
                    if let i = self.rows.firstIndex(where: { $0.url == url }) { self.rows[i].result = result }
                }
            }
            // A run replaced by a newer one leaves `running` to that run.
            if !Task.isCancelled { self?.running = false }
        }
    }

    func stop() {
        job?.cancel()
        job = nil
        running = false
    }

    nonisolated static func measure(_ base: String, tries: Int = 3) async -> Result {
        guard let url = URL(string: base + "v2/serverInfo") else { return .failed }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        var best: Double?
        // One to open the connection, then the timed ones.
        for attempt in 0...tries {
            if Task.isCancelled { return .failed }
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try await session.data(for: request)
            } catch {
                if attempt == 0 { return .failed }
                continue
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if attempt > 0 { best = min(best ?? ms, ms) }
        }
        return best.map { .ms($0) } ?? .failed
    }

    /// "Mumbai" from "NP-MUM-01" style keys is left to the caller; this is the label for a
    /// result.
    nonisolated static func label(_ r: Result) -> String {
        switch r {
        case .waiting: return "Testing\u{2026}"
        case .failed: return "No answer"
        case let .ms(v): return String(format: "%.0f ms", v)
        }
    }
}
