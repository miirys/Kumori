import Foundation

struct Endpoint {
    let ip: String
    let port: Int
}

struct IceSpec {
    let urls: [String]
    let username: String?
    let credential: String?
}

/// One session as the session service describes it.
struct CloudSession {
    let id: String
    /// 1 setting up or queued, 2 ready, 3 streaming.
    let status: Int
    let queuePosition: Int?
    /// Base URL for polling and ending this session.
    var controlBase: String
    let serverIp: String?
    let signalingUrl: String?
    let media: Endpoint?
    let ice: [IceSpec]
    let gpu: String?
    let width: Int?
    let height: Int?
    let fps: Int?
    /// The queue wants to show an ad first, which this app can't play.
    var adsRequired = false
    /// Extra sign-in query the session lists with its signaling entry, if any.
    var signalingQuery = ""
    /// Extra WebSocket subprotocols the session lists with its signaling entry, if any.
    var signalingProtocols: [String] = []
    /// What the session lists to connect to, for the log. No addresses or tokens.
    var connections: [ConnectionSummary] = []
    /// Where seat setup is, for the log.
    var seatStep: Int?
    /// The session's own error code, for the log.
    var errorCode: Int?
    /// The RTSPS control endpoints the rig advertises for the native stream, exactly as it gave
    /// them: scheme, host, port and path. Empty when it advertises none.
    var nativeEndpoints: [String] = []
    /// How this session was asked for, so it goes to the receiver that can play it.
    var transport = Transport.webrtc
    /// True when width, height and fps are the rig's own `monitorSettings`. False when they are
    /// only the echo of what was asked for, which says nothing about what will be streamed.
    var modeFromServer = false

    var ready: Bool { status == 2 || status == 3 }
}

struct SessionError: LocalizedError, ClassifiedRefusal {
    let message: String
    var statusCode = 0
    var http = 0
    var detail: String?

    var errorDescription: String? { message }

    /// What kind of refusal this is. The rules live in `Refusal.classify`, with tests.
    var refusal: Refusal { Refusal.classify(statusCode: statusCode, http: http, detail: detail) }

    /// About the account itself, so asking again in a different way won't help.
    var account: Bool { refusal == .account }

    /// A server-side failure that another server or a smaller stream often avoids.
    var retryable: Bool { refusal == .server }

    /// Worth asking again for a smaller stream: a server-side failure, or the server turning
    /// down the size that was asked for.
    var stepDown: Bool { refusal.stepsDown }
}

struct LaunchRequest {
    var appId: String
    var width: Int
    var height: Int
    var fps: Int
    var bitDepth = 8
    var title: String?
    /// Whether the game is in the user's library on its store. Unowned games must say false.
    var accountLinked = true
    var route = Route.web
    var dlss = DlssOverrides()
    /// Audio channels to ask the native stream for: 2, 6 or 8.
    var audioChannels = 2
}

/// DLSS settings the cloud rig forces on a game, with the numbers the official client sends.
/// Zero leaves a setting to the game. Models: 1 is NVIDIA's recommended one, 12 to 14 are
/// presets K, L and M. Quality: 1 Performance, 2 Balanced, 3 Quality, 4 Ultra Performance, 5 DLAA.
struct DlssOverrides {
    var srModel = 0
    var srMode = 0
    var rrModel = 0
    var fgModel = 0
    /// 3 to 6 turns on dynamic frame generation up to that many frames. 0 leaves it off.
    var fgMultiplier = 0

    /// Nothing is overridden: the request then carries no overrides at all.
    var isDefault: Bool { srModel == 0 && rrModel == 0 && fgModel == 0 }

    var json: [String: Any] {
        // A model left to the game leaves its mode to the game as well.
        let mode = srModel == 0 ? 0 : srMode
        let scale = [1: 50, 2: 58, 3: 67, 4: 33][mode] ?? 100
        let dynamic = fgModel != 0 && (3...6).contains(fgMultiplier)
        var o: [String: Any] = [
            "srMode": mode, "srModel": srModel, "srScale": scale, "rrModel": rrModel,
            "fgMode": dynamic ? 1 : 0, "fgModel": fgModel,
        ]
        if dynamic { o["fgMultiplier"] = fgMultiplier }
        return o
    }
}

