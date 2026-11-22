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

struct StreamMode: Hashable, Identifiable {
    var resolution: Resolution
    var fps: Int

    static let rates = [60, 120]

    var id: String { "\(resolution.rawValue)@\(fps)" }

    /// Every mode, smallest first: the order the picker scrolls through.
    static let all: [StreamMode] = Resolution.allCases.reversed().flatMap { r in rates.map { StreamMode(resolution: r, fps: $0) } }

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
    case auto = "AUTO", av1 = "AV1", hevc = "H265", h264 = "H264"

    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .av1: return "AV1"
        case .hevc: return "HEVC (H.265)"
        case .h264: return "H.264"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "The best codec this Apple TV decodes in hardware."
        case .av1: return HardwareDecoders.av1Hardware ? "Sharpest picture for the bits. Decoded in hardware here." : "Not decoded in hardware on this Apple TV, so it runs in software."
        case .hevc: return "Decoded in hardware on every Apple TV 4K."
        case .h264: return "Most compatible. Needs the most bitrate."
        }
    }
}

/// Which DLSS model the cloud rig runs a game's upscaling with.
enum DlssModel: String, CaseIterable {
    case game, recommended, k, l, m

    var label: String {
        switch self {
        case .game: return "Game's choice"
        case .recommended: return "Recommended"
        case .k: return "Preset K"
        case .l: return "Preset L"
        case .m: return "Preset M"
        }
    }

    var wire: Int {
        switch self {
        case .game: return 0
        case .recommended: return 1
        case .k: return 12
        case .l: return 13
        case .m: return 14
        }
    }
}

/// How much DLSS upscales.
enum DlssQuality: String, CaseIterable {
    case game, dlaa, quality, balanced, performance, ultra

    var label: String {
        switch self {
        case .game: return "Game's choice"
        case .dlaa: return "DLAA"
        case .quality: return "Quality"
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        case .ultra: return "Ultra Performance"
        }
    }

    var wire: Int {
        switch self {
        case .game: return 0
        case .dlaa: return 5
        case .quality: return 3
        case .balanced: return 2
        case .performance: return 1
        case .ultra: return 4
        }
    }
}

enum DlssFrames: String, CaseIterable {
    case game, recommended, x3, x4

    var label: String {
        switch self {
        case .game: return "Game's choice"
        case .recommended: return "Recommended model"
        case .x3: return "Dynamic, up to 3x"
        case .x4: return "Dynamic, up to 4x"
        }
    }

    var multiplier: Int { self == .x3 ? 3 : self == .x4 ? 4 : 0 }
}

