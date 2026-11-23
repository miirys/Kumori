import AVFoundation
import Foundation
import UIKit

/// What the local API and the log report say, as plain dictionaries. Values that aren't
/// known are left out rather than sent as zero. Nothing secret goes in: no tokens, no
/// session addresses, no email.
@MainActor
struct APIReport {
    let app: AppModel
    let player: Player
    let settings: Settings
    let controllers: ControllerCenter?

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func round1(_ v: Double?) -> Double? { v.map { ($0 * 10).rounded() / 10 } }

    var index: [String: Any] {
        [
            "app": "Kumori",
            "version": BuildInfo.current.version,
            "build": BuildInfo.current.build,
            "commit": BuildInfo.current.commit,
            "port": Int(LocalAPI.port),
            "readOnly": true,
            "endpoints": LocalAPI.endpoints.map { ["path": $0.path, "description": $0.what] },
        ]
    }

    var phaseName: String {
        switch player.phase {
        case .none: return "idle"
        case .starting: return "starting"
        case .queued: return "queued"
        case .connecting: return "connecting"
        case .live: return "live"
        case .ended(_, let error): return error ? "failed" : "ended"
        }
    }

    var status: [String: Any] {
        var d: [String: Any] = [
            "signedIn": app.signedIn,
            "phase": phaseName,
            "menuOpen": player.menuOpen,
            "idleEndMinutes": settings.idleMinutes,
            "time": Self.iso(Date()),
        ]
        if let g = player.game { d["game"] = ["id": g.id, "title": g.title] }
        if case .queued(let n) = player.phase { d["queuePosition"] = n }
        if case .starting(let t) = player.phase { d["step"] = t }
        if case .connecting(let t) = player.phase { d["step"] = t }
        if case .ended(let m, _) = player.phase { d["message"] = m }
        if let t = player.playingFor { d["playingForSeconds"] = Int(t) }
        if let left = player.timeLeft {
            d["unlimited"] = left.unlimited
            if !left.unlimited { d["hoursLeft"] = Self.round1(left.seconds / 3600); d["timeLeft"] = left.label }
        }
        if let idle = player.idleSecondsLeft { d["idleSecondsLeft"] = Int(idle) }
        if let n = player.notice { d["notice"] = n }
        return d
    }

    static func stats(_ s: StreamStats, below: BelowTargetReason?) -> [String: Any] {
        var d: [String: Any] = [
            "framesDecoded": s.framesDecoded,
            "packetsReceived": s.packetsReceived,
            "belowTarget": below != nil,
        ]
        if s.width > 0 { d["width"] = s.width; d["height"] = s.height }
        if let v = s.targetFps { d["targetFps"] = v }
        if let v = s.fps { d["fps"] = round1(v) }
        if let v = s.shownFps { d["shownFps"] = round1(v) }
        if let v = s.decodedFps { d["decodedFps"] = round1(v) }
        if let v = s.refreshHz { d["refreshHz"] = round1(v) }
        if let v = s.framesShown { d["framesShown"] = v }
        if let v = s.framesDroppedHere { d["framesDropped"] = v }
        if let v = s.framesDropped { d["framesDroppedDecoder"] = v }
        if let v = s.framesReceived { d["framesReceived"] = v }
        if let v = s.framesFailed { d["framesFailed"] = v }
        if let v = s.codec { d["codec"] = v }
        if let v = s.codecDetail { d["codecDetail"] = v }
        if let v = s.hardwareDecode { d["hardwareDecode"] = v }
        if let v = s.transport { d["transport"] = v }
        if let v = s.bitrateMbps { d["bitrateMbps"] = round1(v) }
        if let v = s.rttMs { d["rttMs"] = round1(v) }
        if let v = s.jitterMs { d["jitterMs"] = round1(v) }
        if let v = s.lossPct { d["lossPct"] = (v * 100).rounded() / 100 }
        if let v = s.packetsLost { d["packetsLost"] = v }
        if let v = s.packetsResent { d["packetsResent"] = v }
        if let v = s.decodeMs { d["decodeMs"] = round1(v) }
        if let v = s.audio { d["audio"] = v }
        if let below {
            d["belowTargetReason"] = below.rawValue
            d["belowTargetText"] = FrameHealth.words(below, target: s.targetFps ?? 60, shown: s.shownFps, decoded: s.decodedFps, refresh: s.refreshHz)
        }
        return d
    }