/// The GeForce NOW session service: start a game on a cloud rig, follow it through the queue,
/// pick up one started elsewhere, and end it.
final class Cloudmatch {
    /// A service token; `true` asks for a renewed one, after the service refused the last.
    private let fetchToken: (_ force: Bool) async throws -> String
    // One identity per session, as the official clients do.
    // The same ids for every request this Apple TV makes, as the PC app keeps them, so the
    // session list, the session and the request that ends it all name the same device. The
    // device id is the one the session list already sends (AppModel.deviceId).
    private let clientId = Cloudmatch.stableId("cloudmatchClientId")
    private let deviceId = Cloudmatch.stableId("deviceId")

    private static func stableId(_ key: String) -> String {
        if let id = UserDefaults.standard.string(forKey: key), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
    /// How this session was asked for. Polls, claims and ends must look like the same client.
    private var route = Route.tv
    /// Told the queue position while a session that is still queued is being followed.
    var onQueue: ((Int) -> Void)?
    /// The request the last claim actually sent. With `adopt` it is the session's own mode,
    /// not the one the caller passed, and the stream has to be set up for this one.
    private(set) var claimed: LaunchRequest?

    init(token: @escaping (_ force: Bool) async throws -> String) { fetchToken = token }

    private func token(force: Bool = false) async throws -> String { try await fetchToken(force) }

    private func headers(_ t: String, origin: Bool, as asked: Route? = nil) -> [String: String] {
        let id = RequestIdentity.of(asked ?? route)
        var h: [String: String] = [
            "User-Agent": id.userAgent,
            "Authorization": "GFNJWT \(t)",
            "Content-Type": "application/json",
            "nv-browser-type": "CHROME",
            "nv-client-id": clientId,
            "nv-client-streamer": id.streamer,
            "nv-client-type": id.clientType,
            "nv-client-version": RequestIdentity.clientVersion,
            "nv-device-make": id.deviceMake,
            "nv-device-model": id.deviceModel,
            "nv-device-os": id.deviceOs,
            "nv-device-type": id.deviceType,
            "x-device-id": deviceId,
        ]
        if origin, id.sendsOrigin {
            h["Origin"] = "https://play.geforcenow.com"
            h["Referer"] = "https://play.geforcenow.com/"
        }
        return h
    }

    func create(base streamingBase: String, _ r: LaunchRequest) async throws -> CloudSession {
        guard Int(r.appId) != nil else { throw SessionError(message: "This game can't be launched from here yet.") }
        route = r.route.wire
        let base = streamingBase.hasSuffix("/") ? String(streamingBase.dropLast()) : streamingBase
        let req = try HTTP.request(
            "\(base)/v2/session?keyboardLayout=en-US&languageCode=en_US", method: "POST",
            headers: headers(try await token(), origin: true), body: jsonData(["sessionRequestData": body(r, claim: false)])
        )
        var made = try parse(try await send(req), base: base)
        made.transport = r.route.transport
        SessionLog.created(route: route.rawValue, width: r.width, height: r.height, fps: r.fps, dlss: !r.dlss.isDefault, session: made)
        return made
    }

    private func get(_ base: String, _ id: String) async throws -> CloudSession {
        var s = try parse(try await send(HTTP.request("\(base)/v2/session/\(id)", headers: headers(try await token(), origin: false))), base: base)
        // Polls and claims keep the transport the session was asked for with.
        s.transport = route.transport
        return s
    }

    /// Follows a session. Once a seat is ready we talk to that rig directly, not the load balancer.
    func poll(_ s: CloudSession) async throws -> CloudSession {
        let next = try await get(s.controlBase, s.id)
        SessionLog.polled(next)
        if next.ready, Self.isZoneHost(Self.host(of: s.controlBase)), let direct = next.serverIp, !Self.isZoneHost(direct) {
            let base = "https://\(direct)"
            if let onRig = try? await get(base, s.id) {
                SessionLog.polled(onRig, direct: true)
                return onRig
            }
            var moved = next
            moved.controlBase = base
            return moved
        }
        return next
    }

    /// Takes over a session running on another device (or left running here) and waits for its seat.
    /// Picks up a running session for this device. With `adopt`, the session is asked for at
    /// the size and rate it is already running at, whatever Settings say, and as the client
    /// that size needs (the native client only when `allowNative`). A rig asked to resume at a
    /// different mode than it runs can fail to come back.
    func claim(_ active: ActiveSession, _ request: LaunchRequest, adopt: Bool = false, allowNative: Bool = true) async throws -> CloudSession {
        var r = request
        route = r.route.wire
        var host = active.serverHost ?? Self.host(of: active.streamingBase)
        // The listing names the region's load balancer. Ask it for the rig itself first.
        if Self.isZoneHost(host), let pre = try? await get("https://\(host)", active.sessionId), let ip = pre.serverIp { host = ip }
        let base = "https://\(host)"
        let current: CloudSession?
        do {
            current = try await get(base, active.sessionId)
        } catch let e as SessionError where e.http == 404 {
            throw SessionError(message: "That session has ended.", http: 404)
        } catch {
            if Task.isCancelled { throw error }
            current = nil
        }
        // A session still being set up or queued can't be resumed yet, only followed. Follow
        // it for as long as the queue takes, then claim it for this device.
        if var waiting = current, waiting.status == 1 {
            var misses = 0
            while waiting.status == 1 {
                onQueue?(waiting.queuePosition ?? 0)
                try await Task.sleep(nanoseconds: (waiting.queuePosition ?? 0) > 10 ? 4_000_000_000 : 1_500_000_000)
                do {
                    waiting = try await get(base, active.sessionId)
                    misses = 0
                } catch let e as SessionError where e.http == 404 || e.statusCode != 0 {
                    throw e.http == 404 ? SessionError(message: "That session has ended.", http: 404) : e
                } catch {
                    if Task.isCancelled { throw error }
                    misses += 1
                    if misses > 20 { throw error }
                }
            }
            guard (1...3).contains(waiting.status) else { throw SessionError(message: "The session ended before it was ready.") }
            if adopt { r = Self.adopting(r, waiting, allowNative: allowNative) }
        } else if adopt, let running = current {
            r = Self.adopting(r, running, allowNative: allowNative)
        }
        route = r.route.wire
        claimed = r
        do {
            var data = body(r, claim: true)
            data["appId"] = Int(active.appId) ?? 0
            let req = try HTTP.request(
                "\(base)/v2/session/\(active.sessionId)?keyboardLayout=en-US&languageCode=en_US", method: "PUT",
                headers: headers(try await token(), origin: true),
                body: jsonData(["action": 2, "data": "RESUME", "sessionRequestData": data, "metaData": [Any]()] as [String: Any])
            )
            _ = try await send(req)
        }
        for attempt in 0..<90 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            do {
                let s = try await get(base, active.sessionId)
                if s.ready { return s }
                if !(1...3).contains(s.status) { throw SessionError(message: "That session has ended.", statusCode: -1) }
            } catch let e as SessionError where e.http == 404 || e.statusCode != 0 {
                // The session is gone. Waiting out the clock would not bring it back.
                throw e.http == 404 ? SessionError(message: "That session has ended.", http: 404) : e
            } catch {
                if Task.isCancelled { throw error }
            }
        }
        throw SessionError(message: "The session didn't come back. It may have ended on the other device.")
    }

