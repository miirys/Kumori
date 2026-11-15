import Foundation

/// Text edits on session descriptions. GeForce NOW's offers need a few fixes before a stock
/// WebRTC stack accepts them, and the answer travels with NVIDIA's own stream settings.
enum SDP {
    struct Ice {
        let ufrag: String
        let pwd: String
        let fingerprint: String
    }

    private static func lines(_ sdp: String) -> [String] {
        sdp.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func eol(_ sdp: String) -> String { sdp.contains("\r\n") ? "\r\n" : "\n" }

    private static func codecName(_ raw: String) -> String {
        let n = raw.uppercased()
        return n == "HEVC" ? "H265" : n
    }

    /// "80-250-97-40.cloud.example" and "80.250.97.40" both mean 80.250.97.40.
    static func publicIp(_ host: String) -> String? {
        func isIp(_ parts: [Substring]) -> Bool { parts.count == 4 && parts.allSatisfy { (1...3).contains($0.count) && $0.allSatisfy(\.isNumber) } }
        if isIp(host.split(separator: ".", omittingEmptySubsequences: false)) { return host }
        let parts = host.prefix { $0 != "." }.split(separator: "-", omittingEmptySubsequences: false)
        return isIp(parts) ? parts.joined(separator: ".") : nil
    }

    /// The server writes 0.0.0.0 where its address belongs. Put the real one in.
    static func fixServerIp(_ sdp: String, server: String) -> String {
        guard let ip = publicIp(server) else { return sdp }
        return sdp.replacingOccurrences(of: "c=IN IP4 0.0.0.0", with: "c=IN IP4 \(ip)")
            .replacingOccurrences(of: #"(a=candidate:\S+\s+\d+\s+\w+\s+\d+\s+)0\.0\.0\.0(\s+)"#, with: "$1\(ip)$2", options: .regularExpression)
    }

    static func value(_ sdp: String, _ prefix: String) -> String? {
        lines(sdp).first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    static func ice(_ sdp: String) -> Ice {
        Ice(ufrag: value(sdp, "a=ice-ufrag:") ?? "", pwd: value(sdp, "a=ice-pwd:") ?? "", fingerprint: value(sdp, "a=fingerprint:sha-256 ") ?? "")
    }

    static func partialReliableThreshold(_ sdp: String) -> Int? {
        guard let l = lines(sdp).first(where: { $0.lowercased().hasPrefix("a=ri.partialreliablethresholdms:") }),
              let v = Int(l.split(separator: ":").last ?? ""), v > 0 else { return nil }
        return v
    }

    private static func payload(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: colon)...].prefix { $0 != " " })
    }

    private static func rtpName(_ line: String) -> String {
        guard let space = line.firstIndex(of: " ") else { return "" }
        return codecName(String(line[line.index(after: space)...].prefix { $0 != "/" }))
    }

    /// Video codecs the offer contains, by name.
    static func offeredCodecs(_ sdp: String) -> Set<String> {
        var out = Set<String>()
        var video = false
        for l in lines(sdp) {
            if l.hasPrefix("m=") { video = l.hasPrefix("m=video") }
            if video, l.hasPrefix("a=rtpmap:") { out.insert(rtpName(l)) }
        }
        return out
    }

    /// Leaves only `codec` and its retransmission streams in the video section, so the answer
    /// cannot settle on anything else.
    static func keepCodec(_ sdp: String, _ codec: String) -> String {
        let all = lines(sdp)
        var nameOf: [String: String] = [:]
        var aptOf: [String: String] = [:]
        var video = false
        for l in all {
            if l.hasPrefix("m=") { video = l.hasPrefix("m=video") }
            guard video else { continue }
            if l.hasPrefix("a=rtpmap:") {
                nameOf[payload(l)] = rtpName(l)
            } else if l.hasPrefix("a=fmtp:"), let r = l.range(of: #"apt=(\d+)"#, options: .regularExpression) {
                aptOf[payload(l)] = String(l[r].dropFirst(4))
            }
        }
        let wanted = Set(nameOf.filter { $0.value == codec }.keys)
        guard !wanted.isEmpty else { return sdp }
        var allowed = wanted
        for (pt, apt) in aptOf where wanted.contains(apt) && nameOf[pt] == "RTX" { allowed.insert(pt) }

        var out: [String] = []
        video = false
        for l in all {
            if l.hasPrefix("m=") { video = l.hasPrefix("m=video") }
            if video, l.hasPrefix("m=video") {
                let parts = l.components(separatedBy: " ")
                let pts = parts.dropFirst(3).filter { allowed.contains($0) }
                let ordered = pts.filter { wanted.contains($0) } + pts.filter { !wanted.contains($0) }
                out.append(ordered.isEmpty ? l : (Array(parts.prefix(3)) + ordered).joined(separator: " "))
                continue
            }
            if video, l.hasPrefix("a=rtpmap:") || l.hasPrefix("a=fmtp:") || l.hasPrefix("a=rtcp-fb:"), !allowed.contains(payload(l)) { continue }
            out.append(l)
        }
        return out.joined(separator: eol(sdp))
    }

