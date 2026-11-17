package app.kumori.tv.stream

import android.media.MediaCodec
import app.kumori.tv.CrashLog
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Process
import android.util.Log
import android.view.Surface
import org.webrtc.EncodedImage
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoCodecInfo
import org.webrtc.VideoCodecStatus
import org.webrtc.VideoDecoder
import org.webrtc.VideoDecoderFactory
import org.webrtc.VideoFrame
import java.util.concurrent.ConcurrentHashMap

/**
 * Where decoded video goes. The stream screen hands us its surface; the decoder renders
 * straight into it, so a frame goes from the network to the panel without a copy or an extra
 * GPU pass, at the stream's full resolution.
 */
object VideoOutput {
    @Volatile var surface: Surface? = null
        set(value) {
            field = value
            generation++
        }

    /** Bumped whenever the surface changes, so the decoder knows to start over. */
    @Volatile var generation = 0
        private set

    /** Asks the server for a fresh key frame (set by the running engine). */
    @Volatile var keyframeRequester: (() -> Unit)? = null

    /** Size and codec of what is on screen, for the stats overlay. */
    @Volatile var width = 0
    @Volatile var height = 0
    @Volatile var decoderName: String? = null

    /** The stream's frame rate, told to the decoder. */
    @Volatile var fps = 0

    /** Frames handed to the panel since the stream began. */
    @Volatile var rendered = 0L

    /** Times the decoder fell behind and a frame had to be dropped. Shown in the stats. */
    @Volatile var stalls = 0

    @Volatile var onFirstFrame: (() -> Unit)? = null

    /**
     * Use WebRTC's own decoder and renderer instead of the direct path. It costs a GPU copy
     * but avoids the low-level decoder features that some TV chips mishandle.
     */
    @Volatile var compatible = false

    /** Where frames go in compatible mode (the stream screen's renderer). */
    @Volatile var renderer: org.webrtc.VideoSink? = null
}

/** Advertises what this device can decode in hardware, with parameters GeForce NOW accepts. */
class TvDecoderFactory : VideoDecoderFactory {

    private val supported: Array<VideoCodecInfo> by lazy {
        val out = ArrayList<VideoCodecInfo>()
        if (find(MIME_HEVC) != null) {
            // Main profile, main tier. Level 5.1 covers 4K at 60 and 1440p at 120; 4K at 120
            // needs 5.2, which is only claimed when the decoder says it keeps up.
            val level = if (Capabilities.codecsFor(3840, 2160, 120).contains("H265")) "156" else "153"
            out += VideoCodecInfo("H265", mapOf("profile-id" to "1", "tier-flag" to "0", "level-id" to level), emptyList())
            // Main 10, for 10-bit colour, only where the decoder has it.
            if (tenBit("H265")) out += VideoCodecInfo("H265", mapOf("profile-id" to "2", "tier-flag" to "0", "level-id" to level), emptyList())
        }
        if (find(MIME_AV1) != null) out += VideoCodecInfo("AV1", mapOf("profile" to "0"), emptyList())
        if (find(MIME_AVC) != null) {
            for (profile in listOf("640c1f", "42e01f")) {
                out += VideoCodecInfo(
                    "H264",
                    mapOf("profile-level-id" to profile, "level-asymmetry-allowed" to "1", "packetization-mode" to "1"),
                    emptyList(),
                )
            }
        }
        out.toTypedArray()
    }

    override fun getSupportedCodecs(): Array<VideoCodecInfo> =
        if (VideoOutput.compatible) stockCodecs.takeIf { it.isNotEmpty() } ?: supported else supported

    override fun createDecoder(info: VideoCodecInfo): VideoDecoder? {
        CrashLog.step("decoder-create")
        if (VideoOutput.compatible) {
            val hw = runCatching { stockHardware.createDecoder(info) }
                .onFailure { Log.w("Decoders", "stock decoder unavailable", it) }.getOrNull()
            // H.264 may fall back to software; HEVC and AV1 only ever use hardware.
            val stock = hw ?: if (info.name.equals("H264", true)) runCatching { stockDefault.createDecoder(info) }.getOrNull() else null
            if (stock != null) {
                VideoOutput.decoderName = stock.implementationName
                // Hand WebRTC its own decoder object, untouched. Wrapping it in a class of ours
                // crashed natively on the first box this ran on as the video started.
                return stock
            }
            // The direct decoder draws into a surface the compatible screen doesn't have, so
            // it would only ever show black here. Better to fail and say so.
            Log.w("Decoders", "no stock decoder for ${info.name} on the compatible path")
            return null
        }
        val mime = mimeOf(info.name) ?: return null
        val codec = find(mime) ?: return null
        return DirectDecoder(mime, codec.name)
    }

