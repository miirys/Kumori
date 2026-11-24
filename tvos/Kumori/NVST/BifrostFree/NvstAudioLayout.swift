import Foundation

/// A speaker position.
public enum NvstSpeaker: Hashable, Sendable {
    case frontLeft, frontRight, frontCenter, lowFrequency, backLeft, backRight, sideLeft, sideRight
}

/// The channel layout of the seat's game audio: one Opus multistream configuration, and the
/// speaker each decoded channel belongs to.
///
/// The seat lists one configuration per channel count in its DESCRIBE answer
/// (`nv-audio-surround-opus-params`, read by `seatLayouts(describe:)`) and sends the requested one
/// from its first audio packet; `libBifrost2.dylib` reads the same line ("Got the right opus info
/// from server"). Its `0x0408` message (`NvstAudioSurroundInfo`) can change it later. The two
/// surround layouts below are the official client's own, from the strings in `libBifrost2.dylib`:
/// `channel_mapping=0,4,1,5,2,3;num_streams=4;coupled_streams=2` and
/// `channel_mapping=0,6,1,7,2,3,4,5;num_streams=5;coupled_streams=3`.
public struct NvstAudioLayout: Equatable, Sendable {
    public let channels: Int
    public let streams: Int
    public let coupledStreams: Int
    /// For each decoded channel, the coded channel it is read from (RFC 7845 section 5.1.1).
    public let mapping: [UInt8]

    public static let stereo = NvstAudioLayout(unchecked: 2, streams: 1, coupledStreams: 1, mapping: [0, 1])
    public static let surround51 = NvstAudioLayout(unchecked: 6, streams: 4, coupledStreams: 2, mapping: [0, 4, 1, 5, 2, 3])
    public static let surround71 = NvstAudioLayout(unchecked: 8, streams: 5, coupledStreams: 3,
                                                   mapping: [0, 6, 1, 7, 2, 3, 4, 5])

    /// The official layout for a channel count, nil for a count the seat does not offer.
    public static func official(channels: Int) -> NvstAudioLayout? {
        switch channels {
        case 2: .stereo
        case 6: .surround51
        case 8: .surround71
        default: nil
        }
    }

    private init(unchecked channels: Int, streams: Int, coupledStreams: Int, mapping: [UInt8]) {
        self.channels = channels
        self.streams = streams
        self.coupledStreams = coupledStreams
        self.mapping = mapping
    }

    /// Nil unless the numbers describe a stream the decoder can be set up for: 6 or 8 channels,
    /// one mapping entry per channel, every entry naming a coded channel, and the coded channels
    /// (one per stream plus one per coupled stream) adding up to the channel count.
    public init?(channels: Int, streams: Int, coupledStreams: Int, mapping: [UInt8]) {
        guard channels == 6 || channels == 8, streams >= 1, coupledStreams >= 0, coupledStreams <= streams,
              streams + coupledStreams == channels, mapping.count == channels,
              mapping.allSatisfy({ Int($0) < channels }) else { return nil }
        self.init(unchecked: channels, streams: streams, coupledStreams: coupledStreams, mapping: mapping)
    }

    /// The layout the seat announced. Two channels are plain stereo whatever else the message says.
    public init?(_ info: NvstAudioSurroundInfo) {
        if info.channels == 2 {
            self = .stereo
            return
        }
        self.init(channels: Int(info.channels), streams: Int(info.streams),
                  coupledStreams: Int(info.coupledStreams), mapping: info.channelMapping)
    }

    /// The surround layouts a seat's DESCRIBE lists in
    /// `a=nv-audio-surround-opus-params: 64204123500;85306123457;…`: each entry is the channel
    /// count, the stream count and the coupled count, then one mapping digit per channel, padded
    /// with zeroes. Entries that are not a layout this client plays are left out.
    public static func seatLayouts(describe body: String) -> [NvstAudioLayout] {
        let prefix = "a=nv-audio-surround-opus-params:"
        guard let line = body.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix(prefix) }) else { return [] }
        return line.dropFirst(prefix.count).split(separator: ";").compactMap { entry in
            let digits = entry.trimmingCharacters(in: .whitespaces).compactMap(\.wholeNumberValue)
            guard digits.count == entry.trimmingCharacters(in: .whitespaces).count, digits.count >= 3,
                  digits.count >= 3 + digits[0] else { return nil }
            return NvstAudioLayout(channels: digits[0], streams: digits[1], coupledStreams: digits[2],
                                   mapping: digits[3..<(3 + digits[0])].map { UInt8($0) })
        }
    }

    /// The speaker of each coded channel as the seat encodes them. Confirmed against a live 7.1
    /// stream on 2026-11-17: with the seat's own table the decoded order is FL, FR, FC, BL, BR,
    /// SL, SR, LFE (stereo menus only on the first two, the last silent, the side pair moving with
    /// the front pair), and the official client's table turns the same coded channels into the
    /// Windows order of the announce's speaker mask (`0x3F`, `0x63F`). 5.1 follows the same
    /// pattern; it was not measured.
    private static func codedSpeakers(channels: Int) -> [NvstSpeaker] {
        switch channels {
        case 6: [.frontLeft, .frontCenter, .backLeft, .backRight, .frontRight, .lowFrequency]
        case 8: [.frontLeft, .frontCenter, .backLeft, .backRight, .sideLeft, .sideRight, .frontRight, .lowFrequency]
        default: [.frontLeft, .frontRight]
        }
    }

    /// The speaker of each decoded channel: the speaker of the coded channel the table reads it from.
    public var speakers: [NvstSpeaker] {
        let coded = Self.codedSpeakers(channels: channels)
        return mapping.map { coded[Int($0)] }
    }

    public var label: String {
        switch channels {
        case 6: "5.1"
        case 8: "7.1"
        default: "Stereo"
        }
    }

    /// RFC 7845's identification header, which the decoder takes as its magic cookie: magic,
    /// version, channel count, pre-skip, input sample rate, output gain, mapping family. Stereo is
    /// family 0; surround is family 1 followed by the stream count, the coupled count and the table.
    public var opusHeadCookie: Data {
        var writer = NvstByteWriter(capacity: 21 + channels)
        writer.bytes(Data("OpusHead".utf8))
        writer.u8(1)
        writer.u8(UInt8(channels))
        writer.zeroes(2)
        writer.u32LE(48_000)
        writer.zeroes(2)
        guard channels > 2 else {
            writer.u8(0)
            return writer.data
        }
        writer.u8(1)
        writer.u8(UInt8(streams))
        writer.u8(UInt8(coupledStreams))
        writer.bytes(mapping)
        return writer.data
    }
}
