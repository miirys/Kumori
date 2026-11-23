package app.kumori.tv.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.util.TimeZone
import java.util.UUID

/** Where to reach the streaming server once a seat is ready. */
data class Endpoint(val ip: String, val port: Int)

data class IceSpec(val urls: List<String>, val username: String?, val credential: String?)

/** One session as the session service describes it. */
data class CloudSession(
    val id: String,
    /** 1 setting up or queued, 2 ready, 3 streaming. */
    val status: Int,
    val queuePosition: Int?,
    val setupStep: Int?,
    /** Base URL for polling and ending this session. */
    val controlBase: String,
    val serverIp: String?,
    val signalingUrl: String?,
    val media: Endpoint?,
    val ice: List<IceSpec>,
    val gpu: String?,
    val width: Int?,
    val height: Int?,
    val fps: Int?,
    val adsRequired: Boolean,
    /** Control endpoints of NVIDIA's native streaming protocol, when the rig offers it. */
    val rtsps: List<String> = emptyList(),
    /** The rig's media endpoint for native streaming, when the service names one. */
    val nativeMedia: Endpoint? = null,
) {
    val ready: Boolean get() = status == 2 || status == 3
}

class SessionException(
    message: String,
    val statusCode: Int = 0,
    val http: Int = 0,
    /** The service's own wording, e.g. INTERNAL_ERROR; useful for deciding whether to retry. */
    val description: String? = null,
) : Exception(message) {
    /** About the account itself, so asking again in a different way won't help. */
    val account: Boolean
        get() = statusCode in ACCOUNT_CODES || http == 401 || http == 403

    /** A server-side failure that a smaller, simpler stream request often avoids. */
    val retryable: Boolean
        get() = statusCode == 3 || statusCode == 4 || statusCode == 5 || statusCode == 8 || http >= 500 ||
            description?.contains("INTERNAL", ignoreCase = true) == true

    /**
     * The service turned this stream shape down (10-bit, the frame rate, the size) without it
     * being about the account, so a simpler shape is still worth asking for.
     */
    val stepDown: Boolean
        get() = retryable || statusCode == 2 || statusCode == 18 || statusCode == 68

    private companion object {
        val ACCOUNT_CODES = setOf(7, 11, 50, 10, 13, 14, 15, 16, 17, 37, 38, 23, 24, 56, 26, 27, 28, 29, 30, 31, 32, 33, 45, 52, 53, 63, 35)
    }
}

/**
 * Who we say we are when asking for a rig. GeForce NOW keeps a separate list of stream sizes
 * for each kind of client, so the same account gets different answers.
 */
enum class Route {
    /** Chrome on a PC. Always streams over WebRTC, up to 1440p at 120 fps. */
    WEB,

    /** The smart TV app, which is a web client too. NVIDIA lists it up to 4K at 120 fps. */
    TV,

    /** The PC app's list of sizes, with the stream still asked for over WebRTC. */
    DESKTOP,

    /** The PC app, streaming with NVIDIA's own protocol. */
    NATIVE;

    val webrtc: Boolean get() = this != NATIVE
}

/** Asks for the stream the user picked; [kbps] caps the video bitrate. */
data class LaunchRequest(
    val appId: String,
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitDepth: Int,
    val lowLatencyMode: Boolean,
    val language: String = "en_US",
    val keyboard: String = "en-US",
    val title: String? = null,
    /** Whether the game is in the user's library on its store; unowned games must say false. */
    val accountLinked: Boolean = true,
    val route: Route = Route.WEB,
    /** Only [Route.NATIVE] sends these two: its handshake must agree with what was allocated. */
    /** "H264", "H265" or "AV1". */
    val codec: String = "H265",
    val maxKbps: Int = 75_000,
    val dlss: DlssOverrides = DlssOverrides(),
)

/**
 * DLSS settings the cloud rig forces on a game, with the numbers the official client sends.
 * Zero leaves a setting to the game. Models: 1 is NVIDIA's recommended one, 12 to 14 are
 * presets K, L and M. Quality: 1 Performance, 2 Balanced, 3 Quality, 4 Ultra Performance, 5 DLAA.
 */
