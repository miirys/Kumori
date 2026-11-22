import Foundation
import LiveKitWebRTC
import SwiftUI

/// Starts a game, follows it through the queue, runs the stream and ends it.
@MainActor
final class Player: ObservableObject {
    enum Phase: Equatable {
        case starting(String)
        case queued(Int)
        case connecting(String)
        case live
        case ended(String, error: Bool)
    }

    @Published private(set) var phase: Phase?
    @Published private(set) var game: Game?
    @Published private(set) var stats = StreamStats()
    @Published private(set) var video: LKRTCVideoTrack?
    @Published private(set) var session: CloudSession?
    @Published var notice: String?
    @Published var menuOpen = false {
        didSet {
            pads.paused = menuOpen
            if !menuOpen { menuClosedAt = Date() }
        }
    }
    private var menuClosedAt = Date.distantPast
    @Published var muted = false { didSet { engine?.muted = muted; native?.muted = muted } }

    private let app: AppModel
    private let settings: Settings
    private let pads = Gamepads()
    private var engine: StreamEngine?
    /// The native receiver, for a session asked for as the native client.
    private var native: NativeEngine?
    /// The on-screen video view's feed. The stream view hands it over; the native receiver
    /// draws into it directly, as a WebRTC track does.
    weak var screen: PictureFeed?
    /// The output channel count the native session was asked for.
    private var nativeAudio = 2
    /// Set when a native 4K stream failed before its picture: the next native ask in this
    /// launch goes no higher than this, so 1440p is tried before the TV client's 1080p.
    private var nativeMaxHeight: Int?
    private var cloud: Cloudmatch?
    private var job: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastResume: ActiveSession?
    private var liveSince: Date?

    /// What the current (or last) launch did, step by step. Kept after it ends for About and
    /// the error screen.
    @Published private(set) var trace: LaunchTrace?
    /// Set by "Try 1080p60 H.264": this launch asks for the mode every membership and route
    /// accepts, with the codec every Apple TV decodes. Settings are left as they are.
    @Published private(set) var safeAttempt = false
    /// Video frames handed to the on-screen renderer in this attempt.
    private var framesShown = 0

    // How the session in hand was asked for, and whether it can still be swapped for another.
    private var route = Route.web
    private var routeFresh = false
    private var skipped = Set<Route>()
    private var askedHeight = 0
    private var pendingNote: String?
    private var sizeChecks = 0
    /// The size and rate last asked of the server, for when its answer doesn't say.
    private var asked: (width: Int, height: Int, fps: Int)?
    /// True when the session in hand was claimed, so its listing may still show the old mode.
    private var claimed = false
    /// A stream from this launch has been on screen. A session that has shown a picture is
    /// never ended for being silent.
    private var everLive = false
    /// The silent session picked up in this launch was already given back once.
    private var restartedSilent = false

    init(app: AppModel, settings: Settings) {
        self.app = app
        self.settings = settings
        pads.onMenu = { [weak self] in
            // The same press that closes the menu also arrives here, so wait a beat before reopening.
            guard let self, self.phase == .live, Date().timeIntervalSince(self.menuClosedAt) > 0.4 else { return }
            self.menuOpen = true
        }
    }

    var active: Bool { phase != nil }

    /// A session is still held on the server after the stream stopped, so it can be ended
    /// from the error screen instead of left running.
    var holdsSession: Bool { session != nil || lastResume != nil }

    /// What is really on screen, as a mode. Nil until a stream is connecting.
    var playing: StreamMode? {
        guard let phase, !isEnded(phase) else { return nil }
        guard let h = stats.height > 0 ? stats.height : session?.height else { return nil }
        return StreamMode.closest(height: h, fps: session?.fps ?? 60)
    }

    var playingFor: TimeInterval? { liveSince.map { Date().timeIntervalSince($0) } }

    private func isEnded(_ p: Phase) -> Bool {
        if case .ended = p { return true }
        return false
    }

    // MARK: Starting

    /// Starts `g`, or picks up its session if one is already running for the account.
    func play(_ g: Game) {
        if let running = app.session(for: g) {
            resume(running, game: g)
        } else {
            startFresh(g)
        }
    }

    /// The ways to ask for this mode. GeForce NOW decides how large a stream may be from the
    /// kind of client that asks. As the TV client it gave 1920 × 1080 at 60 fps to every 4K
    /// ask, at 60 and at 120 fps (build 9de1d9d, Debug page). Asked as the PC client over
    /// WebRTC, the rig never sent an offer (444ce95): a session asked for as the native client
    /// is streamed natively, over RTSPS and SRTP. So a mode above 1080p60 is asked for as the
    /// native client and played by the native receiver, the way the PC app and OpenNOW's tvOS
    /// client do it. If that fails, the TV client's 1080p60 is the fallback.
    private func routes(_ t: (width: Int, height: Int, fps: Int)) -> [Route] {
        guard NativeRequest.wanted(width: t.width, height: t.height, fps: t.fps) else { return [.web] }
        settings.expireFailedRoutes()
        return [Route.native].filter { !skipped.contains($0) && !settings.failedRoutes.contains($0) }
    }

