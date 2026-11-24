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

/// Which surround layout to ask the rig for. GeForce NOW offers stereo, 5.1 and 7.1 — there is
/// no separate 5.1.2 (Atmos height) layout on the wire — so a player who doesn't want 7.1 can
/// pin it to 5.1 or stereo here. Automatic takes the most the HDMI audio route reports.
enum AudioLayout: String, CaseIterable {
    case auto, stereo, surround51, surround71

    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .stereo: return "Stereo"
        case .surround51: return "5.1 surround"
        case .surround71: return "7.1 surround"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "The most your TV or receiver says it can play."
        case .stereo: return "Two channels."
        case .surround51: return "Six channels. Pick this if a 7.1 stream sounds wrong on a 5.1 system."
        case .surround71: return "Eight channels."
        }
    }

    /// The channel count to ask for, never more than the audio route carries.
    func channels(carried: Int) -> Int {
        switch self {
        case .auto: return carried
        case .stereo: return 2
        case .surround51: return min(6, carried)
        case .surround71: return min(8, carried)
        }
    }
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
    /// A bitrate was picked in Settings. Its default, 50 Mbps, is also a choice in the list,
    /// so the number alone can't say whether the mode's own balanced rate should be used.
    var bitrateChosen: Bool { store.object(forKey: "bitrate") != nil }
    @Published var codec: CodecChoice { didSet { store.set(codec.rawValue, forKey: "codec") } }
    /// Name of the chosen server location, or empty for automatic.
    @Published var region: String { didSet { store.set(region, forKey: "region") } }
    @Published var showStats: Bool { didSet { store.set(showStats, forKey: "stats") } }
    /// When stats show: one line, or every number.
    @Published var statsDetailed: Bool { didSet { store.set(statsDetailed, forKey: "statsDetailed") } }

    /// Minutes without controller input before a stream's cloud session is ended, 0 for never.
    @Published var idleMinutes: Int { didSet { store.set(idleMinutes, forKey: "idleMinutes") } }

    /// The store each game launches from, by game id, when it is on more than one and the
    /// player picked one on the game page.
    @Published var storeChoice: [String: String] { didSet { store.set(storeChoice, forKey: "storeChoice") } }

    /// The variant a launch of `g` uses: the one picked on the game page, else the account's.
    func variant(for g: Game) -> Variant? {
        if let id = storeChoice[g.id], let v = g.variants.first(where: { $0.id == id }) { return v }
        return g.launchVariant
    }

    /// Steps `g` to its next store, wrapping round.
    func cycleStore(for g: Game) {
        guard g.variants.count > 1 else { return }
        let i = g.variants.firstIndex(where: { $0.id == variant(for: g)?.id }) ?? 0
        storeChoice[g.id] = g.variants[(i + 1) % g.variants.count].id
    }

    /// Which surround layout to ask the rig for.
    @Published var audioLayout: AudioLayout { didSet { store.set(audioLayout.rawValue, forKey: "audioLayout") } }

    /// How fast the left stick moves the pointer in mouse mode, as a multiple of the default.
    @Published var mouseSensitivity: Double { didSet { store.set(mouseSensitivity, forKey: "mouseSensitivity") } }

    /// The sensitivities the picker steps through, as multiples of the default pointer speed.
    static let mouseSensitivities: [Double] = [0.35, 0.5, 0.7, 1.0, 1.3, 1.6, 2.0]

    /// The mouse sensitivity as a percentage of the default, e.g. "70%".
    var mouseSensitivityLabel: String { "\(Int((mouseSensitivity * 100).rounded()))%" }

    /// Steps to the next sensitivity, wrapping round.
    func cycleMouseSensitivity() {
        let all = Self.mouseSensitivities
        let i = all.firstIndex(of: mouseSensitivity) ?? all.firstIndex(of: 1.0) ?? 0
        mouseSensitivity = all[(i + 1) % all.count]
    }

    /// "Off", "Compact" or "Detailed".
    var statsLabel: String { !showStats ? "Off" : statsDetailed ? "Detailed" : "Compact" }

    /// Off, then compact, then detailed, then off again.
    func cycleStats() {
        if !showStats {
            statsDetailed = false
            showStats = true
        } else if !statsDetailed {
            statsDetailed = true
        } else {
            showStats = false
        }
    }
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
        statsDetailed = store.bool(forKey: "statsDetailed")
        idleMinutes = (store.object(forKey: "idleMinutes") as? Int).flatMap { IdleClock.choices.contains($0) ? $0 : nil } ?? IdleClock.standard
        audioLayout = AudioLayout(rawValue: store.string(forKey: "audioLayout") ?? "") ?? .auto
        storeChoice = store.dictionary(forKey: "storeChoice") as? [String: String] ?? [:]
        mouseSensitivity = (store.object(forKey: "mouseSensitivity") as? Double).flatMap { Self.mouseSensitivities.contains($0) ? $0 : nil } ?? 1.0
        dlssModel = DlssModel(rawValue: store.string(forKey: "dlssModel") ?? "") ?? .game
        dlssQuality = DlssQuality(rawValue: store.string(forKey: "dlssQuality") ?? "") ?? .game
        dlssRays = store.bool(forKey: "dlssRays")
        dlssFrames = DlssFrames(rawValue: store.string(forKey: "dlssFrames") ?? "") ?? .game
        // From shape 2 the PC client is asked for the way OpenNOW's Android app asks. How the
        // older ways of asking did says nothing about it, so their record is dropped once.
        if store.integer(forKey: "routeShape") < 2 {
            for key in ["route4k", "failedRoutes", "failedRoutesAt"] { store.removeObject(forKey: key) }
            store.set(2, forKey: "routeShape")
        }
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

    /// The largest picture the TV takes at 120 Hz, as "1440p", or nil where it can't.
    @MainActor static var fastLines: String? {
        HDMIMode.fastModeSize.flatMap { $0.split(separator: " ").last.map { "\($0)p" } }
    }

    @MainActor static func check(_ mode: StreamMode, membership: Membership?) -> Verdict {
        if mode.fps > maxFps { return Verdict(blocked: true, note: "Up to \(maxFps) fps") }
        if let m = membership, m.tier != "Ultimate", !m.modes.isEmpty, !m.modes.contains(where: { $0.height >= mode.height && $0.fps >= mode.fps }) {
            return Verdict(blocked: true, note: "Not in your plan")
        }
        let lines = Settings.nativeResolution.height
        // Above the TV's rate the picture is as smooth as the TV, with a little less lag.
        if mode.fps > displayHz {
            return Verdict(blocked: false, note: lines < mode.height ? "Shown at \(lines)p, \(displayHz) Hz" : "Shown at \(displayHz) Hz")
        }
        if mode.fps > 60, let fast = fastLines {
            return Verdict(blocked: false, note: mode.height > (Int(fast.dropLast()) ?? 0) ? "Shown at \(fast) 120 Hz" : "TV switches to 120 Hz")
        }
        if lines < mode.height {
            return Verdict(blocked: false, note: "Shown at \(lines)p")
        }
        return Verdict(blocked: false, note: nil)
    }
}
