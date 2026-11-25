import AVFoundation
import CoreMedia
import Foundation
import LiveKitWebRTC
import VideoToolbox

struct StreamConfig {
    var width: Int
    var height: Int
    var fps: Int
    var maxKbps: Int
    /// "AUTO", "AV1", "H265" or "H264".
    var codec: String
    var bitDepth = 8
}

struct StreamStats {
    var width = 0
    var height = 0
    var fps: Double?
    var bitrateMbps: Double?
    var rttMs: Double?
    var lossPct: Double?
    var decodeMs: Double?
    var codec: String?
    var framesDecoded = 0
    /// Video packets received so far. Tells "nothing arrived" from "arrived but not decoded".
    var packetsReceived = 0
    /// Video packets lost for good so far (after resends), as a count. Nil where the stream
    /// doesn't say.
    var packetsLost: Int?
    /// Packets the receiver asked the rig to send again.
    var packetsResent: Int?
    /// Frames the rig sent, whole, and frames the decoder failed on.
    var framesReceived: Int?
    var framesFailed: Int?
    /// Network jitter, in milliseconds.
    var jitterMs: Double?
    /// The codec in use as a name (AV1, HEVC, H.264), and its detail as the decoder reports
    /// it: bit depth and chroma, for example "8-bit 4:2:0", and whether it is in hardware.
    var codecDetail: String?
    var hardwareDecode: Bool?
    /// How the stream arrives: "Native (NVST)" or "WebRTC".
    var transport: String?
    /// The HDMI output's refresh rate while this was measured.
    var displayHz: Int?
    /// The audio format, for example "Opus 5.1".
    var audio: String?
    /// Frames that arrived but were never shown.
    var framesDropped: Int?

    // Filled in by the player from what reached the screen, so the overlay can be trusted.

    /// The decoder's (or WebRTC's) frame rate, before anything is shown.
    var decodedFps: Double?
    /// Frames handed to the screen per second, measured at the screen.
    var shownFps: Double?
    /// Frames handed to the screen, and thrown away on this Apple TV, since the stream began.
    var framesShown: Int?
    var framesDroppedHere: Int?
    /// The frame rate this stream was set up for.
    var targetFps: Int?
    /// The HDMI output's refresh rate right now, from the TV's mode.
    var refreshHz: Double?
}

/// Apple TV decodes HEVC and H.264 in hardware through VideoToolbox, and AV1 on the models
/// whose chip has an AV1 decoder. AV1 goes through Kumori's own VideoToolbox decoder; where
/// there is no AV1 hardware, WebRTC's software decoder is offered only when AV1 is asked for.
final class HardwareDecoders: NSObject, LKRTCVideoDecoderFactory {
    private let base = LKRTCDefaultVideoDecoderFactory()

    static let av1Hardware: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// Set before a stream starts: true when the player picked AV1 by hand.
    static var allowSoftwareAV1 = false

    func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        var out = base.supportedCodecs().filter { ["H264", "H265"].contains($0.name.uppercased()) }
        if Self.av1Hardware || (Self.allowSoftwareAV1 && base.supportedCodecs().contains { $0.name.uppercased() == "AV1" }) {
            out.insert(LKRTCVideoCodecInfo(name: "AV1", parameters: ["profile": "0", "level-idx": "5", "tier": "0"]), at: 0)
        }
        return out
    }

    func createDecoder(_ info: LKRTCVideoCodecInfo) -> LKRTCVideoDecoder? {
        if info.name.uppercased() == "AV1" {
            return Self.av1Hardware ? AV1Decoder() : base.createDecoder(info)
        }
        return base.createDecoder(info)
    }

    static var names: Set<String> { Set(HardwareDecoders().supportedCodecs().map { $0.name.uppercased() }) }

    /// What the About page lists.
    static var describe: String {
        var parts = ["HEVC", "H.264"]
        if av1Hardware { parts.insert("AV1", at: 0) }
        return parts.joined(separator: ", ")
    }
}

enum RTC {
    /// One factory for the app. Audio plays through AVAudioEngine with no voice processing,
    /// since nothing is ever recorded.
    static let factory: LKRTCPeerConnectionFactory = {
        let engine = LKRTCAudioDeviceModuleType(rawValue: 1) ?? LKRTCAudioDeviceModuleType(rawValue: 0)!
        return LKRTCPeerConnectionFactory(
            audioDeviceModuleType: engine,
            bypassVoiceProcessing: true,
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: HardwareDecoders(),
            audioProcessingModule: nil
        )
    }()
}

