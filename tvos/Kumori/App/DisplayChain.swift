import AVFoundation
import Foundation
import UIKit

/// What the HDMI chain (Apple TV, then any receiver, then the TV or projector) lets
/// through, read from the modes tvOS says the display accepts, and what to change when
/// 120 Hz or HDR is missing.
@MainActor
struct DisplayChain {
    enum Level: String { case ok, warning, blocked, unknown }

    struct Finding: Identifiable {
        let id: String
        let title: String
        let level: Level
        let value: String
        let detail: String?
    }

    let current: HDMIMode.ModeInfo?
    let modes: [HDMIMode.ModeInfo]?
    let matchContent: Bool?
    let hdrEligible: Bool
    /// The name of the HDMI device the sound goes to, which is usually the receiver or TV.
    let audioDevice: String?
    let channels: Int

    static func read() -> DisplayChain {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        let output = AVAudioSession.sharedInstance().currentRoute.outputs.first
        return DisplayChain(
            current: HDMIMode.currentMode,
            modes: HDMIMode.offeredModes,
            matchContent: StreamDisplay.manager(of: window)?.isDisplayCriteriaMatchingEnabled,
            hdrEligible: AVPlayer.eligibleForHDRPlayback,
            audioDevice: output.map { $0.portName },
            channels: AVAudioSession.sharedInstance().maximumOutputNumberOfChannels
        )
    }

    private var sdr: [HDMIMode.ModeInfo] { (modes ?? []).filter { !$0.hdr } }
    private var fastest: Double? { sdr.map(\.hz).max() }
    private func fast(_ lines: Int) -> HDMIMode.ModeInfo? { sdr.first { $0.height == lines && $0.hz > 100 } }
    private var hdrModes: [HDMIMode.ModeInfo] { (modes ?? []).filter(\.hdr) }

    var findings: [Finding] {
        var out: [Finding] = []

        // The output right now.
        if let c = current {
            if c.hz < 55 {
                out.append(Finding(id: "output", title: "Apple TV Output", level: .warning, value: c.label,
                                   detail: "Choose a 60 Hz format"))
            } else if c.hdr {
                out.append(Finding(id: "output", title: "Apple TV Output", level: .warning, value: c.label,
                                   detail: "Use 4K SDR with Match Dynamic Range"))
            } else {
                out.append(Finding(id: "output", title: "Apple TV Output", level: .ok, value: c.label, detail: nil))
            }
        } else {
            out.append(Finding(id: "output", title: "Apple TV Output", level: .unknown, value: DisplayInfo.summary,
                               detail: nil))
        }

        // 120 Hz.
        if modes == nil {
            out.append(Finding(id: "120", title: "120 Hz", level: .unknown, value: "Can't read",
                               detail: nil))
        } else if let best = fast(1440) ?? fast(1080) {
            let both = fast(1440) != nil && fast(1080) != nil
            out.append(Finding(id: "120", title: "120 Hz", level: .ok, value: "\(best.height)p at \(FrameHealth.hz(best.hz))",
                               detail: both ? "1440p and 1080p" : nil))
        } else {
            let top = fastest.map { FrameHealth.hz($0) } ?? "60 Hz"
            out.append(Finding(id: "120", title: "120 Hz", level: .blocked, value: "Up to \(top)",
                               detail: "Set HDMI inputs to Enhanced, use a 48 Gbps cable"))
        }

        // HDR.
        let dv = hdrModes.contains { $0.range.lowercased().contains("dolby") }
        let hdr10 = hdrModes.contains { !$0.range.lowercased().contains("dolby") }
        if modes == nil {
            out.append(Finding(id: "hdr", title: "HDR", level: hdrEligible ? .ok : .unknown, value: hdrEligible ? "Available" : "Unknown", detail: nil))
        } else if hdr10 || dv {
            let names = [hdr10 ? "HDR10" : nil, dv ? "Dolby Vision" : nil].compactMap { $0 }.joined(separator: " and ")
            let top = hdrModes.max { ($0.height, $0.hz) < ($1.height, $1.hz) }
            out.append(Finding(id: "hdr", title: "HDR", level: .ok, value: names,
                               detail: top.map { "Up to \($0.height >= 2160 ? "4K" : "\($0.height)p") at \(FrameHealth.hz($0.hz)) in HDR." }))
        } else {
            out.append(Finding(id: "hdr", title: "HDR", level: .blocked, value: "Not offered",
                               detail: "Set HDMI inputs to Enhanced"))
        }

        // Match Content.
        switch matchContent {
        case .some(true):
            out.append(Finding(id: "match", title: "Match Content", level: .ok, value: "On", detail: nil))
        case .some(false):
            out.append(Finding(id: "match", title: "Match Content", level: .warning, value: "Off",
                               detail: "Turn on Match Frame Rate"))
        case .none:
            out.append(Finding(id: "match", title: "Match Content", level: .unknown, value: "Can't read", detail: nil))
        }

        // Where the signal goes.
        if let name = audioDevice {
            out.append(Finding(id: "device", title: "Connected To", level: .ok, value: name,
                               detail: channels > 2 ? "\(channels) audio channels" : nil))
        }
        return out
    }

    /// The modes offered, one line each, fastest of each size first.
    var modeLines: [String] {
        (modes ?? []).sorted { ($0.height, $0.hz, $0.range) > ($1.height, $1.hz, $1.range) }.map(\.label)
    }

    var dictionary: [String: Any] {
        var d: [String: Any] = [
            "findings": findings.map { f -> [String: Any] in
                var x: [String: Any] = ["check": f.title, "result": f.level.rawValue, "value": f.value]
                if let detail = f.detail { x["detail"] = detail }
                return x
            },
            "modesOffered": modeLines,
            "hdrEligible": hdrEligible,
        ]
        if let c = current { d["current"] = c.label }
        if let m = matchContent { d["matchContent"] = m }
        return d
    }
}