    /// The request for a session, at the mode the session itself reports.
    static func adopting(_ r: LaunchRequest, _ s: CloudSession, allowNative: Bool) -> LaunchRequest {
        guard let w = s.width, let h = s.height, w > 0, h > 0 else { return r }
        var out = r
        out.width = w
        out.height = h
        out.fps = s.fps ?? r.fps
        // A mode the TV client can't give, or a session the rig already streams natively, is
        // picked up as the native client. Everything else as the TV client.
        let native = NativeRequest.wanted(width: w, height: h, fps: out.fps) || !s.nativeEndpoints.isEmpty
        out.route = allowNative && native ? .native : .web
        // As the TV client, the most it is given is 1080p at 60 fps. Asked for more (a native
        // 4K session picked up again after the native stream failed), the stream was set up
        // for a size and rate the rig would never send that way.
        if out.route == .web, NativeRequest.wanted(width: out.width, height: out.height, fps: out.fps) {
            out.width = min(out.width, 1920)
            out.height = min(out.height, 1080)
            out.fps = min(out.fps, 60)
        }
        return out
    }

    func stop(base: String, id: String) async {
        await end(id: id, bases: [base])
    }

    func stop(_ active: ActiveSession) async {
        await end(id: active.sessionId, bases: Self.endBases(active))
    }