    /// Whether the native client may be asked right now.
    private var nativeAllowed: Bool {
        settings.expireFailedRoutes()
        return !skipped.contains(.native) && !settings.failedRoutes.contains(.native)
    }

    /// The most the TV client has been given: 1080p at 60 fps.
    private func tvCap(_ t: (width: Int, height: Int, fps: Int)) -> (width: Int, height: Int, fps: Int) {
        Route.needsDesktop(width: t.width, height: t.height, fps: t.fps) ? (min(t.width, 1920), min(t.height, 1080), min(t.fps, 60)) : t
    }

    /// The mode to ask for: the one chosen in Settings, or the closest one the membership includes.
    private func target() -> (width: Int, height: Int, fps: Int) {
        if safeAttempt { return (1920, 1080, 60) }
        let m = settings.mode
        let fps = min(m.fps, Capabilities.maxFps)
        guard let mem = app.membership, mem.tier?.caseInsensitiveCompare("Ultimate") != .orderedSame, !mem.modes.isEmpty else { return (m.width, m.height, fps) }
        // A TV is 16:9. The list can also hold 16:10 and ultrawide modes, which would letterbox.
        let wide = mem.modes.filter { $0.width * 9 == $0.height * 16 }
        let modes = wide.isEmpty ? mem.modes : wide
        if modes.contains(where: { $0.height >= m.height && $0.fps >= fps }) { return (m.width, m.height, fps) }
        guard let best = modes.filter({ $0.height <= m.height && $0.fps <= fps }).max(by: { ($0.height, $0.fps) < ($1.height, $1.fps) }) else {
            return (m.width, m.height, fps)
        }
        notice = "Playing at \(name(best.height, best.fps)), the most your \(mem.tier.map { "\($0) " } ?? "")membership includes."
        return (best.width, best.height, best.fps)
    }

    private func name(_ height: Int, _ fps: Int) -> String { "\(height >= 2160 ? "4K" : "\(height)p") at \(fps) fps" }

    /// Where to ask for a rig: the chosen location, or wherever the account is served from.
    private func places() -> [(name: String?, url: String)] {
        if let r = app.regions.first(where: { $0.name == settings.region }) { return [(r.name, r.url)] }
        return [(nil, app.streamingBase)]
    }

    /// Starts a fresh record for a launch the player asked for. Retries inside one launch
    /// (a 4K route falling back, a reconnect) keep adding to the same record.
    private func newTrace() {
        trace = LaunchTrace()
        safeAttempt = false
        trace?.record(.select)
    }

    /// Called by the stream screen once it is up, or when it couldn't be shown.
    func presented(_ ok: Bool) {
        trace?.record(ok ? .presented : .presentFailed)
        if !ok, phase != nil {
            end("Kumori couldn't open the player. Try again.", error: true)
        }
    }

    /// Called from the renderer, off the main thread, when the first frame of a track reaches
    /// the on-screen video view.
    nonisolated func frameShown() {
        Task { @MainActor in
            guard self.engine != nil || self.native != nil else { return }
            self.framesShown += 1
            guard self.framesShown == 1 else { return }
            self.trace?.once(.firstFrame)
            self.goLive()
        }
    }

    private func begin(_ g: Game?, _ obtain: @escaping @MainActor (Cloudmatch) async throws -> CloudSession) {
        stopEngine()
        job?.cancel()
        // A launch from the browsing screens starts a new record; a retry, reconnect or
        // fallback inside the player keeps adding to the one in hand.
        if trace == nil || phase == nil { newTrace() }
        framesShown = 0
        game = g
        stats = StreamStats()
        menuOpen = false
        notice = nil
        sizeChecks = 0
        liveSince = nil
        let cm = Cloudmatch { [app] in try await app.serviceToken() }
        cloud = cm
        job = Task {
            do {
                let s = try await obtain(cm)
                if Task.isCancelled { return }
                session = s
                connect(s)
            } catch {
                // A request cancelled in flight throws URLError(.cancelled), not
                // CancellationError. Either way this attempt was called off: say nothing.
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                let e = error as? SessionError
                trace?.record(.failed, TraceFields(http: e?.http, status: e?.statusCode, note: "before the rig was ready"))
                end(error.localizedDescription, error: true)
            }
        }
    }

