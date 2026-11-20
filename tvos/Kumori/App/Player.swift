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
    @Published var muted = false { didSet { engine?.muted = muted } }

    private let app: AppModel
    private let settings: Settings
    private let pads = Gamepads()
    private var engine: StreamEngine?
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

    /// The ways to ask for a stream of this height, most promising first. GeForce NOW decides
    /// how large a stream may be from the kind of client that asks, and the web client stops
    /// at 1440p. So 4K is asked for in other ways until one gives a real 4K picture.
    private func routes(_ height: Int) -> [Route] {
        guard height >= 2160 else { return [.web] }
        settings.expireFailedRoutes()
        var order: [Route] = []
        if let known = settings.route4k { order.append(known) }
        for r in [Route.tv, .desktop] where !order.contains(r) { order.append(r) }
        return order.filter { !skipped.contains($0) && !settings.failedRoutes.contains($0) }
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
            guard self.engine != nil else { return }
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
            for r in routes(t.height) where r != .web {
                s = try await tryRoute(cm, ask, r)
                if s != nil { break }
            }
            if s == nil {
                if t.height >= 2160 {
                    // No way of asking gave 4K. The web client's best is 1440p.
                    pendingNote = "GeForce NOW didn't give a 4K rig this time, so this is 1440p."
                    askedHeight = 1440
                    ask.width = 2560
                    ask.height = 1440
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
            // A 4K route keeps what it asked for; the web ladder already noted what it got.
            if route != .web { asked = (ask.width, ask.height, ask.fps) }
            session = s
            return try await waitForSeat(cm, s!)
        }
    }

    /// Asks for a 4K rig one way. Nil when that way gave none, or gave a smaller picture than
    /// was asked for. The caller then tries the next way.
    private func tryRoute(_ cm: Cloudmatch, _ base: LaunchRequest, _ r: Route) async throws -> CloudSession? {
        var ask = base
        ask.route = r
        var why: String?
        for place in places() {
            do {
                trace?.record(.allocate, TraceFields(width: ask.width, height: ask.height, fps: ask.fps, note: "4K route"))
                let s = try await cm.create(base: place.url, ask)
                if let got = s.height, got < ask.height {
                    // The answer already says the rig is smaller. Give it back and move on.
                    await cm.stop(base: s.controlBase, id: s.id)
                    settings.markRoute(r, worked: false)
                    settings.note4k("Asked as \(r.name), offered \(got)p")
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    return nil
                }
                route = r
                routeFresh = true
                settings.note4k("Asked as \(r.name), got a rig")
                return s
            } catch let e as SessionError {
                trace?.record(.refused, TraceFields(width: ask.width, height: ask.height, fps: ask.fps, http: e.http, status: e.statusCode, note: "4K route"))
                if e.account { throw e }
                why = e.detail ?? e.message
                if !e.stepDown { break }
            }
        }
        skipped.insert(r)
        settings.note4k("Asked as \(r.name), refused: \(why ?? "no reason given")")
        return nil
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
                trace?.record(.allocate, TraceFields(width: mode.width, height: mode.height, fps: mode.fps, n: i))
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
            let s = try await cm.claim(a, claimRequest(a.appId, keep: nil))
            trace?.record(.seatReady, TraceFields(width: s.width, height: s.height, fps: s.fps, note: "resume"))
            return s
        }
    }

    /// The request for a session that already exists. It is only asked for in a 4K way that
    /// has worked before, or the one it was started with.
    private func claimRequest(_ appId: String, keep: Route?) -> LaunchRequest {
        let t = target()
        route = .web
        if t.height >= 2160, let r = routes(t.height).first(where: { $0 == keep || $0 == settings.route4k }) { route = r }
        routeFresh = false
        let small = route == .web && t.height >= 2160
        askedHeight = small ? 1440 : t.height
        var ask = LaunchRequest(appId: appId, width: small ? 2560 : t.width, height: askedHeight, fps: t.fps)
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
        armWatchdog(e, seconds: SignalingPolicy.standard.preOffer + 10)
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
        guard s.height > 0 else { return }
        sizeChecks += 1
        guard sizeChecks == 3 else { return }
        guard askedHeight >= 2160, route != .web else {
            // A running session can refuse to change size. Say so, so the menu and the
            // picture don't quietly disagree.
            if claimed, askedHeight > 0, askedHeight < 2160, notice == nil, abs(s.height - askedHeight) > askedHeight / 10 {
                notice = "GeForce NOW kept this session at \(s.height)p. End the session and start the game again to play at \(askedHeight)p."
            }
            return
        }
        let ok = s.height >= 2000
        settings.markRoute(route, worked: ok)
        settings.note4k("Asked as \(route.name), playing at \(s.width) × \(s.height)")
        if !ok, notice == nil { notice = "GeForce NOW is sending \(s.height)p, not 4K. The next game will ask for 4K another way." }
    }

    /// A stream asked for in one of the 4K ways failed before any picture. Remember that and
    /// start again the next way. A stream that was already playing is left alone.
    private func fallBack(_ message: String) -> Bool {
        guard route != .web, liveSince == nil else { return false }
        let g = game
        let r = lastResume
        guard r != nil || (routeFresh && g != nil) else { return false }
        settings.note4k("\(route.name.prefix(1).uppercased() + route.name.dropFirst()) failed before the first picture: \(message)")
        settings.markRoute(route, worked: false)
        skipped.insert(route)
        let s = session
        let cm = cloud
        let fresh = routeFresh
        stopEngine()
        route = .web
        routeFresh = false
        if let r, !fresh {
            resume(r, game: g)
            return true
        }
        phase = .starting("Trying 4K another way")
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

    func refreshPicture() { engine?.requestKeyframe("user") }

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

    /// Ends the session on the server.
    func quit() {
        let s = session
        let cm = cloud
        stopEngine()
        job?.cancel()
        finish()
        Task {
            if let s, let cm { await cm.stop(base: s.controlBase, id: s.id) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await app.refreshSessions()
        }
    }

    /// Ends a session running elsewhere without opening it.
    func quit(_ a: ActiveSession) {
        Task {
            await Cloudmatch { [app] in try await app.serviceToken() }.stop(a)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await app.refreshSessions()
        }
    }

    func dismiss() { finish() }

    private func end(_ message: String, error: Bool) {
        if error, fallBack(message) { return }
        if error, trace?.events.last?.stage != .failed { trace?.record(.failed) }
        // A rig asked for just now that never sent its offer won't send one later. Give it
        // back, so it doesn't use up play time or block the next launch, and so Try Again
        // asks for a new rig instead of signing in to the same silent one. A session picked
        // up from elsewhere is left alone: a game may be running on it.
        if error, lastResume == nil, !claimed, !(trace?.has(.offer) ?? false), let s = session, let cm = cloud {
            session = nil
            Task { await cm.stop(base: s.controlBase, id: s.id) }
        }
        stopEngine()
        menuOpen = false
        phase = .ended(message, error: error)
        Task { await app.refreshSessions() }
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
        safeAttempt = false
        framesShown = 0
    }

    private func stopEngine() {
        watchdog?.cancel()
        pads.stop()
        pads.send = nil
        engine?.close()
        engine = nil
        video = nil
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
