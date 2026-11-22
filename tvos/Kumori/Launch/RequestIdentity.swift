import Foundation

/// Who we say we are when asking for a rig. GeForce NOW keeps a separate list of stream
/// sizes for each kind of client, so the same account gets different answers.
enum Route: String, CaseIterable {
    /// Chrome on a PC. Up to 1440p. On the wire this is asked as the TV client: see `wire`.
    case web
    /// The smart TV app, which is a web client too. NVIDIA lists it up to 4K.
    case tv
    /// The PC app's identity (NATIVE, NVIDIA-CLASSIC), with the stream still over WebRTC.
    /// GeForce NOW only grants more than 1080p, or more than 60 fps, to this kind of client.
    case desktop

    var name: String {
        switch self {
        case .web: return "the web client"
        case .tv: return "the TV client"
        case .desktop: return "the PC client"
        }
    }

    /// How a route is put to the session service. On the Apple TV, build 444ce95 asked for
    /// every size below 4K as the PC client in the PC app's own shape: its GFN-PC user agent,
    /// no Origin and the WebRTC client's feature list. The server answered the sign-in, then
    /// sent only heartbeats and never an offer. In the same build the TV client got its offer
    /// and streamed, but at 1920 × 1080 even when 4K was asked for, and again at 4K 120 on
    /// 578457a. So sizes up to 1080p at 60 fps are asked as the TV client, and higher ones
    /// as the PC client the way OpenNOW's Android TV client asks (see `RequestIdentity`).
    var wire: Route { self == .desktop ? .desktop : .tv }

    /// Whether a mode needs the PC client's list of sizes. OpenNOW's Android client uses the
    /// same rule: the browser and TV clients are held to 1080p at 60 fps.
    static func needsDesktop(width: Int, height: Int, fps: Int) -> Bool {
        fps > 60 || width > 1920 || height > 1200
    }

    /// What to ask the PC client for, best first: the chosen mode, then each smaller one the TV
    /// client can't give. So 4K steps down to 1440p, and 1440p to 1080p at 120 fps, before
    /// the TV client's 1080p60 is the fallback.
    static func desktopLadder(for ask: ModeRequest) -> [ModeRequest] {
        ModeLadder.candidates(for: ask).filter { $0.height >= 1080 && needsDesktop(width: $0.width, height: $0.height, fps: $0.fps) }
    }
}

/// The headers and body fields that say which client is asking. Polls, claims and ends of a
/// session use the same identity as the request that made it.
struct RequestIdentity: Equatable {
    let userAgent: String
    let clientType: String
    let streamer: String
    let deviceMake: String
    let deviceOs: String
    let deviceType: String
    /// `clientPlatformName` in the request body.
    let platformName: String
    /// Whether requests that carry an Origin say play.geforcenow.com.
    let sendsOrigin: Bool
    /// `enablePersistingInGameSettings` in the request body.
    let persistsSettings: Bool
    /// The request body's desktop shape, as OpenNOW's Android client sends it with the PC
    /// client's headers: a monitor at 100 dpi with no display data, and the full feature list.
    var desktopBody: Bool { clientType == "NATIVE" }

    static let clientVersion = "2.0.88.129"
    static let tvUA = "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 WebAppManager"
    static let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
    /// What OpenNOW's Android TV client sends with the PC client's headers when it asks for
    /// more than 1080p 60, and its WebRTC streams start: a Chrome user agent, not the PC
    /// app's own GFN-PC one.
    static let desktopUA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"

    /// The identity a route is asked as, after `Route.wire`.
    static func of(_ route: Route) -> RequestIdentity {
        switch route.wire {
        case .tv, .web:
            return RequestIdentity(userAgent: tvUA, clientType: "BROWSER", streamer: "WEBRTC", deviceMake: "LG",
                                   deviceOs: "WEBOS", deviceType: "TV", platformName: "browser", sendsOrigin: true, persistsSettings: false)
        case .desktop:
            return RequestIdentity(userAgent: desktopUA, clientType: "NATIVE", streamer: "NVIDIA-CLASSIC", deviceMake: "UNKNOWN",
                                   deviceOs: "WINDOWS", deviceType: "DESKTOP", platformName: "windows", sendsOrigin: true, persistsSettings: true)
        }
    }
}