    companion object {
        const val MIME_AVC = "video/avc"
        const val MIME_HEVC = "video/hevc"
        const val MIME_AV1 = "video/av01"

        fun mimeOf(name: String) = when (name.uppercase()) {
            "H264" -> MIME_AVC
            "H265", "HEVC" -> MIME_HEVC
            "AV1" -> MIME_AV1
            else -> null
        }

        /** WebRTC's own factories, sharing the renderer's GL context. */
        private val stockHardware by lazy { org.webrtc.HardwareVideoDecoderFactory(Rtc.egl.eglBaseContext) }
        private val stockDefault by lazy { org.webrtc.DefaultVideoDecoderFactory(Rtc.egl.eglBaseContext) }

        /**
         * On the standard path, WebRTC's own codec list: its usual codecs plus the hardware
         * HEVC and AV1 decoders, with the parameters WebRTC itself generates for them.
         */
        private val stockCodecs: Array<VideoCodecInfo> by lazy {
            val advanced = setOf("H265", "AV1")
            val base = runCatching { stockDefault.supportedCodecs.filter { it.name.uppercase() !in advanced } }.getOrDefault(emptyList())
            val hw = runCatching { stockHardware.supportedCodecs.filter { it.name.uppercase() in advanced } }.getOrDefault(emptyList())
            (base + hw).distinctBy { "${it.name.uppercase()}:${it.params.toSortedMap()}" }.toTypedArray()
        }

        /**
         * Whether the factory will really advertise [name] ("H265", "AV1", "H264") on the
         * video path in use. The codec kept in the rig's offer has to come from this list, or
         * the answer has no video codec in common.
         */
        fun advertises(name: String): Boolean {
            val n = name.uppercase()
            if (VideoOutput.compatible && stockCodecs.isNotEmpty()) return stockCodecs.any { it.name.uppercase() == n }
            return mimeOf(n)?.let { find(it) } != null
        }

        /** Whether the hardware decoder for [name] shows 10-bit video. "AUTO" asks about HEVC and AV1. */
        fun tenBit(name: String): Boolean = when (name.uppercase()) {
            "AUTO" -> tenBit("H265") || tenBit("AV1")
            "H265", "HEVC" -> hasProfile(MIME_HEVC, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10)
            "AV1" -> Build.VERSION.SDK_INT >= 29 &&
                hasProfile(MIME_AV1, MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10, MediaCodecInfo.CodecProfileLevel.AV1ProfileMain10HDR10)
            else -> false
        }

        private fun hasProfile(mime: String, vararg profiles: Int): Boolean = runCatching {
            find(mime)?.getCapabilitiesForType(mime)?.profileLevels?.any { it.profile in profiles } == true
        }.getOrDefault(false)

        private val cache = ConcurrentHashMap<String, Found>()

        private class Found(val info: MediaCodecInfo?)

        /** The best hardware decoder for [mime], skipping software and secure-only ones. */
        fun find(mime: String): MediaCodecInfo? = cache.getOrPut(mime) {
            val all = runCatching { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos }.getOrDefault(emptyArray())
            val candidates = all.filter { info ->
                !info.isEncoder && info.supportedTypes.any { it.equals(mime, ignoreCase = true) } &&
                    !info.name.endsWith(".secure") && isHardware(info) && plain(info, mime)
            }
            Found(candidates.firstOrNull())
        }.info

        /** Not a variant that only runs tunneled or with protected content; those can't be set up for a plain surface. */
        private fun plain(info: MediaCodecInfo, mime: String): Boolean = runCatching {
            val type = info.supportedTypes.first { it.equals(mime, ignoreCase = true) }
            val caps = info.getCapabilitiesForType(type)
            !caps.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback) &&
                !caps.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback)
        }.getOrDefault(true)

        private fun isHardware(info: MediaCodecInfo): Boolean {
            if (Build.VERSION.SDK_INT >= 29) return info.isHardwareAccelerated && !info.isSoftwareOnly
            val n = info.name.lowercase()
            return !(n.startsWith("omx.google.") || n.startsWith("c2.android.") || n.startsWith("omx.ffmpeg.") || n.contains("sw"))
        }

        /**
         * Amlogic boxes decode onto a hardware video layer under the interface. Their decoders
         * want the real picture size, the key-frame flag on key frames, and the vendor
         * low-latency switch, or they hold several frames back.
         */
        fun isRealtek(decoder: String) = "realtek" in decoder || ".rtk" in decoder

        /**
         * Realtek boxes (Zidoo and others). Matching is on the decoder's name, which names the
         * chip family. The direct output is the less proven path there, so it is used last.
         */
        val realtek: Boolean by lazy {
            listOf(MIME_HEVC, MIME_AVC, MIME_AV1).any { m -> find(m)?.name?.lowercase()?.let(::isRealtek) == true }
        }

        val amlogic: Boolean by lazy {
            Build.HARDWARE.contains("amlogic", ignoreCase = true) ||
                listOf(MIME_HEVC, MIME_AVC).any { find(it)?.name?.contains("amlogic", ignoreCase = true) == true }
        }

        /** The highest bitrate, in kbps, the hardware decoder for [codec] says it takes. Null if it doesn't say. */
        fun maxKbps(codec: String): Int? {
            val mime = mimeOf(codec) ?: return null
            val v = runCatching { find(mime)?.getCapabilitiesForType(mime)?.videoCapabilities }.getOrNull() ?: return null
            return runCatching { v.bitrateRange.upper / 1000 }.getOrNull()?.takeIf { it > 0 }
        }

        /** Short, readable decoder description for the stats overlay. */
        fun describe(mime: String): String? = find(mime)?.name
    }
}

