import AudioToolbox
import Foundation

/// Where each decoded channel goes on the output device. Worked out once when the device opens
/// or the seat's layout changes, then applied on every render.
///
/// The device either has a channel for every speaker of the layout, and each decoded channel goes
/// to the device channel of the same speaker, or it has fewer channels than the layout, and the
/// layout is folded to stereo.
public struct NvstAudioPlacement: Equatable, Sendable {
    public struct Tap: Equatable, Sendable {
        public let source: Int
        public let gain: Float
    }

    public let sourceChannels: Int
    /// For each device channel, the decoded channels mixed into it.
    public let taps: [[Tap]]
    /// The layout has more channels than the device, so it is folded to stereo.
    public let isDownmix: Bool

    public var deviceChannels: Int { taps.count }

    /// ITU-R BS.775: centre and surrounds join the front pair 3 dB down; the LFE is left out.
    static let surroundFoldGain: Float = 0.707

    public init(layout: NvstAudioLayout, deviceSpeakers: [NvstSpeaker?]) {
        let speakers = layout.speakers
        func fold(left: Bool) -> [Tap] {
            speakers.enumerated().compactMap { index, speaker in
                Self.foldGain(of: speaker, left: left).map { Tap(source: index, gain: $0) }
            }
        }
        sourceChannels = layout.channels
        if deviceSpeakers.count == 1 {
            isDownmix = layout.channels > 2
            taps = [(fold(left: true) + fold(left: false)).map { Tap(source: $0.source, gain: $0.gain / 2) }]
        } else if deviceSpeakers.count < layout.channels {
            isDownmix = true
            taps = deviceSpeakers.map { speaker in
                switch speaker {
                case .some(.frontLeft): fold(left: true)
                case .some(.frontRight): fold(left: false)
                default: []
                }
            }
        } else {
            isDownmix = false
            taps = deviceSpeakers.map { speaker in
                guard let speaker, let source = speakers.firstIndex(of: speaker) else { return [] }
                return [Tap(source: source, gain: 1)]
            }
        }
    }

    /// What `speaker` adds to the left or the right channel of a stereo fold-down.
    private static func foldGain(of speaker: NvstSpeaker, left: Bool) -> Float? {
        switch speaker {
        case .frontLeft: return left ? 1 : nil
        case .frontRight: return left ? nil : 1
        case .frontCenter: return surroundFoldGain
        case .backLeft, .sideLeft: return left ? surroundFoldGain : nil
        case .backRight, .sideRight: return left ? nil : surroundFoldGain
        case .lowFrequency: return nil
        }
    }

    /// Interleaved 16-bit samples for the device from interleaved decoded floats. Frames the
    /// decode did not supply stay silent.
    public func render(_ samples: [Float], frames: Int) -> [Int16] {
        let frameCount = max(0, frames)
        let channels = deviceChannels
        var output = [Int16](repeating: 0, count: frameCount * channels)
        for frame in 0..<frameCount {
            let base = frame * sourceChannels
            guard base + sourceChannels <= samples.count else { break }
            for channel in 0..<channels where !taps[channel].isEmpty {
                var value: Float = 0
                for tap in taps[channel] { value += samples[base + tap.source] * tap.gain }
                output[frame * channels + channel] = NvstCoreAudioFormat.clamped16(value)
            }
        }
        return output
    }

    /// The speaker order assumed for a device that does not label its channels: Apple's default
    /// multichannel layouts (`kAudioChannelLayoutTag_MPEG_5_1_A`: L R C LFE Ls Rs;
    /// `kAudioChannelLayoutTag_MPEG_7_1_C`: L R C LFE Ls Rs Rls Rrs).
    public static func defaultSpeakers(channelCount: Int) -> [NvstSpeaker?] {
        switch channelCount {
        case 1: [.frontCenter]
        case 6: [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight]
        case 8: [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight, .backLeft, .backRight]
        default: [.frontLeft, .frontRight] + [NvstSpeaker?](repeating: nil, count: max(0, channelCount - 2))
        }
    }

    /// The speaker of each device channel from the route's Core Audio channel labels. A 5.1
    /// route's one surround pair is the layout's rear pair, whether it is labelled plain or
    /// "direct"; when the route also has a rear pair, the plain surround pair is the side pair,
    /// and a direct pair beside another surround pair is the side pair. Labels that do not at
    /// least name a front pair are not trusted.
    public static func speakers(forChannelLabels labels: [UInt32], channelCount: Int) -> [NvstSpeaker?] {
        guard labels.count == channelCount else { return defaultSpeakers(channelCount: channelCount) }
        let hasRearPair = labels.contains(kAudioChannelLabel_RearSurroundLeft)
            || labels.contains(kAudioChannelLabel_RearSurroundRight)
        let hasPlainSurroundPair = labels.contains(kAudioChannelLabel_LeftSurround)
            || labels.contains(kAudioChannelLabel_RightSurround)
        let directIsRear = !hasRearPair && !hasPlainSurroundPair
        let speakers: [NvstSpeaker?] = labels.map { label in
            switch label {
            case kAudioChannelLabel_Left: .frontLeft
            case kAudioChannelLabel_Right: .frontRight
            case kAudioChannelLabel_Center: .frontCenter
            case kAudioChannelLabel_LFEScreen: .lowFrequency
            case kAudioChannelLabel_LeftSurround: hasRearPair ? .sideLeft : .backLeft
            case kAudioChannelLabel_RightSurround: hasRearPair ? .sideRight : .backRight
            case kAudioChannelLabel_RearSurroundLeft: .backLeft
            case kAudioChannelLabel_RearSurroundRight: .backRight
            case kAudioChannelLabel_LeftSurroundDirect: directIsRear ? .backLeft : .sideLeft
            case kAudioChannelLabel_RightSurroundDirect: directIsRear ? .backRight : .sideRight
            default: nil
            }
        }
        guard speakers.contains(.frontLeft), speakers.contains(.frontRight) else {
            return defaultSpeakers(channelCount: channelCount)
        }
        return speakers
    }
}