    /// Where a listed session can be ended: the rig that owns it, then its region.
    static func endBases(_ active: ActiveSession) -> [String] {
        var bases: [String] = []
        if let h = active.serverHost, !h.isEmpty { bases.append("https://\(h)") }
        bases.append("https://\(host(of: active.streamingBase))")
        return bases
    }

    /// Ends a session, asking each base in turn until one takes it. A session the server no
    /// longer knows counts as ended. True when it is gone.
    @discardableResult
    func end(id: String, bases: [String]) async -> Bool {
        guard let t = try? await token() else {
            SessionLog.ended(step: "no token", http: nil, ok: false)
            return false
        }
        // Each place, asked as the client this session was started with, then as the native
        // and the TV client: a session started one way may refuse an end asked another way.
        var identities: [Route] = []
        for r in [route, .native, .tv] where !identities.contains(r) { identities.append(r) }
        var tried = Set<String>()
        var n = 0
        for raw in bases {
            let base = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            guard !base.isEmpty, tried.insert(base).inserted else { continue }
            for who in identities {
                guard let req = try? HTTP.request("\(base)/v2/session/\(id)", method: "DELETE", headers: headers(t, origin: false, as: who)) else { continue }
                n += 1
                do {
                    _ = try await send(req)
                    SessionLog.ended(step: "try \(n) as \(who.rawValue)", http: 200, ok: true)
                    return true
                } catch let e as SessionError {
                    if e.http == 404 {
                        SessionLog.ended(step: "already gone, try \(n) as \(who.rawValue)", http: 404, ok: true)
                        return true
                    }
                    SessionLog.ended(step: "refused, try \(n) as \(who.rawValue) status \(e.statusCode)", http: e.http, ok: false)
                } catch {
                    SessionLog.ended(step: "\((error as NSError).domain) \((error as NSError).code), try \(n)", http: nil, ok: false)
                }
            }
        }
        return false
    }

    // MARK: Request body

    private func body(_ r: LaunchRequest, claim: Bool) -> [String: Any] {
        let request = webBody(r, claim: claim)
        guard r.route == .native else { return request }
        return NativeRequest.transform(request, width: r.width, height: r.height, fps: r.fps, audioChannels: r.audioChannels, claim: claim)
    }