data class DlssOverrides(
    val srModel: Int = 0,
    val srMode: Int = 0,
    val rrModel: Int = 0,
    val fgModel: Int = 0,
    /** 3 to 6 turns on dynamic frame generation up to that many frames; 0 leaves it off. */
    val fgMultiplier: Int = 0,
) {
    fun json(): JSONObject {
        // A model left to the game leaves its mode to the game as well.
        val mode = if (srModel == 0) 0 else srMode
        val scale = when (mode) { 1 -> 50; 2 -> 58; 3 -> 67; 4 -> 33; else -> 100 }
        val dynamic = fgModel != 0 && fgMultiplier in 3..6
        return JSONObject()
            .put("srMode", mode)
            .put("srModel", srModel)
            .put("srScale", scale)
            .put("rrModel", rrModel)
            .put("fgMode", if (dynamic) 1 else 0)
            .put("fgModel", fgModel)
            .apply { if (dynamic) put("fgMultiplier", fgMultiplier) }
    }
}

/**
 * The GeForce NOW session service: start a game on a cloud rig, follow it through the queue,
 * pick up one started elsewhere, and end it.
 */
class Cloudmatch(private val token: suspend () -> String) {

    // The same ids for every request this box makes, as the PC app keeps them, so the session
    // list, the session and the request that ends it all name the same device. A session asked
    // for under one id and ended under another can be refused or left running.
    private val clientId = stableId("cloudmatchClientId")
    private val deviceId = stableId("device")

    /** How this session was asked for. Follow-up calls must look like the same client. */
    @Volatile private var route = Route.WEB

    private fun headers(b: Request.Builder, t: String, origin: Boolean, asked: Route? = null): Request.Builder {
        val route = asked ?: this.route
        val web = route == Route.WEB || route == Route.TV
        b.header("User-Agent", if (route == Route.TV) TV_UA else BROWSER_UA)
            .header("Authorization", "GFNJWT $t")
            .header("Content-Type", "application/json")
            .header("nv-browser-type", "CHROME")
            .header("nv-client-id", clientId)
            .header("nv-client-streamer", if (web) "WEBRTC" else "NVIDIA-CLASSIC")
            .header("nv-client-type", if (web) "BROWSER" else "NATIVE")
            .header("nv-client-version", VERSION)
            .header("nv-device-make", if (route == Route.TV) "LG" else "UNKNOWN")
            .header("nv-device-model", "UNKNOWN")
            .header("nv-device-os", if (route == Route.TV) "WEBOS" else "WINDOWS")
            .header("nv-device-type", if (route == Route.TV) "TV" else "DESKTOP")
            .header("x-device-id", deviceId)
        if (origin) {
            b.header("Origin", "https://play.geforcenow.com").header("Referer", "https://play.geforcenow.com/")
        }
        return b
    }

    suspend fun create(streamingBase: String, r: LaunchRequest): CloudSession = io {
        if (r.appId.toLongOrNull() == null) throw SessionException("This game can't be launched from here yet.")
        route = r.route
        val base = streamingBase.trimEnd('/')
        val url = "$base/v2/session?keyboardLayout=${r.keyboard}&languageCode=${r.language}"
        val req = headers(Request.Builder().url(url), token(), origin = true)
            .post(createBody(r).toString().toRequestBody(JSON))
            .build()
        val s = parse(send(req), base)
        // The request runs to the end even when the caller has given up (Back during
        // "Requesting a rig"). Nobody would ever hear of that session, and it would block the
        // next launch, so give it back here.
        if (!currentCoroutineContext().isActive) {
            runCatching { send(headers(Request.Builder().url("${s.controlBase}/v2/session/${s.id}"), token(), false).delete().build()) }
            throw CancellationException("gave up while the rig was being requested")
        }
        s
    }

    /**
     * How a session listed for the account is doing right now, asked as [route]. Null when the
     * service can't be reached; throws when the session is gone.
     */
    suspend fun peek(active: ActiveSession, route: Route): CloudSession? = io {
        this.route = route
        val base = "https://${active.serverHost ?: hostOf(active.streamingBase)}"
        try {
            parse(send(headers(Request.Builder().url("$base/v2/session/${active.sessionId}"), token(), false).build()), base)
        } catch (e: SessionException) {
            if (e.http == 404) throw SessionException("That session has ended.", e.statusCode, e.http, e.description)
            null
        } catch (e: java.io.IOException) {
            null
        }
    }