    private func startFresh(_ g: Game) {
        lastResume = nil
        claimed = false
        route = .web
        routeFresh = false
        let v = g.launchVariant
        begin(g) { [self] cm in
            phase = .starting("Requesting a rig")
            let t = target()
            var ask = LaunchRequest(appId: v?.id ?? g.id, width: t.width, height: t.height, fps: t.fps)
            ask.title = g.title
            ask.accountLinked = v?.owned ?? true
            // The safe retry asks for nothing the rig could fail to apply.
            ask.dlss = safeAttempt ? DlssOverrides() : settings.dlss
            askedHeight = t.height
            var s: CloudSession?
            let wantsNative = NativeRequest.wanted(width: t.width, height: t.height, fps: t.fps)
            let triedBefore = wantsNative && settings.failedRoutes.contains(.native) && !skipped.contains(.native)
            if routes(t).contains(.native) {
                s = try await tryNative(cm, ask)
            }
            if s == nil {
                if wantsNative {
                    // The native stream didn't work. The TV client gets 1080p at 60 fps at most.
                    let c = tvCap(t)
                    pendingNote = triedBefore
                        ? "This is \(name(c.height, c.fps)), the most GeForce NOW gives the TV client. The native stream didn't work in the last day."
                        : "This is \(name(c.height, c.fps)), the most GeForce NOW gives the TV client. The native stream didn't work this time."
                    ask.width = c.width
                    ask.height = c.height
                    ask.fps = c.fps
                    askedHeight = c.height
                }
                s = try await startWeb(cm, ask)
            }
            if Task.isCancelled, let made = s {
                // Called off while the request was on its way, but the rig was made anyway.
                // Give it back, or it would block the next launch. A cancelled task can't
                // send requests, so this goes in a task of its own.
                Task { await cm.stop(base: made.controlBase, id: made.id) }
                throw CancellationError()
            }
            session = s
            return try await waitForSeat(cm, s!)
        }
    }

    /// Asks as the native client: 4K at 60 fps, then 1440p at 120 fps where the display
    /// shows it, then 1440p at 60 (see `NativeRequest.ladder`). A refusal of a mode steps down,
    /// one fresh allocation at a time. Nil when it gave no rig, or one with no native endpoint;
    /// the caller then asks as the TV client. An account refusal stops everything.
    private func tryNative(_ cm: Cloudmatch, _ base: LaunchRequest) async throws -> CloudSession? {
        let ladder = NativeRequest.ladder(width: base.width, height: base.height, fps: base.fps, displayMaxFps: Capabilities.maxFps)
            .filter { $0.height <= (nativeMaxHeight ?? .max) }
        guard !ladder.isEmpty else { return nil }
        let spots = places()
        let channels = NativeEngine.audioChannels
        var why: String?
        do {
            let (s, got, rung) = try await ModeLadder.run(
                ladder, places: spots.count,
                attempt: { [self] (mode: ModeRequest, i: Int) async throws -> CloudSession in
                    var a = base
                    a.width = mode.width
                    a.height = mode.height
                    a.fps = mode.fps
                    a.route = .native
                    a.audioChannels = channels
                    trace?.record(.allocate, TraceFields(width: mode.width, height: mode.height, fps: mode.fps, n: i, note: "as native client"))
                    return try await cm.create(base: spots[i].url, a)
                },
                onRefused: { [self] mode, error in
                    let e = error as? SessionError
                    why = e?.detail ?? e?.message
                    trace?.record(.refused, TraceFields(width: mode.width, height: mode.height, fps: mode.fps, http: e?.http, status: e?.statusCode, note: "as native client"))
                },
                onRung: { [self] mode, _ in phase = .starting("Trying \(name(mode.height, mode.fps))") }
            )
            route = .native
            routeFresh = true
            nativeAudio = channels
            asked = (got.width, got.height, got.fps)
            askedHeight = got.height
            trace?.record(.accepted, TraceFields(width: got.width, height: got.height, fps: got.fps, n: rung, note: "as native client"))
            settings.note4k("Asked as the native client for \(name(got.height, got.fps)), got a rig")
            if rung > 0 || got.height < base.height || got.fps < base.fps { pendingNote = "Playing at \(name(got.height, got.fps)). \(name(base.height, base.fps)) didn't start for this game." }
            return s
        } catch let e as SessionError {
            if e.account { throw e }
            skipped.insert(.native)
            settings.note4k("Asked as the native client, refused: \(why ?? e.detail ?? e.message)")
            return nil
        }
    }

    /// Asks as the web client. If the mode is turned down, tries the same size at 60 fps,
    /// then each smaller size (see `ModeLadder`). What the service accepted is what the
    /// stream then asks the rig for.
    private func startWeb(_ cm: Cloudmatch, _ ask: LaunchRequest) async throws -> CloudSession {
        let wanted = ModeRequest(width: ask.width, height: ask.height, fps: ask.fps)
        let spots = places()
        let (s, got, rung) = try await ModeLadder.run(
            ModeLadder.candidates(for: wanted), places: spots.count,
            attempt: { [self] (mode: ModeRequest, i: Int) async throws -> CloudSession in
                var a = ask
                a.width = mode.width
                a.height = mode.height
                a.fps = mode.fps
                a.route = .web
                trace?.record(.allocate, TraceFields(width: mode.width, height: mode.height, fps: mode.fps, n: i, note: "as TV client"))
                return try await cm.create(base: spots[i].url, a)
            },
            onRefused: { [self] mode, error in
                let e = error as? SessionError
                trace?.record(.refused, TraceFields(width: mode.width, height: mode.height, fps: mode.fps, http: e?.http, status: e?.statusCode))
            },
            onRung: { [self] mode, _ in phase = .starting("Trying \(name(mode.height, mode.fps))") }
        )
        route = .web
        asked = (got.width, got.height, got.fps)
        askedHeight = got.height
        trace?.record(.accepted, TraceFields(width: got.width, height: got.height, fps: got.fps, n: rung))
        if rung > 0 { notice = "Playing at \(name(got.height, got.fps)). GeForce NOW wouldn't start \(name(ask.height, ask.fps)) for this game." }
        return s
    }

