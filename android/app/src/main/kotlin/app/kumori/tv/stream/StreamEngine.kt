package app.kumori.tv.stream

import android.content.Context
import android.media.AudioAttributes
import android.os.SystemClock
import android.util.Log
import app.kumori.tv.CrashLog
import app.kumori.tv.data.CloudSession
import org.json.JSONObject
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SoftwareVideoEncoderFactory
import org.webrtc.VideoSink
import org.webrtc.VideoTrack
import org.webrtc.audio.JavaAudioDeviceModule
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** The process-wide WebRTC factory: our direct decoder for video, low-latency stereo audio. */
object Rtc {
    private var factory: PeerConnectionFactory? = null

    /** Shared GL context for the compatible video path's decoder and renderer. */
    val egl: org.webrtc.EglBase by lazy { org.webrtc.EglBase.create() }

    @Synchronized
    fun factory(context: Context): PeerConnectionFactory {
        factory?.let { return it }
        val app = context.applicationContext
        // No field trials: WebRTC's defaults.
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(app).setEnableInternalTracer(false).createInitializationOptions(),
        )
        val audio = JavaAudioDeviceModule.builder(app)
            .setUseStereoOutput(true)
            // The low-latency output path makes some TV audio drivers throw inside WebRTC's
            // native audio thread, which ends the app. The standard path is safe everywhere.
            .setUseLowLatency(false)
            .setUseHardwareAcousticEchoCanceler(false)
            .setUseHardwareNoiseSuppressor(false)
            .setAudioTrackErrorCallback(object : JavaAudioDeviceModule.AudioTrackErrorCallback {
                override fun onWebRtcAudioTrackInitError(message: String?) { Log.w("Rtc", "audio init: $message") }
                override fun onWebRtcAudioTrackStartError(code: JavaAudioDeviceModule.AudioTrackStartErrorCode?, message: String?) { Log.w("Rtc", "audio start: $message") }
                override fun onWebRtcAudioTrackError(message: String?) { Log.w("Rtc", "audio: $message") }
            })
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_GAME)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            .createAudioDeviceModule()
        return PeerConnectionFactory.builder()
            .setOptions(PeerConnectionFactory.Options())
            .setAudioDeviceModule(audio)
            .setVideoDecoderFactory(TvDecoderFactory())
            .setVideoEncoderFactory(SoftwareVideoEncoderFactory())
            .createPeerConnectionFactory()
            .also { factory = it }
    }
}

/**
 * One live stream: the peer connection to the rig, its input channels and its statistics.
 * Everything that touches the connection runs on one worker thread, in order.
 */