    private func webBody(_ r: LaunchRequest, claim: Bool) -> [String: Any] {
        let null = NSNull()
        let id = RequestIdentity.of(r.route)
        // The TV client's shape is the one that got offers on the Apple TV (444ce95, 578457a).
        // The PC client's is OpenNOW's Android one for more than 1080p 60.
        let desktopShape = id.desktopBody
        let monitor: [String: Any] = [
            "monitorId": 0, "positionX": 0, "positionY": 0,
            "widthInPixels": r.width, "heightInPixels": r.height, "framesPerSecond": r.fps,
            "sdrHdrMode": 0, "dpi": desktopShape ? 100 : 0,
            "displayData": desktopShape ? null as Any : [String: Any]() as Any, "hdr10PlusGamingData": null,
        ]
        var features: [String: Any] = [
            "reflex": desktopShape && r.fps >= 120, "bitDepth": r.bitDepth >= 10 ? 10 : 0, "cloudGsync": false, "enabledL4S": false,
            "supportedHidDevices": 0, "profile": 0, "fallbackToLogicalResolution": false, "chromaFormat": 0,
            "prefilterMode": 0, "prefilterSharpness": 0, "prefilterNoiseReduction": 0, "hudStreamingMode": 0,
        ]
        if desktopShape {
            features["trueHdr"] = false
            features["mouseMovementFlags"] = 0
            features["hidDevices"] = null
            features["sdrColorSpace"] = 2
            features["hdrColorSpace"] = 0
        }
        // Only a new session carries these, and only when something is overridden. Picking
        // one up keeps what it was started with.
        if !claim, !r.dlss.isDefault { features["dlssOverrides"] = r.dlss.json }
        func meta(_ k: String, _ v: String) -> [String: String] { ["key": k, "value": v] }
        let metaData = [
            meta("SubSessionId", UUID().uuidString.lowercased()),
            meta("wssignaling", "1"),
            meta("GSStreamerType", "WebRTC"),
            meta("networkType", "Unknown"),
            meta("ClientImeSupport", "0"),
            meta("clientPhysicalResolution", jsonString(["horizontalPixels": r.width, "verticalPixels": r.height])),
            meta("surroundAudioInfo", "2"),
        ]
        return [
            "appId": Int(r.appId) ?? 0,
            "internalTitle": (claim ? nil : r.title).map { $0 as Any } ?? null,
            // Tell the rig a gamepad is the main input (as OpenNOW and the PC client do), or
            // some games start in mouse-and-keyboard mode and ignore the pad.
            "availableSupportedControllers": [2],
            "preferredController": 2,
            "networkTestSessionId": null,
            "parentSessionId": null,
            "clientIdentification": "GFN-PC",
            "deviceHashId": claim ? UUID().uuidString.lowercased() : deviceId,
            "clientVersion": "30.0",
            "streamerVersion": 1,
            "sdkVersion": "1.0",
            "enhancedStreamMode": 1,
            "secureRTSPSupported": false,
            "clientPlatformName": id.platformName,
            "clientRequestMonitorSettings": [monitor],
            "useOps": true,
            "audioMode": 2,
            "metaData": metaData,
            "sdrHdrMode": 0,
            "clientDisplayHdrCapabilities": null,
            "surroundAudioInfo": 0,
            "remoteControllersBitmap": 0,
            "clientTimezoneOffset": TimeZone.current.secondsFromGMT() * 1000,
            // Gamepad-friendly: launchers that have one open their controller view.
            "appLaunchMode": 2,
            "partnerCustomData": "",
            "accountLinked": claim ? true : r.accountLinked,
            "enablePersistingInGameSettings": id.persistsSettings,
            "userAge": 26,
            "requestedStreamingFeatures": features,
        ]
    }

    // MARK: Answers

    /// Sends a request. A 401 means the token was refused before its time (revoked, or the
    /// clock is off): it is renewed and the request sent once more, as the Android app does,
    /// instead of failing the launch or the end with "sign-in expired" (bugs.md K-16).
    private func send(_ req: URLRequest) async throws -> J {
        do {
            return try await sendOnce(req)
        } catch let e as SessionError where e.http == 401 {
            guard !Task.isCancelled, let fresh = try? await token(force: true) else { throw e }
            var again = req
            again.setValue("GFNJWT \(fresh)", forHTTPHeaderField: "Authorization")
            return try await sendOnce(again)
        }
    }

    private func sendOnce(_ req: URLRequest) async throws -> J {
        let (http, j) = try await HTTP.send(req)
        let status = j["requestStatus"]
        let code = status["statusCode"].int ?? 0
        if !(200..<300).contains(http) || (status.exists && code != 1) {
            let detail = status["statusDescription"].string
            var unified = status["unifiedErrorCode"].string
            if let n = status["unifiedErrorCode"].raw as? NSNumber { unified = String(n.int64Value, radix: 16).uppercased() }
            var text = Self.message(code, detail, http, unified)
            // Keep the code on screen. It's what tells one refusal from another.
            if code > 1, !text.contains("Error") { text += " (Error \(code))" }
            throw SessionError(message: text, statusCode: code, http: http, detail: detail)
        }
        guard j.exists else { throw SessionError(message: "The session service sent an unreadable answer.", http: http) }
        return j
    }