    /** Follows a session. Once a seat is ready we talk to that rig directly, not the load balancer. */
    suspend fun poll(s: CloudSession): CloudSession = io {
        val t = token()
        val next = parse(send(headers(Request.Builder().url("${s.controlBase}/v2/session/${s.id}"), t, false).build()), s.controlBase)
        val direct = next.serverIp
        if (next.ready && isZoneHost(hostOf(s.controlBase)) && direct != null && !isZoneHost(direct)) {
            val base = "https://$direct"
            runCatching {
                parse(send(headers(Request.Builder().url("$base/v2/session/${s.id}"), t, false).build()), base)
            }.getOrDefault(next.copy(controlBase = base))
        } else {
            next
        }
    }

    /** Takes over a session running on another device (or left running here) and waits for its seat. */
    suspend fun claim(active: ActiveSession, r: LaunchRequest): CloudSession = io {
        route = r.route
        val t = token()
        var host = active.serverHost ?: hostOf(active.streamingBase)
        // The listing names the region's load balancer; ask it for the rig itself first.
        if (isZoneHost(host)) {
            runCatching {
                val pre = parse(send(headers(Request.Builder().url("https://$host/v2/session/${active.sessionId}"), t, false).build()), "https://$host")
                pre.serverIp?.let { host = it }
            }
        }
        val base = "https://$host"
        val current = runCatching {
            parse(send(headers(Request.Builder().url("$base/v2/session/${active.sessionId}"), t, false).build()), base)
        }.getOrNull()
        // A session still being set up can't be resumed, only followed.
        if (current?.status != 1) {
            val url = "$base/v2/session/${active.sessionId}?keyboardLayout=${r.keyboard}&languageCode=${r.language}"
            val req = headers(Request.Builder().url(url), t, origin = true)
                .put(claimBody(active.appId, r).toString().toRequestBody(JSON))
                .build()
            parse(send(req), base)
        }
        repeat(90) { attempt ->
            if (attempt > 0) delay(1000)
            val s = try {
                parse(send(headers(Request.Builder().url("$base/v2/session/${active.sessionId}"), token(), false).build()), base)
            } catch (e: SessionException) {
                // The service answered and said no: the session is gone, so stop waiting for it.
                if (e.http == 404 || e.statusCode != 0) throw e
                null
            } catch (e: java.io.IOException) {
                null
            }
            if (s != null && s.ready) return@io s
            if (s != null && s.status !in 1..3) throw SessionException("The session has ended.")
        }
        throw SessionException("The session didn't come back. It may have ended on the other device.")
    }

    suspend fun stop(s: CloudSession) = end(s.id, listOf(s.controlBase))

    suspend fun stop(active: ActiveSession) = end(active.sessionId, endBases(active))

    /**
     * Ends a session, asking each place in turn until one takes it: as the client the session
     * was started with, then as the PC app and the TV app, since a session started one way can
     * refuse an end asked another way. A session the service no longer knows counts as ended.
     * True when it is gone.
     */
    suspend fun end(id: String, bases: List<String>): Boolean = io {
        val t = runCatching { token() }.getOrElse {
            SessionLog.ended("no token", null, false)
            return@io false
        }
        val identities = listOf(route, Route.NATIVE, Route.TV, Route.WEB).distinct()
        var n = 0
        for (base in bases.map { it.trimEnd('/') }.filter { it.isNotEmpty() }.distinct()) {
            for (who in identities) {
                n++
                try {
                    send(headers(Request.Builder().url("$base/v2/session/$id"), t, false, who).delete().build())
                    SessionLog.ended("try $n as $who", 200, true)
                    return@io true
                } catch (e: SessionException) {
                    if (e.http == 404) {
                        SessionLog.ended("already gone, try $n as $who", 404, true)
                        return@io true
                    }
                    SessionLog.ended("refused, try $n as $who, status ${e.statusCode}", e.http, false)
                } catch (e: java.io.IOException) {
                    SessionLog.ended("${e.javaClass.simpleName}, try $n", null, false)
                }
            }
        }
        false
    }