    /// Takes over a session running elsewhere (or left running here).
    func resume(_ a: ActiveSession, game g: Game?) {
        lastResume = a
        begin(g ?? app.game(for: a)) { [self] cm in
            phase = .starting(a.status == 1 ? "Following your session" : "Taking over your session")
            trace?.record(.allocate, TraceFields(note: "resume"))
            cm.onQueue = { [weak self] position in
                Task { @MainActor in
                    guard let self, self.cloud === cm, let p = self.phase, !self.isEnded(p), p != .live else { return }
                    self.phase = position > 0 ? .queued(position) : .starting("Following your session")
                }
            }
            // Resume at the mode the session runs at, not the one in Settings: a rig asked to come
            // back at another size can fail to. Settings stay as they are for the next game.
            let s = try await cm.claim(a, claimRequest(a.appId, keep: nil), adopt: true, allowNative: nativeAllowed)
            if let w = s.width, let h = s.height, w > 0, h > 0 {
                let f = s.fps ?? asked?.fps ?? 60
                asked = (w, h, f)
                askedHeight = h
                route = s.transport == .nvst ? .native : .web
                let m = settings.mode
                if m.height != h || m.fps != f { pendingNote = "This session runs at \(name(h, f)), so it was picked up at that. Your settings apply to the next game." }
            }
            trace?.record(.seatReady, TraceFields(width: s.width, height: s.height, fps: s.fps, note: "resume"))
            return s
        }
    }

    /// The request for a session that already exists. It is only asked for in a 4K way that
    /// has worked before, or the one it was started with.
    private func claimRequest(_ appId: String, keep: Route?) -> LaunchRequest {
        let t = target()
        route = .web
        if let r = routes(t).first(where: { $0 == keep || $0 == settings.route4k }) { route = r }
        routeFresh = false
        let m = route == .web ? tvCap(t) : t
        askedHeight = m.height
        var ask = LaunchRequest(appId: appId, width: m.width, height: m.height, fps: m.fps)
        ask.route = route
        asked = (ask.width, ask.height, ask.fps)
        claimed = true
        return ask
    }

    private func waitForSeat(_ cm: Cloudmatch, _ first: CloudSession) async throws -> CloudSession {
        var s = first
        var misses = 0
        while !s.ready {
            guard (1...3).contains(s.status) else { throw SessionError(message: "The session ended before it was ready.") }
            if s.adsRequired {
                // A place in the queue that was asked for just now is given back. Left
                // there, it would never start and would block every other launch.
                if lastResume == nil { await cm.stop(base: s.controlBase, id: s.id) }
                throw SessionError(message: "Your membership shows ads in the queue, which this app can't play. A paid membership skips them.")
            }
            let q = s.queuePosition ?? 0
            if q > 0 { trace?.once(.queued, TraceFields(n: q)) }
            phase = q > 0 ? .queued(q) : .starting("Preparing your rig")
            try await Task.sleep(nanoseconds: q > 10 ? 4_000_000_000 : 1_500_000_000)
            do {
                s = try await cm.poll(s)
                // Only failures in a row count: a long queue sees the odd one.
                misses = 0
            } catch let e as SessionError where e.statusCode != 0 {
                throw e
            } catch {
                misses += 1
                if misses > 20 { throw error }
            }
            session = s
        }
        trace?.record(.seatReady, TraceFields(width: s.width, height: s.height, fps: s.fps))
        return s
    }

    // MARK: The stream