    private func parse(_ j: J, base: String) throws -> CloudSession {
        let s = j["session"]
        guard s.isObject else { throw SessionError(message: "The session service didn't describe the session.") }
        let conns = s["connectionInfo"].array
        func usage(_ c: J) -> Int { c["usage"].int ?? -1 }
        func path(_ c: J) -> String { c["resourcePath"].string ?? "" }
        // The signaling endpoint, picked the way OpenNOW and OpenNOW-Mac pick it: the usage 14
        // entry with an address, then any usage 14 entry, then a wss entry of usage 16.
        let signal = conns.first { usage($0) == 14 && $0["ip"].firstString != nil }
            ?? conns.first { usage($0) == 14 }
            ?? conns.first { usage($0) == 16 && (path($0).hasPrefix("wss://") || path($0).hasPrefix("https://")) }
        let serverIp = signal.flatMap { $0["ip"].firstString ?? Self.hostOfUrl(path($0)) } ?? s["sessionControlInfo"]["ip"].firstString
        let monitor = s["monitorSettings"][0].isObject ? s["monitorSettings"][0] : s["sessionRequestData"]["clientRequestMonitorSettings"][0]
        func positive(_ v: Int?) -> Int? { (v ?? 0) > 0 ? v : nil }
        let queue = [s, s["seatSetupInfo"], s["sessionProgress"], s["progressInfo"]].compactMap { positive($0["queuePosition"].int) }.first
        return CloudSession(
            id: s["sessionId"].string ?? "",
            status: s["status"].int ?? 0,
            queuePosition: queue,
            controlBase: base,
            serverIp: serverIp,
            signalingUrl: serverIp.map { Self.signalingUrl(signal.map(path) ?? "", ip: $0) },
            media: media(conns, serverIp),
            ice: s["iceServerConfiguration"]["iceServers"].array.compactMap { o in
                let urls = (o["urls"].string.map { [$0] } ?? o["urls"].array.compactMap(\.string))
                return urls.isEmpty ? nil : IceSpec(urls: urls, username: o["username"].string, credential: o["credential"].string)
            },
            gpu: s["gpuType"].string,
            width: positive(monitor["widthInPixels"].int),
            height: positive(monitor["heightInPixels"].int),
            fps: positive(monitor["framesPerSecond"].int),
            adsRequired: s["sessionAdsRequired"].bool == true || s["isAdsRequired"].bool == true,
            signalingQuery: signal?["queryParameters"].string ?? "",
            signalingProtocols: signal.map { Self.headerTokens($0["headers"]) } ?? [],
            connections: conns.map { c in
                ConnectionSummary(usage: usage(c), protocolId: c["protocol"].int, appProtocol: c["appLevelProtocol"].int,
                                  port: c["port"].int ?? 0, hasIp: c["ip"].firstString != nil, path: path(c),
                                  hasQuery: !(c["queryParameters"].string ?? "").isEmpty, hasHeaders: c["headers"].exists)
            },
            seatStep: s["seatSetupInfo"]["seatSetupStep"].int ?? s["sessionProgress"]["seatSetupStep"].int,
            errorCode: s["errorCode"].int,
            // Read apart from the browser signaling entry, and never rewritten: the native
            // receiver connects to exactly what the rig advertises. No endpoint is assumed.
            nativeEndpoints: NvstRtspEndpoints.collect(connections: s["connectionInfo"].raw as? [[String: Any]] ?? [],
                                                       fallbackHost: serverIp ?? s["sessionControlInfo"]["ip"].firstString,
                                                       allowsAssumedControlPort: false),
            modeFromServer: s["monitorSettings"][0].isObject
        )
    }

    private func media(_ list: [J], _ serverIp: String?) -> Endpoint? {
        func port(_ c: J) -> Int {
            if let p = c["port"].int, p > 0 { return p }
            let path = (c["resourcePath"].string ?? "").replacingOccurrences(of: "rtsps://", with: "https://").replacingOccurrences(of: "rtsp://", with: "http://")
            return URLComponents(string: path)?.port ?? 0
        }
        func from(_ c: J, _ fallback: String?) -> Endpoint? {
            guard let ip = c["ip"].firstString ?? Self.hostOfUrl(c["resourcePath"].string ?? "") ?? fallback, port(c) > 0 else { return nil }
            return Endpoint(ip: ip, port: port(c))
        }
        for u in [2, 17] {
            if let c = list.first(where: { $0["usage"].int == u }), let e = from(c, nil) { return e }
        }
        for c in list.filter({ $0["usage"].int == 14 }).sorted(by: { ($0["port"].int ?? 0) > ($1["port"].int ?? 0) }) {
            if let e = from(c, serverIp) { return e }
        }
        return nil
    }