/**
 * A WebRTC video decoder backed by MediaCodec in low-latency mode, rendering directly to
 * [VideoOutput.surface]. WebRTC still gets a (tiny) frame per decoded picture so its timing
 * and statistics keep working.
 */
class DirectDecoder(private val mime: String, private val codecName: String) : VideoDecoder {

    private var callback: VideoDecoder.Callback? = null
    @Volatile private var codec: MediaCodec? = null
    private var configuredGeneration = -1
    private var needKeyframe = true
    private var width = 1920
    private var height = 1080
    @Volatile private var running = false
    private var output: Thread? = null

    /**
     * Set by the output thread when it stops on its own while the codec is still in use. The
     * codec then shows nothing more, so the next decode call replaces it.
     */
    @Volatile private var outputFailed = false

    /** presentation time (µs) -> when decoding started (ns) and the frame's capture time (ns). */
    private val pending = ConcurrentHashMap<Long, LongArray>()
    private var lastPts = 0L
    private var lastAsk = 0L

    /** Room for one compressed frame. Grows if a frame ever turns out larger. */
    private var inputSize = 0

    // WebRTC wants a frame object back; one tiny shared buffer serves every frame.
    private val stub: JavaI420Buffer = JavaI420Buffer.allocate(2, 2)

    // Every parameter WebRTC's native side passes can be null (it always passes a null
    // DecodeInfo), and a Kotlin non-null parameter throws on entry, before any try block. An
    // exception thrown inside a native call aborts the process: that was the "crash as the
    // video starts" on this path, on every codec. So these stay nullable.
    override fun initDecode(settings: VideoDecoder.Settings?, callback: VideoDecoder.Callback?): VideoCodecStatus = try {
        Log.i(TAG, "init $codecName ${settings?.width}x${settings?.height}")
        CrashLog.step("decoder-init")
        this.callback = callback
        if (settings != null && settings.width > 0 && settings.height > 0) {
            width = settings.width
            height = settings.height
        }
        VideoCodecStatus.OK
    } catch (t: Throwable) {
        Log.w(TAG, "init crashed", t)
        VideoCodecStatus.ERROR
    }

    override fun getImplementationName(): String = codecName

    override fun decode(frame: EncodedImage?, info: VideoDecoder.DecodeInfo?): VideoCodecStatus = try {
        if (frame == null) VideoCodecStatus.NO_OUTPUT else decodeFrame(frame)
    } catch (t: Throwable) {
        // This runs inside a native call; an exception escaping here aborts the process.
        Log.w(TAG, "decode crashed", t)
        runCatching { teardown() }
        needKeyframe = true
        VideoCodecStatus.ERROR
    }

