import Foundation

/// One clock for the time between connecting to the rig and its offer, and one for the time
/// between the offer and a picture. These replace the 12-second sign-in timer and the
/// separate 30-second watchdog, which fought each other: a rig that took 15 seconds to send
/// its offer was signed out at 12, and the watchdog ended the launch while the third
/// sign-in was still waiting.
struct SignalingPolicy: Equatable {
    /// How long one sign-in waits for the offer before signing in again. As long as the
    /// whole wait: OpenNOW's clients sign in once and wait, a rig can take over a minute to
    /// start a game, and the server drops a peer it has given up on for good. A new sign-in
    /// only follows a socket that closed.
    var silentSignIn: Double = 80
    /// All the time allowed from the first sign-in to the offer.
    var preOffer: Double = 80
    /// Time from the offer to the first picture.
    var firstPicture: Double = 30
    /// Most sign-ins for one stream.
    var maxSignIns: Int = 3
    /// The pause before signing in again.
    var pause: Double = 1

    static let standard = SignalingPolicy()

    enum Decision: Equatable {
        /// Sign in again after this many seconds.
        case signInAgain(after: Double)
        case giveUp
    }

    /// When the sign-in that began `startedAt` seconds into the stream stops waiting, measured
    /// from the start of the stream.
    func deadline(signInStartedAt startedAt: Double) -> Double {
        min(startedAt + silentSignIn, preOffer)
    }

    /// What to do when a sign-in went silent or its socket closed before the offer.
    func next(afterSignIns count: Int, elapsed: Double) -> Decision {
        guard count < maxSignIns, elapsed + pause < preOffer - 5 else { return .giveUp }
        return .signInAgain(after: pause)
    }
}

/// How far the video got, from the stream's own counters, for the error screen.
enum MediaCheckpoint: Equatable {
    case noOffer
    case noPackets
    case packetsNotDecoded
    case decodedNotShown
    case shown

    static func from(offered: Bool, packets: Int, decoded: Int, delivered: Int) -> MediaCheckpoint {
        if !offered { return .noOffer }
        if delivered > 0 { return .shown }
        if decoded > 0 { return .decodedNotShown }
        if packets > 0 { return .packetsNotDecoded }
        return .noPackets
    }

    /// What to tell the player when no picture came.
    func message(codec: String?) -> String {
        switch self {
        case .noOffer:
            return "The rig didn't start the stream. Try again in a moment."
        case .noPackets:
            return "The rig connected, but no video reached this Apple TV. Your network may be blocking the stream."
        case .packetsNotDecoded:
            let c = codec.map { " (\($0))" } ?? ""
            return "Video arrived but couldn't be decoded\(c). Try H.264 in Settings, or Try 1080p60 H.264 below."
        case .decodedNotShown:
            return "Video was decoded but never reached the screen. Try again."
        case .shown:
            return "The stream stopped."
        }
    }
}
