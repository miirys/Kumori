import CoreMedia
import Foundation
import LiveKitWebRTC
import OSLog
import VideoToolbox

/// Decodes AV1 with VideoToolbox, on the Apple TV models whose chip decodes AV1 in hardware.
///
/// WebRTC hands over one temporal unit per call: OBUs in the low overhead format, each with
/// its size. That is the sample format VideoToolbox expects, less the temporal delimiters. The
/// decoder is set up from the sequence header, which every key frame carries.
final class AV1Decoder: NSObject, LKRTCVideoDecoder {
    private var callback: ((LKRTCVideoFrame) -> Void)?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sequenceHeader = Data()
    private let lock = NSLock()

    private static let ok = 0
    private static let error = -1
    private static let log = Logger(subsystem: "app.kumori.tv", category: "av1")
    /// How many decode failures have been logged, so a broken stream doesn't flood the log.
    private var failuresLogged = 0
    private var framesOut = 0

    func setCallback(_ callback: @escaping (LKRTCVideoFrame) -> Void) {
        self.callback = callback
    }

    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        Self.ok
    }

    func release() -> Int {
        lock.lock()
        defer { lock.unlock() }
        teardown()
        return Self.ok
    }

    func implementationName() -> String { "VideoToolbox AV1" }

    func decode(_ encodedImage: LKRTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let data = encodedImage.buffer as Data?, !data.isEmpty else { return Self.error }

        let units = OBU.split(data)
        if let header = units.first(where: { $0.type == OBU.sequenceHeader }) {
            let bytes = data.subdata(in: header.range)
            if bytes != sequenceHeader || session == nil {
                guard let seq = SequenceHeader(obu: bytes) else {
                    note("sequence header unreadable (\(bytes.count) bytes)")
                    return Self.error
                }
                teardown()
                guard setup(seq, obu: bytes) else {
                    note("decoder setup failed for \(seq.width)x\(seq.height) profile \(seq.profile) level \(seq.level) \(seq.highBitDepth == 1 ? "10" : "8")-bit")
                    return Self.error
                }
                Self.log.notice("av1 decoder ready: \(seq.width, privacy: .public)x\(seq.height, privacy: .public) profile \(seq.profile, privacy: .public) level \(seq.level, privacy: .public) tier \(seq.tier, privacy: .public) \(seq.highBitDepth == 1 ? "10" : "8", privacy: .public)-bit")
                sequenceHeader = bytes
            }
        }
        // Without a sequence header there is nothing to decode with: ask for a key frame.
        guard let session, let format else {
            note("no sequence header yet; waiting for a key frame")
            return Self.error
        }

        // Temporal delimiters are not part of a sample.
        var sample = Data(capacity: data.count)
        for u in units where u.type != OBU.temporalDelimiter && u.type != OBU.padding {
            sample.append(data.subdata(in: u.range))
        }
        guard !sample.isEmpty, let buffer = Self.sampleBuffer(sample, format: format) else { return Self.error }

        let timeStamp = encodedImage.timeStamp
        let rtpTime = Int32(bitPattern: timeStamp)
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.note("frame not decoded: status \(status)")
                return
            }
            self.framesOut += 1
            if self.framesOut == 1 { Self.log.notice("av1 first frame decoded") }
            let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: image), rotation: ._0, timeStampNs: renderTimeMs * 1_000_000)
            frame.timeStamp = rtpTime
            self.callback?(frame)
        }
        if status == kVTInvalidSessionErr {
            // The session dies when the app goes to the background. Start over at the next key frame.
            teardown()
            return Self.error
        }
        if status != noErr { note("decode call failed: status \(status)") }
        return status == noErr ? Self.ok : Self.error
    }

    /// Logs the first few problems of a stream, publicly, so they show in the TV's syslog.
    private func note(_ text: String) {
        guard failuresLogged < 8 else { return }
        failuresLogged += 1
        Self.log.error("av1: \(text, privacy: .public)")
    }

    private func setup(_ seq: SequenceHeader, obu: Data) -> Bool {
        let first: UInt8 = (seq.profile << 5) | (seq.level & 0x1F)
        var second: UInt8 = (seq.tier << 7) | (seq.highBitDepth << 6)
        second |= (seq.twelveBit << 5) | (seq.monochrome << 4)
        second |= (seq.subsamplingX << 3) | (seq.subsamplingY << 2)
        second |= seq.chromaPosition & 0x3
        var av1C = Data([0x81, first, second, 0])
        av1C.append(obu)
        let atoms: [String: Any] = ["av1C": av1C]
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms,
            kCMFormatDescriptionExtension_FullRangeVideo as String: seq.fullRange,
        ]
        var desc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_AV1,
            width: Int32(seq.width), height: Int32(seq.height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &desc
        ) == noErr, let desc else { return false }

        let pixel = seq.highBitDepth == 1 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixel,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let spec: [String: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true,
        ]
        var made: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: desc,
            decoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &made
        )
        guard status == noErr, let made else { return false }
        VTSessionSetProperty(made, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = made
        format = desc
        return true
    }

    private func teardown() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        sequenceHeader = Data()
    }

    private static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}

/// Splits a temporal unit into its OBUs.
enum OBU {
    static let sequenceHeader: UInt8 = 1
    static let temporalDelimiter: UInt8 = 2
    static let padding: UInt8 = 15

    struct Unit {
        let type: UInt8
        /// The whole OBU, header and size included.
        let range: Range<Int>
        /// Just the payload.
        let payload: Range<Int>
    }