    // ---------- Bodies ----------

    private fun meta(vararg kv: Pair<String, String>) = JSONArray().apply {
        for ((k, v) in kv) put(JSONObject().put("key", k).put("value", v))
    }

    private fun timezoneMs() = TimeZone.getDefault().getOffset(System.currentTimeMillis()).toLong()

    private fun monitor(r: LaunchRequest): JSONObject = JSONObject()
            // The full desktop monitor descriptor, which makes the service offer its whole
            // resolution matrix (4K and 120 fps included) to the web client.
            .put("monitorId", 0)
            .put("positionX", 0)
            .put("positionY", 0)
            .put("widthInPixels", r.width)
            .put("heightInPixels", r.height)
            .put("framesPerSecond", r.fps)
            .put("sdrHdrMode", 0)
            .put(
                "displayData",
                JSONObject().put("desiredContentMaxLuminance", 0).put("desiredContentMinLuminance", 0).put("desiredContentMaxFrameAverageLuminance", 0),
            )
            .put("dpi", 100)

    private fun features(r: LaunchRequest): JSONObject = JSONObject()
            .put("reflex", r.lowLatencyMode && r.fps >= 120)
            .put("bitDepth", if (r.bitDepth >= 10) 10 else 0)
            .put("cloudGsync", false)
            .put("enabledL4S", false)
            .put("mouseMovementFlags", 0)
            .put("trueHdr", false)
            .put("supportedHidDevices", 0)
            .put("profile", 0)
            .put("fallbackToLogicalResolution", false)
            .put("hidDevices", JSONObject.NULL)
            .put("chromaFormat", 0)
            .put("prefilterMode", 0)
            .put("prefilterSharpness", 0)
            .put("prefilterNoiseReduction", 0)
            .put("hudStreamingMode", 0)
            .put("sdrColorSpace", 2)
            .put("hdrColorSpace", 0)
            .apply {
                if (r.route == Route.NATIVE) {
                    put("codec", when (r.codec.uppercase()) { "H264" -> 1; "AV1" -> 3; else -> 2 })
                    put("maxBitrateKbps", r.maxKbps)
                    put("vsync", false)
                    put("audioChannelCount", 2)
                    put("qosPolicy", 0)
                    put("touchSupport", true)
                    put("dynamicStreamingMode", 0)
                }
            }

    /** The session's metadata; native sessions leave out the WebRTC streamer marker. */
    private fun sessionMeta(r: LaunchRequest) = meta(
        *listOfNotNull(
            "SubSessionId" to UUID.randomUUID().toString(),
            "wssignaling" to "1",
            if (r.route == Route.NATIVE) null else "GSStreamerType" to "WebRTC",
            "networkType" to "Unknown",
            "ClientImeSupport" to "0",
            "clientPhysicalResolution" to JSONObject().put("horizontalPixels", r.width).put("verticalPixels", r.height).toString(),
            "surroundAudioInfo" to "2",
        ).toTypedArray(),
    )

    /** How the stream travels. The allocation must agree with the handshake that follows. */
    private fun JSONObject.transport(r: LaunchRequest): JSONObject {
        if (r.route == Route.NATIVE) {
            put("streamerVersion", "14").put("sdkVersion", "2.0").put("enhancedStreamMode", 0)
            put("secureRTSPSupported", true).put("requestedAudioFormat", 0).put("transport", JSONObject.NULL)
        } else {
            put("streamerVersion", 1).put("sdkVersion", "1.0").put("enhancedStreamMode", 1)
            put("secureRTSPSupported", false)
        }
        return this
    }

    private fun platform(r: LaunchRequest) = if (r.route == Route.NATIVE || r.route == Route.DESKTOP) "windows" else "browser"