    var stats: [String: Any] {
        let live = player.phase != nil && (player.stats.width > 0 || player.stats.packetsReceived > 0)
        if live {
            var d = Self.stats(player.stats, below: player.belowTarget)
            d["live"] = true
            return d
        }
        guard let last = player.lastStats else { return ["live": false] }
        var d = Self.stats(last, below: nil)
        d["live"] = false
        d["note"] = "The last stream's numbers, as it ended."
        return d
    }

    var statsHistory: [String: Any] {
        ["samples": StreamHistory.shared.samples.map { s -> [String: Any] in
            var d: [String: Any] = ["at": Self.iso(s.at)]
            if let v = s.fps { d["fps"] = Self.round1(v) }
            if let v = s.decodedFps { d["decodedFps"] = Self.round1(v) }
            if let v = s.rttMs { d["rttMs"] = Self.round1(v) }
            if let v = s.mbps { d["bitrateMbps"] = Self.round1(v) }
            if let v = s.lossPct { d["lossPct"] = (v * 100).rounded() / 100 }
            if let v = s.dropped { d["framesDropped"] = v }
            return d
        }]
    }

    var session: [String: Any] {
        var d: [String: Any] = ["phase": phaseName]
        if let g = player.game { d["game"] = Self.game(g) }
        if let s = player.session {
            var c: [String: Any] = ["status": s.status, "transport": s.transport == .nvst ? "native" : "webrtc"]
            if let w = s.width, let h = s.height { c["width"] = w; c["height"] = h }
            if let f = s.fps { c["fps"] = f }
            if let gpu = s.gpu { c["gpu"] = gpu }
            if let q = s.queuePosition { c["queuePosition"] = q }
            d["cloud"] = c
        }
        d["requested"] = ["resolution": settings.mode.resolution.label, "fps": settings.mode.fps, "codec": settings.codec.label, "bitrateMbps": settings.bitrateMbps]
        if let m = player.playing { d["playing"] = ["resolution": m.resolution.label, "fps": m.fps] }
        if let t = player.playingFor { d["playingForSeconds"] = Int(t) }
        return d
    }

    var sessions: [String: Any] {
        ["sessions": app.sessions.map { s -> [String: Any] in
            var d: [String: Any] = ["status": s.status, "appId": s.appId]
            if let g = app.game(for: s) { d["title"] = g.title }
            return d
        }]
    }

    var history: [String: Any] {
        ["streams": StreamHistory.shared.records.reversed().map { r -> [String: Any] in
            var d: [String: Any] = [
                "startedAt": Self.iso(r.startedAt), "endedAt": Self.iso(r.endedAt), "seconds": r.seconds,
                "endedBy": r.endedBy, "lowSeconds": r.lowSeconds,
            ]
            if let v = r.gameId { d["gameId"] = v }
            if let v = r.title { d["title"] = v }
            if let v = r.targetFps { d["targetFps"] = v }
            if let w = r.width, let h = r.height { d["width"] = w; d["height"] = h }
            if let v = r.codec { d["codec"] = v }
            if let v = r.transport { d["transport"] = v }
            if let v = r.averageFps { d["averageFps"] = v }
            if let v = r.minimumFps { d["minimumFps"] = v }
            if let v = r.framesShown { d["framesShown"] = v }
            if let v = r.framesDropped { d["framesDropped"] = v }
            if let v = r.averageRttMs { d["averageRttMs"] = v }
            if let v = r.averageMbps { d["averageMbps"] = v }
            if let v = r.lossPct { d["lossPct"] = (v * 100).rounded() / 100 }
            if let v = r.message { d["message"] = v }
            return d
        }]
    }

    static func game(_ g: Game) -> [String: Any] {
        var d: [String: Any] = ["id": g.id, "title": g.title, "genres": g.genres]
        if let v = g.publisher { d["publisher"] = v }
        if let v = g.store { d["store"] = v }
        if let v = g.lastPlayed { d["lastPlayed"] = iso(v) }
        if let v = g.summary { d["summary"] = v }
        if let v = g.boxArt { d["boxArt"] = v }
        if let v = g.hero { d["hero"] = v }
        return d
    }

    var games: [String: Any] {
        ["count": app.library.count, "games": app.library.map { g -> [String: Any] in
            var d: [String: Any] = ["id": g.id, "title": g.title]
            if let v = g.store { d["store"] = v }
            if let v = g.lastPlayed { d["lastPlayed"] = Self.iso(v) }
            if app.session(for: g) != nil { d["runningInCloud"] = true }
            return d
        }]
    }