    static func split(_ data: Data) -> [Unit] {
        let bytes = [UInt8](data)
        var out: [Unit] = []
        var i = 0
        while i < bytes.count {
            let start = i
            let header = bytes[i]
            let type = (header >> 3) & 0x0F
            let hasExtension = header & 0x04 != 0
            let hasSize = header & 0x02 != 0
            i += hasExtension ? 2 : 1
            guard i <= bytes.count else { break }
            var size = bytes.count - i
            if hasSize {
                guard let (value, used) = leb128(bytes, i) else { break }
                i += used
                size = value
            }
            guard size >= 0, i + size <= bytes.count else { break }
            out.append(Unit(type: type, range: start..<(i + size), payload: i..<(i + size)))
            i += size
        }
        return out
    }

    static func leb128(_ b: [UInt8], _ at: Int) -> (Int, Int)? {
        var value = 0
        for k in 0..<8 {
            guard at + k < b.count else { return nil }
            let byte = b[at + k]
            value |= Int(byte & 0x7F) << (7 * k)
            if byte & 0x80 == 0 { return (value, k + 1) }
        }
        return nil
    }
}

/// The parts of an AV1 sequence header that the av1C box and the decoder need.
struct SequenceHeader {
    var profile: UInt8 = 0
    var level: UInt8 = 0
    var tier: UInt8 = 0
    var highBitDepth: UInt8 = 0
    var twelveBit: UInt8 = 0
    var monochrome: UInt8 = 0
    var subsamplingX: UInt8 = 1
    var subsamplingY: UInt8 = 1
    var chromaPosition: UInt8 = 0
    var fullRange = false
    var width = 0
    var height = 0

    init?(obu: Data) {
        guard let unit = OBU.split(obu).first, unit.type == OBU.sequenceHeader else { return nil }
        var r = BitReader([UInt8](obu.subdata(in: unit.payload)))
        profile = UInt8(r.bits(3))
        _ = r.bit() // still_picture
        let reduced = r.bit() == 1
        var decoderModel = false
        var bufferDelayLength = 0
        if reduced {
            level = UInt8(r.bits(5))
        } else {
            if r.bit() == 1 { // timing_info_present_flag
                _ = r.bits(32)
                _ = r.bits(32)
                if r.bit() == 1 { _ = r.uvlc() }
                decoderModel = r.bit() == 1
                if decoderModel {
                    bufferDelayLength = r.bits(5) + 1
                    _ = r.bits(32)
                    _ = r.bits(5)
                    _ = r.bits(5)
                }
            }
            let initialDisplayDelay = r.bit() == 1
            let points = r.bits(5) + 1
            for i in 0..<points {
                _ = r.bits(12)
                let lvl = r.bits(5)
                let t = lvl > 7 ? r.bit() : 0
                if i == 0 {
                    level = UInt8(lvl)
                    tier = UInt8(t)
                }
                if decoderModel, r.bit() == 1 {
                    _ = r.bits(bufferDelayLength)
                    _ = r.bits(bufferDelayLength)
                    _ = r.bit()
                }
                if initialDisplayDelay, r.bit() == 1 { _ = r.bits(4) }
            }
        }
        let widthBits = r.bits(4) + 1
        let heightBits = r.bits(4) + 1
        width = r.bits(widthBits) + 1
        height = r.bits(heightBits) + 1
        if !reduced, r.bit() == 1 { // frame_id_numbers_present_flag
            _ = r.bits(4)
            _ = r.bits(3)
        }
        _ = r.bits(3) // 128x128 superblocks, filter intra, intra edge filter
        if !reduced {
            _ = r.bits(4) // interintra, masked compound, warped motion, dual filter
            let orderHint = r.bit() == 1
            if orderHint { _ = r.bits(2) }
            var forceScreenContent = 2
            if r.bit() == 0 { forceScreenContent = r.bit() }
            if forceScreenContent > 0, r.bit() == 0 { _ = r.bit() }
            if orderHint { _ = r.bits(3) }
        }
        _ = r.bits(3) // superres, cdef, restoration
        // color_config()
        highBitDepth = UInt8(r.bit())
        if profile == 2, highBitDepth == 1 { twelveBit = UInt8(r.bit()) }
        monochrome = profile == 1 ? 0 : UInt8(r.bit())
        var primaries = 2, transfer = 2, matrix = 2
        if r.bit() == 1 {
            primaries = r.bits(8)
            transfer = r.bits(8)
            matrix = r.bits(8)
        }
        if monochrome == 1 {
            fullRange = r.bit() == 1
            subsamplingX = 1
            subsamplingY = 1
        } else if primaries == 1, transfer == 13, matrix == 0 {
            fullRange = true
            subsamplingX = 0
            subsamplingY = 0
        } else {
            fullRange = r.bit() == 1
            switch profile {
            case 0:
                subsamplingX = 1
                subsamplingY = 1
            case 1:
                subsamplingX = 0
                subsamplingY = 0
            default:
                if twelveBit == 1 {
                    subsamplingX = UInt8(r.bit())
                    subsamplingY = subsamplingX == 1 ? UInt8(r.bit()) : 0
                } else {
                    subsamplingX = 1
                    subsamplingY = 0
                }
            }
            if subsamplingX == 1, subsamplingY == 1 { chromaPosition = UInt8(r.bits(2)) }
        }
        guard !r.overrun, width > 0, height > 0 else { return nil }
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var position = 0
    private(set) var overrun = false

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func bit() -> Int {
        let index = position >> 3
        guard index < bytes.count else {
            overrun = true
            return 0
        }
        let value = (bytes[index] >> (7 - UInt8(position & 7))) & 1
        position += 1
        return Int(value)
    }

    mutating func bits(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n { v = (v << 1) | bit() }
        return v
    }

    mutating func uvlc() -> Int {
        var zeros = 0
        while bit() == 0 {
            zeros += 1
            if zeros >= 32 || overrun { return 0 }
        }
        return zeros == 0 ? 0 : bits(zeros) + (1 << zeros) - 1
    }
}