/// One stream to one rig: signaling, the WebRTC connection, input and stats.
final class StreamEngine: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    var onProgress: (String) -> Void = { _ in }
    var onVideo: (LKRTCVideoTrack) -> Void = { _ in }
    var onConnected: () -> Void = {}
    var onInputReady: () -> Void = {}
    var onStats: (StreamStats) -> Void = { _ in }
    var onTimeWarning: (Int) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }
    /// The rig's offer arrived. From here the picture has its own deadline.
    var onOffered: () -> Void = {}
    /// Where this stream's steps are written down. Set before `start()`.
    var trace: LaunchTrace?

    private let session: CloudSession
    private let config: StreamConfig
    private let queue = DispatchQueue(label: "kumori.stream")
    private let encoder = InputEncoder()

    private var pc: LKRTCPeerConnection?
    private var signaling: Signaling?
    private var input: LKRTCDataChannel?
    private var partial: LKRTCDataChannel?
    private var control: LKRTCDataChannel?
    private var audio: LKRTCAudioTrack?
    private var pending: [LKRTCIceCandidate] = []
    private var remoteSet = false
    private var offerSeen = false
    private var signIns = 0
    private let policy = SignalingPolicy.standard
    /// When the first sign-in began, on the system's uptime clock.
    private var streamStartedAt = 0.0
    private var audioObserver: NSObjectProtocol?
    private var closed = false
    private var gathered: (() -> Void)?
    private var timers: [DispatchSourceTimer] = []
    private var lastBytes = 0.0
    private var lastStatsAt = 0.0
    private var lastKeyframeAt = 0.0
    private(set) var inputReady = false
    private var stats = InputStats()
    /// Which pads the server has been told about. Guarded by `wireLock`.
    private var wire = PadWire()
    private let wireLock = NSLock()
    private let statsLock = NSLock()
    private(set) var codec: String?

    /// Whether the rig sent its offer, which tells a missing picture from a rig that never started.
    var offered: Bool { offerSeen }

    var muted = false { didSet { applyVolume() } }

    init(session: CloudSession, config: StreamConfig) {
        self.session = session
        self.config = config
    }

    func start() {
        queue.async { self.open() }
    }

    private func open() {
        onProgress("Connecting to the rig")
        activateAudio()

        var servers = session.ice.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        if servers.isEmpty {
            servers = [
                LKRTCIceServer(urlStrings: ["stun:s1.stun.gamestream.nvidia.com:19308"]),
                LKRTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]),
            ]
        }
        let rtc = LKRTCConfiguration()
        rtc.iceServers = servers
        rtc.bundlePolicy = .maxBundle
        rtc.rtcpMuxPolicy = .require
        rtc.sdpSemantics = .unifiedPlan
        rtc.tcpCandidatePolicy = .enabled
        rtc.continualGatheringPolicy = .gatherOnce
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = RTC.factory.peerConnection(with: rtc, constraints: constraints, delegate: self) else {
            fail("Couldn't set up the stream.")
            return
        }
        self.pc = pc
        streamStartedAt = ProcessInfo.processInfo.systemUptime
        signIn()
    }

    // MARK: Audio session

    /// Game sound plays through the playback category. A failure here used to be dropped; now
    /// it is written to the launch record, and the video carries on either way.
    private func activateAudio() {
        let a = AVAudioSession.sharedInstance()
        do {
            try a.setCategory(.playback, mode: .default)
            try a.setActive(true)
        } catch {
            trace?.record(.audioSession, TraceFields(status: (error as NSError).code, note: "activation failed"))
        }
        if audioObserver == nil {
            // After an interruption (a Siri request, another app's sound) the session has to
            // be made active again or the game goes quiet.
            audioObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: a, queue: nil) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self?.queue.async {
                    guard let self, !self.closed else { return }
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        self.trace?.record(.audioSession, TraceFields(note: "reactivated"))
                    } catch {
                        self.trace?.record(.audioSession, TraceFields(status: (error as NSError).code, note: "reactivation failed"))
                    }
                }
            }
        }
    }

    private func releaseAudio() {
        if let o = audioObserver { NotificationCenter.default.removeObserver(o) }
        audioObserver = nil
        // The session is left active: WebRTC's audio engine is shared by every stream, and
        // switching the session off under it can leave the next stream silent.
    }

    // MARK: Signaling

    /// Signs in to the session's signaling server and waits for the rig's offer. If the socket
    /// closes first, sign in again under a new name: the server won't take back a peer it
    /// dropped. How long the wait is, and how many sign-ins there are, is `SignalingPolicy`.
    private func signIn() {
        guard let url = session.signalingUrl else {
            trace?.record(.failed, TraceFields(note: "no signaling address"))
            fail("The rig didn't say where to connect.")
            return
        }
        signaling?.close()
        signIns += 1
        let attempt = signIns
        let startedAt = ProcessInfo.processInfo.systemUptime - streamStartedAt
        let s = Signaling(url: url, sessionId: session.id, resolution: "\(config.width)x\(config.height)", peerName: SignIn.newPeerName(),
                          extraQuery: session.signalingQuery, extraProtocols: session.signalingProtocols, attempt: attempt)
        s.onOpen = { [weak self] in
            self?.trace?.record(.signalingOpen, TraceFields(n: attempt))
            self?.onProgress("Waiting for the rig")
        }
        s.onSendFailed = { [weak self] in
            self?.trace?.once(.signalingSendFailed, TraceFields(n: attempt))
        }
        s.onOffer = { [weak self] sdp in
            self?.queue.async {
                // An offer from a socket that has since been replaced belongs to nobody: our
                // answer would go out on the new socket to a pairing that isn't waiting.
                guard let self, !self.closed, !self.offerSeen, attempt == self.signIns else { return }
                self.offerSeen = true
                self.trace?.record(.offer, TraceFields(n: attempt))
                self.onOffered()
                Task { await self.answer(sdp) }
            }
        }
        s.onCandidate = { [weak self] sdp, mid, index in
            self?.queue.async {
                guard let self, attempt == self.signIns else { return }
                let c = LKRTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: mid ?? String(index))
                if self.remoteSet { self.pc?.add(c) { _ in } } else { self.pending.append(c) }
            }
        }
        s.onClosed = { [weak self] reason in
            self?.queue.async {
                guard let self, attempt == self.signIns, !self.closed, !self.inputReady else { return }
                // The reason is fixed words (peerRemoved, BYE…), never the server's text.
                self.trace?.record(.signalingClosed, TraceFields(n: attempt, note: reason.note))
                // Before the offer, sign in again. After it, the media connection carries on
                // without signaling.
                if !self.remoteSet { self.retrySignIn(reason.text) }
            }
        }
        signaling = s
        s.connect()
        let wait = max(1, policy.deadline(signInStartedAt: startedAt) - startedAt)
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.closed, !self.offerSeen, attempt == self.signIns else { return }
            SignalingLog.note(attempt, "no offer after \(Int(wait)) s")
            self.retrySignIn("no offer after \(Int(wait)) s")
        }
    }

    private func retrySignIn(_ reason: String) {
        guard !closed, !inputReady else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - streamStartedAt
        switch policy.next(afterSignIns: signIns, elapsed: elapsed) {
        case .giveUp:
            trace?.record(.failed, TraceFields(n: signIns, note: "no offer from the rig"))
            fail(offerSeen ? "The rig closed the connection (\(reason))." : "The rig didn't start the stream (\(reason)).")
        case .signInAgain(let pause):
            trace?.record(.signalingRetry, TraceFields(n: signIns + 1))
            onProgress("Reconnecting to the rig")
            queue.asyncAfter(deadline: .now() + pause) { [weak self] in
                guard let self, !self.closed, !self.inputReady, !self.offerSeen else { return }
                self.signIn()
            }
        }
    }

    // MARK: Negotiation

    private func pickCodec(_ offer: String) -> String {
        let offered = SDP.offeredCodecs(offer)
        let usable = HardwareDecoders.names
        let wanted = config.codec.uppercased()
        if wanted != "AUTO", offered.contains(wanted), usable.contains(wanted) { return wanted }
        // AV1 first where the chip decodes it, then HEVC: both need far fewer bits than H.264
        // for the same picture.
        let order = HardwareDecoders.av1Hardware ? ["AV1", "H265", "H264"] : ["H265", "H264"]
        return order.first { offered.contains($0) && usable.contains($0) } ?? "H264"
    }

    private func answer(_ offerSdp: String) async {
        guard let pc else { return }
        do {
            onProgress("Negotiating the stream")
            let serverIp = session.media?.ip ?? session.serverIp ?? ""
            var offer = serverIp.isEmpty ? offerSdp : SDP.fixServerIp(offerSdp, server: serverIp)
            let serverUfrag = SDP.value(offer, "a=ice-ufrag:") ?? ""
            let threshold = SDP.partialReliableThreshold(offer) ?? 300
            let chosen = pickCodec(offer)
            offer = SDP.keepCodec(offer, chosen)

            // Input channels, before the answer, so they ride the offer's data section.
            let reliable = LKRTCDataChannelConfiguration()
            reliable.isOrdered = true
            input = pc.dataChannel(forLabel: "input_channel_v1", configuration: reliable)
            input?.delegate = self
            let lossy = LKRTCDataChannelConfiguration()
            lossy.isOrdered = false
            lossy.maxPacketLifeTime = Int32(threshold)
            partial = pc.dataChannel(forLabel: "input_channel_partially_reliable", configuration: lossy)

            try await set { pc.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: offer), completionHandler: $0) }
            queue.sync {
                remoteSet = true
                for c in pending { pc.add(c) { _ in } }
                pending.removeAll()
            }

            let created: LKRTCSessionDescription = try await withCheckedThrowingContinuation { done in
                pc.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                    if let sdp { done.resume(returning: sdp) } else { done.resume(throwing: error ?? APIError(message: "no answer")) }
                }
            }
            let local = LKRTCSessionDescription(type: .answer, sdp: SDP.mungeAnswer(created.sdp, videoKbps: config.maxKbps))
            let gathering = Task { await waitForCandidates() }
            try await set { pc.setLocalDescription(local, completionHandler: $0) }
            await gathering.value

            let final = pc.localDescription?.sdp ?? local.sdp
            let negotiated = SDP.negotiatedCodec(final) ?? chosen
            codec = negotiated
            let nvst = SDP.nvst(
                width: config.width, height: config.height, fps: config.fps, maxKbps: config.maxKbps,
                bitDepth: negotiated == "H264" ? 8 : config.bitDepth, partialReliableMs: threshold, ice: SDP.ice(final),
                av1: negotiated == "AV1"
            )
            signaling?.sendAnswer(sdp: final, nvst: nvst)
            trace?.record(.answerSent, TraceFields(width: config.width, height: config.height, fps: config.fps, codec: negotiated))

            // The rig runs ICE-lite and may not send candidates. Tell ICE where it is.
            if let m = session.media {
                let ip = SDP.publicIp(m.ip) ?? m.ip
                let ufrag = serverUfrag.isEmpty ? "" : " generation 0 ufrag \(serverUfrag)"
                pc.add(LKRTCIceCandidate(sdp: "candidate:1 1 udp 2130706431 \(ip) \(m.port) typ host\(ufrag)", sdpMLineIndex: 0, sdpMid: "0")) { _ in }
                pc.add(LKRTCIceCandidate(sdp: "candidate:2 1 tcp 1518149375 \(ip) \(m.port) typ host tcptype passive\(ufrag)", sdpMLineIndex: 0, sdpMid: "0")) { _ in }
            }
            onProgress("Starting the video")
            every(1) { [weak self] in self?.pollStats() }
        } catch {
            trace?.record(.failed, TraceFields(status: (error as NSError).code, note: "negotiation failed"))
            fail("The stream couldn't be negotiated: \(error.localizedDescription)")
        }
    }

    /// Runs one description step and waits for it.
    private func set(_ step: (@escaping (Error?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            step { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            }
        }
    }

    /// Waits until our network candidates are in the description, or five seconds.
    private func waitForCandidates() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                var finished = false
                let finish = {
                    if !finished {
                        finished = true
                        self.gathered = nil
                        done.resume()
                    }
                }
                self.gathered = finish
                self.queue.asyncAfter(deadline: .now() + 5, execute: finish)
            }
        }
    }

    // MARK: Peer connection

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        trace?.record(.ice, TraceFields(n: newState.rawValue, note: Self.iceName(newState)))
    }

    private static func iceName(_ s: LKRTCIceConnectionState) -> StaticString {
        switch s {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        default: return "other"
        }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        if newState == .complete { queue.async { self.gathered?() } }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        signaling?.sendCandidate(candidate.sdp, mid: candidate.sdpMid, index: Int(candidate.sdpMLineIndex))
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        switch newState {
        case .connected:
            trace?.record(.peer, TraceFields(note: "connected"))
            onConnected()
        case .failed:
            trace?.record(.peer, TraceFields(note: "failed"))
            fail(offerSeen && !(trace?.has(.firstPackets) ?? true)
                ? "Couldn't reach the rig's video. Your network may be blocking the stream."
                : "The connection to the rig was lost.")
        case .disconnected:
            trace?.record(.peer, TraceFields(note: "disconnected"))
        default: break
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        guard dataChannel.label == "control_channel" else { return }
        control = dataChannel
        dataChannel.delegate = self
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        if let v = transceiver.receiver.track as? LKRTCVideoTrack {
            trace?.once(.videoTrack)
            onVideo(v)
        } else if let a = transceiver.receiver.track as? LKRTCAudioTrack {
            trace?.once(.audioTrack)
            audio = a
            applyVolume()
        }
    }

    /// The source volume is a gain, where 1 plays the sound as it was sent.
    private func applyVolume() { audio?.source.volume = muted ? 0 : 1 }

    // MARK: Data channels

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {}

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        if dataChannel === control {
            let j = J(data: buffer.data)["timerNotification"]
            if let left = j["secondsLeft"].int, left >= 0 { onTimeWarning(left) }
            return
        }
        queue.async { self.handshake([UInt8](buffer.data)) }
    }

    /// The server opens input with its protocol version. From then on we may send.
    private func handshake(_ b: [UInt8]) {
        guard !inputReady, let version = InputHandshake.version(b) else { return }
        encoder.version = version
        statsLock.lock()
        stats.version = version
        statsLock.unlock()
        inputReady = true
        every(2) { [weak self] in
            guard let self else { return }
            self.send(self.encoder.heartbeat(), on: self.input)
        }
        onInputReady()
    }

    @discardableResult
    private func send(_ data: Data, on channel: LKRTCDataChannel?) -> Bool {
        guard !closed, let channel, channel.readyState == .open else { return false }
        return channel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
    }

    /// What happened to controller reports so far, for the stats bar.
    var inputStats: InputStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    /// Controller reports go on the partially reliable channel: a late report is useless.
    /// The ordered channel takes them when the other one isn't open, and always carries the
    /// registrations and releases that tell the server which pads exist (see `PadWire`).
    /// `connected` is Kumori's slot mask; the wire bitmap is built from it here.
    func sendGamepad(slot: Int, connected: Int, buttons: Int, lt: Int, rt: Int, lx: Int, ly: Int, rx: Int, ry: Int) {
        let route = InputRoute.choose(
            ready: inputReady, closed: closed,
            partialOpen: partial?.readyState == .open, reliableOpen: input?.readyState == .open
        )
        guard route == .partial || route == .reliable else {
            record(route, accepted: false)
            return
        }
        let report = PadReport(buttons: buttons, lt: lt, rt: rt, lx: lx, ly: ly, rx: rx, ry: ry)
        wireLock.lock()
        defer { wireLock.unlock() }
        let frames = wire.plan(slot: slot, connected: connected, report: report, partialOpen: route == .partial)
        for f in frames {
            let ok: Bool
            switch f.kind {
            case .registration, .release:
                ok = send(encoder.gamepadEvent(slot: f.slot, connected: f.bitmap, report: f.report), on: input)
                // A slot's count is never started again mid-stream. Reset to 1 when a pad left,
                // the reports of a pad that came back numbered below the server's last one,
                // and the server dropped them all as late: the pad moved nothing until the
                // stream was restarted.
                if f.kind == .registration, ok { wire.accept(f.bitmap) }
                if !ok {
                    // Not registered: try the whole thing again with the next report.
                    record(.reliable, accepted: false)
                    return
                }
            case .state:
                let lossy = f.channel == .partial
                ok = send(encoder.gamepad(slot: f.slot, connected: f.bitmap, report: f.report, partial: lossy), on: lossy ? partial : input)
                record(lossy ? .partial : .reliable, accepted: ok)
            }
        }
    }

    /// Mouse events, for pointer mode. They go on the ordered channel, as the desktop app's do.
    func sendMouse(dx: Int, dy: Int, wheel: Int, buttons: [(button: Int, pressed: Bool)]) {
        let route = InputRoute.choose(ready: inputReady, closed: closed, partialOpen: false, reliableOpen: input?.readyState == .open)
        guard route == .reliable else {
            record(route, accepted: false)
            return
        }
        if dx != 0 || dy != 0 { record(.reliable, accepted: send(encoder.mouseMove(dx: dx, dy: dy), on: input)) }
        if wheel != 0 { record(.reliable, accepted: send(encoder.wheel(wheel), on: input)) }
        for b in buttons { record(.reliable, accepted: send(encoder.mouseButton(b.button, down: b.pressed), on: input)) }
    }

    /// Types keys on the rig over the ordered channel, each pressed and let go.
    func sendKeys(_ keys: [KeyText.Key]) {
        guard InputRoute.choose(ready: inputReady, closed: closed, partialOpen: false, reliableOpen: input?.readyState == .open) == .reliable else { return }
        // Keys asked for while earlier ones are still going out wait their turn. Started at
        // once, a second batch (Send, then the Enter key) interleaved with the first: letters
        // came out of order and a held Shift capitalised the other batch's keys.
        let now = DispatchTime.now()
        var at = keysFreeAt > now ? keysFreeAt : now
        for k in keys {
            let mods = k.shift ? KeyText.shiftBit : 0
            let presses: [(UInt16, UInt16, Bool)] = (k.shift ? [(0xA0, 0, true)] : []) + [(k.code, mods, true), (k.code, mods, false)] + (k.shift ? [(0xA0, 0, false)] : [])
            for p in presses {
                DispatchQueue.main.asyncAfter(deadline: at) { [weak self] in
                    guard let self else { return }
                    _ = self.send(self.encoder.key(p.0, modifiers: p.1, down: p.2), on: self.input)
                }
                at = at + 0.012
            }
        }
        keysFreeAt = at
    }
    /// When the keys already scheduled have all gone out. Main queue only.
    private var keysFreeAt = DispatchTime.now()

    private func record(_ route: InputRoute, accepted: Bool) {
        statsLock.lock()
        stats.record(route, accepted: accepted)
        statsLock.unlock()
    }

    func requestKeyframe(_ reason: String) {
        let now = CACurrentMediaTime()
        guard now - lastKeyframeAt > 0.4 else { return }
        lastKeyframeAt = now
        signaling?.requestKeyframe(reason)
    }

    // MARK: Stats

    private func every(_ seconds: Double, _ work: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, repeating: seconds)
        t.setEventHandler(handler: work)
        t.resume()
        queue.async { self.timers.append(t) }
    }

    private func pollStats() {
        pc?.statistics { [weak self] report in
            guard let self else { return }
            var s = StreamStats()
            var codecId: String?
            for (_, stat) in report.statistics {
                let v = stat.values
                func number(_ k: String) -> Double? { (v[k] as? NSNumber)?.doubleValue }
                // Older WebRTC builds name the field mediaType instead of kind.
                if stat.type == "inbound-rtp", ((v["kind"] ?? v["mediaType"]) as? String) == "video" {
                    s.width = Int(number("frameWidth") ?? 0)
                    s.height = Int(number("frameHeight") ?? 0)
                    s.fps = number("framesPerSecond")
                    s.framesDecoded = Int(number("framesDecoded") ?? 0)
                    s.packetsReceived = Int(number("packetsReceived") ?? 0)
                    codecId = v["codecId"] as? String
                    if let lost = number("packetsLost") { s.packetsLost = max(0, Int(lost)) }
                    if let jitter = number("jitter") { s.jitterMs = jitter * 1000 }
                    if let dropped = number("framesDropped") { s.framesDropped = Int(dropped) }
                    if let lost = number("packetsLost"), let got = number("packetsReceived"), lost + got > 0 {
                        s.lossPct = max(0, lost) / (lost + got) * 100
                    }
                    if let total = number("totalDecodeTime"), s.framesDecoded > 0 { s.decodeMs = total / Double(s.framesDecoded) * 1000 }
                    if let bytes = number("bytesReceived") {
                        let now = CACurrentMediaTime()
                        if self.lastStatsAt > 0, now > self.lastStatsAt {
                            s.bitrateMbps = max(0, bytes - self.lastBytes) * 8 / (now - self.lastStatsAt) / 1e6
                        }
                        self.lastBytes = bytes
                        self.lastStatsAt = now
                    }
                } else if stat.type == "candidate-pair", (v["nominated"] as? NSNumber)?.boolValue == true, let rtt = number("currentRoundTripTime") {
                    s.rttMs = rtt * 1000
                }
            }
            if let codecId, let mime = report.statistics[codecId]?.values["mimeType"] as? String {
                s.codec = mime.replacingOccurrences(of: "video/", with: "")
            }
            s.codec = s.codec ?? self.codec
            self.onStats(s)
        }
    }

    // MARK: Ending

    private func fail(_ message: String) {
        guard !closed else { return }
        close()
        onFailed(message)
    }

    func close() {
        guard !closed else { return }
        closed = true
        queue.async {
            for t in self.timers { t.cancel() }
            self.timers.removeAll()
            self.signaling?.close()
            self.pc?.close()
            self.pc = nil
            self.releaseAudio()
        }
    }
}
