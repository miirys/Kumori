import AVFoundation
import Foundation
import os
import UIKit

/// Streams one session over native NVST: the RTSPS control channel the rig advertises, its
/// SRTP video socket and the DTLS/SCTP bundle for control, audio and input. This is what the
/// official PC client does. A session asked for as the native client has to be streamed this
/// way: it never sends a WebRTC offer.
@MainActor
final class NativeEngine {
    var onProgress: (String) -> Void = { _ in }
    var onStats: (StreamStats) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }
    /// The rig ended the stream itself, with what it said.
    var onTerminated: (String) -> Void = { _ in }
    var trace: LaunchTrace?

    /// The handshake reached PLAY, so the rig is sending.
    private(set) var playing = false
    /// The last handshake step reached, for the error screen and the log.
    private(set) var lastStage: NvstRtspStage?
    private(set) var codec: String?
    var muted = false { didSet { let m = muted; Task { await stream?.setAudioMuted(m) } } }

    private let options: NativeStreamOptions
    private let feed: PictureFeed
    private var stream: NativeStreamNVST?
    private var task: Task<Void, Never>?
    private var closed = false
    private var lastSample: (at: Date, decoded: UInt64, bytes: UInt64)?
    private var lastLogged = Date.distantPast

    nonisolated private static let logger = Logger(subsystem: "app.kumori.tv", category: "native")

    init(options: NativeStreamOptions, feed: PictureFeed) {
        self.options = options
        self.feed = feed
        codec = options.codec.rawValue
    }

    /// The highest output channel count the audio route carries: 8, 6 or 2. An AV receiver
    /// on HDMI reports its own speaker layout here.
    static var audioChannels: Int {
        let carried = AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        let wanted = carried >= 8 ? 8 : (carried >= 6 ? 6 : 2)
        guard wanted > 2 else { return 2 }
        // Without a decoder for the surround layouts, stay stereo.
        let decodes = [NvstAudioLayout.surround51, .surround71].allSatisfy { (try? NvstOpusDecoder(layout: $0)) != nil }
        return decodes ? wanted : 2
    }

    func start() {
        let o = options
        let line = "native start \(o.width)x\(o.height)@\(o.fps) \(o.codec.rawValue) \(o.colorQuality) \(o.bitrateKbps) kbps audio \(o.audioChannelCount)ch endpoints \(Self.describe(o.endpoints))"
        Self.logger.notice("\(line, privacy: .public)")
        let feed = feed
        let stream = NativeStreamNVST(options: o,
            onFrame: { frame in feed.showPaced(frame.pixelBuffer) },
            onSample: { [weak self] sample in Task { @MainActor in self?.sampled(sample) } },
            onFailure: { [weak self] reason in Task { @MainActor in self?.failed(reason) } },
            onTermination: { [weak self] event in Task { @MainActor in self?.terminated(event) } },
            onProgress: { [weak self] stage in Task { @MainActor in self?.progressed(stage) } },
            onDiagnostic: { line in Self.logger.notice("nvst: \(Self.redact(line), privacy: .public)") })
        self.stream = stream
        task = Task { [weak self] in
            do {
                try await stream.start()
                await MainActor.run { self?.negotiated() }
            } catch {
                guard !Task.isCancelled else { return }
                let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                await MainActor.run { self?.failed(text) }
            }
        }
    }

    func sendGamepad(slot: Int, connected: Int, buttons: Int, lt: Int, rt: Int, lx: Int, ly: Int, rx: Int, ry: Int) {
        guard let stream else { return }
        Task { await stream.sendGamepad(slot: slot, connected: connected, buttons: buttons, lt: lt, rt: rt, lx: lx, ly: ly, rx: rx, ry: ry) }
    }

    func sendMouse(dx: Int, dy: Int, wheel: Int, buttons: [(button: Int, pressed: Bool)]) {
        guard let stream else { return }
        Task { await stream.sendMouse(dx: dx, dy: dy, wheel: wheel, buttons: buttons) }
    }

    func requestKeyframe() {
        guard let stream else { return }
        Task { await stream.requestKeyframe() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        task?.cancel()
        feed.stopPacing()
        let stream = stream
        self.stream = nil
        Task { await stream?.close() }
    }

    // MARK: Events

    private func progressed(_ stage: NvstRtspStage) {
        guard !closed else { return }
        lastStage = stage
        if stage == .play { playing = true }
        let line = "native stage \(stage.rawValue)"
        Self.logger.notice("\(line, privacy: .public)")
        if stage == .play { trace?.once(.nativePlay) } else { trace?.record(.nativeStep, TraceFields(n: Self.stageNumber(stage))) }
        onProgress(Self.step(stage))
    }

    private func negotiated() {
        guard !closed else { return }
        playing = true
        let line = "native negotiated, waiting for video"
        Self.logger.notice("\(line, privacy: .public)")
        onProgress("Waiting for video")
    }

    private func sampled(_ s: NativeStreamNVSTSample) {
        guard !closed else { return }
        var stats = StreamStats()
        let parts = (s.resolution ?? "").split(separator: "x").compactMap { Int($0) }
        if parts.count == 2 { stats.width = parts[0]; stats.height = parts[1] }
        let now = Date()
        if let last = lastSample, now.timeIntervalSince(last.at) > 0.2 {
            let dt = now.timeIntervalSince(last.at)
            stats.fps = Double(s.decoded &- last.decoded) / dt
            stats.bitrateMbps = Double(s.bytes &- last.bytes) * 8 / dt / 1_000_000
        }
        lastSample = (now, s.decoded, s.bytes)
        stats.rttMs = s.pingMilliseconds
        stats.lossPct = s.packets > 0 ? Double(s.lost) / Double(s.packets + s.lost) * 100 : nil
        stats.decodeMs = s.decodeMilliseconds
        // The codec's name, not the decoder's format summary (7a1adc8 showed "8BIT420").
        stats.codec = Self.codecName(options.codec)
        stats.codecDetail = s.bitstream == "pending" ? nil : Self.formatName(s.bitstream)
        stats.hardwareDecode = s.hardware
        // The decoder's count, or the frames received whole if it hasn't reported yet: either
        // one means a picture is coming.
        stats.framesDecoded = Int(clamping: max(s.decoded, s.received > 0 && s.decoded == 0 ? 1 : 0))
        stats.framesReceived = Int(clamping: s.received)
        stats.packetsReceived = Int(clamping: s.packets)
        stats.packetsLost = Int(clamping: s.lost)
        stats.packetsResent = s.resendRequests.map { Int(clamping: $0) }
        stats.framesFailed = s.failed.map { Int(clamping: $0) }
        stats.jitterMs = s.jitterMilliseconds
        stats.transport = "Native (NVST)"
        stats.displayHz = UIScreen.main.maximumFramesPerSecond
        stats.audio = s.audioFormat
        if now.timeIntervalSince(lastLogged) >= 10 {
            lastLogged = now
            // Asked, decoded and shown are three different rates: the rig's encoder, this
            // decoder, and the HDMI mode the Apple TV is in (a 50 Hz mode shows at most 50).
            let hz = UIScreen.main.maximumFramesPerSecond
            let line = "native stats asked=\(self.options.width)x\(self.options.height)@\(self.options.fps) decoded=\(stats.width)x\(stats.height) fps=\(stats.fps.map { String(format: "%.1f", $0) } ?? "-") hdmiHz=\(hz) codec=\(stats.codec ?? "-") mbps=\(stats.bitrateMbps.map { String(format: "%.1f", $0) } ?? "-") loss=\(stats.lossPct.map { String(format: "%.2f", $0) } ?? "-") decodeMs=\(stats.decodeMs.map { String(format: "%.1f", $0) } ?? "-") rtt=\(stats.rttMs.map { String(format: "%.0f", $0) } ?? "-")"
            Self.logger.notice("\(line, privacy: .public)")
        }
        onStats(stats)
    }

    private func failed(_ reason: String) {
        guard !closed else { return }
        let at = lastStage?.rawValue ?? "before connecting"
        let line = "native failed at \(at): \(Self.redact(reason))"
        Self.logger.notice("\(line, privacy: .public)")
        onFailed(reason)
    }

    private func terminated(_ event: NvstSeatTermination) {
        guard !closed else { return }
        let line = "native ended by the rig: \(String(describing: event))"
        Self.logger.notice("\(line, privacy: .public)")
        onTerminated("The rig ended the stream.")
    }

    // MARK: Words

    nonisolated static func codecName(_ c: NativeStreamVideoCodec) -> String {
        switch c {
        case .av1: return "AV1"
        case .h265: return "HEVC"
        case .h264: return "H.264"
        }
    }

    /// "8BIT420" as "8-bit 4:2:0".
    nonisolated static func formatName(_ summary: String) -> String {
        let u = summary.uppercased()
        let depth = u.hasPrefix("10") ? "10-bit" : (u.hasPrefix("8") ? "8-bit" : nil)
        let chroma = u.hasSuffix("444") ? "4:4:4" : (u.hasSuffix("422") ? "4:2:2" : (u.hasSuffix("420") ? "4:2:0" : nil))
        guard let depth, let chroma else { return summary }
        return "\(depth) \(chroma)"
    }

    private nonisolated static func step(_ stage: NvstRtspStage) -> String {
        switch stage {
        case .connecting: return "Connecting to the rig"
        case .upgrading, .options: return "Opening the stream"
        case .describe, .setup: return "Setting up the stream"
        case .preparingVideo, .preparingBundle: return "Preparing video and sound"
        case .announce: return "Asking for the picture"
        case .play: return "Starting the picture"
        }
    }

    private nonisolated static func stageNumber(_ stage: NvstRtspStage) -> Int {
        [NvstRtspStage.connecting, .upgrading, .options, .describe, .setup, .preparingVideo, .preparingBundle, .announce, .play]
            .firstIndex(of: stage) ?? -1
    }

    /// Endpoints for the log: scheme and port only, never the host.
    nonisolated static func describe(_ endpoints: [String]) -> String {
        endpoints.map { e in
            guard let u = URLComponents(string: e) else { return "?" }
            return "\(u.scheme ?? "?"):\(u.port.map(String.init) ?? "-")\(u.path.isEmpty ? "" : " path")"
        }.joined(separator: ", ")
    }

    /// Strips keys, passwords and session ids from a diagnostic line.
    nonisolated static func redact(_ line: String) -> String {
        var out = line
        for pattern in [#"(?i)(key|pwd|password|ufrag|fingerprint|sessionid|x-nv-sessionid)[=:]\s*\S+"#,
                        #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
                        #"\b\d{1,3}(\.\d{1,3}){3}\b"#] {
            out = out.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return out
    }
}