    private func connect(_ s: CloudSession) {
        phase = .connecting("Connecting to the rig")
        if s.transport == .nvst { connectNative(s); return }
        let m = settings.mode
        // A claimed session can still list the mode it had before, so what was just asked
        // for wins there. A new session's own answer is the better source.
        let width = (claimed ? asked?.width : nil) ?? s.width ?? asked?.width ?? m.width
        let height = (claimed ? asked?.height : nil) ?? s.height ?? asked?.height ?? m.height
        let fps = (claimed ? asked?.fps : nil) ?? s.fps ?? asked?.fps ?? 60
        let codec: CodecChoice = safeAttempt ? .h264 : settings.codec
        HardwareDecoders.allowSoftwareAV1 = codec == .av1
        let e = StreamEngine(session: s, config: StreamConfig(
            width: width, height: height, fps: min(fps, Capabilities.maxFps),
            maxKbps: settings.bitrateMbps * 1000, codec: codec.rawValue
        ))
        e.trace = trace
        e.muted = muted
        e.onProgress = { [weak self, weak e] step in
            Task { @MainActor in
                guard let self, self.engine === e, self.phase != .live, !(self.phase.map(self.isEnded) ?? true) else { return }
                self.phase = .connecting(step)
            }
        }
        e.onVideo = { [weak self, weak e] track in
            Task { @MainActor in if let self, self.engine === e { self.video = track } }
        }
        e.onStats = { [weak self, weak e] stats in
            Task { @MainActor in if let self, self.engine === e { self.update(stats) } }
        }
        e.onTimeWarning = { [weak self] left in
            Task { @MainActor in
                let mins = (left + 59) / 60
                self?.notice = "Your session ends in \(mins) \(mins == 1 ? "minute" : "minutes")."
            }
        }
        e.onFailed = { [weak self, weak e] message in
            Task { @MainActor in if let self, self.engine === e { self.end(message, error: true) } }
        }
        e.onOffered = { [weak self, weak e] in
            // The pre-offer clock belongs to the engine. From the offer on, give the picture
            // its own deadline.
            Task { @MainActor in if let self, let e, self.engine === e { self.armWatchdog(e, seconds: SignalingPolicy.standard.firstPicture) } }
        }
        engine = e
        pads.send = { [weak e] slot, connected, buttons, lt, rt, lx, ly, rx, ry in
            e?.sendGamepad(slot: slot, connected: connected, buttons: buttons, lt: lt, rt: rt, lx: lx, ly: ly, rx: rx, ry: ry)
        }
        pads.start()
        e.start()
        // The engine ends a launch that gets no offer within its own budget. This is only a
        // backstop in case that never reports.
        // A session picked up from the list is already running, so its rig answers fast or
        // not at all: one started as the PC client never sends a WebRTC offer (a45faa4 log,
        // 00:35 and 00:36: sign-in acknowledged, then nothing for 80 s). Give it 40 s.
        armWatchdog(e, seconds: lastResume != nil && !everLive ? 40 : SignalingPolicy.standard.preOffer + 10)
    }

    /// If no picture arrives in time, say how far the video got instead of spinning forever.
    private func armWatchdog(_ e: StreamEngine, seconds: Double) {
        watchdog?.cancel()
        watchdog = Task { [weak self, weak e] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, let e, !Task.isCancelled, self.engine === e, self.phase != .live else { return }
            let where_ = MediaCheckpoint.from(offered: e.offered, packets: self.stats.packetsReceived, decoded: self.stats.framesDecoded, delivered: self.framesShown)
            self.trace?.record(.failed, TraceFields(codec: e.codec, note: "no picture in time"))
            self.end(where_.message(codec: e.codec), error: true)
        }
    }

    /// Streams a session asked for as the native client with the native receiver. Such a
    /// session never sends a WebRTC offer, so it is never handed to `StreamEngine`.
    private func connectNative(_ s: CloudSession) {
        // The server's mode first: it is what the rig was set up for. A claimed session can
        // still list the old one, so there what was just asked for wins.
        let width = (claimed ? asked?.width : nil) ?? s.width ?? asked?.width ?? settings.mode.width
        let height = (claimed ? asked?.height : nil) ?? s.height ?? asked?.height ?? settings.mode.height
        let fps = (claimed ? asked?.fps : nil) ?? s.fps ?? asked?.fps ?? 60
        guard !s.nativeEndpoints.isEmpty else {
            trace?.record(.failed, TraceFields(note: "native session without an RTSPS endpoint"))
            end("GeForce NOW gave this session no native stream address.", error: true)
            return
        }
        guard let screen else {
            end("Kumori couldn't open the player. Try again.", error: true)
            return
        }
        let codec = Self.nativeCodec(safeAttempt ? .h264 : settings.codec, fps: fps)
        // 50 Mbps is the setting's default, so it is read as "not chosen": the mode's own
        // balanced rate is used then (50 Mbps for 4K60, 38 Mbps for 1440p120).
        let chosen = settings.bitrateMbps == 50 ? nil : settings.bitrateMbps
        let options = NativeStreamOptions(
            sessionID: s.id, endpoints: s.nativeEndpoints, width: width, height: height, fps: fps,
            codec: codec, bitrateKbps: NativeRequest.bitrateKbps(width: width, height: height, fps: fps, chosenMbps: chosen),
            audioChannelCount: nativeAudio, displayFPS: Capabilities.maxFps, muted: muted
        )
        screen.reset()
        screen.onFirst = { [weak self] in self?.frameShown() }
        let n = NativeEngine(options: options, feed: screen)
        n.trace = trace
        n.muted = muted
        n.onProgress = { [weak self, weak n] step in
            guard let self, let n, self.native === n, self.phase != .live, !(self.phase.map(self.isEnded) ?? true) else { return }
            self.phase = .connecting(step)
            // The rig is sending: give the picture its own deadline.
            if n.playing { self.armNativeWatchdog(n, seconds: SignalingPolicy.standard.firstPicture) }
        }
        n.onStats = { [weak self, weak n] stats in
            if let self, let n, self.native === n { self.update(stats) }
        }
        n.onFailed = { [weak self, weak n] message in
            if let self, let n, self.native === n { self.end("The native stream stopped: \(message)", error: true) }
        }
        n.onTerminated = { [weak self, weak n] message in
            if let self, let n, self.native === n { self.end(message, error: self.liveSince == nil) }
        }
        native = n
        pads.send = { [weak n] slot, connected, buttons, lt, rt, lx, ly, rx, ry in
            n?.sendGamepad(slot: slot, connected: connected, buttons: buttons, lt: lt, rt: rt, lx: lx, ly: ly, rx: rx, ry: ry)
        }
        pads.start()
        n.start()
        // The handshake has its own timeouts. This is the backstop for a rig that never answers.
        armNativeWatchdog(n, seconds: SignalingPolicy.standard.preOffer + 10)
    }

