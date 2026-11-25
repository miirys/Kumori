import AVFoundation
import CoreMedia
import CoreVideo
import LiveKitWebRTC
import os
import UIKit

/// Puts the stream's frames on screen through AVSampleBufferDisplayLayer, the layer Apple's
/// own players draw video with on the Apple TV.
///
/// On build 444ce95 the 4K launch decoded video: its stats gave the decoded size, 1920 × 1080,
/// and it went live. The screen stayed black. So the frames got as far as WebRTC's Metal
/// view and no further. That view draws only 8-bit NV12, BGRA and I420
/// frames, compiles its shaders on the device, and skips a frame it can't draw without a
/// word. This layer takes whatever VideoToolbox decodes, in any bit depth or range, and a
/// frame in WebRTC's own memory is copied into a buffer it can show.
final class PictureView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    /// What the stream's video track draws into. Frames arrive on WebRTC's own threads, so
    /// this is a plain object, not the view.
    let feed: PictureFeed

    override init(frame: CGRect) {
        feed = PictureFeed()
        super.init(frame: frame)
        backgroundColor = .black
        let own = layer as! AVSampleBufferDisplayLayer
        own.videoGravity = .resizeAspect
        own.backgroundColor = UIColor.black.cgColor
        feed.screen = own.sampleBufferRenderer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Turns WebRTC frames into sample buffers for a `PictureView`'s layer.
final class PictureFeed: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    /// Called on the main thread, once per track, when the first frame goes to the screen.
    var onFirst: (() -> Void)?

    /// The view's layer's renderer, which may be used from any thread.
    fileprivate var screen: AVSampleBufferVideoRenderer?
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var shown = false
    private var reportedFailure = false

    // What really reached the screen, for the stats overlay. Counted here, at the last step,
    // so the overlay's frame rate is the rate on screen, not the decoder's or the rig's.
    private let countLock = NSLock()
    private var presentedCount: UInt64 = 0
    private var droppedCount: UInt64 = 0

    /// Frames handed to the screen, and frames thrown away on this Apple TV because the
    /// screen was busy or a newer frame arrived in the same refresh. Totals since `reset()`.
    func counters() -> (presented: UInt64, dropped: UInt64) {
        countLock.lock()
        defer { countLock.unlock() }
        return (presentedCount, droppedCount)
    }

    private func count(presented: UInt64 = 0, dropped: UInt64 = 0) {
        countLock.lock()
        presentedCount &+= presented
        droppedCount &+= dropped
        countLock.unlock()
    }

    private static let logger = Logger(subsystem: "app.kumori.tv", category: "picture")

    // Pacing for the native stream. On 7a1adc8 (4K60 AV1) the rig's frames came in bursts:
    // 26 to 104 a second, about 51 on average. The display took ~310 every 6 s and showed
    // ~280: a frame that arrives in the same refresh as the one before replaces it, so it is
    // never seen, and the picture jumps. Frames are handed over on the display's own beat
    // instead, at most one per refresh, from a display link on a thread of its own (so busy
    // screens on the main thread can't hold it up). A burst is held back by up to two
    // refreshes; older frames are dropped beyond that, so the delay never builds up.
    private let paceLock = NSLock()
    private var waiting: [CVPixelBuffer] = []
    private var ticker: Thread?
    /// One refresh, in nanoseconds, for the stream's rate. The beat itself is the display's,
    /// but the display link is asked for this rate: a link left at the system's default rate
    /// is free to tick slower than the HDMI mode, and every tick it skips is a frame dropped
    /// from the two-deep queue below (a 120 fps stream shown at 60-100).
    var refreshNanos: UInt64 = 16_666_667

    /// Shows a native frame on the next refresh (see the note above).
    func showPaced(_ pixels: CVPixelBuffer) {
        paceLock.lock()
        waiting.append(pixels)
        if waiting.count > 2 {
            count(dropped: UInt64(waiting.count - 2))
            waiting.removeFirst(waiting.count - 2)
        }
        var started: Thread?
        if ticker == nil {
            let rate = Int((1_000_000_000 / Double(max(1, refreshNanos))).rounded())
            started = Self.makeTicker(TickProxy(self), rate: rate)
            ticker = started
        }
        paceLock.unlock()
        started?.start()
    }

    /// Once a refresh, on the ticker thread.
    fileprivate func tick() {
        paceLock.lock()
        let next = waiting.isEmpty ? nil : waiting.removeFirst()
        paceLock.unlock()
        if let next { show(next) }
    }

    /// Stops the beat and forgets the frames held back.
    func stopPacing() {
        paceLock.lock()
        ticker?.cancel()
        ticker = nil
        waiting.removeAll()
        paceLock.unlock()
    }

    private static func makeTicker(_ proxy: TickProxy, rate: Int) -> Thread {
        let t = Thread {
            let link = CADisplayLink(target: proxy, selector: #selector(TickProxy.tick(_:)))
            let wanted = Float(min(max(rate, 24), 240))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: wanted, maximum: wanted, preferred: wanted)
            link.add(to: .current, forMode: .default)
            while !Thread.current.isCancelled {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
            }
            link.invalidate()
        }
        t.name = "app.kumori.picture.pacer"
        t.qualityOfService = .userInteractive
        return t
    }

    deinit {
        ticker?.cancel()
    }

    /// A new track is about to start: forget the last one's picture.
    func reset() {
        stopPacing()
        lock.lock()
        shown = false
        format = nil
        reportedFailure = false
        lock.unlock()
        countLock.lock()
        presentedCount = 0
        droppedCount = 0
        countLock.unlock()
        screen?.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame, frame.width > 0, frame.height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let r = screen, let pixels = pixelBuffer(frame), let sample = sampleBuffer(pixels) else { return }
        if r.status == .failed || r.requiresFlushToResumeDecoding {
            if r.status == .failed, !reportedFailure {
                reportedFailure = true
                let e = r.error as NSError?
                Self.logger.notice("picture renderer failed: \(e?.domain ?? "-", privacy: .public) \(e?.code ?? 0, privacy: .public), flushing")
            }
            r.flush()
        }
        // A live stream never waits: if the screen is still busy, this frame is dropped.
        guard r.isReadyForMoreMediaData else { count(dropped: 1); return }
        r.enqueue(sample)
        count(presented: 1)
        if !shown {
            shown = true
            let fmt = CVPixelBufferGetPixelFormatType(pixels)
            Self.logger.notice("picture first frame \(CVPixelBufferGetWidth(pixels), privacy: .public)x\(CVPixelBufferGetHeight(pixels), privacy: .public) format \(Self.fourCC(fmt), privacy: .public) from \((frame.buffer as? LKRTCCVPixelBuffer)?.pixelBuffer === pixels ? "decoder" : "copy", privacy: .public)")
            let first = onFirst
            DispatchQueue.main.async { first?() }
        }
    }

    /// A frame the native NVST receiver decoded. Called on its decode queue.
    func show(_ pixels: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let r = screen, let sample = sampleBuffer(pixels) else { return }
        if r.status == .failed || r.requiresFlushToResumeDecoding {
            if r.status == .failed, !reportedFailure {
                reportedFailure = true
                let e = r.error as NSError?
                Self.logger.notice("picture renderer failed: \(e?.domain ?? "-", privacy: .public) \(e?.code ?? 0, privacy: .public), flushing")
            }
            r.flush()
        }
        guard r.isReadyForMoreMediaData else { count(dropped: 1); return }
        r.enqueue(sample)
        count(presented: 1)
        if !shown {
            shown = true
            let fmt = CVPixelBufferGetPixelFormatType(pixels)
            Self.logger.notice("picture first frame \(CVPixelBufferGetWidth(pixels), privacy: .public)x\(CVPixelBufferGetHeight(pixels), privacy: .public) format \(Self.fourCC(fmt), privacy: .public) from native")
            let first = onFirst
            DispatchQueue.main.async { first?() }
        }
    }

    // MARK: Frames

    /// The frame as a pixel buffer the layer can show at the frame's own size.
    private func pixelBuffer(_ frame: LKRTCVideoFrame) -> CVPixelBuffer? {
        if let cv = frame.buffer as? LKRTCCVPixelBuffer {
            let pb = cv.pixelBuffer
            // Uncropped and unscaled, which is what the hardware decoders hand over: show it as is.
            if Int(cv.width) == CVPixelBufferGetWidth(pb), Int(cv.height) == CVPixelBufferGetHeight(pb) { return pb }
        }
        return copy(frame.buffer.toI420())
    }

    /// Copies a planar frame into an NV12 buffer from a pool, so the layer can show it.
    private func copy(_ i420: LKRTCI420BufferProtocol) -> CVPixelBuffer? {
        let w = Int(i420.width), h = Int(i420.height)
        guard w > 0, h > 0 else { return nil }
        if pool == nil || poolWidth != w || poolHeight != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
            pool = p
            poolWidth = w
            poolHeight = h
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let yDst = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvDst = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let sy = Int(i420.strideY), su = Int(i420.strideU), sv = Int(i420.strideV)
        for row in 0..<h {
            (yDst + row * yStride).update(from: i420.dataY + row * sy, count: w)
        }
        let cw = Int(i420.chromaWidth), ch = Int(i420.chromaHeight)
        for row in 0..<ch {
            let u = i420.dataU + row * su
            let v = i420.dataV + row * sv
            let d = uvDst + row * uvStride
            for x in 0..<cw {
                d[2 * x] = u[x]
                d[2 * x + 1] = v[x]
            }
        }
        return pb
    }

    /// Wraps a picture for the layer, to be shown as soon as it arrives.
    private func sampleBuffer(_ pb: CVPixelBuffer) -> CMSampleBuffer? {
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: pb) {
            var f: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &f)
            format = f
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &out) == noErr, let sample = out else { return nil }
        if let list = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(list) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(list, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// A pixel format as its four letters, such as 420v or x420.
    private static func fourCC(_ t: OSType) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((t >> $0) & 0xFF))) }
        return chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") } ? String(chars) : String(t)
    }
}

/// The display link's target, holding the feed weakly so a running beat never keeps it alive.
private final class TickProxy: NSObject {
    private weak var feed: PictureFeed?

    init(_ feed: PictureFeed) {
        self.feed = feed
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let feed else {
            link.invalidate()
            Thread.current.cancel()
            return
        }
        feed.tick()
    }
}
