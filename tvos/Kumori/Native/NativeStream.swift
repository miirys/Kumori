import CoreMedia
import CoreVideo
import Foundation
import os

// The native NVST receiver's session driver. Adapted for Kumori from OpenNOW's
// NativeStreamNVST.swift (github.com/Lacrowx/OpenNOW at 445865e, ios/OpenNOWiOS/OpenNOWiOS,
// MIT, Copyright (c) 2025 Zortos). The protocol modules it drives are in Kumori/NVST, with their
// own licenses and upstream record. Changes from the original: it takes Kumori's session and
// options instead of OpenNOW's store types, sends Kumori's controller state directly, and drops
// the iOS-only paths (touch, HID and DualSense passthrough, microphone).

/// A decoded frame for the renderer.
struct NativeStreamNVSTFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
}

/// The video codecs the native receiver can ask the rig for.
enum NativeStreamVideoCodec: String, CaseIterable, Sendable {
    case h264 = "H264"
    case h265 = "H265"
    case av1 = "AV1"

    /// The codec name the RTSP negotiation announces.
    var announced: String { self == .h265 ? "HEVC" : rawValue }
}

/// Pixel-surface checks the VideoToolbox decoder makes on 10-bit output. From OpenNOW's
/// NativeStreamHDRMetal.swift; the Metal renderer itself is not used here.
enum NativeStreamTenBitSurface {
    static func chroma(_ format: OSType) -> String? {
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "4:2:0"
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: return "4:2:2"
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: return "4:4:4"
        default: return nil
        }
    }

    static func preserves444(_ buffer: CVPixelBuffer) -> Bool {
        chroma(CVPixelBufferGetPixelFormatType(buffer)) == "4:4:4"
            && CVPixelBufferGetPlaneCount(buffer) == 2
            && CVPixelBufferGetWidthOfPlane(buffer, 0) == CVPixelBufferGetWidthOfPlane(buffer, 1)
            && CVPixelBufferGetHeightOfPlane(buffer, 0) == CVPixelBufferGetHeightOfPlane(buffer, 1)
    }
}

struct NativeStreamVideoLiveness {
    enum Action: Equatable { case none, requestKeyframe, failed }
    private var lastProgressAt: UInt64
    private var lastDecoded: UInt64 = 0
    private var lastRequestAt: UInt64?

    init(now: UInt64) { lastProgressAt = now }

    mutating func observe(decoded: UInt64, now: UInt64) -> Action {
        if decoded > lastDecoded {
            lastDecoded = decoded
            lastProgressAt = now
            lastRequestAt = nil
            return .none
        }
        let age = now >= lastProgressAt ? now - lastProgressAt : 0
        if age >= 20_000_000_000 { return .failed }
        guard age >= 1_000_000_000 else { return .none }
        if let lastRequestAt, now >= lastRequestAt, now - lastRequestAt < 1_000_000_000 { return .none }
        lastRequestAt = now
        return .requestKeyframe
    }
}

/// A PLI on an unopened feedback channel can be discarded without an error. The
/// host also accepts an explicit IDR command on its reliable control channel.
enum NativeStreamKeyframeRecovery {
    @discardableResult
    static func request(sendControl: (NvstControlCommand) -> Bool, sendUDP: () -> Void) -> Bool {
        let sent = sendControl(.idrRequest())
        if !sent { sendUDP() }
        return sent
    }
}

/// One second of the running native stream, for the stats overlay and the log.
struct NativeStreamNVSTSample: Sendable {
    let received: UInt64
    let decoded: UInt64
    let bytes: UInt64
    let lost: UInt64
    let packets: UInt64
    let resolution: String?
    let decodeMilliseconds: Double
    let pingMilliseconds: Double?
    let jitterMilliseconds: Double
    let hardware: Bool
    let pixelFormat: String
    let bitstream: String
    let detail: String
    var audioFormat: String?
    /// Packets the receiver asked the rig to resend, and frames the decoder failed on.
    var resendRequests: UInt64?
    var failed: UInt64?
    /// When the counters above were read (`systemUptime`). Rates are worked out against this,
    /// not against when the sample reached the main actor, which wanders with its load.
    var sampledAt: Double?
}

