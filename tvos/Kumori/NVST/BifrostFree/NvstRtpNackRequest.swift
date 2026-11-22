import Foundation

/// Control command `0x317`: the video packets the client wants the seat to send again.
///
/// Read from the official client (`libBifrost2`, 2.0.90.126) by disassembly, not from a wire
/// capture. `NvscClientPipeline::createAndSendNackRequest` builds the payload with
/// `RtpSourceQueueExtV2::createNackRequest` and hands it to `ServerControl::sendRtpNackRequest`,
/// which sends command `0x317` on the channel created as `control_channel_partially_reliable`.
/// The payload is not an RTCP packet:
///
///     +0  u16 LE  version, 2 (`video.rtpNackVersion`, which this client announces)
///     +2  u8      entry count, at most 64
///     +3  entries, 10 bytes each:
///           u16 LE  RTP sequence number of the first missing packet
///           u64 LE  bit n set = packet (first + n + 1) is missing too
///
/// The RFC 4585 Generic NACK this client used to send over SRTCP is a different message, and it
/// went out only after the gap had already been given up.
public struct NvstRtpNackRequest: Equatable, Sendable {
    public static let commandCode = NvstControlCommandCode.rtpNackRequest
    public static let version: UInt16 = 2
    /// The official client looks at no more than this many missing packets per request.
    public static let maximumPackets = 64

    public struct Entry: Equatable, Sendable {
        public let first: UInt16
        public let following: UInt64
    }

    public let entries: [Entry]

    /// `missing` in sequence order. Packets past `maximumPackets` are left for the next request.
    public init?(missing: [UInt16]) {
        guard !missing.isEmpty else { return nil }
        var entries: [Entry] = []
        var index = 0
        let end = min(missing.count, Self.maximumPackets)
        while index < end {
            let first = missing[index]
            var following: UInt64 = 0
            index += 1
            while index < end {
                // Distance in 16-bit sequence space, so a run that crosses 0xffff stays one entry.
                let distance = missing[index] &- first
                guard distance >= 1, distance <= 64 else { break }
                following |= 1 << UInt64(distance - 1)
                index += 1
            }
            entries.append(Entry(first: first, following: following))
        }
        self.entries = entries
    }

    public var command: NvstControlCommand {
        var writer = NvstByteWriter(capacity: 3 + entries.count * 10)
        writer.u16LE(Self.version)
        writer.u8(UInt8(entries.count))
        for entry in entries {
            writer.u16LE(entry.first)
            writer.u64LE(entry.following)
        }
        return NvstControlCommand(code: Self.commandCode, payload: writer.data)
    }
}