    /// The codec to ask the native stream for. Automatic means AV1 where this Apple TV decodes
    /// it in hardware (7a1adc8, 4K60: AV1 decoded in 6 to 7 ms a frame), HEVC elsewhere. Above
    /// 60 fps HEVC, until AV1 at 120 has been seen to decode natively (on WebRTC it didn't).
    nonisolated static func nativeCodec(_ choice: CodecChoice, fps: Int, av1Hardware: Bool = HardwareDecoders.av1Hardware) -> NativeStreamVideoCodec {
        switch choice {
        case .h264: return .h264
        case .hevc: return .h265
        case .auto, .av1: return fps <= 60 && av1Hardware ? .av1 : .h265
        }
    }

    private func armNativeWatchdog(_ n: NativeEngine, seconds: Double) {
        watchdog?.cancel()
        watchdog = Task { [weak self, weak n] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, let n, !Task.isCancelled, self.native === n, self.phase != .live else { return }
            let at = n.lastStage.map { "\($0.rawValue)" } ?? "before connecting"
            // The note is fixed text; the last step reached is in the log (NativeEngine).
            self.trace?.record(.failed, TraceFields(codec: n.codec, note: "native: no picture in time"))
            self.end(n.playing
                ? "The rig started the native stream, but no picture arrived. Packets: \(self.stats.packetsReceived), frames decoded: \(self.stats.framesDecoded)."
                : "The native stream didn't get past \(at).", error: true)
        }
    }

    /// The first picture is up: hand the controller to the game.
    private func goLive() {
        guard phase != .live, !(phase.map(isEnded) ?? true) else { return }
        phase = .live
        watchdog?.cancel()
        trace?.once(.live, TraceFields(width: stats.width > 0 ? stats.width : nil, height: stats.height > 0 ? stats.height : nil, codec: stats.codec))
        routeFresh = false
        if let n = pendingNote { notice = n }
        pendingNote = nil
        if liveSince == nil { liveSince = Date() }
        everLive = true
    }

    private func update(_ s: StreamStats) {
        stats = s
        if s.packetsReceived > 0 { trace?.once(.firstPackets, TraceFields(codec: s.codec)) }
        if s.framesDecoded > 0 {
            trace?.once(.firstDecoded, TraceFields(width: s.width, height: s.height, codec: s.codec))
            // A decoded frame is the old signal for "playing". The renderer's first frame
            // usually comes first; either one is enough.
            goLive()
        }
        // A few seconds in, compare the picture with what was asked for. A 4K way of asking
        // that really gave 4K is kept. One that gave less is not used again.
        // (Asking as the PC client is kept while it gives more than the TV client's 1080p.)
        guard s.height > 0 else { return }
        sizeChecks += 1
        guard sizeChecks == 3 else { return }
        guard route == .desktop || route == .native else {
            // A running session can refuse to change size. Say so, so the menu and the
            // picture don't quietly disagree.
            if claimed, askedHeight > 0, notice == nil, abs(s.height - askedHeight) > askedHeight / 10 {
                notice = "GeForce NOW kept this session at \(s.height)p. End the session and start the game again to play at \(askedHeight)p."
            }
            return
        }
        let ok = askedHeight <= 1080 || s.height > 1080
        settings.markRoute(route, worked: ok)
        settings.note4k("Asked as \(route.name) for \(askedHeight)p, playing at \(s.width) × \(s.height)")
        guard notice == nil else { return }
        if !ok {
            notice = "GeForce NOW is sending \(s.height)p to \(route.name) too. The next game will ask as the TV client."
        } else if s.height < askedHeight - askedHeight / 10 {
            notice = "GeForce NOW is sending \(s.height)p for this game, not \(askedHeight >= 2160 ? "4K" : "\(askedHeight)p")."
        }
    }