    private fun createBody(r: LaunchRequest): JSONObject {
        val monitor = monitor(r)
        // Only a new session carries these. Picking one up keeps what it was started with.
        val features = features(r).put("dlssOverrides", r.dlss.json())
        val data = JSONObject()
            .put("appId", r.appId.toLong())
            .put("internalTitle", r.title ?: JSONObject.NULL)
            .put("availableSupportedControllers", JSONArray())
            .put("networkTestSessionId", JSONObject.NULL)
            .put("parentSessionId", JSONObject.NULL)
            .put("clientIdentification", "GFN-PC")
            .put("deviceHashId", deviceId)
            .put("clientVersion", "30.0")
            .transport(r)
            .put("clientPlatformName", platform(r))
            .put("clientRequestMonitorSettings", JSONArray().put(monitor))
            .put("useOps", true)
            .put("audioMode", 2)
            .put("metaData", sessionMeta(r))
            .put("sdrHdrMode", 0)
            .put("clientDisplayHdrCapabilities", JSONObject.NULL)
            .put("surroundAudioInfo", 0)
            .put("remoteControllersBitmap", 0)
            .put("clientTimezoneOffset", timezoneMs())
            .put("appLaunchMode", 1)
            .put("partnerCustomData", "")
            .put("accountLinked", r.accountLinked)
            .put("enablePersistingInGameSettings", r.route == Route.NATIVE || r.route == Route.DESKTOP)
            .put("userAge", 26)
            .put("requestedStreamingFeatures", features)
        return JSONObject().put("sessionRequestData", data)
    }

    /**
     * Taking over a session asks for this device's stream shape, so a game started elsewhere
     * comes back at the quality chosen here rather than the service's 1080p default.
     */
    private fun claimBody(appId: String, r: LaunchRequest): JSONObject {
        val features = features(r)
        val data = JSONObject()
            .put("clientRequestMonitorSettings", JSONArray().put(monitor(r)))
            .put("audioMode", 2)
            .put("remoteControllersBitmap", 0)
            .put("sdrHdrMode", 0)
            .put("networkTestSessionId", JSONObject.NULL)
            .put("availableSupportedControllers", JSONArray())
            .put("clientVersion", "30.0")
            .put("deviceHashId", UUID.randomUUID().toString())
            .put("internalTitle", JSONObject.NULL)
            .put("clientPlatformName", platform(r))
            .put("metaData", sessionMeta(r))
            .put("surroundAudioInfo", 0)
            .put("clientTimezoneOffset", timezoneMs())
            .put("clientIdentification", "GFN-PC")
            .put("parentSessionId", JSONObject.NULL)
            .put("appId", appId.toLongOrNull() ?: 0L)
            .transport(r)
            .put("appLaunchMode", 1)
            .put("useOps", true)
            .put("clientDisplayHdrCapabilities", JSONObject.NULL)
            .put("accountLinked", true)
            .put("partnerCustomData", "")
            .put("enablePersistingInGameSettings", r.route == Route.NATIVE || r.route == Route.DESKTOP)
            .put("userAge", 26)
            .put("requestedStreamingFeatures", features)
        return JSONObject().put("action", 2).put("data", "RESUME").put("sessionRequestData", data).put("metaData", JSONArray())
    }

    // ---------- Parsing ----------

    private fun send(req: Request): JSONObject {
        Nvidia.http.newCall(req).execute().use { r ->
            val text = r.body?.string().orEmpty()
            val j = runCatching { JSONObject(text) }.getOrNull()
            val status = j?.optJSONObject("requestStatus")
            val code = status?.optInt("statusCode", 0) ?: 0
            if (!r.isSuccessful || (status != null && code != 1)) {
                val desc = status?.str("statusDescription")?.takeIf { it.isNotBlank() && it != "null" }
                val unified = status?.opt("unifiedErrorCode")?.let { u ->
                    (u as? Number)?.toLong()?.let { java.lang.Long.toHexString(it).uppercase() } ?: u.toString()
                }
                android.util.Log.w("Session", "${req.method} ${req.url.encodedPath} -> HTTP ${r.code}, status $code, $desc, unified $unified")
                throw SessionException(message(code, desc, r.code, unified), code, r.code, desc)
            }
            return j ?: throw SessionException("The session service sent an unreadable answer.", 0, r.code)
        }
    }