    /// The codec our answer settled on: the first payload type on the video line.
    static func negotiatedCodec(_ sdp: String) -> String? {
        let all = lines(sdp)
        guard let m = all.first(where: { $0.hasPrefix("m=video") }) else { return nil }
        let parts = m.components(separatedBy: " ")
        guard parts.count > 3 else { return nil }
        return all.first { $0.hasPrefix("a=rtpmap:\(parts[3]) ") }.map(rtpName)
    }

    /// Tells the server how much we can take, and asks for stereo game audio.
    static func mungeAnswer(_ sdp: String, videoKbps: Int) -> String {
        let all = lines(sdp)
        var out: [String] = []
        for (i, l) in all.enumerated() {
            out.append(l.hasPrefix("a=fmtp:") && l.contains("minptime=") && !l.contains("stereo=1") ? "\(l);stereo=1" : l)
            let video = l.hasPrefix("m=video")
            let next = i + 1 < all.count ? all[i + 1] : ""
            if video || l.hasPrefix("m=audio"), !next.hasPrefix("b=") { out.append("b=AS:\(video ? videoKbps : 128)") }
        }
        return out.joined(separator: eol(sdp))
    }

    /// The lowest bitrate the server's rate control may settle on, idle screens included.
    static let minKbps = 20_000

    /// NVIDIA's companion description. It carries the ICE credentials again plus the encoder
    /// and pacing settings the server applies: a fixed resolution, and adaptive bitrate that
    /// never drops below 20 Mbps (or the cap, when the cap is lower).
    static func nvst(width: Int, height: Int, fps: Int, maxKbps: Int, bitDepth: Int, partialReliableMs: Int, ice: Ice) -> String {
        let low = min(maxKbps, max(minKbps, maxKbps * 35 / 100))
        let start = max(low, maxKbps * 70 / 100)
        var a: [String] = []
        a += [
            "general.icePassword:\(ice.pwd)",
            "general.iceUserNameFragment:\(ice.ufrag)",
            "general.dtlsFingerprint:\(ice.fingerprint)",
        ]
        var video = [
            "msid:fbc-video-0",
            "vqos.fec.rateDropWindow:10", "vqos.fec.minRequiredFecPackets:2", "vqos.fec.repairMinPercent:5",
            "vqos.fec.repairPercent:5", "vqos.fec.repairMaxPercent:35",
            "vqos.drc.enable:0", "vqos.dfc.enable:0",
            "video.dx9EnableNv12:1", "video.dx9EnableHdr:1",
            "vqos.qpg.enable:1", "vqos.resControl.qp.qpg.featureSetting:7",
            "bwe.useOwdCongestionControl:1", "video.enableRtpNack:1",
            "vqos.bw.txRxLag.minFeedbackTxDeltaMs:200", "vqos.drc.bitrateIirFilterFactor:18",
            "video.packetSize:1140", "packetPacing.minNumPacketsPerGroup:15",
            "vqos.adjustStreamingFpsDuringOutOfFocus:1",
            "vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1",
            "vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1",
            "vqos.resControl.cpmRtc.featureMask:0", "vqos.resControl.cpmRtc.enable:0",
            "vqos.resControl.cpmRtc.minResolutionPercent:100",
            "vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999",
            "packetPacing.numGroups:5", "packetPacing.maxDelayUs:1000", "packetPacing.minNumPacketsFrame:10",
            "video.rtpNackQueueLength:1024", "video.rtpNackQueueMaxPackets:512", "video.rtpNackMaxPacketCount:25",
            "vqos.drc.qpMaxResThresholdAdj:4", "vqos.grc.qpMaxResThresholdAdj:4", "vqos.drc.iirFilterFactor:100",
        ]
        video += [
            "video.clientViewportWd:\(width)", "video.clientViewportHt:\(height)", "video.maxFPS:\(fps)",
            "video.initialBitrateKbps:\(start)", "video.initialPeakBitrateKbps:\(maxKbps)",
            "vqos.bw.maximumBitrateKbps:\(maxKbps)", "vqos.bw.minimumBitrateKbps:\(low)",
            "vqos.bw.peakBitrateKbps:\(maxKbps)", "vqos.bw.serverPeakBitrateKbps:\(maxKbps)",
            "vqos.bw.enableBandwidthEstimation:1", "vqos.bw.disableBitrateLimit:0",
            "vqos.grc.maximumBitrateKbps:\(maxKbps)", "vqos.grc.enable:0",
            "video.maxNumReferenceFrames:4", "video.mapRtpTimestampsToFrames:1",
            "video.encoderCscMode:3", "video.dynamicRangeMode:0", "video.bitDepth:\(bitDepth)",
            "video.scalingFeature1:0", "video.prefilterParams.prefilterModel:0",
        ]
        var s = "v=0\no=SdpTest test_id_13 14 IN IPv4 127.0.0.1\ns=-\nt=0 0\n"
        for l in a { s += "a=\(l)\n" }
        s += "m=video 0 RTP/AVP\n"
        for l in video { s += "a=\(l)\n" }
        s += "m=audio 0 RTP/AVP\na=msid:audio\n"
        s += "m=mic 0 RTP/AVP\na=msid:mic\na=rtpmap:0 PCMU/8000\n"
        s += "m=application 0 RTP/AVP\na=msid:input_1\na=ri.partialReliableThresholdMs:\(partialReliableMs)\n"
        return s
    }
}
