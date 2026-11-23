package app.kumori.link.ui

import android.animation.LayoutTransition
import android.animation.ObjectAnimator
import android.animation.PropertyValuesHolder
import android.content.Context
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.DecelerateInterpolator
import android.view.animation.PathInterpolator
import android.widget.LinearLayout
import app.kumori.link.PadView
import kotlin.math.min

/** One controller's card: who it is, then the live drawing. */
class PadCard(context: Context, slot: Int, name: String, private val usb: Boolean) : GlassFrame(context, Look.dp(context, 26f)) {
    val pad = PadView(context)
    val slot = slot
    private val note = context.label(13f, Look.tertiary)

    init {
        val col = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val top = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        top.addView(PlayerBadge(context, slot + 1), LinearLayout.LayoutParams(dpi(28f), dpi(28f)).apply { marginEnd = dpi(10f) })
        val names = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        names.addView(context.label(16f, Look.primary, bold = true).apply { text = "Player ${slot + 1}"; isSingleLine = true; ellipsize = TextUtils.TruncateAt.END })
        names.addView(context.label(13f, Look.tertiary).apply {
            text = name.trim().ifEmpty { "Controller" }
            isSingleLine = true; ellipsize = TextUtils.TruncateAt.END
            setPadding(0, dpi(4f), 0, 0)
        })
        top.addView(names, LinearLayout.LayoutParams(0, -2, 1f))
        note.text = if (usb) "USB" else ""
        top.addView(note, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dpi(8f) })
        col.addView(top)
        col.addView(pad, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = dpi(10f) })
        addView(col, LayoutParams(-1, -1))
        setPadding(dpi(18f), dpi(16f), dpi(18f), dpi(14f))
    }

    fun paused(on: Boolean) {
        pad.paused = on
        note.say(if (on) "Paused" else if (usb) "USB" else "")
    }
}

/** The player number in a small circle. */
class PlayerBadge(context: Context, private val n: Int) : View(context) {
    private val fill = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
    private val txt = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { textAlign = android.graphics.Paint.Align.CENTER }

    override fun onDraw(c: android.graphics.Canvas) {
        val r = min(width, height) / 2f
        fill.color = 0xFFF4F4F4.toInt()
        c.drawCircle(width / 2f, height / 2f, r, fill)
        txt.typeface = Look.bold
        txt.textSize = r * 1.05f
        txt.color = Look.ink
        c.drawText(n.toString(), width / 2f, height / 2f + txt.textSize * 0.36f, txt)
    }
}

/**
 * Lays out up to four cards in a row, centred. Cards arrive by rising into place and leave by
 * fading back, and the others slide over to make room or close the gap.
 */
class PadGrid(context: Context) : ViewGroup(context) {
    private val gap = Look.dp(context, 20f).toInt()

    init {
        clipChildren = false
        clipToPadding = false
        val ease = PathInterpolator(0.2f, 0f, 0f, 1f)
        layoutTransition = LayoutTransition().apply {
            val rise = Look.dp(context, 28f)
            setAnimator(LayoutTransition.APPEARING, ObjectAnimator.ofPropertyValuesHolder(null as Any?,
                PropertyValuesHolder.ofFloat(View.ALPHA, 0f, 1f),
                PropertyValuesHolder.ofFloat(View.TRANSLATION_Y, rise, 0f),
                PropertyValuesHolder.ofFloat(View.SCALE_X, 0.96f, 1f),
                PropertyValuesHolder.ofFloat(View.SCALE_Y, 0.96f, 1f)))
            setAnimator(LayoutTransition.DISAPPEARING, ObjectAnimator.ofPropertyValuesHolder(null as Any?,
                PropertyValuesHolder.ofFloat(View.ALPHA, 1f, 0f),
                PropertyValuesHolder.ofFloat(View.SCALE_X, 1f, 0.96f),
                PropertyValuesHolder.ofFloat(View.SCALE_Y, 1f, 0.96f)))
            setDuration(LayoutTransition.APPEARING, 460)
            setDuration(LayoutTransition.DISAPPEARING, 240)
            setDuration(LayoutTransition.CHANGE_APPEARING, 420)
            setDuration(LayoutTransition.CHANGE_DISAPPEARING, 420)
            setStartDelay(LayoutTransition.APPEARING, 120)
            setStartDelay(LayoutTransition.CHANGE_DISAPPEARING, 120)
            setInterpolator(LayoutTransition.APPEARING, ease)
            setInterpolator(LayoutTransition.CHANGE_APPEARING, ease)
            setInterpolator(LayoutTransition.CHANGE_DISAPPEARING, ease)
            setInterpolator(LayoutTransition.DISAPPEARING, DecelerateInterpolator())
        }
    }

    fun add(card: PadCard) {
        var index = 0
        for (i in 0 until childCount) if ((getChildAt(i) as PadCard).slot < card.slot) index++
        addView(card, index)
    }

    private fun cells(w: Int, h: Int): IntArray {
        val n = childCount
        if (n == 0) return intArrayOf(0, 0, 0)
        // One row, each card keeping roughly the controller's own proportions. Up to four fit
        // side by side on a TV; a grid would make each one too short to read.
        val cw = min((w - gap * (n - 1)) / n, (h * if (n == 1) 1.3f else 1.22f).toInt())
        val ch = min(h, (cw * if (n == 1) 1f else 1.15f).toInt())
        return intArrayOf(cw, ch, n)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        val (cw, ch) = cells(w, h)
        for (i in 0 until childCount) getChildAt(i).measure(MeasureSpec.makeMeasureSpec(cw, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(ch, MeasureSpec.EXACTLY))
        setMeasuredDimension(w, h)
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val w = r - l; val h = b - t
        val (cw, ch, n) = cells(w, h)
        val total = n * cw + (n - 1) * gap
        val x0 = (w - total) / 2; val y0 = (h - ch) / 2
        for (i in 0 until n) {
            val x = x0 + i * (cw + gap)
            getChildAt(i).layout(x, y0, x + cw, y0 + ch)
        }
    }
}