/// What one native stream is set up with. Nothing here is a secret except `sessionID`, which
/// never goes to the log.
struct NativeStreamOptions: Sendable {
    var sessionID: String
    /// The rig's advertised RTSPS control endpoints, exactly as it gave them.
    var endpoints: [String]
    var width: Int
    var height: Int
    var fps: Int
    var codec: NativeStreamVideoCodec
    var bitrateKbps: Int
    /// "8bit_420", "10bit_420", "8bit_444" or "10bit_444".
    var colorQuality: String = "8bit_420"
    var hdr = false
    /// 2, 6 or 8.
    var audioChannelCount = 2
    /// The refresh rate the display runs at, for frame pacing.
    var displayFPS = 60
    var muted = false

    var resolution: String { "\(width)x\(height)" }
}

actor NativeStreamNVST {
    private let options: NativeStreamOptions
    private let onFrame: @Sendable (NativeStreamNVSTFrame) -> Void
    private let onSample: @Sendable (NativeStreamNVSTSample) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let onTermination: @Sendable (NvstSeatTermination) -> Void
    private let onProgress: @Sendable (NvstRtspStage) -> Void
    private let onDiagnostic: (@Sendable (String) -> Void)?
    private let clock = NvstSessionClock()
    private var reserver: NvstLocalBundleReserver?
    private var rtsp: NvstRtspSession?
    private var receiver: NvstMjolnirReceiver?
    private var bundle: NvstNativeBundle?
    private var decoder: NvstVideoToolboxDecoder?
    private var pipeline: NvstVideoPipeline?
    private let feedback = NvstFeedbackSender()
    private var stopped = false
    private var bundleGeneration: UInt64 = 0
    private var preparationError: Error?
    private var sampling: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var qos: Task<Void, Never>?
    private var inputSequence: UInt16 = 0
    private var gamepadSequences: [UInt16: UInt16] = [:]
    private var registeredBitmap: UInt16 = NvstGamepadPacket.connectedBitmap
    private var activatedInput = false
    private var qosSequence: UInt32 = 0
    private var lastQosBytes: UInt64 = 0
    private var lastDelay: UInt32 = 0
    private var lastRtpStatsFrame: UInt64 = 0
    private var lastControlStatsAt: Date?
    private var lastKeyframeRequestAt: Date?
    private var keyframeRequests = 0
    private var controlKeyframeRequests = 0
    private var udpKeyframeRequests = 0
    private var videoLiveness = NativeStreamVideoLiveness(now: DispatchTime.now().uptimeNanoseconds)
    private var didFinish = false
    private var muted: Bool

    init(options: NativeStreamOptions,
         onFrame: @escaping @Sendable (NativeStreamNVSTFrame) -> Void,
         onSample: @escaping @Sendable (NativeStreamNVSTSample) -> Void,
         onFailure: @escaping @Sendable (String) -> Void,
         onTermination: @escaping @Sendable (NvstSeatTermination) -> Void,
         onProgress: @escaping @Sendable (NvstRtspStage) -> Void,
         onDiagnostic: (@Sendable (String) -> Void)? = nil) {
        self.options = options
        self.muted = options.muted
        self.onFrame = onFrame; self.onSample = onSample; self.onFailure = onFailure
        self.onTermination = onTermination
        self.onProgress = onProgress
        self.onDiagnostic = onDiagnostic
    }

    func start() async throws {
        guard !stopped else { throw CancellationError() }
        guard !options.endpoints.isEmpty else { throw NvstRtspNegotiationError.missingEndpoint }
        clock.start()
        let reserver = NvstLocalBundleReserver(bundleProvider: { [weak self] handoff, micOffered, seatAudioLayouts in
            await self?.prepareBundle(handoff: handoff, microphoneOffered: micOffered, seatAudioLayouts: seatAudioLayouts)
        })
        self.reserver = reserver
        // The rig's DESCRIBE can offer a 720p60 baseline even for a larger allocation, so the
        // mode is always announced explicitly: viewport, frame rate, codec, depth and chroma.
        let input = NvstRtspNegotiationInput(sessionID: options.sessionID, rtspsEndpoints: options.endpoints,
            resolution: options.resolution, fps: options.fps, codec: options.codec.announced,
            // Initial is the mode's target; the ceiling sits well above it. The official client
            // announces initial 25 Mbps against a 100 Mbps maximum, and VQOS's bandwidth estimator
            // needs that gap to hold the target under the normal trickle of loss. Pinning the two
            // equal (as this once did) left no headroom: one 0.1% loss burst throttled a 50 Mbps
            // 4K60 request down to ~29 Mbps with nothing to recover toward. The ceiling is at least
            // the official client's 100 Mbps, and never below twice the target.
            bitrateKbps: options.bitrateKbps,
            maximumBitrateKbps: max(100_000, options.bitrateKbps * 2),
            colorQuality: options.colorQuality, hdrEnabled: options.hdr, audioChannelCount: options.audioChannelCount,
            rtcpOnSctp: true, disablesOwdCongestionControl: false, vsyncMode: .adaptive,
            announceOverrides: [("x-nv-vqos[0].dfc.enable", "0")])
        do {
            let negotiated = try await NvstRtspNegotiator(reserver: reserver, logger: onDiagnostic, onProgress: onProgress).negotiate(input,
                onVideoReady: { [weak self] handoff in
                    guard let self else { throw CancellationError() }
                    try await self.startVideo(handoff)
                }, onAnnounceReady: { [weak self] _ in await self?.punchBeforePlay() })
            if stopped || didFinish || Task.isCancelled {
                await negotiated.release("cancelled")
                throw CancellationError()
            }
            rtsp = negotiated
            if let preparationError { throw preparationError }
            videoLiveness = NativeStreamVideoLiveness(now: DispatchTime.now().uptimeNanoseconds)
            sampling = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sample()
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                }
            }
        } catch {
            await close()
            throw error
        }
    }

    private func prepareBundle(handoff: NVSTVideoHandoff, microphoneOffered: Bool,
                               seatAudioLayouts: [NvstAudioLayout]) async -> NvstBundleReservation? {
        guard !stopped else { return nil }
        do {
            let nativeBundle = NvstNativeBundle(handoff: handoff, identity: try NvstDtlsIdentity(), logger: nil)
            bundle = nativeBundle
            let generation = bundleGeneration
            feedback.configure(channelWriter: { [weak nativeBundle] data in _ = nativeBundle?.sendFeedback(data) },
                               senderSSRC: NvstVideoReceiver.clientSSRC, mediaSSRC: 0)
            nativeBundle.onControlChannelOpen = { [weak self] in Task { await self?.ifCurrent(generation) { $0.controlOpened() } } }
            nativeBundle.onPartiallyReliableControlOpen = { [weak self] in Task { await self?.ifCurrent(generation) { $0.qosOpened() } } }
            nativeBundle.onFeedbackChannelOpen = { [weak self] in Task { await self?.ifCurrent(generation) { $0.feedbackOpened() } } }
            nativeBundle.onInputProtocolNegotiated = { [weak self] _ in Task { await self?.ifCurrent(generation) { $0.activateInput() } } }
            nativeBundle.onSeatTermination = { [weak self] event in
                Task { await self?.ifCurrent(generation) { $0.terminate(event) } }
            }
            nativeBundle.onFailure = { [weak self] reason in Task { await self?.ifCurrent(generation) { $0.fail(reason) } } }
            nativeBundle.onAudioDiagnostic = { [onDiagnostic] message in onDiagnostic?("audio: \(message)") }
            // Kumori sends no microphone.
            let identity = try await nativeBundle.prepare(microphone: nil, audioChannelCount: options.audioChannelCount,
                                                          seatAudioLayouts: seatAudioLayouts)
            guard !stopped else { nativeBundle.close(); return nil }
            nativeBundle.setRemoteAudioMuted(muted)
            pipeline?.attach(bundle: nativeBundle)
            return NvstBundleReservation(bundlePort: identity.bundlePort, mjolnirPort: handoff.mjolnirUDPPort ?? handoff.clientUDPPort,
                localAddress: identity.localAddress, iceCredentials: reserver?.localIceCredentials,
                dtlsFingerprint: identity.dtlsFingerprint, microphoneNegotiated: nativeBundle.microphoneNegotiation.negotiated,
                microphoneSenderSsrc: nativeBundle.microphoneNegotiation.senderSsrc)
        } catch { preparationError = error; return nil }
    }

    private func startVideo(_ handoff: NVSTVideoHandoff) throws {
        guard !stopped else { throw CancellationError() }
        if let preparationError { throw preparationError }
        // Video must be armed before ANNOUNCE. The bundle identity is prepared during ANNOUNCE,
        // then attached to this pipeline before PLAY begins.
        bundleGeneration &+= 1
        receiver?.stop(); pipeline?.stop(); decoder?.invalidate()
        bundle?.close(); bundle = nil
        keepalive?.cancel(); keepalive = nil; qos?.cancel(); qos = nil
        feedback.stop(); activatedInput = false
        preparationError = nil; lastQosBytes = 0; lastDelay = 0; qosSequence = 0
        lastKeyframeRequestAt = nil
        keyframeRequests = 0; controlKeyframeRequests = 0; udpKeyframeRequests = 0
        lastRtpStatsFrame = 0; lastControlStatsAt = nil; gamepadSequences.removeAll()

        let decoder = NvstVideoToolboxDecoder(codec: handoff.codec, requiresTenBit444: options.colorQuality == "10bit_444")
        self.decoder = decoder
        if let onDiagnostic { decoder.onDecodeFailure = { _, message in onDiagnostic(message) } }
        let callback = onFrame
        decoder.onPixelBuffer = { pixelBuffer, time, _ in
            callback(NativeStreamNVSTFrame(pixelBuffer: pixelBuffer, time: time))
        }
        let pipeline = NvstVideoPipeline(decoder: decoder, clock: clock,
            frameTimeMicroseconds: UInt32(1_000_000 / max(1, options.fps)),
            displayVsyncMicroseconds: UInt32(1_000_000 / max(1, options.displayFPS)),
            logger: onDiagnostic, mediaSink: nil,
            onKeyframeNeeded: { [weak self] in Task { await self?.requestKeyframe() } },
            onFatalDecodeError: { [weak self] reason in
                Task { await self?.fail(reason) }
            })
        self.pipeline = pipeline
        pipeline.attach(bundle: bundle)
        let descriptor = reserver?.takeMjolnirDescriptor() ?? -1
        let receiver = try NvstMjolnirReceiver(handoff: handoff, sendsReceiverReports: false, existingDescriptor: descriptor)
        self.receiver = receiver
        receiver.onAccessUnit = { unit in pipeline.submit(unit) }
        receiver.onRecoveryNeeded = { [weak self] _ in Task { await self?.requestKeyframe() } }
        receiver.onRetransmissionWanted = { sequences in pipeline.requestRetransmission(of: sequences) }
        receiver.onDiagnostic = onDiagnostic
        feedback.setReportProvider { [weak receiver] in receiver?.receiverReportBlock() }
        try receiver.start()
    }

    private func punchBeforePlay() async {
        receiver?.beginHolePunch()
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private func ifCurrent(_ generation: UInt64, _ action: @Sendable (isolated NativeStreamNVST) -> Void) {
        guard !stopped, generation == bundleGeneration else { return }
        action(self)
    }

    private func controlOpened() {
        guard !stopped, keepalive == nil else { return }
        _ = bundle?.sendControl(.windowStateChange())
        _ = bundle?.sendControl(.systemStateChange())
        requestKeyframe()
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendKeepalive()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }

    private func sendKeepalive() {
        guard !stopped else { return }
        _ = bundle?.sendControl(.pingBackAck(streamValue: UInt32(truncatingIfNeeded: receiver?.feedbackCounters.framesEmitted ?? 0)))
    }

    private func feedbackOpened() {
        guard !stopped else { return }
        if let ssrc = receiver?.stats.boundSSRC { feedback.updateMediaSSRC(ssrc) }
        feedback.start()
    }

    private func qosOpened() {
        guard !stopped, qos == nil else { return }
        qos = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendQos()
                do { try await Task.sleep(nanoseconds: UInt64(NvstQosReport.interval * 1_000_000_000)) } catch { return }
            }
        }
    }

    private func sendQos() {
        guard !stopped, let bundle, let receiver else { return }
        let counters = receiver.feedbackCounters
        let stats = receiver.stats
        qosSequence &+= 1
        let delay = UInt32(clamping: Int(Double(stats.lastJitter) * 1_000_000 / 90_000))
        let delta = counters.bytesReceived >= lastQosBytes ? counters.bytesReceived - lastQosBytes : 0
        let report = NvstQosReport(sequence: qosSequence, framesReceived: UInt32(truncatingIfNeeded: counters.framesEmitted),
            bytesReceived: UInt32(truncatingIfNeeded: counters.bytesReceived),
            // The flat capability figure the official client sends on every report, whatever rate
            // it is actually getting. This field is a capability class, not a measurement:
            // reporting our observed or target throughput here closes the rate-control loop at
            // whatever we are currently given and throttles the stream (215-297 fps/30s against the
            // official client's 412-503). Overriding it to the target bitrate was starving 4K60.
            linkCapabilityKbps: NvstQosReport.defaultLinkCapabilityKbps,
            rtpTimestamp: counters.lastRtpTimestamp, previousBytesReceived: UInt32(truncatingIfNeeded: lastQosBytes),
            delayMicroseconds: delay, delayTrendMicroseconds: delay > lastDelay ? delay - lastDelay : lastDelay - delay,
            intervalBits: UInt32(clamping: delta * 8), isWarmedUp: clock.elapsedMicroseconds() >= 1_900_000)
        _ = bundle.sendPartiallyReliableControl(report.command)
        lastQosBytes = counters.bytesReceived; lastDelay = delay
        if stats.framesEmitted >= lastRtpStatsFrame + NvstRtpStatsReport.frameInterval {
            lastRtpStatsFrame = stats.framesEmitted
            let frame = UInt32(truncatingIfNeeded: stats.framesEmitted)
            let report = NvstRtpStatsReport(frameNumber: frame, totalReceivedPackets: stats.authenticatedPackets,
                outOfOrderPackets: UInt32(clamping: stats.outOfOrderPackets), dropEvents: UInt32(clamping: stats.recoveries),
                latePackets: UInt32(clamping: stats.latePackets), droppedPackets: UInt32(clamping: stats.droppedPackets),
                recoveredPackets: UInt32(clamping: stats.recoveredPackets), maxDropBurstLength: stats.maxLossBurst,
                maxWaitingQueueDepth: stats.maxReorderDepth, duplicatePackets: UInt32(clamping: stats.duplicatePackets),
                micChatSentDataBytes: bundle.microphoneSentBytes)
            _ = bundle.sendPartiallyReliableControl(report.command)
            _ = bundle.sendPartiallyReliableControl(NvstRtpNackStatsReport(frameNumber: frame,
                nackRequestsSent: UInt32(clamping: stats.nack.requestsSent),
                nackedPacketsRequested: UInt32(clamping: stats.nack.packetsRequested),
                nackedPacketsReceived: UInt32(clamping: stats.nack.packetsReceived),
                nackedPacketsUtilized: UInt32(clamping: stats.nack.packetsReceived),
                nackedPacketsRetried: UInt32(clamping: stats.nack.packetsRetried)).command)
        }
        if lastControlStatsAt.map({ Date().timeIntervalSince($0) >= NvstControlChannelStatsReport.transmitInterval }) ?? true {
            let stats = bundle.controlChannelStats
            _ = bundle.sendPartiallyReliableControl(NvstControlChannelStatsReport(timestampMicroseconds: clock.elapsedMicroseconds(),
                totalMessagesSent: stats.totalSent, totalMessagesFailed: stats.totalFailed, totalBytesSent: stats.totalBytes,
                commands: stats.commands).command)
            lastControlStatsAt = Date()
        }
    }

    private func activateInput() {
        guard !stopped, !activatedInput, let bundle, bundle.isInputReady else { return }
        activatedInput = true
        _ = bundle.sendControl(NvstInputActivation.enableInput(counter: 1, isEnabled: false))
        _ = bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: clock.elapsedMicroseconds(), connectedBitmap: registeredBitmap))
        _ = bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: true))
        _ = bundle.sendControl(NvstInputActivation.mimicRemoteCursor(isEnabled: true))
        _ = bundle.sendControl(.windowStateChange()); _ = bundle.sendControl(.systemStateChange())
        _ = bundle.sendControl(NvstInputActivation.enableInput(counter: UInt32(clamping: (pipeline?.snapshot.frameAcksSent ?? 0) + 1)))
        let haptics = NvstRemoteInput.framed(NvstRemoteInput.hapticsState(enabled: true),
            framing: .enveloped, sequence: inputSequence, timestampMicroseconds: clock.elapsedMicroseconds())
        _ = bundle.sendControl(NvstControlCommand(code: .remoteInput, payload: haptics))
    }

    /// One controller's state, as Kumori's pads report it: XInput buttons, triggers 0...255,
    /// sticks -32768...32767 with up positive. `connected` is the mask of every pad slot in use.
    @discardableResult
    func sendGamepad(slot: Int, connected: Int, buttons: Int, lt: Int, rt: Int, lx: Int, ly: Int, rx: Int, ry: Int) -> Bool {
        guard !stopped, activatedInput, let bundle else { return false }
        let mask = UInt16(truncatingIfNeeded: connected & 0x0f)
        let bitmap = mask | (mask << 8)
        if bitmap != registeredBitmap {
            registeredBitmap = bitmap
            _ = bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: clock.elapsedMicroseconds(), connectedBitmap: registeredBitmap))
        }
        let index = UInt16(slot & 3)
        let seq = (gamepadSequences[index] ?? 0) &+ 1
        gamepadSequences[index] = seq
        let pad = NvstGamepadPacket(sequence: seq, timestampMicroseconds: clock.elapsedMicroseconds(),
            buttons: UInt16(truncatingIfNeeded: buttons),
            leftTrigger: UInt8(clamping: lt), rightTrigger: UInt8(clamping: rt),
            leftStickX: Int16(clamping: lx), leftStickY: Int16(clamping: ly),
            rightStickX: Int16(clamping: rx), rightStickY: Int16(clamping: ry),
            gamepadIndex: index, connectedBitmap: bitmap)
        do { return bundle.sendInput(try pad.command.encoded) } catch { return false }
    }

    /// Relative mouse input, as Kumori's mouse mode reports it: a move, a wheel step (in
    /// Windows wheel units) and button changes, 1 left, 2 middle, 3 right. The same remote
    /// input packets OpenNOW's native client sends (NativeStreamNVSTInput, types 7 to 10).
    @discardableResult
    func sendMouse(dx: Int, dy: Int, wheel: Int, buttons: [(button: Int, pressed: Bool)]) -> Bool {
        guard !stopped, activatedInput, let bundle else { return false }
        var packets: [Data] = []
        if dx != 0 || dy != 0 {
            packets.append(NvstRemoteInput.mouseMove(deltaX: Int16(clamping: dx), deltaY: Int16(clamping: dy)))
        }
        if wheel != 0 { packets.append(NvstRemoteInput.mouseWheel(delta: Int16(clamping: wheel))) }
        for b in buttons {
            guard let button = NvstRemoteInput.Button(rawValue: UInt8(truncatingIfNeeded: b.button)) else { continue }
            packets.append(NvstRemoteInput.mouseButton(button, isPressed: b.pressed))
        }
        var sent = true
        for packet in packets {
            inputSequence &+= 1
            let framed = NvstRemoteInput.framed(packet, framing: .enveloped, sequence: inputSequence,
                                                timestampMicroseconds: clock.elapsedMicroseconds())
            sent = bundle.sendControl(NvstControlCommand(code: .remoteInput, payload: framed)) && sent
        }
        return sent
    }

    /// One key going down or up: Windows virtual-key code and modifier bits (shift 0x01).
    @discardableResult
    func sendKey(code: UInt16, modifiers: UInt16, down: Bool) -> Bool {
        guard !stopped, activatedInput, let bundle else { return false }
        inputSequence &+= 1
        let framed = NvstRemoteInput.framed(NvstRemoteInput.keyboard(virtualKey: code, modifiers: modifiers, isPressed: down),
                                            framing: .enveloped, sequence: inputSequence,
                                            timestampMicroseconds: clock.elapsedMicroseconds())
        return bundle.sendControl(NvstControlCommand(code: .remoteInput, payload: framed))
    }

    func requestKeyframe() {
        guard !stopped, lastKeyframeRequestAt.map({ Date().timeIntervalSince($0) >= 0.25 }) ?? true else { return }
        lastKeyframeRequestAt = Date()
        keyframeRequests += 1
        let controlSent = NativeStreamKeyframeRecovery.request(
            sendControl: { bundle?.sendControl($0) ?? false },
            sendUDP: { receiver?.requestKeyframe() })
        if controlSent { controlKeyframeRequests += 1 }
        else { udpKeyframeRequests += 1 }
        if bundle?.isFeedbackChannelOpen == true {
            if let ssrc = receiver?.stats.boundSSRC { feedback.updateMediaSSRC(ssrc) }
            try? feedback.sendKeyframeRequestNow()
            feedback.requestKeyframe()
        }
    }

    private func sample() async {
        guard !stopped, let receiver, let decoder, let pipeline else { return }
        let stats = receiver.stats
        if let ssrc = stats.boundSSRC { feedback.updateMediaSSRC(ssrc) }
        let sampledAt = ProcessInfo.processInfo.systemUptime
        let decoded = decoder.decodedFrameCount
        switch videoLiveness.observe(decoded: decoded, now: DispatchTime.now().uptimeNanoseconds) {
        case .none: break
        case .requestKeyframe: requestKeyframe()
        case .failed:
            fail(bundle?.isControlChannelOpen == true
                ? "Video stopped arriving from the rig."
                : "The rig's control channel didn't connect.")
            return
        }
        let counters = receiver.feedbackCounters
        var ping = receiver.roundTripMilliseconds
        if ping < 0, let rtsp { ping = await rtsp.controlRoundTripMilliseconds() }
        guard !stopped else { return }
        let state = pipeline.snapshot
        let detail = "hardware=\(decoder.isHardwareAccelerated) resolution=\(decoder.decodedResolution ?? "pending") output=\(decoder.outputPixelFormatName) bitstream=\(decoder.bitstreamFormat?.summary ?? "pending") failed=\(decoder.failedFrameCount) keyframeRequests=\(keyframeRequests) keyframes=\(stats.keyframesEmitted) fec=\(stats.recoveredPackets) nack=\(stats.nack.requestsSent) auth=\(stats.authenticatedPackets)"
        var nvstSample = NativeStreamNVSTSample(received: counters.framesEmitted, decoded: decoded, bytes: counters.bytesReceived,
            lost: stats.finalizedLossPackets, packets: stats.authenticatedPackets, resolution: decoder.decodedResolution,
            decodeMilliseconds: state.decodeP50Milliseconds, pingMilliseconds: ping >= 0 ? ping : nil,
            jitterMilliseconds: Double(stats.lastJitter) / 90, hardware: decoder.isHardwareAccelerated,
            pixelFormat: decoder.outputPixelFormatName, bitstream: decoder.bitstreamFormat?.summary ?? "pending", detail: detail)
        nvstSample.audioFormat = bundle?.audioFormatLabel
        nvstSample.resendRequests = UInt64(stats.nack.requestsSent)
        nvstSample.failed = UInt64(decoder.failedFrameCount)
        nvstSample.sampledAt = sampledAt
        onSample(nvstSample)
    }

    private func fail(_ reason: String) {
        guard !stopped, !didFinish else { return }
        didFinish = true
        onFailure(reason)
        Task { await self.close() }
    }

    private func terminate(_ event: NvstSeatTermination) {
        guard !stopped, !didFinish else { return }
        didFinish = true
        onTermination(event)
        Task { await self.close() }
    }

    func setAudioMuted(_ muted: Bool) {
        self.muted = muted
        bundle?.setRemoteAudioMuted(muted)
    }

    func close() async {
        guard !stopped else { return }
        stopped = true
        bundleGeneration &+= 1
        sampling?.cancel(); sampling = nil
        keepalive?.cancel(); keepalive = nil
        qos?.cancel(); qos = nil
        feedback.stop()
        receiver?.stop(); receiver = nil
        pipeline?.stop(); pipeline?.attach(bundle: nil); pipeline = nil
        bundle?.close(); bundle = nil
        // Hardware teardown can wait for output callbacks; keep it off the main actor.
        decoder?.invalidate(); decoder = nil
        reserver?.release(); reserver = nil
        let session = rtsp; rtsp = nil
        await session?.release("Kumori native transport closed")
    }
}