    private fun parse(j: JSONObject, base: String): CloudSession {
        val s = j.optJSONObject("session") ?: throw SessionException("The session service didn't describe the session.")
        val conns = s.optJSONArray("connectionInfo") ?: JSONArray()
        val list = (0 until conns.length()).mapNotNull { conns.optJSONObject(it) }
        // The WebRTC signaling endpoint: a wss or https entry first (RTSPS entries belong to the
        // native transport), then the signaling usages 14 and 16.
        fun usage(c: JSONObject) = c.str("usage").toIntOrNull() ?: c.optInt("usage", -1)
        val signal = list.firstOrNull { c ->
            val r = c.str("resourcePath")
            (r.startsWith("wss://") || r.startsWith("https://")) && usage(c) in listOf(14, 16)
        } ?: list.firstOrNull { usage(it) == 14 } ?: list.firstOrNull { usage(it) == 16 }
        val serverIp = signal?.let { ipOf(it) ?: it.str("resourcePath").takeIf(String::isNotBlank)?.let(::hostOfUrl) }
            ?: firstString(s.optJSONObject("sessionControlInfo")?.opt("ip"))
        val monitor = s.optJSONArray("monitorSettings")?.optJSONObject(0)
            ?: s.optJSONObject("sessionRequestData")?.optJSONArray("clientRequestMonitorSettings")?.optJSONObject(0)
        return CloudSession(
            id = s.str("sessionId"),
            status = s.optInt("status", 0),
            queuePosition = queue(s),
            setupStep = s.optJSONObject("seatSetupInfo")?.optInt("seatSetupStep", -1)?.takeIf { it >= 0 },
            controlBase = base,
            serverIp = serverIp,
            signalingUrl = serverIp?.let { signalingUrl(signal?.str("resourcePath").orEmpty(), it) },
            media = media(list, serverIp),
            ice = ice(s),
            gpu = s.str("gpuType").takeIf { it.isNotBlank() && it != "null" },
            width = monitor?.optInt("widthInPixels")?.takeIf { it > 0 },
            height = monitor?.optInt("heightInPixels")?.takeIf { it > 0 },
            fps = monitor?.optInt("framesPerSecond")?.takeIf { it > 0 },
            adsRequired = s.optBoolean("sessionAdsRequired", false) || s.optBoolean("isAdsRequired", false),
            rtsps = rtspEndpoints(list),
            nativeMedia = nativeMedia(list, serverIp),
        )
    }

    private fun isRtsp(c: JSONObject): Boolean {
        val r = c.str("resourcePath")
        return r.startsWith("rtsps://") || r.startsWith("rtsp://") || c.str("usage") == "16" ||
            c.str("appLevelProtocol") in listOf("1", "6")
    }