    /// A signaling entry's extra headers, as WebSocket subprotocol tokens `key.value`, the way
    /// OpenNOW-Mac sends them. The session id token always goes first.
    static func headerTokens(_ v: J) -> [String] {
        if let list = v.raw as? [String] { return list.filter { !$0.isEmpty } }
        if let map = v.raw as? [String: Any] {
            return map.compactMap { k, val in
                let t = (val as? String) ?? (val as? NSNumber)?.stringValue ?? ""
                return k.isEmpty || t.isEmpty ? nil : "\(k).\(t)"
            }.sorted()
        }
        return v.array.compactMap { e in
            guard let k = e["key"].string, let val = e["value"].string, !k.isEmpty, !val.isEmpty else { return nil }
            return "\(k).\(val)"
        }
    }

    private static func signalingUrl(_ path: String, ip: String) -> String {
        if path.hasPrefix("rtsps://") || path.hasPrefix("rtsp://") { return "wss://\(hostOfUrl(path) ?? "\(ip):443")/nvst/" }
        if path.hasPrefix("wss://") { return path }
        if path.hasPrefix("https://") { return "wss://" + path.dropFirst("https://".count) }
        if path.hasPrefix("/") { return "wss://\(ip):443\(path)" }
        return "wss://\(ip):443/nvst/"
    }

    static func isZoneHost(_ host: String) -> Bool {
        host.contains("cloudmatchbeta.nvidiagrid.net") || host.contains("cloudmatch.nvidiagrid.net")
    }

    static func host(of url: String) -> String {
        var s = Substring(url)
        for p in ["https://", "http://"] where s.hasPrefix(p) { s = s.dropFirst(p.count) }
        return String(s.prefix { $0 != "/" })
    }

    /// Host of an rtsps, rtsp, wss or https URL, without the port.
    static func hostOfUrl(_ url: String) -> String? {
        for p in ["rtsps://", "rtsp://", "wss://", "https://"] where url.hasPrefix(p) {
            let host = url.dropFirst(p.count).prefix { $0 != "/" && $0 != ":" }
            return host.isEmpty ? nil : String(host)
        }
        return nil
    }

    /// Plain reasons for the session service's status codes.
    static func message(_ code: Int, _ detail: String?, _ http: Int, _ unified: String?) -> String {
        switch code {
        case 2: return "GeForce NOW refused the request."
        case 7, 11, 50: return "Another game is already running on your account. Resume it or end it first."
        case 10: return "Too many requests in a row. Wait a moment and try again."
        case 13: return "You've used all the playtime your membership includes for now."
        case 14, 15, 16, 17, 37, 38: return "Your sign-in has expired. Sign in again to continue."
        case 18, 68: return "Your membership doesn't include this game or setting."
        case 19, 20, 42: return "This game isn't available to stream right now."
        case 23: return "Accept GeForce NOW's terms on another device first, then try again."
        case 24, 56: return "GeForce NOW is under maintenance. Try again a little later."
        case 25, 48: return "GeForce NOW isn't available right now. Try again a little later."
        case 26, 27, 28: return "Steam needs you to sign in again. Launch the game once on another device to fix it."
        case 29: return "Your Steam profile is private, so your games can't be checked."
        case 30, 31, 32, 33, 45, 52, 53, 63: return "GeForce NOW isn't available in your region."
        case 34: return "This session can't be resumed right now."
        case 35: return "Verify your email address with NVIDIA first."
        case 41: return "This game is being updated. Try again in a few minutes."
        case 46: return "The session was taken over by another device."
        case 49: return "The session expired."
        case 51, 58, 59, 60: return "All rigs nearby are busy. Try again in a moment."
        case 54, 55: return "Your region is temporarily paused for new sessions."
        case 62: return "The queue is full right now. Try again a little later."
        case 69: return "You left the queue."
        default:
            if http == 401 || http == 403 { return "Your sign-in has expired. Sign in again to continue." }
            // Keep the raw code visible. It's what NVIDIA support and forums go by.
            var ref = unified.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
            if ref == nil { ref = code > 0 ? "status \(code)" : (http > 0 ? "HTTP \(http)" : nil) }
            return "GeForce NOW couldn't start the game." + (ref.map { " Error \($0)." } ?? "")
        }
    }
}
