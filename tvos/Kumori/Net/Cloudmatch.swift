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

    var ready: Bool { status == 2 || status == 3 }
}

struct SessionError: LocalizedError {
    let message: String
    var statusCode = 0
    var http = 0
    var detail: String?

    var errorDescription: String? { message }

    private static let accountCodes: Set<Int> = [7, 11, 50, 10, 13, 14, 15, 16, 17, 37, 38, 23, 24, 56, 26, 27, 28, 29, 30, 31, 32, 33, 45, 52, 53, 63, 35]

    /// About the account itself, so asking again in a different way won't help.
    var account: Bool { Self.accountCodes.contains(statusCode) || http == 401 || http == 403 }

    /// A server-side failure that another server or a smaller stream often avoids.
    var retryable: Bool {
        [3, 4, 5, 8].contains(statusCode) || http >= 500 || (detail?.localizedCaseInsensitiveContains("INTERNAL") ?? false)
    }

    /// Worth asking again for a smaller stream: a server-side failure, or the server turning
    /// down the size that was asked for.
    var stepDown: Bool { retryable || [2, 18, 68].contains(statusCode) }
}

/// Who we say we are when asking for a rig. GeForce NOW keeps a separate list of stream
/// sizes for each kind of client, so the same account gets different answers.
enum Route: String, CaseIterable {
    /// Chrome on a PC. Up to 1440p.
    case web
    /// The smart TV app, which is a web client too. NVIDIA lists it up to 4K.
    case tv
    /// The PC app's list of sizes, with the stream still asked for over WebRTC.
    case desktop

    var name: String {
        switch self {
        case .web: return "the web client"
        case .tv: return "the TV client"
        case .desktop: return "the PC client"
        }
    }
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
    private let token: () async throws -> String
    // One identity per session, as the official clients do.
    private let clientId = UUID().uuidString.lowercased()
    private let deviceId = UUID().uuidString.lowercased()
    /// How this session was asked for. Follow-up calls must look like the same client.
    private var route = Route.web
    /// Told the queue position while a session that is still queued is being followed.
    var onQueue: ((Int) -> Void)?

    private static let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
    private static let tvUA = "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 WebAppManager"
    private static let version = "2.0.88.129"

    init(token: @escaping () async throws -> String) { self.token = token }

    private func headers(_ t: String, origin: Bool) -> [String: String] {
        let web = route != .desktop
        var h: [String: String] = [
            "User-Agent": route == .tv ? Self.tvUA : Self.browserUA,
            "Authorization": "GFNJWT \(t)",
            "Content-Type": "application/json",
            "nv-browser-type": "CHROME",
            "nv-client-id": clientId,
            "nv-client-streamer": web ? "WEBRTC" : "NVIDIA-CLASSIC",
            "nv-client-type": web ? "BROWSER" : "NATIVE",
            "nv-client-version": Self.version,
            "nv-device-make": route == .tv ? "LG" : "UNKNOWN",
            "nv-device-model": "UNKNOWN",
            "nv-device-os": route == .tv ? "WEBOS" : "WINDOWS",
            "nv-device-type": route == .tv ? "TV" : "DESKTOP",
            "x-device-id": deviceId,
        ]
        if origin {
            h["Origin"] = "https://play.geforcenow.com"
            h["Referer"] = "https://play.geforcenow.com/"
        }
        return h
    }

    func create(base streamingBase: String, _ r: LaunchRequest) async throws -> CloudSession {
        guard Int(r.appId) != nil else { throw SessionError(message: "This game can't be launched from here yet.") }
        route = r.route
        Log.info("Asking for app \(r.appId) at \(r.width)x\(r.height)@\(r.fps) as \(r.route.rawValue), linked \(r.accountLinked)")
        let base = streamingBase.hasSuffix("/") ? String(streamingBase.dropLast()) : streamingBase
        let req = try HTTP.request(
            "\(base)/v2/session?keyboardLayout=en-US&languageCode=en_US", method: "POST",
            headers: headers(try await token(), origin: true), body: jsonData(["sessionRequestData": body(r, claim: false)])
        )
        return try parse(try await send(req), base: base)
    }

    private func get(_ base: String, _ id: String) async throws -> CloudSession {
        try parse(try await send(HTTP.request("\(base)/v2/session/\(id)", headers: headers(try await token(), origin: false))), base: base)
    }

    /// Follows a session. Once a seat is ready we talk to that rig directly, not the load balancer.
    func poll(_ s: CloudSession) async throws -> CloudSession {
        let next = try await get(s.controlBase, s.id)
        if next.ready, Self.isZoneHost(Self.host(of: s.controlBase)), let direct = next.serverIp, !Self.isZoneHost(direct) {
            let base = "https://\(direct)"
            if let onRig = try? await get(base, s.id) { return onRig }
            var moved = next
            moved.controlBase = base
            return moved
        }
        return next
    }