extension CaseIterable where Self: Equatable {
    /// The case after this one, wrapping round.
    var next: Self {
        let all = Array(Self.allCases)
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
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
    @Published var dlssModel: DlssModel { didSet { store.set(dlssModel.rawValue, forKey: "dlssModel") } }
    @Published var dlssQuality: DlssQuality { didSet { store.set(dlssQuality.rawValue, forKey: "dlssQuality") } }
    /// Whether Ray Reconstruction runs NVIDIA's recommended model in place of the game's.
    @Published var dlssRays: Bool { didSet { store.set(dlssRays, forKey: "dlssRays") } }
    @Published var dlssFrames: DlssFrames { didSet { store.set(dlssFrames.rawValue, forKey: "dlssFrames") } }

    /// What the next new session asks the rig to force. A quality mode needs a model, so it gets the recommended one.
    var dlss: DlssOverrides {
        DlssOverrides(
            srModel: dlssModel == .game && dlssQuality != .game ? 1 : dlssModel.wire,
            srMode: dlssQuality.wire,
            rrModel: dlssRays ? 1 : 0,
            fgModel: dlssFrames == .game ? 0 : 1,
            fgMultiplier: dlssFrames.multiplier
        )
    }

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
            fps: StreamMode.rates.contains(store.integer(forKey: "fps")) ? store.integer(forKey: "fps") : 60
        )
        bitrateMbps = store.object(forKey: "bitrate") as? Int ?? 50
        codec = CodecChoice(rawValue: store.string(forKey: "codec") ?? "") ?? .auto
        region = store.string(forKey: "region") ?? ""
        showStats = store.bool(forKey: "stats")
        dlssModel = DlssModel(rawValue: store.string(forKey: "dlssModel") ?? "") ?? .game
        dlssQuality = DlssQuality(rawValue: store.string(forKey: "dlssQuality") ?? "") ?? .game
        dlssRays = store.bool(forKey: "dlssRays")
        dlssFrames = DlssFrames(rawValue: store.string(forKey: "dlssFrames") ?? "") ?? .game
        route4k = store.string(forKey: "route4k").flatMap(Route.init)
        // A way of asking that failed is tried again after a day. One bad evening on
        // NVIDIA's side should not rule it out for good.
        failedRoutes = Self.recentFailures(store)
        log4k = store.stringArray(forKey: "log4k") ?? []
    }

    /// Failed ways of asking for 4K, less the ones that failed more than a day ago.
    private static func recentFailures(_ store: UserDefaults) -> Set<Route> {
        let failedAt = store.dictionary(forKey: "failedRoutesAt") as? [String: Double] ?? [:]
        let dayAgo = Date().timeIntervalSince1970 - 24 * 3600
        return Set((store.stringArray(forKey: "failedRoutes") ?? []).compactMap(Route.init).filter { (failedAt[$0.rawValue] ?? 0) > dayAgo })
    }

    /// Lets failures older than a day lapse. The app can stay open for days, so this runs
    /// each time 4K is asked for, not only at launch.
    func expireFailedRoutes() {
        let recent = Self.recentFailures(store)
        if recent != failedRoutes { failedRoutes = recent }
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
        var failedAt = store.dictionary(forKey: "failedRoutesAt") as? [String: Double] ?? [:]
        failedAt[r.rawValue] = worked ? nil : Date().timeIntervalSince1970
        store.set(failedAt, forKey: "failedRoutesAt")
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
        store.removeObject(forKey: "failedRoutesAt")
    }
}

/// Whether a mode can be used here, and a line that says why not or what to expect.
struct Verdict {
    let blocked: Bool
    let note: String?
}

enum Capabilities {
    /// The highest refresh rate this Apple TV can send to the TV. tvOS itself reports 60, but
    /// the A19 box lists 120 Hz modes below 4K that `HDMIMode` can switch to.
    @MainActor static var displayHz: Int { max(60, UIScreen.main.maximumFramesPerSecond, HDMIMode.fastestRate ?? 0) }

    /// The highest rate to ask GeForce NOW for. This is not held to `displayHz`: a 120 fps
    /// stream shown at 60 Hz still puts a newer frame on screen at each refresh, which cuts
    /// a little input lag. If a later tvOS opens 120 Hz output, the same stream fills it.
    static let maxFps = 120

    @MainActor static func check(_ mode: StreamMode, membership: Membership?) -> Verdict {
        if mode.fps > maxFps { return Verdict(blocked: true, note: "GeForce NOW streams up to \(maxFps) frames a second.") }
        if let m = membership, m.tier != "Ultimate", !m.modes.isEmpty, !m.modes.contains(where: { $0.height >= mode.height && $0.fps >= mode.fps }) {
            return Verdict(blocked: true, note: "Not part of your \(m.tier.map { "\($0) " } ?? "")membership.")
        }
        let lines = Settings.nativeResolution.height
        if mode.fps > displayHz {
            let scaled = lines < mode.height ? " It's also scaled down to \(lines)p." : ""
            return Verdict(blocked: false, note: "This Apple TV shows \(displayHz) Hz, so the picture stays as smooth as \(displayHz) fps, but controls respond a little faster.\(scaled)")
        }
        if mode.fps > 60, let fast = HDMIMode.fastModeSize {
            let shown = mode.height >= 2160 ? "Shown at \(fast) at 120 Hz, the largest this Apple TV sends at 120 Hz." : "The TV switches to 120 Hz while you play."
            return Verdict(blocked: false, note: "\(shown) Runs the Apple TV warmer.")
        }
        if lines < mode.height {
            return Verdict(blocked: false, note: "The Apple TV is set to \(lines)p, so \(mode.resolution.label) is scaled down to fit.")
        }
        if mode.height >= 2160 {
            return Verdict(blocked: false, note: "Needs Ultimate. If GeForce NOW doesn't give a 4K rig, the game starts at 1440p and says so.")
        }
        return Verdict(blocked: false, note: nil)
    }
}