    /// A stream asked for in one of the 4K ways failed before any picture. Remember that and
    /// start again the next way. A stream that was already playing is left alone.
    private func fallBack(_ message: String) -> Bool {
        guard route != .web, liveSince == nil else { return false }
        let g = game
        let r = lastResume
        guard r != nil || (routeFresh && g != nil) else { return false }
        settings.note4k("\(route.name.prefix(1).uppercased() + route.name.dropFirst()) failed before the first picture: \(message)")
        let s = session
        let cm = cloud
        let fresh = routeFresh
        // A native 4K stream that failed steps down to native 1440p once, on a new rig,
        // before the TV client's 1080p.
        if route == .native, fresh, r == nil, let g, askedHeight > 1440, nativeMaxHeight == nil {
            nativeMaxHeight = 1440
            stopEngine()
            routeFresh = false
            phase = .starting("Trying 1440p")
            job?.cancel()
            job = Task {
                if let s, let cm { await cm.stop(base: s.controlBase, id: s.id) }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled { startFresh(g) }
            }
            return true
        }
        settings.markRoute(route, worked: false)
        skipped.insert(route)
        stopEngine()
        route = .web
        routeFresh = false
        if let r, !fresh {
            resume(r, game: g)
            return true
        }
        phase = .starting("Asking again as the TV client")
        job?.cancel()
        job = Task {
            if let s, let cm { await cm.stop(base: s.controlBase, id: s.id) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled, let g { startFresh(g) }
        }
        return true
    }

    /// Changes the resolution. With a game running, the stream reconnects to the same rig at
    /// the new size. The game itself keeps going.
    func changeMode(_ m: StreamMode) {
        // Picking the chosen mode again is a way to ask for it once more, when the stream
        // is playing at something else.
        if m == settings.mode {
            guard let now = playing, now != m else { return }
        }
        settings.mode = m
        menuOpen = false
        guard let s = session, s.ready, let phase, !isEnded(phase) else { return }
        reconnect(s, "Switching to \(m.label)")
    }

    /// Connects again to the rig in hand, asking for the mode that is chosen now.
    private func reconnect(_ s: CloudSession, _ step: String) {
        let appId = lastResume?.appId ?? game?.launchVariant?.id ?? game?.id ?? ""
        let a = ActiveSession(sessionId: s.id, appId: appId, base: s.controlBase, host: Cloudmatch.host(of: s.controlBase))
        // Kept so a 4K way that fails here can still fall back to the web client.
        lastResume = a
        let keep = route
        begin(game) { [self] cm in
            phase = .starting(step)
            return try await cm.claim(a, claimRequest(appId, keep: keep))
        }
    }

    /// Starts the game again at 1080p, 60 fps, H.264, SDR: the mode to try when a launch
    /// fails, since every membership and route accepts it. Settings are left as they are.
    func retrySafe() {
        safeAttempt = true
        trace?.record(.select, TraceFields(width: 1920, height: 1080, fps: 60, codec: "H264", note: "safe mode"))
        // The player screen stays up throughout, so there is nothing to dismiss and present again.
        if let s = session, s.ready {
            reconnect(s, "Trying 1080p at 60 fps with H.264")
        } else if let r = lastResume {
            resume(r, game: game)
        } else if let g = game {
            startFresh(g)
        } else {
            finish()
        }
    }

    /// Whether the error screen should offer the 1080p60 H.264 retry.
    var offerSafeRetry: Bool {
        guard !safeAttempt, game != nil || lastResume != nil, liveSince == nil else { return false }
        return settings.mode.height != 1080 || settings.mode.fps != 60 || settings.codec != .h264
    }

    func retry() {
        trace?.record(.select, TraceFields(note: "try again"))
        if let s = session, s.ready {
            reconnect(s, "Reconnecting")
        } else if let r = lastResume {
            resume(r, game: game)
        } else if let g = game {
            play(g)
        } else {
            finish()
        }
    }

    func refreshPicture() {
        engine?.requestKeyframe("user")
        native?.requestKeyframe()
    }

    // MARK: Ending

    /// Backs out of a stream that isn't up yet. A game that was already running in the cloud
    /// (a resume, a reconnect, a mode switch) is left running. Only a rig that was asked for
    /// just now is given back.
    func cancel() {
        trace?.record(.cancelled)
        if lastResume != nil { leave() } else { quit() }
    }

    /// The app is going to the background.
    func background() {
        if let phase, isEnded(phase) {
            dismiss()
        } else if session == nil && lastResume == nil {
            quit()
        } else {
            leave()
        }
    }

    /// Leaves the stream but keeps the game running in the cloud, to resume later.
    func leave() {
        if phase != nil { trace?.record(.left) }
        stopEngine()
        job?.cancel()
        finish()
        Task { await app.refreshSessions() }
    }

    /// Ends the session on the server. The screen goes back at once; the ending itself
    /// carries on behind it until the server no longer lists the session.
    func quit() {
        let s = session
        let cm = cloud
        let resumed = lastResume
        stopEngine()
        job?.cancel()
        finish()
        if let s, let cm {
            var bases = [s.controlBase]
            if let r = resumed { bases += Cloudmatch.endBases(r) }
            bases += places().map(\.url)
            endForSure(s.id, cm, bases)
        } else if let r = resumed {
            quit(r)
        } else {
            Task { await app.refreshSessions() }
        }
    }

    /// Ends a session running elsewhere without opening it.
    func quit(_ a: ActiveSession) {
        endForSure(a.sessionId, Cloudmatch { [app] in try await app.serviceToken() }, Cloudmatch.endBases(a))
    }

    /// Asks the server to end a session, then checks that it is gone, and asks again where
    /// the server still lists it, up to three times. The session is off Home from the start.
    private func endForSure(_ id: String, _ cm: Cloudmatch, _ first: [String]) {
        app.hideWhileEnding(id)
        Task { [app] in
            var bases = first
            var accepted = false
            for round in 0..<3 {
                if await cm.end(id: id, bases: bases) { accepted = true }
                try? await Task.sleep(nanoseconds: round == 0 ? 1_000_000_000 : 2_500_000_000)
                await app.refreshSessions()
                guard let still = app.listedSession(id) else { break }
                // Still listed: ask where the list says it lives, then everywhere else again.
                bases = Cloudmatch.endBases(still) + first
            }
            // The server took the end and only lists it as winding down: keep it off Home.
            // Still queued, ready or streaming: show it again, so it can be ended once more.
            if accepted, ![1, 2, 3].contains(app.listedSession(id)?.status ?? 0) { return }
            app.doneEnding(id)
        }
    }

    func dismiss() { finish() }

    private func end(_ message: String, error: Bool) {
        if error, fallBack(message) { return }
        if error, restartSilentSession() { return }
        if error, trace?.events.last?.stage != .failed { trace?.record(.failed) }
        // A rig asked for just now that never sent its offer won't send one later. Give it
        // back, so it doesn't use up play time or block the next launch, and so Try Again
        // asks for a new rig instead of signing in to the same silent one. A session picked
        // up from elsewhere is left alone: a game may be running on it.
        if error, lastResume == nil, !claimed, !(trace?.has(.offer) ?? false), !(trace?.has(.nativePlay) ?? false), let s = session, let cm = cloud {
            session = nil
            Task { await cm.stop(base: s.controlBase, id: s.id) }
        }
        stopEngine()
        menuOpen = false
        phase = .ended(message, error: error)
        Task { await app.refreshSessions() }
    }

    /// A session picked up from the list that never sent its offer, nor started natively, and
    /// never showed a picture here, can't be streamed: waiting for it again only hangs on
    /// "Waiting for the rig" again. End it and start the game fresh, once per launch.
    private func restartSilentSession() -> Bool {
        guard lastResume != nil, !everLive, !restartedSilent, !(trace?.has(.offer) ?? false),
              !(trace?.has(.nativePlay) ?? false),
              let g = game, let s = session, let cm = cloud else { return false }
        restartedSilent = true
        trace?.record(.failed, TraceFields(note: "picked-up session sent no offer, starting fresh"))
        settings.note4k("A running session sent no offer; it was ended and the game started fresh")
        stopEngine()
        session = nil
        pendingNote = "The running session didn't answer, so it was ended and the game started again."
        phase = .starting("Starting the game again")
        job?.cancel()
        job = Task {
            await cm.stop(base: s.controlBase, id: s.id)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { startFresh(g) }
        }
        return true
    }

    private func finish() {
        menuOpen = false
        phase = nil
        session = nil
        game = nil
        lastResume = nil
        stats = StreamStats()
        route = .web
        routeFresh = false
        skipped = []
        pendingNote = nil
        liveSince = nil
        asked = nil
        claimed = false
        nativeMaxHeight = nil
        safeAttempt = false
        everLive = false
        restartedSilent = false
        framesShown = 0
    }

    private func stopEngine() {
        watchdog?.cancel()
        pads.stop()
        pads.send = nil
        engine?.close()
        engine = nil
        video = nil
        if let n = native {
            n.close()
            native = nil
            screen?.onFirst = nil
            screen?.reset()
        }
    }
}

#if DEBUG
/// Puts the player in a given state for the fixture harness. Nothing connects.
extension Player {
    func applyFixture(phase: Phase?, game: Game?, stats: StreamStats = StreamStats(),
                      menuOpen: Bool = false, notice: String? = nil, liveFor: TimeInterval? = nil) {
        self.phase = phase
        self.game = game
        self.stats = stats
        self.menuOpen = menuOpen
        self.notice = notice
        liveSince = liveFor.map { Date().addingTimeInterval(-$0) }
    }
}
#endif