    /**
     * The native protocol's control endpoints, in the service's order: usage 16, or usage 14
     * carrying RTSP. Media entries are left out even when their address looks like a URL.
     */
    private fun rtspEndpoints(list: List<JSONObject>): List<String> = list.mapNotNull { c ->
        val usage = c.str("usage").toIntOrNull()
        val protocol = c.str("appLevelProtocol").toIntOrNull()
        if (usage != null && usage != 16 && !(usage == 14 && protocol in listOf(1, 6))) return@mapNotNull null
        if (usage == null && !isRtsp(c)) return@mapNotNull null
        val address = ipOf(c)?.trim()?.takeIf { it.isNotEmpty() }
            ?: c.str("resourcePath").trim().takeIf { it.isNotEmpty() } ?: return@mapNotNull null
        val scheme = if (protocol == 1) "rtsp" else "rtsps"
        val uri = runCatching {
            URI(if ("://" in address) address else {
                val host = if (address.count { it == ':' } > 1 && !address.startsWith("[")) "[$address]" else address
                "$scheme://$host"
            })
        }.getOrNull() ?: return@mapNotNull null
        if (uri.scheme !in listOf("rtsp", "rtsps") || uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return@mapNotNull null
        val host = uri.host?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
        val port = c.optInt("port", 0).takeIf { it in 1..65535 } ?: uri.port.takeIf { it in 1..65535 } ?: 322
        "${uri.scheme}://${if (':' in host && !host.startsWith("[")) "[$host]" else host}:$port"
    }.distinct().take(20)

    /** The media endpoint for native streaming. A control (RTSP) entry is never the media peer. */
    private fun nativeMedia(list: List<JSONObject>, serverIp: String?): Endpoint? {
        fun from(c: JSONObject, fallback: String?): Endpoint? {
            val ip = ipOf(c) ?: c.str("resourcePath").takeIf(String::isNotBlank)?.let(::hostOfUrl) ?: fallback ?: return null
            val port = portOf(c)
            return if (port > 0) Endpoint(ip, port) else null
        }
        list.firstOrNull { it.optInt("usage") == 2 }?.let { c -> from(c, null)?.let { return it } }
        list.firstOrNull { it.optInt("usage") == 17 }?.let { c -> from(c, null)?.let { return it } }
        for (c in list.filter { it.str("usage") == "14" && !isRtsp(it) }.sortedByDescending { it.optInt("port") }) {
            from(c, serverIp)?.let { return it }
        }
        return null
    }

    private fun queue(s: JSONObject): Int? {
        fun pos(o: JSONObject?) = o?.optInt("queuePosition", 0)?.takeIf { it > 0 }
        return pos(s) ?: pos(s.optJSONObject("seatSetupInfo")) ?: pos(s.optJSONObject("sessionProgress")) ?: pos(s.optJSONObject("progressInfo"))
    }

    private fun firstString(v: Any?): String? = when (v) {
        is String -> v.takeIf { it.isNotBlank() }
        is JSONArray -> v.optString(0).takeIf { it.isNotBlank() }
        else -> null
    }

    private fun ipOf(c: JSONObject) = firstString(c.opt("ip"))

    private fun portOf(c: JSONObject): Int {
        val p = c.optInt("port", 0)
        if (p > 0) return p
        val path = c.str("resourcePath")
        return runCatching { URI(path.replace("rtsps://", "https://").replace("rtsp://", "http://")).port }.getOrDefault(-1).coerceAtLeast(0)
    }

    private fun media(list: List<JSONObject>, serverIp: String?): Endpoint? {
        fun from(c: JSONObject, fallback: String?): Endpoint? {
            val ip = ipOf(c) ?: c.str("resourcePath").takeIf(String::isNotBlank)?.let(::hostOfUrl) ?: fallback ?: return null
            val port = portOf(c)
            return if (port > 0) Endpoint(ip, port) else null
        }
        list.firstOrNull { it.optInt("usage") == 2 }?.let { c -> from(c, null)?.let { return it } }
        list.firstOrNull { it.optInt("usage") == 17 }?.let { c -> from(c, null)?.let { return it } }
        for (c in list.filter { it.optInt("usage") == 14 }.sortedByDescending { it.optInt("port") }) {
            from(c, serverIp)?.let { return it }
        }
        return null
    }

    private fun ice(s: JSONObject): List<IceSpec> {
        val arr = s.optJSONObject("iceServerConfiguration")?.optJSONArray("iceServers") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val urls = when (val u = o.opt("urls")) {
                is String -> listOf(u)
                is JSONArray -> (0 until u.length()).map { u.optString(it) }
                else -> emptyList()
            }.filter { it.isNotBlank() }
            if (urls.isEmpty()) null else IceSpec(urls, o.str("username").ifBlank { null }, o.str("credential").ifBlank { null })
        }
    }

    private fun signalingUrl(resourcePath: String, ip: String): String = when {
        resourcePath.startsWith("rtsps://") || resourcePath.startsWith("rtsp://") ->
            hostOfUrl(resourcePath)?.let { "wss://$it/nvst/" } ?: "wss://$ip:443/nvst/"
        resourcePath.startsWith("wss://") -> resourcePath
        resourcePath.startsWith("https://") -> resourcePath.replaceFirst("https://", "wss://")
        resourcePath.startsWith("/") -> "wss://$ip:443$resourcePath"
        else -> "wss://$ip:443/nvst/"
    }

    private suspend fun <T> io(block: suspend () -> T): T = withContext(Dispatchers.IO) { block() }

    companion object {
        private const val BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
        private const val VERSION = "2.0.88.129"
        private const val TV_UA = "Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 WebAppManager"
        private val JSON = "application/json".toMediaType()

        private var prefs: android.content.SharedPreferences? = null

        /** Gives the session service somewhere to keep this box's ids. Call once at start. */
        fun init(context: android.content.Context) {
            // The account file already holds the device id the session list is asked with.
            prefs = context.applicationContext.getSharedPreferences("account", android.content.Context.MODE_PRIVATE)
        }

        private fun stableId(key: String): String {
            val p = prefs ?: return UUID.randomUUID().toString()
            p.getString(key, null)?.takeIf { it.isNotEmpty() }?.let { return it }
            return UUID.randomUUID().toString().also { p.edit().putString(key, it).apply() }
        }

        /** Where a listed session can be ended: the rig that owns it, then its region. */
        fun endBases(active: ActiveSession): List<String> = listOfNotNull(
            active.serverHost?.takeIf { it.isNotEmpty() }?.let { "https://$it" },
            "https://${hostOf(active.streamingBase)}",
        )

        fun isZoneHost(host: String) = host.contains("cloudmatchbeta.nvidiagrid.net") || host.contains("cloudmatch.nvidiagrid.net")

        fun hostOf(url: String): String = url.removePrefix("https://").removePrefix("http://").substringBefore('/')

        /** Host of rtsps://, rtsp://, wss:// or https:// URLs, without the port. */
        fun hostOfUrl(url: String): String? {
            val rest = listOf("rtsps://", "rtsp://", "wss://", "https://").firstOrNull { url.startsWith(it) }?.let { url.removePrefix(it) } ?: return null
            val host = rest.substringBefore('/').substringBefore(':')
            return host.takeIf { it.isNotBlank() }
        }

        /** Plain-language reasons for the session service's status codes. */
        fun message(code: Int, description: String?, http: Int, unified: String? = null): String = when (code) {
            2 -> "GeForce NOW refused the request."
            7, 11, 50 -> "Another game is already running on your account. Resume it or end it first."
            10 -> "Too many requests in a row. Wait a moment and try again."
            13 -> "You've used all the playtime your membership includes for now."
            14, 15, 16, 17, 37, 38 -> "Your sign-in has expired. Sign in again to continue."
            18, 68 -> "Your membership doesn't include this game or setting."
            19, 20, 42 -> "This game isn't available to stream right now."
            23 -> "Accept GeForce NOW's terms on another device first, then try again."
            24, 56 -> "GeForce NOW is under maintenance. Try again a little later."
            25, 48 -> "GeForce NOW isn't available right now. Try again a little later."
            26, 27, 28 -> "Steam needs you to sign in again. Launch the game once on another device to fix it."
            29 -> "Your Steam profile is private, so your games can't be checked."
            30, 31, 32, 33, 45, 52, 53, 63 -> "GeForce NOW isn't available in your region."
            34 -> "This session can't be resumed right now."
            35 -> "Verify your email address with NVIDIA first."
            41 -> "This game is being updated. Try again in a few minutes."
            46 -> "The session was taken over by another device."
            49 -> "The session expired."
            51, 58, 59, 60 -> "All rigs nearby are busy. Try again in a moment."
            54, 55 -> "Your region is temporarily paused for new sessions."
            62 -> "The queue is full right now. Try again a little later."
            69 -> "You left the queue."
            else -> when {
                http == 401 || http == 403 -> "Your sign-in has expired. Sign in again to continue."
                else -> {
                    // Keep the raw code visible: it's what NVIDIA support and forums go by.
                    val ref = unified?.takeIf { it.isNotBlank() && it != "0" }
                        ?: description?.substringAfterLast('_')?.takeIf { it.length >= 6 && it.all { c -> c.isLetterOrDigit() } }
                        ?: if (code > 0) "status $code" else if (http > 0) "HTTP $http" else null
                    "GeForce NOW couldn't start the game." + (ref?.let { " Error $it." } ?: "")
                }
            }
        }
    }
}