class StreamEngine(
    private val context: Context,
    private val session: CloudSession,
    private val config: Config,
    private val listener: Listener,
) {
    data class Config(
        val width: Int,
        val height: Int,
        val fps: Int,
        val maxKbps: Int,
        /** "H265", "H264", "AV1" or "AUTO". */
        val codec: String,
        val bitDepth: Int,
        /** False to leave the sound line idle (after sound took the app down here). */
        val audio: Boolean = true,
        /** Stream over NVIDIA's native protocol ([NativeTransport]) instead of WebRTC. */
        val native: Boolean = false,
    )

    interface Listener {
        fun onProgress(step: String)
        fun onConnected()
        fun onFirstFrame()
        fun onInputReady()
        /** Input stopped working while the stream carries on (the native route can lose it alone). */
        fun onInputLost() = Unit
        fun onStats(stats: StreamStats)
        fun onTimeWarning(code: Int, secondsLeft: Int?)
        fun onClosed(reason: String, error: Boolean)
    }

    private val worker = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "stream").apply { priority = Thread.MAX_PRIORITY } }
    private var pc: PeerConnection? = null
    private var signaling: Signaling? = null
    private var input: DataChannel? = null
    private var partial: DataChannel? = null
    private var control: DataChannel? = null
    private var audio: AudioTrack? = null
    private var videoTrack: VideoTrack? = null
    private val pendingCandidates = ArrayList<IceCandidate>()
    private var remoteSet = false
    private var gathered: CountDownLatch? = null
    private var heartbeat: ScheduledFuture<*>? = null
    private var statsTask: ScheduledFuture<*>? = null
    private val statsReader = StatsReader()
    @Volatile private var closed = false
    @Volatile private var lastKeyframeAt = 0L

    val encoder = InputEncoder()
    @Volatile var inputReady = false
        private set

    /** What actually got negotiated, for the stats overlay. */
    @Volatile var codec: String? = null
        private set

    /**
     * The direct path renders inside the decoder, so this sees only tiny placeholder frames.
     * In compatible mode the real pictures arrive here and go on to the screen's renderer.
     */
    private var compatFrames = 0L
    private val sink = VideoSink { frame ->
        if (!VideoOutput.compatible) return@VideoSink
        try {
            VideoOutput.renderer?.onFrame(frame)
            VideoOutput.rendered++
            VideoOutput.width = frame.rotatedWidth
            VideoOutput.height = frame.rotatedHeight
            if (compatFrames++ == 0L) {
                CrashLog.step("video")
                VideoOutput.onFirstFrame?.invoke()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "render failed", t)
        }
    }

    /**
     * Queues [block] on the worker. Work that arrives after shutdown is dropped, and a failure
     * inside it ends the stream with a message instead of taking the app down: most of these
     * calls come from WebRTC's native threads, where an escaping exception is fatal.
     */
    private fun post(block: () -> Unit) {
        if (worker.isShutdown) return
        try {
            worker.execute { guarded(block) }
        } catch (_: RejectedExecutionException) {
        }
    }

    private fun every(seconds: Long, block: () -> Unit): ScheduledFuture<*>? = try {
        worker.scheduleWithFixedDelay({ guarded(block) }, seconds, seconds, TimeUnit.SECONDS)
    } catch (_: RejectedExecutionException) {
        null
    }

    private fun guarded(block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            Log.e(TAG, "stream task failed", t)
            if (!closed) fail("The stream stopped because of an internal error (${t.javaClass.simpleName}).")
        }
    }

    /** For callbacks on WebRTC and OkHttp threads: never let an exception escape. */
    private inline fun safe(what: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            Log.e(TAG, "$what failed", t)
        }
    }

    fun start() {
        VideoHooks.begin(config.fps)
        VideoOutput.rendered = 0
        VideoOutput.width = 0
        VideoOutput.height = 0
        VideoOutput.keyframeRequester = { requestKeyframe("decoder") }
        VideoOutput.onFirstFrame = { listener.onFirstFrame() }
        post { if (config.native) openNative() else open() }
    }

    // ---------- NVIDIA's native protocol ----------

    @Volatile private var native: NativeTransport? = null

    /**
     * Starts the stream over the native protocol. The library does the connecting; input goes
     * through the same encoder as on WebRTC, and the picture through the direct decoder.
     */
    private fun openNative() {
        try {
            progress("Connecting to the rig")
            val t = NativeTransport(session, config, object : NativeTransport.Events {
                override fun onEvent(kind: String, detail: String) = post {
                    if (closed) return@post
                    when (kind) {
                        "connected" -> {
                            offerSeen = true
                            connected = true
                            CrashLog.step("connected")
                            listener.onConnected()
                        }
                        "input-ready" -> {
                            encoder.version = detail.toIntOrNull() ?: 2
                            if (!inputReady) {
                                inputReady = true
                                listener.onInputReady()
                            }
                        }
                        // The library gave up on the input channel. Say so: until now every
                        // press was dropped while the app still showed input as working.
                        "input-unavailable" -> if (inputReady) {
                            inputReady = false
                            listener.onInputLost()
                        }
                    }
                }

                override fun onStats(stats: StreamStats) = safe("native stats") { if (!closed) listener.onStats(stats) }

                override fun onFailed(reason: String) = post { fail("4K streaming stopped: $reason") }
            })
            t.volume = volume
            t.muted = muted
            codec = NativeTransport.nativeCodec(config.codec)
            native = t
            t.start()
        } catch (t: Throwable) {
            fail("Couldn't set up the 4K stream: ${t.message ?: t.javaClass.simpleName}")
        }
    }

    private fun open() {
        try {
            progress("Connecting to the rig")
            CrashLog.step("factory")
            val factory = Rtc.factory(context)
            val servers = session.ice.map { spec ->
                PeerConnection.IceServer.builder(spec.urls).apply {
                    spec.username?.let(::setUsername)
                    spec.credential?.let(::setPassword)
                }.createIceServer()
            }.ifEmpty {
                listOf(
                    PeerConnection.IceServer.builder("stun:s1.stun.gamestream.nvidia.com:19308").createIceServer(),
                    PeerConnection.IceServer.builder(listOf("stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302")).createIceServer(),
                )
            }
            val rtc = PeerConnection.RTCConfiguration(servers).apply {
                bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE
                rtcpMuxPolicy = PeerConnection.RtcpMuxPolicy.REQUIRE
                sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
                tcpCandidatePolicy = PeerConnection.TcpCandidatePolicy.ENABLED
                continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
                keyType = PeerConnection.KeyType.ECDSA
            }
            CrashLog.step("peer")
            pc = factory.createPeerConnection(rtc, observer) ?: throw IllegalStateException("no peer connection")
            CrashLog.step("signaling")
            signIn(reconnect = false)
        } catch (t: Throwable) {
            fail("Couldn't set up the stream: ${t.message ?: "unknown error"}")
        }
    }

    private val peerName = Signaling.newPeerName()
    @Volatile private var offerSeen = false
    /** Whether the rig sent its offer, which tells a missing picture from a rig that never started. */
    val offered: Boolean get() = offerSeen

    /** Whether the media connection to the rig came up. Only after that is a missing picture the decoder's doing. */
    @Volatile var connected = false
        private set

    /** Progress is only worth reporting while this engine is still the running one. */
    private fun progress(step: String) {
        if (!closed) listener.onProgress(step)
    }
    @Volatile private var signIns = 0

    /** The answer, kept until a signaling socket is open to carry it. Worker thread only. */
    private var pendingAnswer: Pair<String, String>? = null
    private var answerSent = false

    /**
     * Signs in to the session's signaling server. If the rig stays silent, sign in again as a
     * reconnecting client, the way GeForce NOW's own clients recover a pairing the rig missed.
     */
    private fun signIn(reconnect: Boolean) {
        val url = session.signalingUrl ?: throw IllegalStateException("The rig didn't say where to connect.")
        signaling?.close()
        val attempt = ++signIns
        signaling = Signaling(url, session.id, "${config.width}x${config.height}", reconnect, peerName, signalingEvents(attempt)).also { it.connect() }
        try {
            worker.schedule({
                guarded {
                    if (!closed && !offerSeen && attempt == signIns) retrySignIn("no offer after 12 s")
                }
            }, 12, TimeUnit.SECONDS)
        } catch (_: RejectedExecutionException) {
        }
    }

    /**
     * Signs in again after the signaling socket dropped or the rig stayed silent, as GeForce
     * NOW's clients do: a closed signaling socket doesn't mean the session ended.
     */
    private fun retrySignIn(reason: String) {
        if (closed || inputReady) return
        if (answerSent && pendingAnswer == null) return
        if (signIns >= MAX_SIGN_INS) {
            fail(if (offerSeen) "The rig closed the connection ($reason)." else "The rig didn't start the stream ($reason).")
            return
        }
        Log.w(TAG, "signing in again: $reason")
        progress("Reconnecting to the rig")
        val delayMs = 1000L shl (signIns - 1).coerceIn(0, 3)
        try {
            worker.schedule({ guarded { if (!closed && !inputReady) signIn(reconnect = true) } }, delayMs, TimeUnit.MILLISECONDS)
        } catch (_: RejectedExecutionException) {
        }
    }

    private fun signalingEvents(attempt: Int) = object : Signaling.Events {
        override fun onOpen() = safe("open") {
            if (attempt != signIns || closed) return@safe
            progress("Waiting for the rig")
            // The socket dropped while the answer was being built, and this is the sign-in
            // that replaced it: the answer still has to reach the rig.
            post { pendingAnswer?.let { (sdp, nvst) -> pendingAnswer = null; signaling?.sendAnswer(sdp, nvst) } }
        }
        override fun onOffer(sdp: String) {
            if (offerSeen) return
            offerSeen = true
            post { answer(sdp) }
        }
        override fun onRemoteCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int) = post {
            val c = IceCandidate(sdpMid ?: sdpMLineIndex.toString(), sdpMLineIndex, candidate)
            if (remoteSet) pc?.addIceCandidate(c) else pendingCandidates += c
        }
        override fun onClosed(reason: String) = safe("signaling close") {
            // Only the current sign-in counts; an older socket closing is expected.
            if (attempt != signIns || closed || inputReady) return@safe
            // Before the offer, sign in again. After it, the media connection carries on without
            // signaling, and the no-video check catches a stream that never comes up.
            post {
                when {
                    !remoteSet -> retrySignIn(reason)
                    // The rig's offer is in hand but our answer hasn't gone out: without a
                    // socket it never would, so sign in again and send it then.
                    !answerSent || pendingAnswer != null -> {
                        Log.w(TAG, "signaling closed before the answer went out: $reason")
                        retrySignIn(reason)
                    }
                    else -> Log.w(TAG, "signaling closed after the answer: $reason")
                }
            }
        }
    }

    private fun pickCodec(offer: String): String {
        val offered = Sdp.offeredCodecs(offer)
        // What the decoder factory will put in the answer on this video path. On the compatible
        // path that is WebRTC's own list, which can be shorter than the device's.
        val decodable = { name: String -> TvDecoderFactory.advertises(name) }
        val wanted = config.codec.uppercase()
        if (wanted != "AUTO" && wanted in offered && decodable(wanted)) return wanted
        val deep = config.bitDepth >= 10
        // AV1 first: it is the lightest to decode at a given quality and GeForce NOW keeps its
        // frames small. Only codecs whose hardware decoder keeps up with this size and rate
        // count; if the device makes no such claim, anything it can decode will do.
        val order = listOf("AV1", "H265", "H264")
        val fit = Capabilities.codecsFor(config.width, config.height, config.fps)
        return order.firstOrNull { it in offered && it in fit && decodable(it) && (!deep || TvDecoderFactory.tenBit(it)) }
            ?: order.firstOrNull { it in offered && it in fit && decodable(it) }
            ?: order.firstOrNull { it in offered && decodable(it) }
            ?: "H264"
    }

    private fun answer(offerSdp: String) {
        val pc = pc ?: return
        try {
            if (closed) return
            progress("Negotiating the stream")
            val serverIp = session.media?.ip ?: session.serverIp.orEmpty()
            var offer = if (serverIp.isNotEmpty()) Sdp.fixServerIp(offerSdp, serverIp) else offerSdp
            val serverUfrag = Sdp.value(offer, "a=ice-ufrag:").orEmpty()
            val threshold = Sdp.partialReliableThreshold(offer) ?: 300
            val chosen = pickCodec(offer)
            offer = Sdp.keepCodec(offer, chosen)
            // Never ask for more than the hardware decoder says it can take in.
            val kbps = minOf(config.maxKbps, TvDecoderFactory.maxKbps(chosen)?.takeIf { it >= Sdp.MIN_KBPS } ?: Int.MAX_VALUE)
            if (kbps < config.maxKbps) Log.i(TAG, "bitrate held to $kbps kbps for the $chosen decoder")

            // Input channels, before the answer, so they ride the offer's data section.
            input = pc.createDataChannel("input_channel_v1", DataChannel.Init().apply { ordered = true })?.also { ch ->
                ch.registerObserver(object : DataChannel.Observer {
                    override fun onBufferedAmountChange(previous: Long) = Unit
                    override fun onStateChange() = Unit
                    override fun onMessage(buffer: DataChannel.Buffer) = safe("input message") { handshake(buffer.data) }
                })
            }
            partial = pc.createDataChannel(
                "input_channel_partially_reliable",
                DataChannel.Init().apply {
                    ordered = false
                    maxRetransmitTimeMs = threshold
                },
            )

            CrashLog.step("offer")
            await("offer") { obs -> pc.setRemoteDescription(obs, SessionDescription(SessionDescription.Type.OFFER, offer)) }
            remoteSet = true
            // Receive only: the rig's microphone line would otherwise start recording, which
            // needs a permission we don't ask for and fails on some TVs.
            for (t in pc.transceivers) {
                runCatching {
                    val type = t.mediaType
                    if (type == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO && !config.audio) {
                        t.direction = RtpTransceiver.RtpTransceiverDirection.INACTIVE
                    } else if (type == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO || type == org.webrtc.MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO) {
                        t.direction = RtpTransceiver.RtpTransceiverDirection.RECV_ONLY
                    }
                }
            }
            pendingCandidates.forEach { pc.addIceCandidate(it) }
            pendingCandidates.clear()

            CrashLog.step("answer")
            var created: SessionDescription? = null
            await("answer") { obs ->
                pc.createAnswer(
                    object : SdpObserver by obs {
                        override fun onCreateSuccess(sdp: SessionDescription) {
                            created = sdp
                            obs.onSetSuccess()
                        }
                    },
                    MediaConstraints(),
                )
            }
            val local = SessionDescription(SessionDescription.Type.ANSWER, Sdp.mungeAnswer(created!!.description, kbps))
            gathered = CountDownLatch(1)
            await("local") { obs -> pc.setLocalDescription(obs, local) }
            gathered?.await(5, TimeUnit.SECONDS)

            if (closed) return
            val final = pc.localDescription?.description ?: local.description
            codec = Sdp.negotiatedCodec(final) ?: chosen
            val nvst = Sdp.nvst(
                Sdp.StreamParams(
                    width = config.width,
                    height = config.height,
                    viewportWidth = config.width,
                    viewportHeight = config.height,
                    fps = config.fps,
                    maxKbps = kbps,
                    codec = codec ?: chosen,
                    bitDepth = if (TvDecoderFactory.tenBit(codec ?: chosen)) config.bitDepth else 8,
                    partialReliableMs = threshold,
                    ice = Sdp.credentials(final),
                ),
            )
            // If the socket dropped during the steps above, the sign-in that replaces it
            // sends this once it is open.
            pendingAnswer = final to nvst
            if (signaling?.open == true) {
                signaling?.sendAnswer(final, nvst)
                pendingAnswer = null
            }
            answerSent = true

            // The rig runs ICE-lite and may not send candidates; tell ICE where it is.
            session.media?.let { m ->
                val ip = Sdp.publicIp(m.ip) ?: m.ip
                val ufrag = if (serverUfrag.isNotEmpty()) " generation 0 ufrag $serverUfrag" else ""
                pc.addIceCandidate(IceCandidate("0", 0, "candidate:1 1 udp 2130706431 $ip ${m.port} typ host$ufrag"))
                // The rig listens, so its TCP candidate is the passive side and we dial out.
                pc.addIceCandidate(IceCandidate("0", 0, "candidate:2 1 tcp 1518149375 $ip ${m.port} typ host tcptype passive$ufrag"))
            }
            progress("Starting the video")
            statsTask = every(1) { pollStats() }
        } catch (t: Throwable) {
            Log.e(TAG, "negotiation failed", t)
            fail("The stream couldn't be negotiated: ${t.message ?: "unknown error"}")
        }
    }

    /** Runs one SDP step and waits for it, so the negotiation reads top to bottom. */
    private fun await(what: String, step: (SdpObserver) -> Unit) {
        val done = CountDownLatch(1)
        var error: String? = null
        val obs = object : SdpObserver {
            override fun onCreateSuccess(sdp: SessionDescription) = done.countDown()
            override fun onSetSuccess() = done.countDown()
            override fun onCreateFailure(reason: String?) {
                error = reason ?: "failed"
                done.countDown()
            }
            override fun onSetFailure(reason: String?) {
                error = reason ?: "failed"
                done.countDown()
            }
        }
        step(obs)
        if (!done.await(10, TimeUnit.SECONDS)) throw IllegalStateException("$what timed out")
        error?.let { throw IllegalStateException("$what: $it") }
    }

    /** The server opens input with its protocol version; from then on we may send. */
    private fun handshake(data: ByteBuffer) {
        if (inputReady || data.remaining() < 2) return
        val b = ByteArray(data.remaining()).also { data.get(it) }
        val first = (b[0].toInt() and 0xff) or ((b[1].toInt() and 0xff) shl 8)
        val version = when {
            first == 526 -> if (b.size >= 4) (b[2].toInt() and 0xff) or ((b[3].toInt() and 0xff) shl 8) else 2
            b[0].toInt() == 0x0e -> first
            else -> return
        }
        encoder.version = version
        inputReady = true
        heartbeat = every(2) { sendReliable(encoder.heartbeat()) }
        listener.onInputReady()
    }

    private val observer = object : PeerConnection.Observer {
        override fun onSignalingChange(state: PeerConnection.SignalingState?) = Unit
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) = Unit
        override fun onConnectionChange(state: PeerConnection.PeerConnectionState?) = safe("connection change") {
            when (state) {
                PeerConnection.PeerConnectionState.CONNECTED -> if (!closed) {
                    connected = true
                    CrashLog.step("connected")
                    listener.onConnected()
                }
                PeerConnection.PeerConnectionState.FAILED -> post { fail("The connection to the rig was lost.") }
                else -> Unit
            }
        }
        override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) = safe("gathering") {
            if (state == PeerConnection.IceGatheringState.COMPLETE) gathered?.countDown()
        }
        override fun onIceCandidate(c: IceCandidate) = safe("candidate") {
            signaling?.sendCandidate(c.sdp, c.sdpMid, c.sdpMLineIndex)
        }
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) = Unit
        override fun onAddStream(stream: MediaStream?) = Unit
        override fun onRemoveStream(stream: MediaStream?) = Unit
        override fun onDataChannel(channel: DataChannel) = safe("data channel") {
            if (channel.label() != "control_channel") return@safe
            control = channel
            channel.registerObserver(object : DataChannel.Observer {
                override fun onBufferedAmountChange(previous: Long) = Unit
                override fun onStateChange() = Unit
                override fun onMessage(buffer: DataChannel.Buffer) = safe("control message") { controlMessage(buffer.data) }
            })
        }
        override fun onRenegotiationNeeded() = Unit
        override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) = Unit
        override fun onTrack(transceiver: RtpTransceiver) = safe("track") {
            when (val track = transceiver.receiver?.track()) {
                is VideoTrack -> {
                    videoTrack = track
                    track.addSink(sink)
                }
                is AudioTrack -> {
                    audio = track
                    applyVolume()
                }
            }
        }
    }

    private fun controlMessage(data: ByteBuffer) {
        val text = ByteArray(data.remaining()).also { data.get(it) }.toString(Charsets.UTF_8)
        val timer = runCatching { JSONObject(text).optJSONObject("timerNotification") }.getOrNull() ?: return
        val left = timer.optInt("secondsLeft", -1).takeIf { it >= 0 }
        listener.onTimeWarning(timer.optInt("code", 0), left)
    }

    private fun pollStats() {
        val pc = pc ?: return
        pc.getStats { report ->
            safe("stats") {
                val s = runCatching { statsReader.read(report) }.getOrNull() ?: return@safe
                listener.onStats(s.copy(codec = s.codec ?: codec))
            }
        }
    }

    // ---------- Input ----------

    private fun DataChannel.sendBytes(b: ByteArray) {
        if (state() == DataChannel.State.OPEN) send(DataChannel.Buffer(ByteBuffer.wrap(b), true))
    }

    fun sendReliable(b: ByteArray) {
        if (closed) return
        val n = native
        if (n != null) n.sendInput(b, partial = false) else input?.sendBytes(b)
    }

    /** Controller reports go on the partially reliable channel: a late report is useless. */
    fun sendGamepad(slot: Int, connected: Int, buttons: Int, lt: Int, rt: Int, lx: Int, ly: Int, rx: Int, ry: Int) {
        if (!inputReady || closed) return
        native?.let {
            it.sendInput(encoder.gamepad(slot, connected, buttons, lt, rt, lx, ly, rx, ry, partiallyReliable = true), partial = true)
            return
        }
        val p = partial
        if (p != null && p.state() == DataChannel.State.OPEN) {
            p.sendBytes(encoder.gamepad(slot, connected, buttons, lt, rt, lx, ly, rx, ry, partiallyReliable = true))
        } else {
            sendReliable(encoder.gamepad(slot, connected, buttons, lt, rt, lx, ly, rx, ry, partiallyReliable = false))
        }
    }

    fun sendKey(down: Boolean, key: Keymap.Key, modifiers: Int = 0) {
        if (inputReady) sendReliable(encoder.key(down, key.vk, key.scan, modifiers))
    }

    fun sendMouseMove(dx: Int, dy: Int) {
        if (inputReady && (dx != 0 || dy != 0)) sendReliable(encoder.mouseMove(dx, dy))
    }

    fun sendMouseButton(down: Boolean, button: Int) {
        if (inputReady) sendReliable(encoder.mouseButton(down, button))
    }

    fun sendWheel(delta: Int) {
        if (inputReady && delta != 0) sendReliable(encoder.wheel(delta))
    }

    /** Types [text] as key presses, the way a US keyboard would. Characters it can't type are skipped. */
    fun typeText(text: String) {
        post {
            for (c in text) {
                val (key, shift) = Keymap.forChar(c) ?: continue
                val mods = if (shift) InputEncoder.MOD_SHIFT else 0
                if (shift) sendKey(true, Keymap.SHIFT, mods)
                sendKey(true, key, mods)
                SystemClock.sleep(6)
                sendKey(false, key, mods)
                if (shift) sendKey(false, Keymap.SHIFT, 0)
                SystemClock.sleep(6)
            }
        }
    }

    /** Taps a key combination: all down in order, then all up in reverse. */
    fun sendCombo(vararg keys: Keymap.Key) {
        post {
            var mods = 0
            for (k in keys) {
                if (k == Keymap.ALT) mods = mods or InputEncoder.MOD_ALT
                sendKey(true, k, mods)
                SystemClock.sleep(30)
            }
            for (k in keys.reversed()) {
                sendKey(false, k, mods)
                if (k == Keymap.ALT) mods = mods and InputEncoder.MOD_ALT.inv()
                SystemClock.sleep(20)
            }
        }
    }

    fun requestKeyframe(reason: String) {
        val now = SystemClock.uptimeMillis()
        if (now - lastKeyframeAt < 400) return
        lastKeyframeAt = now
        native?.let {
            it.requestKeyframe()
            return
        }
        post {
            val c = control
            if (c != null && c.state() == DataChannel.State.OPEN) {
                val msg = JSONObject().put("type", "request_keyframe").put("reason", reason).put("backlogFrames", 0).put("attempt", 1)
                c.send(DataChannel.Buffer(ByteBuffer.wrap(msg.toString().toByteArray()), false))
            } else {
                signaling?.requestKeyframe(reason)
            }
        }
    }

    // ---------- Audio ----------

    @Volatile var volume = 1.0
        set(value) {
            field = value.coerceIn(0.0, 1.0)
            post { applyVolume() }
        }

    @Volatile var muted = false
        set(value) {
            field = value
            post { applyVolume() }
        }

    private fun applyVolume() {
        native?.let {
            it.volume = volume
            it.muted = muted
        }
        val a = audio ?: return
        runCatching {
            a.setEnabled(!muted)
            // WebRTC's gain runs 0 to 10; 1 is unchanged.
            a.setVolume(volume)
        }
    }

    // ---------- Shutdown ----------

    private fun fail(reason: String) {
        if (closed) return
        listener.onClosed(reason, error = true)
        stop()
    }

    fun stop() {
        if (closed) return
        closed = true
        VideoOutput.keyframeRequester = null
        VideoOutput.onFirstFrame = null
        inputReady = false
        runCatching { native?.stop() }
        try {
            worker.execute { shutdown() }
        } catch (_: RejectedExecutionException) {
        }
    }

    private fun shutdown() {
        try {
            heartbeat?.cancel(false)
            statsTask?.cancel(false)
            runCatching { signaling?.close() }
            runCatching { videoTrack?.removeSink(sink) }
            // Close and free every channel before the connection that owns them goes.
            for (ch in listOf(input, partial, control)) {
                runCatching { ch?.unregisterObserver() }
                runCatching { ch?.close() }
                runCatching { ch?.dispose() }
            }
            input = null
            partial = null
            control = null
            runCatching { pc?.close() }
            runCatching { pc?.dispose() }
        } catch (t: Throwable) {
            Log.e(TAG, "shutdown failed", t)
        } finally {
            pc = null
            worker.shutdown()
        }
    }

    companion object {
        private const val TAG = "StreamEngine"
        private const val MAX_SIGN_INS = 4
    }
}
