import Foundation

/// Who we say we are when asking for a rig. GeForce NOW keeps a separate list of stream
/// sizes for each kind of client, so the same account gets different answers.
enum Route: String, CaseIterable {
    /// Chrome on a PC. Up to 1440p. On the wire this is asked as the TV client: see `wire`.
    case web
    /// The smart TV app, which is a web client too. NVIDIA lists it up to 4K.
    case tv
    /// The PC app. Kept so saved settings that name it still read, but never asked as.
    case desktop

    var name: String {
        switch self {
        case .web: return "the web client"
        case .tv: return "the TV client"
        case .desktop: return "the PC client"
        }
    }

    /// How a route is put to the session service. On the Apple TV, build 444ce95 asked for
    /// every size below 4K as the PC client (NATIVE, NVIDIA-CLASSIC). The server answered the
    /// sign-in, then sent only heartbeats and never an offer, launch after launch. In the same
    /// build the 4K launch asked as the TV client, got its offer and decoded video at
    /// 1920 × 1080, a size the PC client never got an offer for. So the identity is what
    /// decides it, and every size is asked for as the TV client. The sizes tried are still
    /// the web list.
    var wire: Route { self == .desktop ? .desktop : .tv }
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

    static let clientVersion = "2.0.88.129"
    static let tvUA = "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 WebAppManager"
    static let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
    static let pcUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/7b92719716 GFN-PC/\(clientVersion)"

    /// The identity a route is asked as, after `Route.wire`.
    static func of(_ route: Route) -> RequestIdentity {
        switch route.wire {
        case .tv, .web:
            return RequestIdentity(userAgent: tvUA, clientType: "BROWSER", streamer: "WEBRTC", deviceMake: "LG",
                                   deviceOs: "WEBOS", deviceType: "TV", platformName: "browser", sendsOrigin: true, persistsSettings: false)
        case .desktop:
            return RequestIdentity(userAgent: pcUA, clientType: "NATIVE", streamer: "NVIDIA-CLASSIC", deviceMake: "UNKNOWN",
                                   deviceOs: "WINDOWS", deviceType: "DESKTOP", platformName: "windows", sendsOrigin: false, persistsSettings: true)
        }
    }
}
