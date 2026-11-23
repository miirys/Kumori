package app.kumori.link.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Typeface
import android.util.TypedValue
import app.kumori.link.R

/**
 * Colours, type and motion, taken from Kumori on the Apple TV (`TVTokens`, `TVPanels`) so the two
 * screens look like one product: true black, graphite glass, white and grey text, the pink
 * only where something is happening.
 */
object Look {
    const val canvas = 0xFF080808.toInt()
    /** The glass's own colour, laid over the light behind it. */
    const val glass = 0xFF131313.toInt()
    /** A control at rest: neutral graphite. */
    const val control = 0xFF2C2C2E.toInt()
    const val controlHi = 0xFF3A3A3D.toInt()
    const val primary = 0xFFFFFFFF.toInt()
    /** 11.6:1 on canvas. */
    const val secondary = 0xFFC5C5C5.toInt()
    /** 7.1:1 on canvas. Never lower than this for text. */
    const val tertiary = 0xFF9A9A9A.toInt()
    /** Kumori pink. */
    const val accent = 0xFFF27BA6.toInt()
    /** Dark text on a white platter. */
    const val ink = 0xFF121212.toInt()
    const val warn = 0xFFFFB35C.toInt()
    const val hairline = 0x1FFFFFFF

    lateinit var regular: Typeface; private set
    lateinit var bold: Typeface; private set

    fun load(context: Context) {
        regular = context.resources.getFont(R.font.inter_medium)
        bold = context.resources.getFont(R.font.inter_semibold)
    }

    fun dp(context: Context, v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, context.resources.displayMetrics)

    /** False when the owner turned animations off in Android's settings. Everything then holds still. */
    val motion: Boolean get() = ValueAnimator.areAnimatorsEnabled()

    fun mix(a: Int, b: Int, t: Float): Int {
        val k = t.coerceIn(0f, 1f)
        fun ch(shift: Int) = (((a shr shift) and 0xFF) + (((b shr shift) and 0xFF) - ((a shr shift) and 0xFF)) * k).toInt()
        return (ch(24) shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
    }

    fun alpha(c: Int, a: Float) = (c and 0x00FFFFFF) or ((((c ushr 24) * a.coerceIn(0f, 1f)).toInt()) shl 24)
}
