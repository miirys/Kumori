import Foundation

/// The session request as the native NVST client sends it. The rig then streams over RTSPS and
/// SRTP to Kumori's native receiver, instead of over WebRTC.
///
/// The fields follow OpenNOW's tvOS client (github.com/Lacrowx/OpenNOW at 445865e,
/// NativeStreamNVSTConfiguration.requestBody and GFNAPIClient.buildSessionBody), which streams
/// 4K60 and 1440p120 on an Apple TV this way. The request Kumori builds for the WebRTC clients is
/// taken as the starting point, and only what differs is changed, so the two stay in step.
enum NativeRequest {
    /// The PC client's user agent, which the native identity sends.
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.88.129"

    /// The session request's audio fields for a channel count: `requestedAudioFormat` 2 for
    /// 5.1 and 3 for 7.1 (0 for stereo), and the count as text in the `surroundAudioInfo` entry.
    static func audio(channels: Int) -> (format: Int, info: String) {
        switch channels {
        case 8: return (3, "8")
        case 6: return (2, "6")
        default: return (0, "2")
        }
    }

    /// Turns a WebRTC session request (`sessionRequestData`) into the native one.
    static func transform(_ base: [String: Any], width: Int, height: Int, fps: Int, audioChannels: Int = 2,
                          claim: Bool = false) -> [String: Any] {
        let null = NSNull()
        var r = base
        let audio = audio(channels: audioChannels)
        r["clientIdentification"] = "GFN-PC"
        r["clientPlatformName"] = "windows"
        r["clientVersion"] = "30.0"
        r["sdkVersion"] = "2.0"
        // A string on the wire, unlike the WebRTC request's number 1.
        r["streamerVersion"] = "14"
        r["secureRTSPSupported"] = true
        r["enhancedStreamMode"] = 0
        r["transport"] = null
        r["requestedAudioFormat"] = audio.format
        r["availableSupportedControllers"] = [2]
        r["remoteControllersBitmap"] = 1
        r["appLaunchMode"] = 2
        r["sdrHdrMode"] = 0
        r["clientDisplayHdrCapabilities"] = null
        r["enablePersistingInGameSettings"] = true
        // One monitor per attempt, at the mode this attempt asks for.
        r["clientRequestMonitorSettings"] = [[
            "monitorId": 0, "positionX": 0, "positionY": 0,
            "widthInPixels": width, "heightInPixels": height, "framesPerSecond": fps,
            "sdrHdrMode": 0, "displayData": null, "hdr10PlusGamingData": null, "dpi": 100,
        ] as [String: Any]]
        var features: [String: Any] = [
            "reflex": fps >= 120,
            // CloudMatch writes 8 and 10 bit as 0 and 1. The native SDP uses 8 and 10.
            "bitDepth": 0,
            "trueHdr": false,
            "enabledL4S": false,
            "supportedHidDevices": 0,
            "profile": 0,
            "fallbackToLogicalResolution": false,
            "chromaFormat": 0,
            "prefilterMode": 0,
            "prefilterSharpness": 0,
            "prefilterNoiseReduction": 0,
            "hudStreamingMode": 0,
        ]
        // A new session keeps the game's DLSS choices.
        if !claim, let old = r["requestedStreamingFeatures"] as? [String: Any], let dlss = old["dlssOverrides"] {
            features["dlssOverrides"] = dlss
        }
        r["requestedStreamingFeatures"] = features
        // Metadata by key: the WebRTC streamer type goes, the rest stays, and the physical
        // resolution and audio layout follow this attempt.
        var meta = (r["metaData"] as? [[String: String]] ?? []).filter { $0["key"] != "GSStreamerType" }
        func put(_ key: String, _ value: String) {
            if let i = meta.firstIndex(where: { $0["key"] == key }) { meta[i]["value"] = value } else { meta.append(["key": key, "value": value]) }
        }
        put("wssignaling", "1")
        put("clientPhysicalResolution", "{\"horizontalPixels\":\(width),\"verticalPixels\":\(height)}")
        put("surroundAudioInfo", audio.info)
        if !meta.contains(where: { $0["key"] == "SubSessionId" }) { put("SubSessionId", UUID().uuidString.lowercased()) }
        r["metaData"] = meta
        return r
    }

    /// The modes to ask the native client for, best first, for a chosen mode. The Apple TV has no
    /// 4K 120 Hz output, so 4K is asked at 60 at most; 1440p keeps 120 only where the display
    /// can show it; and the TV client's 1080p60 is the last resort, which the caller handles.
    static func ladder(width: Int, height: Int, fps: Int, displayMaxFps: Int) -> [ModeRequest] {
        var out: [ModeRequest] = []
        func add(_ w: Int, _ h: Int, _ f: Int) {
            let m = ModeRequest(width: w, height: h, fps: f)
            if !out.contains(m) { out.append(m) }
        }
        let fast = fps > 60 && displayMaxFps >= 120
        if height >= 2160 { add(3840, 2160, 60) }
        if height >= 1440 {
            if fast { add(2560, 1440, 120) }
            add(2560, 1440, 60)
        }
        if height >= 1080, fast { add(1920, 1080, 120) }
        if out.isEmpty { add(width, height, min(fps, displayMaxFps >= 120 ? fps : 60)) }
        return out
    }

    /// Whether a mode is worth the native client: anything the TV client can't give, which is
    /// more than 1080p or more than 60 fps.
    static func wanted(width: Int, height: Int, fps: Int) -> Bool {
        fps > 60 || width > 1920 || height > 1200
    }

    /// The balanced bitrate for a mode, as OpenNOW's tvOS client picks it, unless the player set
    /// a different one: 50 Mbps for 4K60, 38 Mbps for 1440p120.
    static func bitrateKbps(width: Int, height: Int, fps: Int, chosenMbps: Int?) -> Int {
        if let chosenMbps, chosenMbps > 0 { return chosenMbps * 1000 }
        if height >= 2160 { return 50_000 }
        if height >= 1440 { return fps > 60 ? 38_000 : 30_000 }
        return fps > 60 ? 30_000 : 20_000
    }
}
