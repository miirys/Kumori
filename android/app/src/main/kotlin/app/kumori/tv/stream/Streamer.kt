package app.kumori.tv.stream

import android.content.Context
import android.hardware.display.DisplayManager
import android.view.Display
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.kumori.tv.CrashLog
import app.kumori.tv.Diagnostics
import app.kumori.tv.Resolution
import app.kumori.tv.Settings
import app.kumori.tv.VideoPath
import app.kumori.tv.VideoCodec
import app.kumori.tv.data.ActiveSession
import app.kumori.tv.data.AppState
import app.kumori.tv.data.CloudSession
import app.kumori.tv.data.Cloudmatch
import app.kumori.tv.data.Game
import app.kumori.tv.data.LaunchRequest
import app.kumori.tv.data.Route
import app.kumori.tv.StreamMode
import app.kumori.tv.data.SessionException
import app.kumori.tv.input.PadHub
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * Runs a game from the moment Play is pressed until the session ends: asks for a rig, waits
 * in the queue, connects, and keeps the screens informed. Compose reads its state directly.
 */
class Streamer(
    private val context: Context,
    private val scope: CoroutineScope,
    val app: AppState,
    private val settings: Settings,
    private val hub: PadHub,
) {
    sealed interface Phase {
        /** Talking to the session service; [step] says what we are doing. */
        data class Starting(val step: String) : Phase
        data class Queued(val position: Int) : Phase
        data class Connecting(val step: String) : Phase
        data object Live : Phase
        data class Ended(val message: String, val error: Boolean, val canRetry: Boolean) : Phase
    }

    var phase by mutableStateOf<Phase?>(null)
        private set
    var game by mutableStateOf<Game?>(null)
        private set
    var stats by mutableStateOf(StreamStats.Empty)
        private set
    var menuOpen by mutableStateOf(false)
        private set
    var notice by mutableStateOf<String?>(null)
        private set

    /** The running stream's frame rate, 0 when nothing is streaming. Picks the TV's mode. */
    var streamFps by mutableIntStateOf(0)
        private set

    /**
     * What is really on screen, as a mode: the size the decoder reports and the rate the rig
     * agreed to. Null until a stream is connecting. Settings shows this, not what was asked for.
     */
    val playing: StreamMode?
        get() {
            if (phase == null || phase is Phase.Ended) return null
            val h = stats.height.takeIf { it > 0 } ?: session?.height ?: return null
            return StreamMode.closest(h, streamFps.takeIf { it > 0 } ?: session?.fps ?: 60)
        }
    var liveSince by mutableLongStateOf(0L)
        private set
    var muted by mutableStateOf(false)
        private set
    var controllerMouse by mutableStateOf(false)
        private set
    var session by mutableStateOf<CloudSession?>(null)
        private set
    var inputReady by mutableStateOf(false)
        private set
    /** Whether this stream uses the compatible video path (WebRTC's renderer). */
    var compatibleVideo by mutableStateOf(false)
        private set

    val active: Boolean get() = phase != null
    val live: Boolean get() = phase == Phase.Live

    /** True while the stream plays in a small picture-in-picture window. */
    var inPip by mutableStateOf(false)
        private set

    /**
     * In the small window the game is only watched: the controller goes back to driving the
     * launcher behind it, and nothing is sent to the game.
     */
    fun setPip(on: Boolean) {
        if (inPip == on) return
        inPip = on
        if (on) {
            releaseHeld()
            input.enabled = false
            hub.captured = false
        } else if (phase == Phase.Live && !menuOpen && !keyboardOpen) {
            hub.captured = true
            input.enabled = true
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var job: Job? = null
    @Volatile private var engine: StreamEngine? = null
    private var cloud: Cloudmatch? = null
    private var lastResume: ActiveSession? = null
    private var lastGame: Game? = null

    val input = GameInput(onMenu = { openMenu() }).apply { slotFor = hub::slotOf }

    init {
        hub.raw = { id, state -> if (engine != null) input.report(id, state) }
    }

    /** The codec to ask for: the chosen one, or H.264 after a decoder crash on Automatic. */
    private fun codecName() = if (settings.safeCodec && settings.codec == VideoCodec.AUTO) "H264" else settings.codec.sdpName

    /** 10-bit only when it is switched on and the decoder for [codec] can really show it. */
    private fun bitDepth(codec: String = codecName()) = if (settings.tenBit && TvDecoderFactory.tenBit(codec)) 10 else 8

    private fun request(): LaunchRequest {
        val m = settings.mode
        return LaunchRequest(
            appId = "",
            width = m.width,
            height = m.height,
            fps = m.fps,
            bitDepth = bitDepth(),
            lowLatencyMode = settings.lowLatency,
            language = settings.language.code,
        )
    }

    /** Starts [g], or picks up its session if one is already running for the account. */
    fun play(g: Game) {
        val running = app.sessions.firstOrNull { app.gameFor(it) == g }
        if (running != null) {
            resume(running, g)
            return
        }
        startFresh(g)
    }

    // ---------- 4K ----------
    //
    // GeForce NOW decides how large a stream may be from the kind of client that asks, and the
    // desktop web client (the one that always works) stops at 1440p. So 4K is asked for in
    // other ways, one after another, until one gives a real 4K picture. What worked is
    // remembered, so only the first 4K game on a device pays for the search.

    /** How the session in hand was asked for. */
    private var route = Route.WEB

    /** That session is brand new and has shown no picture yet, so it can be swapped for another. */
    private var routeFresh = false

    /** Ways of asking that didn't work for this game. Forgotten when the stream screen closes. */
    private val skipped = HashSet<Route>()

    /** The picture height that was asked for, to compare with what arrives. */
    private var askedHeight = 0

    /** The rest of what was asked for, used when the service doesn't say what it gave. */
    private var askedWidth = 0
    private var askedFps = 0

    /**
     * True when the session in hand was taken over or reconnected. Its listing can still show
     * the mode it had before, so what was just asked for is the better guide.
     */
    private var claimed = false

    private fun asked(width: Int, height: Int, fps: Int) {
        askedWidth = width
        askedHeight = height
        askedFps = fps
    }

    /** Shown once the picture is up, to say why this isn't the stream that was asked for. */
    private var pendingNote: String? = null

    /** The ways to ask for a stream of this height, most promising first. */
    private fun routes(height: Int): List<Route> {
        if (height < 2160) return listOf(Route.WEB)
        settings.expireRoutes()
        val known = settings.route4k?.let { n -> Route.entries.firstOrNull { it.name == n } }
        // The native protocol only draws through the direct output. On Realtek that is the
        // less proven path, so there it never jumps the queue, even after it once worked.
        val order = if (TvDecoderFactory.realtek) {
            listOfNotNull(known.takeIf { it != Route.NATIVE }) + listOf(Route.TV, Route.DESKTOP, Route.NATIVE)
        } else {
            listOfNotNull(known) + listOf(Route.TV, Route.DESKTOP, Route.NATIVE)
        }
        return order.distinct().filter {
            it !in skipped && it.name !in settings.failedRoutes && (it != Route.NATIVE || nativeUsable())
        }
    }

    /** The native protocol needs its library in this build and a hardware decoder for its codec. */
    private fun nativeUsable(): Boolean {
        if (!NativeTransport.available) return false
        val mime = TvDecoderFactory.mimeOf(NativeTransport.nativeCodec(codecName())) ?: return false
        return TvDecoderFactory.find(mime) != null
    }

    /** [r] for one way of asking. The native protocol also needs the codec and bitrate up front. */
    private fun via(r: LaunchRequest, route: Route): LaunchRequest {
        val codec = NativeTransport.nativeCodec(codecName())
        return r.copy(
            route = route,
            codec = codec,
            maxKbps = settings.bitrateMbps * 1000,
            // The native protocol names its codec up front, so the depth must suit that codec.
            bitDepth = if (route == Route.NATIVE) minOf(r.bitDepth, bitDepth(codec)) else r.bitDepth,
        )
    }

    private fun note4k(text: String) {
        android.util.Log.w("Streamer", "4K: $text")
        settings.note4k(text)
    }

    private fun routeName(r: Route) = when (r) {
        Route.WEB -> "the web client"
        Route.TV -> "the TV client"
        Route.DESKTOP -> "the PC client"
        Route.NATIVE -> "NVIDIA's own protocol"
    }

    /**
     * Asks for a 4K rig one way. Null when that way gave none, or gave a smaller picture than
     * was asked for; the caller then tries the next way.
     */
    private suspend fun tryRoute(cm: Cloudmatch, base: LaunchRequest, r: Route): CloudSession? {
        val ask = via(base, r)
        var why: String? = null
        search@ for ((j, place) in places(chosenRegion()).withIndex()) {
            val (name, url) = place
            if (j > 0) phase = Phase.Starting("Trying ${name ?: "another server"}")
            var shapeRefused = false
            for (attempt in listOfNotNull(ask, if (ask.bitDepth == 10) ask.copy(bitDepth = 8) else null)) {
                try {
                    val s = cm.create(url, attempt)
                    val got = s.height
                    if (got != null && got < ask.height) {
                        // The answer already says the rig is smaller. Give it back and move on.
                        runCatching { cm.stop(s) }
                        settings.markRoute(r.name, worked = false)
                        note4k("Asked as ${routeName(r)}, offered ${got}p")
                        delay(1500)
                        return null
                    }
                    route = r
                    routeFresh = true
                    note4k("Asked as ${routeName(r)}, got a rig from ${name ?: "the nearest server"}")
                    return s
                } catch (e: SessionException) {
                    if (e.account) throw e
                    why = e.description ?: e.message
                    Diagnostics.lastRefusal = "${modeName(ask.height, ask.fps)} as ${routeName(r)}: $why"
                    if (!e.stepDown) break@search
                    // A refusal of the stream's shape is worth one more try in 8-bit, but it
                    // would be the same at every other server.
                    shapeRefused = !e.retryable
                }
            }
            if (shapeRefused) break@search
        }
        skipped += r
        note4k("Asked as ${routeName(r)}, refused: ${why ?: "no reason given"}")
        return null
    }

    /**
     * A stream that was asked for in one of the 4K ways failed before any picture. Remember
     * that, and start again the next way. A stream that was already playing is left alone.
     */
    private fun fallBack(message: String): Boolean {
        if (route == Route.WEB || liveSince != 0L) return false
        val g = lastGame
        val r = lastResume
        if (r == null && !(routeFresh && g != null)) return false
        note4k("${routeName(route).replaceFirstChar { it.uppercase() }} failed before the first picture: $message")
        settings.markRoute(route.name, worked = false)
        skipped += route
        val s = session
        val cm = cloud
        stopEngine()
        val fresh = routeFresh
        route = Route.WEB
        routeFresh = false
        if (r != null && !fresh) {
            resume(r, g)
            return true
        }
        phase = Phase.Starting("Trying 4K another way")
        job?.cancel()
        job = scope.launch {
            if (s != null && cm != null) runCatching { cm.stop(s) }
            delay(1500)
            startFresh(g!!)
        }
        return true
    }

    private fun startFresh(g: Game) {
        lastResume = null
        claimed = false
        val v = g.variants.firstOrNull { it.selected } ?: g.variants.firstOrNull()
        val appId = v?.id ?: g.id
        route = Route.WEB
        routeFresh = false
        begin(g) { cm ->
            phase = Phase.Starting("Requesting a rig")
            val (w, h, fps) = target()
            val ask = request().copy(appId = appId, title = g.title, accountLinked = v?.owned ?: true, width = w, height = h, fps = fps)
            asked(w, h, fps)
            var s: CloudSession? = null
            for (r in routes(h)) {
                if (r == Route.WEB) break
                s = tryRoute(cm, ask, r)
                if (s != null) break
            }
            if (s == null) {
                if (h >= 2160) {
                    // No way of asking gave 4K. The web client's best is 1440p.
                    pendingNote = "GeForce NOW didn't give a 4K rig this time, so this is 1440p."
                    asked(2560, 1440, fps)
                    s = start(cm, ask.copy(width = 2560, height = 1440))
                } else {
                    s = start(cm, ask)
                }
            }
            session = s
            waitForSeat(cm, s)
        }
    }

    /**
     * The mode to ask for: the one chosen in Settings, or the closest one the membership
     * includes when the choice is beyond it (asking for more only gets the request refused).
     */
    private fun target(): Triple<Int, Int, Int> {
        var m = settings.mode
        // A mode this device's decoder can't keep up with (the default on a fresh install can
        // be one) only gives a stuttering or black picture, so take the nearest it can run.
        if (!Capabilities.decodes(m)) {
            val fit = Resolution.entries.flatMap { r -> StreamMode.RATES.map { StreamMode(r, it) } }
                .filter { it.height <= m.height && it.fps <= m.fps && Capabilities.decodes(it) }
                .maxWithOrNull(compareBy({ it.height }, { it.fps }))
            if (fit != null) {
                notice = "Playing at ${modeName(fit.height, fit.fps)}, the most this device can decode."
                m = fit
            }
        }
        // Ultimate includes every mode; never second-guess it from the entitlement list.
        if (app.membership?.tier.equals("Ultimate", ignoreCase = true)) return Triple(m.width, m.height, m.fps)
        // Only TV-shaped modes count: the list also carries 16:10 and ultrawide ones.
        val allowed = app.allowedModes?.let { all -> all.filter { it.width * 9 == it.height * 16 }.ifEmpty { all } }
            ?: return Triple(m.width, m.height, m.fps)
        if (allowed.any { it.height >= m.height && it.fps >= m.fps }) return Triple(m.width, m.height, m.fps)
        val best = allowed.filter { it.height <= m.height && it.fps <= m.fps }.maxWithOrNull(compareBy({ it.height }, { it.fps }))
            ?: allowed.minWithOrNull(compareBy({ it.height }, { it.fps }))
            ?: return Triple(m.width, m.height, m.fps)
        val tier = app.membership?.tier
        notice = "Playing at ${modeName(best.height, best.fps)}, the most ${if (tier != null) "your $tier membership" else "your membership"} includes."
        return Triple(best.width, best.height, best.fps)
    }

    /**
     * Asks for a rig. When the nearest location turns the stream shape down (it happens when
     * its high-end rigs are busy or missing, whatever the membership), the next-closest
     * locations are asked for the same quality first. Only if none of them can is the quality
     * stepped down, one level at a time.
     */
    private fun chosenRegion(): Pair<String, String>? {
        val name = settings.region.takeIf { it.isNotEmpty() } ?: return null
        val listed = app.regions.firstOrNull { it.name == name }
        if (listed != null) {
            // Kept with the choice, so it still holds before the region list has loaded.
            if (settings.regionUrl != listed.url) settings.chooseRegion(name, listed.url)
            return name to listed.url
        }
        return settings.regionUrl.takeIf { it.isNotEmpty() }?.let { name to it }
    }

    /** Where to ask for a rig, nearest first: the chosen location, or the default and its neighbours. */
    private fun places(chosen: Pair<String, String>?): List<Pair<String?, String>> {
        if (chosen != null) return listOf(chosen.first to chosen.second)
        val nearest = app.regions.firstOrNull { it.pingMs != null }?.pingMs
        val near = app.regions
            .filter { r -> r.pingMs != null && nearest != null && r.pingMs <= nearest * 2 + 25 }
            .take(3)
            .map { it.name to it.url }
        return (listOf<Pair<String?, String>>(null to app.streamingBase) + near).distinctBy { it.second.trimEnd('/') }
    }

    private suspend fun start(cm: Cloudmatch, ask: LaunchRequest): CloudSession {
        val chosen = chosenRegion()
        val bases = places(chosen)
        val ladder = buildList {
            add(ask)
            if (ask.bitDepth == 10) add(ask.copy(bitDepth = 8))
            for ((w, h, f) in listOf(Triple(2560, 1440, 120), Triple(2560, 1440, 60), Triple(1920, 1080, 120), Triple(1920, 1080, 60))) {
                if (h <= ask.height && f <= ask.fps && !(h == ask.height && f == ask.fps)) add(ask.copy(width = w, height = h, fps = f, bitDepth = 8))
            }
        }
        var last: SessionException? = null
        for ((i, attempt) in ladder.withIndex()) {
            // The full quality is worth trying everywhere nearby; lower steps stay on the first.
            // Always as the desktop web client, so the rig streams over WebRTC.
            val places = if (i == 0) bases else bases.take(1)
            for ((j, place) in places.withIndex()) {
                val (name, base) = place
                if (j > 0) phase = Phase.Starting("Trying ${name ?: "another server"}")
                try {
                    val s = cm.create(base, attempt.copy(route = Route.WEB))
                    route = Route.WEB
                    notice = when {
                        i == 0 && name != null && chosen == null ->
                            "Playing from $name, because the nearest server couldn't start ${modeName(ask.height, ask.fps)}."
                        i == 0 -> notice
                        attempt.height == ask.height && attempt.fps == ask.fps -> "Playing in 8-bit colour; this game wouldn't start in 10-bit."
                        else -> "Playing at ${modeName(attempt.height, attempt.fps)}; no server nearby could start ${modeName(ask.height, ask.fps)} for this game."
                    }
                    return s
                } catch (e: SessionException) {
                    android.util.Log.w("Streamer", "create refused at ${attempt.width}x${attempt.height}@${attempt.fps} via ${name ?: "default"}: ${e.message}")
                    Diagnostics.lastRefusal = "${modeName(attempt.height, attempt.fps)}: ${e.description ?: e.message}"
                    if (!e.stepDown) throw e
                    last = e
                    // A refused shape would be refused at the other servers too: step down.
                    if (!e.retryable) break
                }
            }
            ladder.getOrNull(i + 1)?.let { phase = Phase.Starting("Trying ${modeName(it.height, it.fps)}") }
        }
        throw last ?: SessionException("GeForce NOW couldn't start the game.")
    }

    private fun modeName(height: Int, fps: Int) = "${if (height >= 2160) "4K" else "${height}p"} at $fps fps"

    /** Takes over a session running elsewhere (or left running here). */
    fun resume(a: ActiveSession, g: Game?) {
        lastResume = a
        begin(g ?: app.gameFor(a)) { cm ->
            phase = Phase.Starting(if (a.status == 1) "Following your session" else "Taking over your session")
            val (w, h, fps) = target()
            // A running session is only taken over in a 4K way that has already worked here.
            route = routes(h).firstOrNull { it.name == settings.route4k } ?: Route.WEB
            routeFresh = false
            val size = if (route == Route.WEB && h >= 2160) Pair(2560, 1440) else Pair(w, h)
            asked(size.first, size.second, fps)
            claimed = true
            val ask = via(request().copy(appId = a.appId, width = size.first, height = size.second, fps = fps), route)
            // A session still queued or being set up can't be taken over yet. Wait for its
            // seat here, where the queue position shows, however long the queue is.
            val now = cm.peek(a, route)
            if (now != null && now.status == 1) {
                session = now
                waitForSeat(cm, now)
            }
            val s = cm.claim(a, ask)
            session = s
            s
        }
    }

    private suspend fun waitForSeat(cm: Cloudmatch, first: CloudSession): CloudSession {
        var s = first
        var tries = 0
        while (!s.ready) {
            if (s.status !in 1..3) throw SessionException("The session ended before it was ready.")
            if (s.adsRequired) {
                // A place in the queue that was asked for just now is given back. Left
                // there, it would never start and would block every other launch.
                if (lastResume == null) runCatching { cm.stop(s) }
                throw SessionException("Your membership shows ads in the queue, which this app can't play. A paid membership skips them.")
            }
            val q = s.queuePosition
            phase = if (q != null && q > 0) Phase.Queued(q) else Phase.Starting(setupText(s.setupStep, tries))
            delay(if (q != null && q > 10) 4000 else 1500)
            s = runCatching { cm.poll(s) }.getOrElse { e ->
                if (e is SessionException && e.statusCode != 0) throw e
                if (++tries > 20) throw e
                s
            }
            session = s
        }
        return s
    }

    private fun setupText(step: Int?, tries: Int) = when {
        step == null && tries == 0 -> "Preparing your rig"
        step == null -> "Preparing your rig"
        step <= 1 -> "Finding a rig"
        step <= 3 -> "Preparing your rig"
        else -> "Launching the game"
    }

    private fun begin(g: Game?, obtain: suspend (Cloudmatch) -> CloudSession) {
        stopEngine()
        job?.cancel()
        game = g
        lastGame = g
        stats = StreamStats.Empty
        menuOpen = false
        notice = null
        inputReady = false
        sizeChecks = 0
        liveSince = 0
        // The controller keeps driving our screens until the picture is up.
        hub.captured = false
        // Chosen before the stream screen appears, since it decides what that screen draws into.
        compatibleVideo = standardOutput()
        val cm = Cloudmatch({ app.serviceToken() }).also { cloud = it }
        job = scope.launch {
            try {
                val s = obtain(cm)
                session = s
                connect(s)
            } catch (c: CancellationException) {
                throw c
            } catch (e: SessionException) {
                end(e.message ?: "The session couldn't start.", error = true)
            } catch (t: Throwable) {
                end("GeForce NOW can't be reached. Check the network connection.", error = true)
            }
        }
    }

    /** Whether video goes through WebRTC's own decoder and renderer rather than the direct output. */
    private fun standardOutput() = when (settings.videoPath) {
            VideoPath.COMPATIBLE -> true
            VideoPath.DIRECT -> false
            // Amlogic boxes decode straight onto their hardware video layer, with no copy
            // through the graphics chip: the only path there that keeps up with 120 fps.
            // Everything else, and any box where that path has failed, uses WebRTC's own
            // decoder and renderer.
            VideoPath.AUTO -> !(TvDecoderFactory.amlogic && !settings.directFailed)
    }

    private fun connect(s: CloudSession) {
        phase = Phase.Connecting("Connecting to the rig")
        val m = settings.mode
        val native = route == Route.NATIVE
        // The native protocol only draws through the direct output, whatever the setting says.
        compatibleVideo = if (native) false else standardOutput()
        if (native && s.rtsps.isEmpty()) {
            end("4K streaming couldn't start: the rig didn't offer NVIDIA's native protocol", error = true)
            return
        }
        val codec = codecName()
        val wantW = askedWidth.takeIf { it > 0 }
        val wantH = askedHeight.takeIf { it > 0 }
        val wantFps = askedFps.takeIf { it > 0 }
        val fps = (if (claimed) wantFps else null) ?: s.fps ?: wantFps ?: m.fps
        val listener = EngineListener()
        val e = StreamEngine(
            context,
            s,
            StreamEngine.Config(
                // What the rig agreed to, which can be less than what was asked for. When the
                // service doesn't say, it is what was asked for, not what Settings shows.
                width = (if (claimed) wantW else null) ?: s.width ?: wantW ?: m.width,
                height = (if (claimed) wantH else null) ?: s.height ?: wantH ?: m.height,
                fps = fps,
                maxKbps = settings.bitrateMbps * 1000,
                codec = codec,
                bitDepth = bitDepth(if (native) NativeTransport.nativeCodec(codec) else codec),
                audio = !settings.noAudio,
                native = native,
            ),
            listener,
        )
        listener.owner = e
        engine = e
        VideoOutput.compatible = compatibleVideo
        CrashLog.markStreaming(context, if (native) "native" else if (compatibleVideo) "compatible" else "direct")
        input.engine = e
        // The game only hears about a controller when it reports, and a controller at rest
        // reports nothing, so tell it now about every one that is already connected.
        for ((id, state) in hub.snapshot()) input.report(id, state)
        VideoHooks.swapInterval = settings.framePacing.swapInterval
        VideoHooks.tuneDecoder = settings.decoderHints
        streamFps = fps
        VideoOutput.fps = streamFps
        input.holdMs = settings.holdToOpenMs.toLong()
        input.mouseSpeed = settings.mouseSpeed
        e.volume = settings.volume / 100.0
        e.muted = muted
        e.start()
        // The direct output is new on this kind of box. If the rig is sending but no picture
        // comes out of it, go back to the standard output rather than leave a black screen.
        // The clock starts when the rig's stream is connected: a slow rig or a slow network
        // is not the decoder's fault, and this choice is remembered.
        if (!native && !compatibleVideo && settings.videoPath == VideoPath.AUTO) scope.launch {
            while (engine === e && !e.connected) delay(500)
            delay(15_000)
            if (engine === e && e.offered && phase !is Phase.Live && phase !is Phase.Ended) {
                settings.markDirectFailed()
                end("The direct video output showed no picture, so the standard one is switched on. Try again.", error = true)
            }
        }
        // If no picture arrives, say so instead of spinning forever.
        scope.launch {
            delay(if (native) 25_000 else 30_000)
            if (engine === e && phase !is Phase.Live && phase !is Phase.Ended) {
                end(
                    if (native) "4K streaming showed no picture${if (e.offered) " after connecting" else ""}"
                    else if (e.offered) "The rig didn't send any video. Try again, or pick a different video codec in Settings."
                    else "The rig didn't start the stream. Try again in a moment.",
                    error = true,
                )
            }
        }
    }

    private var sizeChecks = 0

    /**
     * One engine's reports. An engine that has been stopped can still report for a moment
     * (its worker finishes what it was doing), and those must not touch the next stream or
     * bring a closed stream screen back, so everything is checked against [owner].
     */
    private inner class EngineListener : StreamEngine.Listener {
        @Volatile var owner: StreamEngine? = null

        private fun mine() = owner != null && engine === owner && phase != null

        override fun onProgress(step: String) = ui { if (mine() && phase !is Phase.Live && phase !is Phase.Ended) phase = Phase.Connecting(step) }
        override fun onConnected() = ui { if (mine() && phase !is Phase.Live && phase !is Phase.Ended) phase = Phase.Connecting("Starting the video") }
        override fun onFirstFrame() = ui {
            // The direct decoder reports a first frame again each time it restarts.
            if (mine() && phase !is Phase.Ended && phase != Phase.Live) {
                CrashLog.step("live")
                phase = Phase.Live
                routeFresh = false
                pendingNote?.let { notice = it }
                pendingNote = null
                if (settings.noAudio && notice == null) notice = NO_SOUND
                if (notice == null) notice = slowScreenNotice()
                if (liveSince == 0L) liveSince = SystemClock.elapsedRealtime()
                val play = !menuOpen && !keyboardOpen && !inPip
                hub.captured = play
                input.enabled = play
            }
        }
        override fun onInputReady() = ui {
            if (!mine()) return@ui
            inputReady = true
            input.enabled = !menuOpen && !keyboardOpen && !inPip && phase == Phase.Live
        }
        override fun onInputLost() = ui {
            if (!mine()) return@ui
            inputReady = false
            if (phase == Phase.Live) notice = "The game stopped taking input. Reconnect from the menu to get it back."
        }
        override fun onStats(stats: StreamStats) = ui {
            if (!mine()) return@ui
            this@Streamer.stats = stats
            // A few seconds in, compare the picture with what was asked for. A 4K way of
            // asking that really gave 4K is kept; one that gave less is not used again.
            if (stats.height > 0 && ++sizeChecks == 3 && askedHeight >= 2160 && route != Route.WEB) {
                val ok = stats.height >= 2000
                settings.markRoute(route.name, worked = ok)
                note4k("Asked as ${routeName(route)}, playing at ${stats.width} × ${stats.height}")
                if (!ok && notice == null) {
                    notice = "GeForce NOW is sending ${stats.height}p, not 4K. The next game will ask for 4K another way."
                }
            } else if (sizeChecks == 3 && claimed && stats.height > 0 && askedHeight in 1..2159 && notice == null &&
                kotlin.math.abs(stats.height - askedHeight) > askedHeight / 10
            ) {
                // A running session can refuse to change size. Say so rather than show a
                // setting that doesn't match the picture.
                notice = "GeForce NOW kept this session at ${stats.height}p. End the session and start the game again to play at ${askedHeight}p."
            }
        }
        override fun onTimeWarning(code: Int, secondsLeft: Int?) = ui {
            if (!mine()) return@ui
            val mins = secondsLeft?.let { (it + 59) / 60 }
            notice = when (code) {
                1, 2 -> if (mins != null) "Your session ends in $mins ${if (mins == 1) "minute" else "minutes"}." else "Your session time is almost up."
                4 -> "You've been idle for a while. Press something to keep playing."
                6 -> "Your session is ending."
                else -> null
            }
        }
        override fun onClosed(reason: String, error: Boolean) = ui {
            if (!mine() || phase is Phase.Ended) return@ui
            end(reason, error, canRetry = true)
        }
    }

    private fun ui(block: () -> Unit) {
        main.post(block)
    }

    // ---------- Menu ----------

    fun openMenu() {
        if (phase == null || phase is Phase.Ended || menuOpen) return
        releaseHeld()
        menuOpen = true
        input.enabled = false
        hub.captured = false
    }

    fun closeMenu() {
        if (!menuOpen) return
        menuOpen = false
        // The Start press that closed the menu must not reach the game or open it again.
        input.swallowStart()
        if (phase == Phase.Live && !inPip) {
            hub.captured = true
            input.enabled = true
        }
    }

    /** True while the on-screen keyboard types into the game. */
    var keyboardOpen by mutableStateOf(false)
        private set

    fun openKeyboard() {
        if (phase != Phase.Live) return
        closeMenu()
        releaseHeld()
        keyboardOpen = true
        input.enabled = false
        hub.captured = false
    }

    fun closeKeyboard() {
        if (!keyboardOpen) return
        keyboardOpen = false
        if (phase == Phase.Live && !menuOpen && !inPip) {
            hub.captured = true
            input.enabled = true
        }
    }

    fun type(text: String) {
        if (text.isNotEmpty()) engine?.typeText(text)
    }

    fun clearNotice() {
        notice = null
    }

    fun toggleMute() {
        muted = !muted
        engine?.muted = muted
    }

    fun stepVolume(step: Int) {
        settings.stepVolume(step)
        engine?.volume = settings.volume / 100.0
    }

    fun stepMouseSpeed(step: Int) {
        settings.stepMouseSpeed(step)
        input.mouseSpeed = settings.mouseSpeed
    }

    fun toggleControllerMouse() {
        controllerMouse = !controllerMouse
        input.controllerMouse = controllerMouse
    }

    fun sendCombo(vararg keys: Keymap.Key) {
        engine?.sendCombo(*keys)
    }

    fun refreshPicture() {
        engine?.requestKeyframe("user")
    }

    // ---------- Keyboard and mouse from the activity ----------

    // What is held down in the game right now, so it can all be let go when the menu or the
    // typing bar takes the keyboard away. Their key-up events never reach the game.
    private val heldKeys = LinkedHashSet<Keymap.Key>()
    private val heldButtons = HashSet<Int>()

    private fun releaseHeld() {
        val e = engine
        if (e != null) {
            for (k in heldKeys) e.sendKey(false, k, 0)
            for (b in heldButtons) e.sendMouseButton(false, b)
        }
        heldKeys.clear()
        heldButtons.clear()
    }

    fun key(down: Boolean, key: Keymap.Key, modifiers: Int) {
        if (menuOpen) return
        if (down) heldKeys += key else heldKeys -= key
        engine?.sendKey(down, key, modifiers)
    }

    // Fractions of a count left over from earlier moves, so slow, careful aiming isn't lost
    // to rounding.
    private var restX = 0f
    private var restY = 0f

    fun mouseMove(dx: Float, dy: Float) {
        if (menuOpen) return
        val s = settings.mouseSpeed
        restX += dx * s
        restY += dy * s
        val x = restX.toInt()
        val y = restY.toInt()
        restX -= x
        restY -= y
        engine?.sendMouseMove(x, y)
    }

    fun mouseButton(down: Boolean, button: Int) {
        if (menuOpen) return
        if (down) heldButtons += button else heldButtons -= button
        engine?.sendMouseButton(down, button)
    }

    fun wheel(delta: Int) {
        if (!menuOpen) engine?.sendWheel(delta)
    }

    // ---------- Ending ----------

    /** Leaves the stream but keeps the game running in the cloud, to resume later. */
    fun leave() {
        stopEngine()
        job?.cancel()
        finish()
        app.refreshSessions()
    }

    /**
     * Backs out of a stream that hasn't shown a picture yet. A game that was already running
     * (a reconnect, a mode change, a session picked up from elsewhere) is left running; only
     * a launch that never got going is ended.
     */
    fun cancel() {
        if (lastResume != null || liveSince != 0L) leave() else quit()
    }

    /** The activity is going away for good: stop everything, including the input thread. */
    fun close() {
        stopEngine()
        job?.cancel()
        finish()
        hub.raw = null
        input.close()
    }

    /** Ends the session on the server. */
    fun quit() {
        val s = session
        val cm = cloud
        stopEngine()
        job?.cancel()
        finish()
        scope.launch {
            if (s != null && cm != null) cm.stop(s)
            delay(800)
            app.refreshSessions()
        }
    }

    /** Ends a session running elsewhere without opening it. */
    fun quit(a: ActiveSession) {
        scope.launch {
            Cloudmatch({ app.serviceToken() }).stop(a)
            delay(800)
            app.refreshSessions()
        }
    }

    fun retry() {
        val g = lastGame
        val r = lastResume
        val s = session
        when {
            // The rig is still ours: reconnect to it rather than queueing again.
            s != null && s.ready -> reconnect(s, "Reconnecting")
            r != null -> resume(r, g)
            g != null -> play(g)
            else -> finish()
        }
    }

    /** Connects again to the rig in hand, asking for the mode that is chosen now. */
    private fun reconnect(s: CloudSession, step: String) {
        val g = lastGame
        val appId = lastResume?.appId ?: appIdOf(g)
        val a = ActiveSession(s.id, appId, 2, null, null, null, s.controlBase, s.serverIp, s.gpu)
        // Kept so a 4K way that fails here can still fall back to the web client.
        lastResume = a
        val keep = route
        begin(g) { cm ->
            phase = Phase.Starting(step)
            val (w, h, fps) = target()
            route = if (h >= 2160) routes(h).firstOrNull { it == keep || it.name == settings.route4k } ?: Route.WEB else Route.WEB
            routeFresh = false
            val size = if (route == Route.WEB && h >= 2160) Pair(2560, 1440) else Pair(w, h)
            asked(size.first, size.second, fps)
            claimed = true
            cm.claim(a, via(request().copy(appId = appId, width = size.first, height = size.second, fps = fps), route))
        }
    }

    /**
     * Changes the resolution and frame rate. With a game running, the stream reconnects to the
     * same rig at the new mode; the game itself keeps going.
     */
    fun changeMode(m: StreamMode) {
        // Picking the chosen mode again is how to ask once more for a mode the rig didn't give.
        val playingNow = playing
        if (m == settings.mode && (playingNow == null || playingNow == m)) return
        settings.chooseMode(m)
        closeMenu()
        val s = session
        if (s != null && s.ready && phase != null && phase !is Phase.Ended) reconnect(s, "Switching to ${m.label}")
    }

    private fun appIdOf(g: Game?) = g?.let { (it.variants.firstOrNull { v -> v.selected } ?: it.variants.firstOrNull())?.id ?: it.id }.orEmpty()

    fun dismiss() = finish()

    /** A background thread failed; end the stream cleanly rather than leaving it frozen. */
    fun internalFailure(t: Throwable) {
        if (phase == null || phase is Phase.Ended) return
        end("The stream stopped because of an internal error (${t.javaClass.simpleName}). Your game is still running; try again to reconnect.", error = true)
    }

    private fun end(message: String, error: Boolean, canRetry: Boolean = true) {
        if (error && fallBack(message)) return
        stopEngine()
        menuOpen = false
        keyboardOpen = false
        hub.captured = false
        phase = Phase.Ended(message, error, canRetry)
        app.refreshSessions()
    }

    /** Says so when the TV is refreshing slower than the stream, which caps what is shown. */
    private fun slowScreenNotice(): String? = runCatching {
        val hz = context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)?.refreshRate ?: return null
        if (streamFps <= 0 || hz >= streamFps - 1f) return null
        "The TV is running at ${hz.roundToInt()} Hz, so this $streamFps fps stream shows at ${hz.roundToInt()}. " +
            "Set the TV's output to $streamFps Hz to see every frame."
    }.getOrNull()

    private fun finish() {
        streamFps = 0
        menuOpen = false
        keyboardOpen = false
        hub.captured = false
        phase = null
        session = null
        game = null
        lastResume = null
        claimed = false
        stats = StreamStats.Empty
        controllerMouse = false
        input.controllerMouse = false
        route = Route.WEB
        routeFresh = false
        skipped.clear()
        pendingNote = null
    }

    private companion object {
        const val NO_SOUND = "Sound is off after an earlier crash. Settings, Stream can turn it back on."
    }

    private fun stopEngine() {
        CrashLog.markStreaming(context, null)
        input.enabled = false
        input.engine = null
        input.reset()
        heldKeys.clear()
        heldButtons.clear()
        engine?.stop()
        engine = null
        inputReady = false
    }
}