    /// Takes over a session running on another device (or left running here) and waits for its seat.
    func claim(_ active: ActiveSession, _ r: LaunchRequest) async throws -> CloudSession {
        route = r.route
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
        }
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

    func stop(base: String, id: String) async {
        guard let t = try? await token(), let req = try? HTTP.request("\(base)/v2/session/\(id)", method: "DELETE", headers: headers(t, origin: false)) else { return }
        _ = try? await send(req)
    }

    func stop(_ active: ActiveSession) async {
        await stop(base: "https://\(active.serverHost ?? Self.host(of: active.streamingBase))", id: active.sessionId)
    }

    // MARK: Request body

    private func body(_ r: LaunchRequest, claim: Bool) -> [String: Any] {
        let null = NSNull()
        let desktop = r.route == .desktop
        let monitor: [String: Any] = [
            "monitorId": 0, "positionX": 0, "positionY": 0,
            "widthInPixels": r.width, "heightInPixels": r.height, "framesPerSecond": r.fps,
            "sdrHdrMode": 0, "dpi": 100,
            "displayData": ["desiredContentMaxLuminance": 0, "desiredContentMinLuminance": 0, "desiredContentMaxFrameAverageLuminance": 0],
        ]
        var features: [String: Any] = [
            "reflex": false, "bitDepth": r.bitDepth >= 10 ? 10 : 0, "cloudGsync": false, "enabledL4S": false,
            "mouseMovementFlags": 0, "trueHdr": false, "supportedHidDevices": 0, "profile": 0,
            "fallbackToLogicalResolution": false, "hidDevices": null, "chromaFormat": 0,
            "prefilterMode": 0, "prefilterSharpness": 0, "prefilterNoiseReduction": 0,
            "hudStreamingMode": 0, "sdrColorSpace": 2, "hdrColorSpace": 0,
        ]
        // Only a new session carries these. Picking one up keeps what it was started with.
        if !claim { features["dlssOverrides"] = r.dlss.json }
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
            "availableSupportedControllers": [Any](),
            "networkTestSessionId": null,
            "parentSessionId": null,
            "clientIdentification": "GFN-PC",
            "deviceHashId": claim ? UUID().uuidString.lowercased() : deviceId,
            "clientVersion": "30.0",
            "streamerVersion": 1,
            "sdkVersion": "1.0",
            "enhancedStreamMode": 1,
            "secureRTSPSupported": false,
            "clientPlatformName": desktop ? "windows" : "browser",
            "clientRequestMonitorSettings": [monitor],
            "useOps": true,
            "audioMode": 2,
            "metaData": metaData,
            "sdrHdrMode": 0,
            "clientDisplayHdrCapabilities": null,
            "surroundAudioInfo": 0,
            "remoteControllersBitmap": 0,
            "clientTimezoneOffset": TimeZone.current.secondsFromGMT() * 1000,
            "appLaunchMode": 1,
            "partnerCustomData": "",
            "accountLinked": claim ? true : r.accountLinked,
            "enablePersistingInGameSettings": desktop,
            "userAge": 26,
            "requestedStreamingFeatures": features,
        ]
    }

    // MARK: Answers

    private func send(_ req: URLRequest) async throws -> J {
        let (http, j) = try await HTTP.send(req)
        let status = j["requestStatus"]
        let code = status["statusCode"].int ?? 0
        if !(200..<300).contains(http) || (status.exists && code != 1) {
            let detail = status["statusDescription"].string
            var unified = status["unifiedErrorCode"].string
            if let n = status["unifiedErrorCode"].raw as? NSNumber { unified = String(n.int64Value, radix: 16).uppercased() }
            Log.error("Session request \(req.httpMethod ?? "") \(req.url?.path ?? "") failed: http \(http) status \(code) unified \(unified ?? "-") \(detail ?? "")")
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
        if (s["status"].int ?? 0) >= 2 {
            let list = conns.map { c in "usage \(c["usage"].int ?? -1) proto \(c["appLevelProtocol"].int ?? -1) ip \(c["ip"].firstString ?? "-") port \(c["port"].int ?? 0) path \(c["resourcePath"].string ?? "-")" }
            Log.info("Session \(s["sessionId"].string ?? "") status \(s["status"].int ?? 0) control \(s["sessionControlInfo"]["ip"].firstString ?? "-") connections: \(list.joined(separator: " | "))")
        }
        func usage(_ c: J) -> Int { c["usage"].int ?? -1 }
        func path(_ c: J) -> String { c["resourcePath"].string ?? "" }
        // The signaling endpoint: a wss or https entry first, then usages 14 and 16.
        let signal = conns.first { (path($0).hasPrefix("wss://") || path($0).hasPrefix("https://")) && [14, 16].contains(usage($0)) }
            ?? conns.first { usage($0) == 14 } ?? conns.first { usage($0) == 16 }
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
            adsRequired: s["sessionAdsRequired"].bool == true || s["isAdsRequired"].bool == true
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
