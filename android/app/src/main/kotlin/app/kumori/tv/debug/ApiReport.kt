package app.kumori.tv.debug

import android.content.Context
import android.os.Build
import android.os.SystemClock
import app.kumori.tv.BuildConfig
import app.kumori.tv.Settings
import app.kumori.tv.data.AppState
import app.kumori.tv.data.Game
import app.kumori.tv.data.History
import app.kumori.tv.data.SessionLog
import app.kumori.tv.input.PadHub
import app.kumori.tv.stream.StreamStats
import app.kumori.tv.stream.Streamer
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * What the local API and the saved log say, built from the app's live state. Values that
 * aren't known are left out rather than sent as zero. Nothing secret goes in: no tokens, no
 * session addresses, no email. Field names match the Apple TV app's, so one script reads both.
 */
class ApiReport(
    private val context: Context,
    private val app: AppState,
    private val streamer: Streamer,
    private val settings: Settings,
    private val hub: PadHub,
) {
    companion object {
        fun iso(ms: Long): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).apply { timeZone = TimeZone.getDefault() }.format(Date(ms))
        private fun r1(v: Double?): Any = v?.let { Math.round(it * 10) / 10.0 } ?: JSONObject.NULL
        private fun JSONObject.opt(k: String, v: Any?): JSONObject = if (v == null) this else put(k, v)
    }

    fun index(): JSONObject = JSONObject()
        .put("app", "Kumori")
        .put("platform", "Android TV")
        .put("version", BuildConfig.VERSION_NAME)
        .put("build", BuildConfig.VERSION_CODE)
        .put("port", LocalApi.PORT)
        .put("readOnly", true)
        .put("endpoints", JSONArray().apply { for ((p, w) in LocalApi.ENDPOINTS) put(JSONObject().put("path", p).put("description", w)) })

    private fun phaseName(): String = when (val p = streamer.phase) {
        null -> "idle"
        is Streamer.Phase.Starting -> "starting"
        is Streamer.Phase.Queued -> "queued"
        is Streamer.Phase.Connecting -> "connecting"
        Streamer.Phase.Live -> "live"
        is Streamer.Phase.Ended -> if (p.error) "failed" else "ended"
    }

    private fun playingFor(): Long? = streamer.liveSince.takeIf { it > 0 }?.let { (SystemClock.elapsedRealtime() - it) / 1000 }

    fun status(): JSONObject {
        val d = JSONObject()
            .put("signedIn", app.signedIn)
            .put("phase", phaseName())
            .put("menuOpen", streamer.menuOpen)
            .put("idleEndMinutes", settings.idleMinutes)
            .put("time", iso(System.currentTimeMillis()))
        streamer.game?.let { d.put("game", JSONObject().put("id", it.id).put("title", it.title)) }
        when (val p = streamer.phase) {
            is Streamer.Phase.Queued -> d.put("queuePosition", p.position)
            is Streamer.Phase.Starting -> d.put("step", p.step)
            is Streamer.Phase.Connecting -> d.put("step", p.step)
            is Streamer.Phase.Ended -> d.put("message", p.message)
            else -> Unit
        }
        d.opt("playingForSeconds", playingFor())
        app.membership?.let { m ->
            d.put("unlimited", m.unlimited)
            if (!m.unlimited) streamer.hoursLeft()?.let { d.put("hoursLeft", r1(it)) }
        }
        d.opt("idleSecondsLeft", streamer.idleSecondsLeft)
        d.opt("notice", streamer.notice)
        return d
    }

    fun stats(s: StreamStats = streamer.stats): JSONObject {
        val live = streamer.phase != null && s.width > 0
        val d = JSONObject()
            .put("live", live)
            .put("framesDecoded", s.framesDecoded)
            .put("belowTarget", streamer.belowTarget != null)
        if (s.width > 0) d.put("width", s.width).put("height", s.height)
        if (streamer.streamFps > 0) d.put("targetFps", streamer.streamFps)
        s.fps?.let { d.put("fps", r1(it)).put("shownFps", r1(it)) }
        s.receivedFps?.let { d.put("receivedFps", r1(it)) }
        s.fps?.let { d.put("decodedFps", r1(it)) }
        context.display?.refreshRate?.let { d.put("refreshHz", r1(it.toDouble())) }
        d.put("framesDropped", s.framesSkipped)
        d.put("framesDroppedDecoder", s.framesDropped)
        d.opt("codec", s.codec)
        d.opt("codecDetail", s.decoder)
        d.put("hardwareDecode", s.decoder?.let { !it.startsWith("c2.android") && !it.startsWith("OMX.google") } ?: JSONObject.NULL)
        d.opt("transport", s.transport)
        s.bitrateMbps?.let { d.put("bitrateMbps", r1(it)) }
        s.rttMs?.let { d.put("rttMs", r1(it)) }
        s.jitterMs?.let { d.put("jitterMs", r1(it)) }
        s.packetLossPct?.let { d.put("lossPct", Math.round(it * 100) / 100.0) }
        d.put("packetsLost", s.packetsLost)
        d.put("packetsResent", s.nacks)
        s.decodeMs?.let { d.put("decodeMs", r1(it)) }
        d.put("freezes", s.freezes)
        d.put("quality", s.quality.label)
        streamer.belowTarget?.let { d.put("belowTargetText", it) }
        return d
    }

    fun statsHistory(): JSONObject {
        val list = synchronized(streamer.statsHistory) { streamer.statsHistory.toList() }
        return JSONObject().put("samples", JSONArray().apply {
            for ((at, s) in list) {
                put(
                    JSONObject().put("at", iso(at))
                        .apply {
                            s.fps?.let { put("fps", r1(it)) }
                            s.rttMs?.let { put("rttMs", r1(it)) }
                            s.bitrateMbps?.let { put("bitrateMbps", r1(it)) }
                            s.packetLossPct?.let { put("lossPct", Math.round(it * 100) / 100.0) }
                            put("framesDropped", s.framesSkipped + s.framesDropped)
                        },
                )
            }
        })
    }

    fun session(): JSONObject {
        val d = JSONObject().put("phase", phaseName())
        streamer.game?.let { d.put("game", game(it)) }
        streamer.session?.let { s ->
            d.put(
                "cloud",
                JSONObject().put("status", s.status)
                    .put("transport", if (s.rtsps.isNotEmpty() && s.signalingUrl == null) "native" else "webrtc")
                    .apply {
                        if (s.width != null && s.height != null) put("width", s.width).put("height", s.height)
                        s.fps?.let { put("fps", it) }
                        s.gpu?.let { put("gpu", it) }
                        s.queuePosition?.let { put("queuePosition", it) }
                    },
            )
        }
        d.put(
            "requested",
            JSONObject().put("resolution", settings.mode.resolution.label).put("fps", settings.mode.fps)
                .put("codec", settings.codec.label).put("bitrateMbps", settings.bitrateMbps),
        )
        streamer.playing?.let { d.put("playing", JSONObject().put("resolution", it.resolution.label).put("fps", it.fps)) }
        d.opt("playingForSeconds", playingFor())
        return d
    }

    fun sessions(): JSONObject = JSONObject().put("sessions", JSONArray().apply {
        for (s in app.sessions) {
            put(JSONObject().put("status", s.status).put("appId", s.appId).apply {
                app.gameFor(s)?.let { put("title", it.title) }
                s.resolution?.let { put("resolution", it) }
                s.fps?.let { put("fps", it) }
                s.gpu?.let { put("gpu", it) }
            })
        }
    })

    fun history(): JSONObject = JSONObject().put("streams", JSONArray().apply {
        for (r in History.all()) {
            put(
                JSONObject()
                    .put("startedAt", iso(r.startedAt))
                    .put("endedAt", iso(r.endedAt))
                    .put("seconds", r.seconds)
                    .put("endedBy", r.endedBy)
                    .put("title", r.game)
                    .put("mode", r.mode)
                    .put("framesDropped", r.framesDropped)
                    .apply {
                        r.gameId?.let { put("gameId", it) }
                        r.codec?.let { put("codec", it) }
                        r.avgFps?.let { put("averageFps", r1(it)) }
                        r.minFps?.let { put("minimumFps", r1(it)) }
                        r.avgRttMs?.let { put("averageRttMs", r1(it)) }
                        r.avgMbps?.let { put("averageMbps", r1(it)) }
                    },
            )
        }
    })

    fun game(g: Game): JSONObject = JSONObject()
        .put("id", g.id)
        .put("title", g.title)
        .put("genres", JSONArray(g.genres))
        .apply {
            g.publisher?.let { put("publisher", it) }
            g.store?.let { put("store", it) }
            if (g.lastPlayedMs > 0) put("lastPlayed", iso(g.lastPlayedMs))
            g.description?.let { put("summary", it) }
            g.boxArt?.let { put("boxArt", it) }
            g.hero?.let { put("hero", it) }
        }

    fun games(): JSONObject = JSONObject().put("count", app.library.size).put("games", JSONArray().apply {
        for (g in app.library) {
            put(JSONObject().put("id", g.id).put("title", g.title).apply {
                g.store?.let { put("store", it) }
                if (g.lastPlayedMs > 0) put("lastPlayed", iso(g.lastPlayedMs))
                if (app.sessionFor(g) != null) put("runningInCloud", true)
            })
        }
    })

    fun game(id: String): JSONObject? {
        val all = app.library + app.featured + app.shelves.flatMap { it.games }
        return all.firstOrNull { it.id == id || it.variants.any { v -> v.id == id } }?.let(::game)
    }

    fun settings(): JSONObject = JSONObject()
        .put("resolution", settings.mode.resolution.label)
        .put("width", settings.mode.width)
        .put("height", settings.mode.height)
        .put("fps", settings.mode.fps)
        .put("codec", settings.codec.label)
        .put("bitrateMbps", settings.bitrateMbps)
        .put("region", settings.region.ifEmpty { "Automatic" })
        .put("stats", settings.stats.label)
        .put("statsPosition", settings.statsCorner.label)
        .put("idleEndMinutes", settings.idleMinutes)
        .put("videoOutput", settings.videoPath.label)
        .put("framePacing", settings.framePacing.label)
        .put("tenBit", settings.tenBit)
        .put("highestRefreshRate", settings.maxRefresh)
        .put("reflex", settings.lowLatency)
        .put("gameLanguage", settings.language.label)
        .put("volume", settings.volume)
        .put("mouseSpeed", settings.mouseSpeed.toDouble())
        .put("holdStartMs", settings.holdToOpenMs)
        .put(
            "dlss",
            JSONObject().put("model", settings.dlssModel.label).put("quality", settings.dlssQuality.label)
                .put("rayReconstruction", settings.dlssRays.label).put("frameGeneration", settings.dlssFrames.label),
        )
        .put("route4k", settings.route4k ?: "none")

    fun account(): JSONObject {
        val d = JSONObject().put("signedIn", app.signedIn)
        app.profile?.let { d.put("name", it.name) }
        app.membership?.let { m ->
            m.tier?.let { d.put("plan", it) }
            d.put("unlimited", m.unlimited)
            m.hoursLeft?.let { d.put("hoursLeftReported", r1(it)) }
            if (app.membershipReadAtMs > 0) d.put("reportedAt", iso(app.membershipReadAtMs))
            d.put("modes", JSONArray().apply { for (x in m.modes) put(JSONObject().put("width", x.width).put("height", x.height).put("fps", x.fps)) })
            if (!m.unlimited) streamer.hoursLeft()?.let { d.put("hoursLeft", r1(it)) }
        }
        d.put("regions", JSONArray().apply { for (r in app.regions) put(JSONObject().put("name", r.name).apply { r.pingMs?.let { put("pingMs", it) } }) })
        return d
    }

    fun device(): JSONObject = JSONObject()
        .put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
        .put("android", Build.VERSION.RELEASE)
        .put("api", Build.VERSION.SDK_INT)
        .apply { LocalApi.address()?.let { put("address", it) } }
        .put("chain", DisplayChain.read(context).json())

    fun launch(): JSONObject = JSONObject()
        .put("steps", JSONArray(SessionLog.all()))
        .put("last4k", JSONArray(settings.log4k.lines().filter { it.isNotBlank() }))

    fun input(): JSONObject = JSONObject().put("controllers", JSONArray().apply {
        for (p in hub.pads.value) put(JSONObject().put("name", p.name).put("connection", p.route).put("player", p.slot + 1).put("reportsPerSecond", p.reportsPerSecond))
    })
}
