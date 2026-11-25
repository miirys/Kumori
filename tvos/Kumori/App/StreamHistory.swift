import Foundation

/// One finished stream, as the API's /history and the log report list it.
struct StreamRecord: Codable, Equatable {
    var gameId: String?
    var title: String?
    var startedAt: Date
    var endedAt: Date
    var seconds: Int
    /// The mode set up with the rig, and the picture that arrived.
    var targetFps: Int?
    var width: Int?
    var height: Int?
    var codec: String?
    var transport: String?
    var averageFps: Double?
    var minimumFps: Double?
    var framesShown: Int?
    var framesDropped: Int?
    var averageRttMs: Double?
    var averageMbps: Double?
    var lossPct: Double?
    /// Seconds the stream spent below its target.
    var lowSeconds: Int
    /// "left", "ended", "idle", "error" or "switched".
    var endedBy: String
    var message: String?
}

/// One stats sample a second, for /stats/history.
struct StatsSample: Codable, Equatable {
    var at: Date
    var fps: Double?
    var decodedFps: Double?
    var rttMs: Double?
    var mbps: Double?
    var lossPct: Double?
    var dropped: Int?
}

/// The last 50 streams, kept in user defaults (the only storage tvOS doesn't purge), and
/// the current stream's last ten minutes of samples, in memory.
@MainActor
final class StreamHistory: ObservableObject {
    static let shared = StreamHistory()

    @Published private(set) var records: [StreamRecord] = []
    private(set) var samples: [StatsSample] = []
    private let key = "streamHistory"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([StreamRecord].self, from: data) {
            records = list
        }
    }

    func add(_ r: StreamRecord) {
        records = Array((records + [r]).suffix(50))
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }

    func sample(_ s: StatsSample) {
        if let last = samples.last, s.at.timeIntervalSince(last.at) < 0.9 { return }
        samples.append(s)
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
    }

    func clearSamples() { samples = [] }
}