    private fun decodeFrame(frame: EncodedImage): VideoCodecStatus {
        CrashLog.step("decoding")
        val surface = VideoOutput.surface
        if (surface == null || !surface.isValid) {
            teardown()
            needKeyframe = true
            return VideoCodecStatus.NO_OUTPUT
        }
        if (frame.encodedWidth > 0 && frame.encodedHeight > 0) {
            width = frame.encodedWidth
            height = frame.encodedHeight
        }
        val key = frame.frameType == EncodedImage.FrameType.VideoFrameKey
        if (outputFailed) {
            // The output thread died, so this codec would take input and never show it.
            outputFailed = false
            teardown()
            needKeyframe = true
        }
        if (codec == null || configuredGeneration != VideoOutput.generation) {
            teardown()
            needKeyframe = true
            // Start the decoder on a key frame, so it is set up for the stream's real size.
            if (!key) {
                askKeyframe()
                return VideoCodecStatus.NO_OUTPUT
            }
            if (!configure(surface)) return VideoCodecStatus.ERROR
        }
        if (needKeyframe) {
            if (!key) {
                askKeyframe()
                return VideoCodecStatus.NO_OUTPUT
            }
            needKeyframe = false
        }
        val c = codec ?: return VideoCodecStatus.ERROR
        return try {
            val index = c.dequeueInputBuffer(INPUT_TIMEOUT_US)
            if (index < 0) {
                // The decoder is backed up; skip and ask for a clean restart point.
                needKeyframe = true
                VideoOutput.stalls++
                askKeyframe()
                return VideoCodecStatus.NO_OUTPUT
            }
            val buf = c.getInputBuffer(index) ?: return VideoCodecStatus.ERROR
            val data = frame.buffer
            val size = data.remaining()
            if (size > buf.capacity()) {
                // Too big for the decoder's buffer. Start it again with room for this frame;
                // an error here would make WebRTC give up on the decoder altogether.
                Log.w(TAG, "frame of $size bytes doesn't fit ${buf.capacity()}")
                c.queueInputBuffer(index, 0, 0, 0, 0)
                inputSize = maxOf(inputSize, size * 2)
                VideoOutput.stalls++
                teardown()
                needKeyframe = true
                askKeyframe()
                return VideoCodecStatus.NO_OUTPUT
            }
            buf.clear()
            buf.put(data)
            // Presentation times must be unique and rising; the capture time nearly always is.
            var pts = frame.captureTimeNs / 1000
            if (pts <= lastPts) pts = lastPts + 1
            lastPts = pts
            pending[pts] = longArrayOf(System.nanoTime(), frame.captureTimeNs)
            if (pending.size > 64) pending.keys.sorted().take(pending.size - 32).forEach { pending.remove(it) }
            c.queueInputBuffer(index, 0, size, pts, if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            VideoCodecStatus.OK
        } catch (t: Throwable) {
            Log.w(TAG, "decode failed", t)
            teardown()
            needKeyframe = true
            VideoCodecStatus.ERROR
        }
    }

    /**
     * Asks the server for a key frame, at most a few times a second. Every frame that arrives
     * while waiting for one would otherwise ask again, and each answer is a large frame that
     * sets the decoder back further.
     */
    private fun askKeyframe() {
        val now = System.nanoTime()
        if (now - lastAsk < KEYFRAME_SPACING_NS) return
        lastAsk = now
        runCatching { VideoOutput.keyframeRequester?.invoke() }
    }

    private fun configure(surface: Surface): Boolean {
        var created: MediaCodec? = null
        return try {
            val c = MediaCodec.createByCodecName(codecName)
            created = c
            configure(c, surface)
            true
        } catch (t: Throwable) {
            Log.e(TAG, "could not start $codecName", t)
            // Give the hardware decoder back. This is retried on every key frame, and a TV
            // chip only has a few decoders to hand out.
            runCatching { created?.release() }
            running = false
            codec = null
            false
        }
    }

    private fun configure(c: MediaCodec, surface: Surface) {
        val caps = runCatching { c.codecInfo.getCapabilitiesForType(mime) }.getOrNull()
        fun format(fast: Boolean) = MediaFormat.createVideoFormat(mime, width, height).apply {
            if (caps?.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_AdaptivePlayback) == true) {
                setInteger(MediaFormat.KEY_MAX_WIDTH, maxOf(width, 3840))
                setInteger(MediaFormat.KEY_MAX_HEIGHT, maxOf(height, 2160))
            }
            // Room for the largest frame the stream can send. HEVC has no quality ceiling on
            // GeForce NOW, so its key frames are far larger than AV1's, and a decoder's default
            // buffer for 1080p doesn't hold a 4K one.
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(inputSize, width * height * 3 / 4, 2 shl 20))
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            if (fast && VideoOutput.fps >= 60) setInteger(MediaFormat.KEY_FRAME_RATE, VideoOutput.fps)
            val n = codecName.lowercase()
            // Realtek's decoders are the ones whose low-latency mode is unreliable, so they
            // run in their normal mode.
            if (!TvDecoderFactory.isRealtek(n) && Build.VERSION.SDK_INT >= 30 && caps?.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency) == true) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            // Vendor switches that stop decoders from holding frames back, only for the vendors
            // whose decoders are known to handle them well.
            if ("qti" in n || "qcom" in n) setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            if ("amlogic" in n) setInteger("vendor.low-latency.enable", 1)
            if ("mtk" in n || "mediatek" in n) setInteger("vdec-lowlatency", 1)
            if ("exynos" in n) setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)
            if ("hisi" in n) {
                setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req", 1)
                setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-rdy", -1)
            }
            // Decode as fast as frames arrive rather than at a playback pace.
            if (fast) setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
        }
        try {
            c.configure(format(fast = true), surface, null, 0)
        } catch (t: Throwable) {
            // Some decoders reject the operating-rate hint; try once without it.
            Log.w(TAG, "configure with operating rate failed", t)
            c.reset()
            c.configure(format(fast = false), surface, null, 0)
        }
        c.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
        c.start()
        codec = c
        configuredGeneration = VideoOutput.generation
        VideoOutput.decoderName = codecName
        running = true
        outputFailed = false
        output = Thread({ drain(c) }, "video-out").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    private fun drain(c: MediaCodec) {
        runCatching { Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY) }
        try {
            drainLoop(c)
        } catch (t: Throwable) {
            // Never let the output thread take the app down.
            Log.w(TAG, "output thread stopped", t)
        } finally {
            // Left while the codec is still meant to run: have the next decode call replace
            // the codec and wait for a key frame, which also restarts this thread.
            if (running && codec === c) {
                outputFailed = true
                askKeyframe()
            }
        }
    }

    private fun drainLoop(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var first = true
        while (running && codec === c) {
            val index = try {
                c.dequeueOutputBuffer(info, OUTPUT_TIMEOUT_US)
            } catch (t: Throwable) {
                Log.w(TAG, "dequeueOutputBuffer failed", t)
                break
            }
            when {
                index >= 0 -> {
                    // "Wait for the screen" queues every picture for a refresh of its own.
                    // "Fastest" stamps it with the current time instead: if a newer picture
                    // is ready before the next refresh, the screen takes the newer one and
                    // the decoder never waits.
                    runCatching {
                        if (VideoHooks.swapInterval == 0) c.releaseOutputBuffer(index, System.nanoTime())
                        else c.releaseOutputBuffer(index, true)
                    }
                    VideoOutput.rendered++
                    if (first) {
                        first = false
                        CrashLog.step("video")
                        runCatching { VideoOutput.onFirstFrame?.invoke() }
                    }
                    val times = pending.remove(info.presentationTimeUs)
                    val decodeMs = times?.let { ((System.nanoTime() - it[0]) / 1_000_000).toInt() }
                    val captureNs = times?.get(1) ?: (info.presentationTimeUs * 1000)
                    stub.retain()
                    val f = VideoFrame(stub, 0, captureNs)
                    runCatching { callback?.onDecodedFrame(f, decodeMs, null) }
                    f.release()
                }
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> runCatching {
                    val fmt = c.outputFormat
                    val w = if (fmt.containsKey("crop-right")) fmt.getInteger("crop-right") - fmt.getInteger("crop-left") + 1 else fmt.getInteger(MediaFormat.KEY_WIDTH)
                    val h = if (fmt.containsKey("crop-bottom")) fmt.getInteger("crop-bottom") - fmt.getInteger("crop-top") + 1 else fmt.getInteger(MediaFormat.KEY_HEIGHT)
                    VideoOutput.width = w
                    VideoOutput.height = h
                }
            }
        }
    }

    private fun teardown() {
        running = false
        val c = codec ?: return
        codec = null
        output?.let { t ->
            runCatching { t.join(200) }
        }
        output = null
        runCatching { c.stop() }
        runCatching { c.release() }
        pending.clear()
    }

    override fun release(): VideoCodecStatus {
        runCatching { teardown() }
        callback = null
        return VideoCodecStatus.OK
    }

    companion object {
        private const val TAG = "DirectDecoder"
        // Long enough to ride out one slow frame without dropping it. A dropped frame costs
        // a key frame, which is the most expensive thing the stream can send.
        private const val INPUT_TIMEOUT_US = 80_000L
        private const val KEYFRAME_SPACING_NS = 400_000_000L
        private const val OUTPUT_TIMEOUT_US = 20_000L
    }
}
