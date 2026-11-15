import Foundation
import UIKit

enum Resolution: Int, CaseIterable {
    case uhd = 2160, qhd = 1440, fhd = 1080, hd = 720

    var width: Int {
        switch self {
        case .uhd: return 3840
        case .qhd: return 2560
        case .fhd: return 1920
        case .hd: return 1280
        }
    }

    var height: Int { rawValue }

    var label: String { self == .uhd ? "4K" : "\(rawValue)p" }
}

struct StreamMode: Equatable {
    var resolution: Resolution
    var fps: Int

    static let rates = [60, 120]

    var width: Int { resolution.width }
    var height: Int { resolution.height }
    var label: String { "\(resolution.label) at \(fps) fps" }

    /// The mode nearest to a picture of this height and rate.
    static func closest(height: Int, fps: Int) -> StreamMode {
        let r = Resolution.allCases.min { abs($0.height - height) < abs($1.height - height) } ?? .fhd
        return StreamMode(resolution: r, fps: fps > 90 ? 120 : 60)
    }
}

enum CodecChoice: String, CaseIterable {
    case auto = "AUTO", hevc = "H265", h264 = "H264"

    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        }
    }
}

/// What the player chose, kept between launches.
final class Settings: ObservableObject {
    private let store = UserDefaults.standard

    static let bitrates = [15, 20, 30, 40, 50, 60, 75, 90, 100]

    @Published var mode: StreamMode { didSet { store.set(mode.resolution.rawValue, forKey: "resolution"); store.set(mode.fps, forKey: "fps") } }
    @Published var bitrateMbps: Int { didSet { store.set(bitrateMbps, forKey: "bitrate") } }
    @Published var codec: CodecChoice { didSet { store.set(codec.rawValue, forKey: "codec") } }
    /// Name of the chosen server location, or empty for automatic.
    @Published var region: String { didSet { store.set(region, forKey: "region") } }
    @Published var showStats: Bool { didSet { store.set(showStats, forKey: "stats") } }

    /// The way of asking for 4K that last gave a real 4K picture.
    @Published private(set) var route4k: Route?
    /// Ways of asking for 4K that gave a smaller picture on this account.
    @Published private(set) var failedRoutes: Set<Route>
    /// What happened the last few times 4K was asked for.
    @Published private(set) var log4k: [String]

    init() {
        mode = StreamMode(
            // 1440p until the player asks for more. 4K needs Ultimate and a rig that offers it.
            resolution: Resolution(rawValue: store.integer(forKey: "resolution")) ?? (Self.nativeResolution.height >= 1440 ? .qhd : Self.nativeResolution),
            fps: 60
        )
        bitrateMbps = store.object(forKey: "bitrate") as? Int ?? 50
        codec = CodecChoice(rawValue: store.string(forKey: "codec") ?? "") ?? .auto
        region = store.string(forKey: "region") ?? ""
        showStats = store.bool(forKey: "stats")
        route4k = store.string(forKey: "route4k").flatMap(Route.init)
        failedRoutes = Set((store.stringArray(forKey: "failedRoutes") ?? []).compactMap(Route.init))
        log4k = store.stringArray(forKey: "log4k") ?? []
    }

    /// The largest mode that fits what the Apple TV is sending to the TV right now.
    static var nativeResolution: Resolution {
        let lines = Int(min(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))
        return Resolution.allCases.first { $0.height <= lines } ?? .fhd
    }

    func markRoute(_ r: Route, worked: Bool) {
        if worked {
            route4k = r
            failedRoutes.remove(r)
        } else {
            if route4k == r { route4k = nil }
            failedRoutes.insert(r)
        }
        store.set(route4k?.rawValue, forKey: "route4k")
        store.set(failedRoutes.map(\.rawValue), forKey: "failedRoutes")
    }

    func note4k(_ text: String) {
        log4k = Array((log4k + [text]).suffix(6))
        store.set(log4k, forKey: "log4k")
    }

    /// Forget which ways of asking for 4K failed, so they are all tried again.
    func retry4k() {
        failedRoutes = []
        store.set([String](), forKey: "failedRoutes")
    }
}

/// Whether a mode can be used here, and a line that says why not or what to expect.
struct Verdict {
    let blocked: Bool
    let note: String?
}

enum Capabilities {
    static func check(_ mode: StreamMode, membership: Membership?) -> Verdict {
        // Apple TV 4K sends at most 60 pictures a second to the TV, on every model so far.
        if mode.fps > 60 { return Verdict(blocked: true, note: "Apple TV shows up to 60 frames a second.") }
        if let m = membership, m.tier != "Ultimate", !m.modes.isEmpty, !m.modes.contains(where: { $0.height >= mode.height && $0.fps >= mode.fps }) {
            return Verdict(blocked: true, note: "Not part of your \(m.tier.map { "\($0) " } ?? "")membership.")
        }
        let lines = Settings.nativeResolution.height
        if lines < mode.height {
            return Verdict(blocked: false, note: "The Apple TV is set to \(lines)p, so \(mode.resolution.label) is scaled down to fit.")
        }
        if mode.height >= 2160 {
            return Verdict(blocked: false, note: "Needs Ultimate. If GeForce NOW doesn't give a 4K rig, the game starts at 1440p and says so.")
        }
        return Verdict(blocked: false, note: nil)
    }
}
