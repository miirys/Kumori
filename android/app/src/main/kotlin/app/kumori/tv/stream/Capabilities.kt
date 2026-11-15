package app.kumori.tv.stream

import android.content.Context
import android.hardware.display.DisplayManager
import android.view.Display
import app.kumori.tv.StreamMode
import app.kumori.tv.data.AppState

/** What this device, this TV and this membership can do with a stream mode. */
object Capabilities {

    /** Whether a mode can be used, and a line that says why not or what to expect. */
    class Verdict(val blocked: Boolean, val note: String?)

    private val codecs = listOf("AV1" to TvDecoderFactory.MIME_AV1, "H265" to TvDecoderFactory.MIME_HEVC, "H264" to TvDecoderFactory.MIME_AVC)

    /** The fastest this device's hardware decoder says it can go at a size, or 0 if it can't decode it. */
    private fun maxRate(mime: String, width: Int, height: Int): Int {
        val v = runCatching { TvDecoderFactory.find(mime)?.getCapabilitiesForType(mime)?.videoCapabilities }.getOrNull() ?: return 0
        if (!runCatching { v.isSizeSupported(width, height) }.getOrDefault(false)) return 0
        val listed = runCatching { v.getSupportedFrameRatesFor(width, height).upper.toInt() }.getOrDefault(0)
        val measured = runCatching { v.getAchievableFrameRatesFor(width, height)?.upper?.toInt() }.getOrNull() ?: 0
        return maxOf(listed, measured)
    }

    /** Codecs with a hardware decoder that keeps up with this mode, best first. */
    fun codecsFor(width: Int, height: Int, fps: Int): List<String> =
        codecs.filter { maxRate(it.second, width, height) >= fps }.map { it.first }

    private fun bestRate(width: Int, height: Int) = codecs.maxOf { maxRate(it.second, width, height) }

    private fun display(context: Context): Display? =
        runCatching { (context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager).getDisplay(Display.DEFAULT_DISPLAY) }.getOrNull()

    fun check(mode: StreamMode, app: AppState, context: Context): Verdict {
        val name = mode.resolution.label
        val allowed = app.allowedModes
        val ultimate = app.membership?.tier.equals("Ultimate", ignoreCase = true)
        if (!ultimate && allowed != null && allowed.none { it.height >= mode.height && it.fps >= mode.fps }) {
            val tier = app.membership?.tier
            return Verdict(true, "Not part of ${if (tier != null) "your $tier membership" else "your membership"}.")
        }
        val rate = bestRate(mode.width, mode.height)
        if (rate == 0) return Verdict(true, "This device can't decode $name video.")
        if (rate < mode.fps) return Verdict(true, "This device decodes $name at up to $rate fps.")

        val modes = display(context)?.supportedModes.orEmpty()
        val hz = modes.maxOfOrNull { it.refreshRate } ?: 60f
        val lines = modes.maxOfOrNull { minOf(it.physicalWidth, it.physicalHeight) } ?: 0
        return Verdict(
            false,
            when {
                mode.fps > hz + 1 -> "The TV is running at ${hz.toInt()} Hz, so it can't show all ${mode.fps} frames. Set the TV output to ${mode.fps} Hz first."
                lines in 1 until mode.height -> "The TV output is ${lines}p, so $name is scaled down to fit."
                mode.height >= 2160 -> "Needs Ultimate. If GeForce NOW doesn't give a 4K rig, the game starts at 1440p and says so."
                else -> null
            },
        )
    }
}
