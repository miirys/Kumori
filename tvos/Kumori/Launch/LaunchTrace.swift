import Foundation
#if canImport(os)
import os
#endif

/// The steps between pressing Play and a moving picture, in the order they normally happen.
/// Each launch attempt records these with safe fields only, so a failed launch says where it
/// stopped without carrying tokens, session ids, addresses or SDP.
enum LaunchStage: String, Codable, CaseIterable {
    case select
    case presented
    case presentFailed
    case allocate
    case refused
    case accepted
    case queued
    case seatReady
    case audioSession
    case signalingOpen
    case signalingClosed
    case signalingSendFailed
    case signalingRetry
    case offer
    case answerSent
    case ice
    case peer
    case videoTrack
    case audioTrack
    case firstPackets
    case firstDecoded
    case firstFrame
    case live
    case cancelled
    case left
    case failed

    /// Steps that mean the launch got further than before. Used for "last good step".
    var isProgress: Bool {
        switch self {
        case .presentFailed, .refused, .signalingClosed, .signalingSendFailed, .signalingRetry, .cancelled, .left, .failed, .ice, .peer, .audioSession:
            return false
        default:
            return true
        }
    }

    /// Words for the error screen and About.
    var label: String {
        switch self {
        case .select: return "Play pressed"
        case .presented: return "Player shown"
        case .presentFailed: return "Player couldn't be shown"
        case .allocate: return "Asked for a rig"
        case .refused: return "Request refused"
        case .accepted: return "Rig accepted"
        case .queued: return "In the queue"
        case .seatReady: return "Rig ready"
        case .audioSession: return "Audio session"
        case .signalingOpen: return "Connected to the rig"
        case .signalingClosed: return "Rig connection closed"
        case .signalingSendFailed: return "Couldn't send to the rig"
        case .signalingRetry: return "Signed in again"
        case .offer: return "Rig sent its offer"
        case .answerSent: return "Answer sent"
        case .ice: return "Network path"
        case .peer: return "Media connection"
        case .videoTrack: return "Video track"
        case .audioTrack: return "Audio track"
        case .firstPackets: return "Video arriving"
        case .firstDecoded: return "First frame decoded"
        case .firstFrame: return "First frame on screen"
        case .live: return "Playing"
        case .cancelled: return "Cancelled"
        case .left: return "Left the stream"
        case .failed: return "Stopped"
        }
    }
}

/// The only values a trace event may carry. Free text is limited to compile-time literals
/// (`StaticString`), so nothing read from the network or the account can end up in a trace.
struct TraceFields: Codable, Equatable {
    var width: Int?
    var height: Int?
    var fps: Int?
    var http: Int?
    var status: Int?
    /// A sign-in number, a ladder rung or a counter.
    var n: Int?
    var codec: String?
    var note: String?

    init(width: Int? = nil, height: Int? = nil, fps: Int? = nil, http: Int? = nil, status: Int? = nil,
         n: Int? = nil, codec: String? = nil, note: StaticString? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.http = http
        self.status = status
        self.n = n
        self.codec = codec.map(Self.safeCodec)
        self.note = note.map { $0.description }
    }

    /// A codec name such as "H264" or "video/AV1", cut down to letters, digits and dots.
    static func safeCodec(_ s: String) -> String {
        let name = s.hasPrefix("video/") ? String(s.dropFirst(6)) : s
        return String(name.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }.prefix(8))
    }

    var isEmpty: Bool { self == TraceFields() }

    var text: String {
        var parts: [String] = []
        if let width, let height { parts.append("\(width)x\(height)") }
        if let fps { parts.append("\(fps)fps") }
        if let codec { parts.append(codec) }
        if let http, http != 0 { parts.append("http \(http)") }
        if let status, status != 0 { parts.append("status \(status)") }
        if let n { parts.append("#\(n)") }
        if let note { parts.append(note) }
        return parts.joined(separator: " ")
    }
}

struct TraceEvent: Codable, Equatable {
    let at: Double
    let stage: LaunchStage
    let fields: TraceFields

    var line: String {
        let t = String(format: "%6.2f", at)
        return fields.isEmpty ? "\(t)s  \(stage.rawValue)" : "\(t)s  \(stage.rawValue)  \(fields.text)"
    }
}

/// One launch attempt, from Play to a picture or a failure. Safe to call from any thread.
final class LaunchTrace {
    /// Six hex digits, local to this device. Not a session id.
    let id: String
    private let clock: () -> Double
    private let started: Double
    private let lock = NSLock()
    private var list: [TraceEvent] = []
    private var seen = Set<LaunchStage>()
    static let limit = 200

    init(id: String = LaunchTrace.newId(), clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.id = id
        self.clock = clock
        self.started = clock()
    }

    static func newId() -> String { String(format: "%06x", UInt32.random(in: 0...0xFFFFFF)) }

    var events: [TraceEvent] { lock.withLock { list } }

    func record(_ stage: LaunchStage, _ fields: TraceFields = TraceFields()) {
        let e = lock.withLock { () -> TraceEvent? in
            guard list.count < Self.limit else { return nil }
            let e = TraceEvent(at: max(0, clock() - started), stage: stage, fields: fields)
            list.append(e)
            seen.insert(stage)
            return e
        }
        if let e { Self.log(id, e) }
    }

    /// Records a stage only the first time it happens in this attempt.
    @discardableResult
    func once(_ stage: LaunchStage, _ fields: TraceFields = TraceFields()) -> Bool {
        let fresh = lock.withLock { !seen.contains(stage) }
        if fresh { record(stage, fields) }
        return fresh
    }

    func has(_ stage: LaunchStage) -> Bool { lock.withLock { seen.contains(stage) } }

    /// The furthest step this attempt reached.
    var lastGood: LaunchStage? {
        let reached = lock.withLock { seen }
        return LaunchStage.allCases.last { $0.isProgress && reached.contains($0) }
    }

    var elapsed: Double { max(0, clock() - started) }

    /// Plain lines for About and for copying into a bug report.
    var lines: [String] { ["Launch \(id)"] + events.map(\.line) }

    #if canImport(os)
    private static let logger = Logger(subsystem: "app.kumori.tv", category: "launch")
    private static func log(_ id: String, _ e: TraceEvent) {
        // Every field is a number, a codec name or a literal, so it is safe to show publicly.
        logger.notice("launch \(id, privacy: .public) \(e.line, privacy: .public)")
    }
    #else
    private static func log(_ id: String, _ e: TraceEvent) {}
    #endif
}