    func game(_ id: String) -> [String: Any]? {
        let all = app.library + app.shelves.flatMap(\.games)
        return all.first { $0.id == id || $0.variants.contains { $0.id == id } }.map(Self.game)
    }

    var settingsDict: [String: Any] {
        [
            "resolution": settings.mode.resolution.label,
            "width": settings.mode.width, "height": settings.mode.height,
            "fps": settings.mode.fps,
            "codec": settings.codec.label,
            "bitrateMbps": settings.bitrateMbps,
            "region": settings.region.isEmpty ? "Automatic" : settings.region,
            "stats": settings.statsLabel,
            "idleEndMinutes": settings.idleMinutes,
            "dlss": [
                "model": settings.dlssModel.label, "quality": settings.dlssQuality.label,
                "rayReconstruction": settings.dlssRays, "frameGeneration": settings.dlssFrames.label,
            ],
            "route4k": settings.route4k.map(\.rawValue) ?? "none",
        ]
    }

    var account: [String: Any] {
        var d: [String: Any] = ["signedIn": app.signedIn]
        if let p = app.profile { d["name"] = p.name }
        if let m = app.membership {
            if let t = m.tier { d["plan"] = t }
            d["unlimited"] = m.unlimited
            if let h = m.hoursLeft { d["hoursLeftReported"] = Self.round1(h) }
            if let at = app.membershipAt { d["reportedAt"] = Self.iso(at) }
            d["modes"] = m.modes.map { ["width": $0.width, "height": $0.height, "fps": $0.fps] }
        }
        if let left = player.timeLeft, !left.unlimited { d["hoursLeft"] = Self.round1(left.seconds / 3600) }
        d["regions"] = app.regions.map(\.name)
        return d
    }

    var device: [String: Any] {
        var d: [String: Any] = [
            "model": DeviceInfo.model,
            "tvOS": UIDevice.current.systemVersion,
            "display": DisplayInfo.summary,
            "maximumFramesPerSecond": UIScreen.main.maximumFramesPerSecond,
            "hdrEligible": AVPlayer.eligibleForHDRPlayback,
            "thermalState": ProcessInfo.processInfo.thermalState.label,
            "av1Hardware": HardwareDecoders.av1Hardware,
            "audioChannels": AVAudioSession.sharedInstance().maximumOutputNumberOfChannels,
        ]
        if let ip = LocalAddress.ipv4() { d["address"] = ip }
        let chain = DisplayChain.read()
        d["chain"] = chain.dictionary
        return d
    }

    var launch: [String: Any] {
        guard let t = player.trace else { return ["launch": NSNull()] }
        return [
            "id": t.id,
            "furthestStep": t.lastGood.map { $0.rawValue } ?? "none",
            "steps": t.events.map { e -> [String: Any] in
                var d: [String: Any] = ["at": (e.at * 100).rounded() / 100, "stage": e.stage.rawValue]
                if !e.fields.isEmpty { d["detail"] = e.fields.text }
                return d
            },
        ]
    }

    var input: [String: Any] {
        let link = KumoriLink.shared
        var d: [String: Any] = [
            "controllers": (controllers?.pads ?? []).map { p -> [String: Any] in
                var c: [String: Any] = ["name": p.name, "kind": p.category, "siriRemote": p.isRemote]
                if let b = p.battery { c["battery"] = Int((b * 100).rounded()) }
                return c
            },
        ]
        var l: [String: Any] = ["connected": link.status == .connected, "controllers": link.controllers, "packetsReceived": link.received]
        if let v = link.boxModel { l["box"] = v }
        if let v = link.boxVersion { l["boxVersion"] = v }
        if let v = link.roundTripMs { l["roundTripMs"] = Self.round1(v) }
        d["kumoriLink"] = l
        let stats = player.phase != nil ? player.inputStats : (player.lastInput ?? InputStats())
        d["reports"] = ["ready": stats.ready, "sent": stats.sent, "sentOrdered": stats.reliable, "beforeReady": stats.early, "rejected": stats.rejected]
        return d
    }
}

extension APIReport {
    /// `/settings`. Named apart from the stored `settings` property.
    var settingsJSON: [String: Any] { settingsDict }
}
