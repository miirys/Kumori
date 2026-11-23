package app.kumori.tv.debug

import android.content.Context
import android.hardware.display.DisplayManager
import android.media.MediaCodecInfo
import android.os.Build
import android.view.Choreographer
import android.view.Display
import app.kumori.tv.stream.TvDecoderFactory
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume
import kotlin.math.roundToInt

/**
 * What stands between a 120 fps stream and the screen: the modes the TV (and any receiver in
 * between) offer this box over HDMI, what the box runs at now, HDR, and whether the hardware
 * decoders keep up. Each check says plainly whether it passes and, if not, what to change.
 */
object DisplayChain {
    enum class Level(val wire: String) { OK("ok"), WARN("warn"), FAIL("fail"), INFO("info") }

    data class Finding(val title: String, val level: Level, val value: String, val detail: String? = null)

    data class Report(val findings: List<Finding>, val current: String?, val modes: List<String>, val hdr: List<String>) {
        fun json(): JSONObject = JSONObject()
            .put("findings", JSONArray().apply {
                for (f in findings) put(JSONObject().put("check", f.title).put("result", f.level.wire).put("value", f.value).apply { f.detail?.let { put("detail", it) } })
            })
            .put("modesOffered", JSONArray(modes))
            .put("hdr", JSONArray(hdr))
            .apply { current?.let { put("current", it) } }

        fun text(): String = buildString {
            current?.let { appendLine("Current: $it") }
            for (f in findings) appendLine("[${f.level.wire}] ${f.title}: ${f.value}${f.detail?.let { " ($it)" } ?: ""}")
            appendLine("Modes offered: ${modes.joinToString(", ")}")
        }
    }

    private fun label(m: Display.Mode) = "${m.physicalWidth} × ${m.physicalHeight} at ${m.refreshRate.roundToInt()} Hz"

    fun read(context: Context): Report {
        val d = context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)
            ?: return Report(listOf(Finding("Display", Level.FAIL, "Not found")), null, emptyList(), emptyList())
        val now = d.mode
        val modes = d.supportedModes.sortedWith(compareByDescending<Display.Mode> { it.physicalHeight }.thenByDescending { it.refreshRate })
        val out = ArrayList<Finding>()

        val fast = modes.filter { it.refreshRate >= 119f }
        out += if (fast.isEmpty()) {
            Finding("120 Hz offered", Level.FAIL, "No", "The TV or the receiver in between offers no 120 Hz mode. Check its HDMI input is set to enhanced or 4K120, and that the cable is rated for 48 Gbps.")
        } else {
            Finding("120 Hz offered", Level.OK, fast.map { "${it.physicalHeight}p" }.distinct().joinToString(", "))
        }
        for ((h, name) in listOf(2160 to "4K at 120 Hz", 1440 to "1440p at 120 Hz", 1080 to "1080p at 120 Hz")) {
            if (fast.none { it.physicalHeight == h } && fast.isNotEmpty()) {
                out += Finding(name, Level.INFO, "Not offered")
            }
        }
        out += if (now.refreshRate >= 119f) {
            Finding("Running now", Level.OK, label(now))
        } else if (fast.isNotEmpty()) {
            Finding("Running now", Level.WARN, label(now), "Kumori switches to 120 Hz for 120 fps streams. Highest refresh rate in Settings keeps it there in the menus too.")
        } else {
            Finding("Running now", Level.INFO, label(now))
        }

        @Suppress("DEPRECATION")
        val hdrTypes = d.hdrCapabilities?.supportedHdrTypes?.toList().orEmpty().mapNotNull {
            when (it) {
                Display.HdrCapabilities.HDR_TYPE_HDR10 -> "HDR10"
                Display.HdrCapabilities.HDR_TYPE_HDR10_PLUS -> "HDR10+"
                Display.HdrCapabilities.HDR_TYPE_HLG -> "HLG"
                Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION -> "Dolby Vision"
                else -> null
            }
        }
        out += if (hdrTypes.isEmpty()) {
            Finding("HDR", Level.WARN, "Not offered", "The display chain reports no HDR. Turn on HDR or deep colour for this HDMI input.")
        } else {
            Finding("HDR", Level.OK, hdrTypes.joinToString(", "))
        }

        if (Build.VERSION.SDK_INT >= 31) {
            val pref = runCatching { context.getSystemService(DisplayManager::class.java).matchContentFrameRateUserPreference }.getOrNull()
            val text = when (pref) {
                DisplayManager.MATCH_CONTENT_FRAMERATE_NEVER -> "Never"
                DisplayManager.MATCH_CONTENT_FRAMERATE_SEAMLESSS_ONLY -> "Seamless only"
                DisplayManager.MATCH_CONTENT_FRAMERATE_ALWAYS -> "Always"
                else -> null
            }
            if (text != null) {
                out += Finding(
                    "Match frame rate", if (pref == DisplayManager.MATCH_CONTENT_FRAMERATE_NEVER) Level.WARN else Level.OK, text,
                    if (pref == DisplayManager.MATCH_CONTENT_FRAMERATE_NEVER) "Android won't switch refresh rate for apps. Set it to Always in the box's display settings." else null,
                )
            }
        }

        for ((name, mime) in listOf("AV1" to TvDecoderFactory.MIME_AV1, "HEVC" to TvDecoderFactory.MIME_HEVC)) {
            val info = TvDecoderFactory.find(mime)
            if (info == null) {
                out += Finding("$name decoder", if (name == "HEVC") Level.FAIL else Level.WARN, "No hardware decoder")
                continue
            }
            val v = runCatching { info.getCapabilitiesForType(mime).videoCapabilities }.getOrNull()
            fun ok(w: Int, h: Int, f: Double) = v != null && runCatching { v.areSizeAndRateSupported(w, h, f) }.getOrDefault(false)
            val can = listOfNotNull(
                "4K60".takeIf { ok(3840, 2160, 60.0) },
                "4K120".takeIf { ok(3840, 2160, 120.0) },
                "1440p120".takeIf { ok(2560, 1440, 120.0) },
                "1080p120".takeIf { ok(1920, 1080, 120.0) },
            )
            out += Finding(
                "$name decoder", if (can.any { it.endsWith("120") }) Level.OK else Level.WARN,
                can.joinToString(", ").ifEmpty { "Below 4K60" },
                info.name,
            )
        }
        return Report(out, label(now), modes.map(::label).distinct(), hdrTypes)
    }

    /** Counts frames for [ms] milliseconds: the refresh rate the screen really runs at. */
    suspend fun measureHz(ms: Long = 1000): Double = suspendCancellableCoroutine { c ->
        val chor = Choreographer.getInstance()
        var first = 0L
        var count = 0
        val cb = object : Choreographer.FrameCallback {
            override fun doFrame(t: Long) {
                if (first == 0L) first = t
                count++
                val span = (t - first) / 1_000_000L
                if (span >= ms) {
                    if (c.isActive) c.resume((count - 1) * 1000.0 / span)
                } else {
                    chor.postFrameCallback(this)
                }
            }
        }
        chor.postFrameCallback(cb)
        c.invokeOnCancellation { chor.removeFrameCallback(cb) }
    }

    /** The fastest mode at the current size, for the 120 Hz test. */
    fun fastestAtSize(context: Context): Display.Mode? {
        val d = context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY) ?: return null
        val now = d.mode
        return d.supportedModes.filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }.maxByOrNull { it.refreshRate }
            ?: d.supportedModes.maxByOrNull { it.refreshRate }
    }

    @Suppress("unused")
    private fun MediaCodecInfo.short() = name.substringAfterLast('.')
}
