package app.kumori.link.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.os.SystemClock
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.max
import kotlin.math.sin

fun View.dp(v: Float) = Look.dp(context, v)
fun View.dpi(v: Float) = Look.dp(context, v).toInt()

fun Context.label(size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
    setTextColor(color)
    typeface = if (bold) Look.bold else Look.regular
    includeFontPadding = false
    setLineSpacing(0f, 1.18f)
}

/** Changes a label's text with a short fade, so status lines don't jump. */
fun TextView.say(value: CharSequence) {
    if (text.toString() == value.toString()) return
    if (!Look.motion || !isLaidOut || visibility != View.VISIBLE) { text = value; return }
    animate().cancel()
    animate().alpha(0f).setDuration(110).withEndAction {
        text = value
        animate().alpha(1f).setDuration(200).setInterpolator(DecelerateInterpolator()).start()
    }.start()
}

/** A FrameLayout on graphite glass. */
open class GlassFrame(context: Context, radius: Float) : FrameLayout(context) {
    val glass = Glass(this, radius)

    init { setWillNotDraw(false) }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); Light.watch(this) }
    override fun onDetachedFromWindow() { Light.unwatch(this); super.onDetachedFromWindow() }

    override fun onDraw(c: Canvas) {
        glass.draw(c, width, height, rootView)
    }
}

/** A LinearLayout on graphite glass. */
class GlassRow(context: Context, radius: Float) : LinearLayout(context) {
    private val glass = Glass(this, radius)

    init { setWillNotDraw(false) }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); Light.watch(this) }
    override fun onDetachedFromWindow() { Light.unwatch(this); super.onDetachedFromWindow() }

    override fun onDraw(c: Canvas) {
        glass.draw(c, width, height, rootView)
    }
}

/**
 * The small light beside the connection status. Looking: a ring slowly opens out from it, like
 * a call going out. Connected: steady pink with a soft halo. Paused or offline: still.
 */
class StatusDot(context: Context) : View(context) {
    enum class Mode { LOOKING, CONNECTED, PAUSED, OFFLINE }

    var mode = Mode.LOOKING
        set(value) { if (field != value) { field = value; changedAt = SystemClock.uptimeMillis(); invalidate() } }

    private var changedAt = 0L
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }

    override fun onDraw(c: Canvas) {
        val cx = width / 2f; val cy = height / 2f
        val r = dp(4f)
        val now = SystemClock.uptimeMillis()
        val color = when (mode) {
            Mode.LOOKING -> Look.secondary
            Mode.CONNECTED -> Look.accent
            Mode.PAUSED -> Look.warn
            Mode.OFFLINE -> Look.tertiary
        }
        val animate = Look.motion
        when (mode) {
            Mode.LOOKING -> if (animate) {
                for (k in 0..1) {
                    val t = (((now + k * 900L) % 1800L) / 1800f)
                    ring.color = Look.alpha(color, 0.55f * (1f - t))
                    ring.strokeWidth = dp(1.2f)
                    c.drawCircle(cx, cy, r + (width / 2f - r - dp(1f)) * t, ring)
                }
            }
            Mode.CONNECTED -> {
                // A halo that swells once when the connection arrives, then breathes very slightly.
                val since = (now - changedAt) / 1000f
                val swell = if (animate && since < 1.2f) sin(since / 1.2f * Math.PI.toFloat()) else 0f
                val breathe = if (animate) 0.5f + 0.5f * sin(now / 1400f) else 0.5f
                fill.color = Look.alpha(color, 0.16f + 0.08f * breathe + 0.25f * swell)
                c.drawCircle(cx, cy, r * (1.9f + 0.6f * swell), fill)
            }
            else -> {}
        }
        fill.color = color
        c.drawCircle(cx, cy, r, fill)
        if (animate && (mode == Mode.LOOKING || mode == Mode.CONNECTED)) postInvalidateDelayed(33)
    }
}

/** The connection status at the top right: a dot and a line of text on a glass capsule. */
class StatusChip(context: Context) : LinearLayout(context) {
    val dot = StatusDot(context)
    val text = context.label(15f, Look.primary, bold = true).apply { isSingleLine = true; ellipsize = TextUtils.TruncateAt.END }
    private val glass = Glass(this, 0f)

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setWillNotDraw(false)
        setPadding(dpi(12f), dpi(10f), dpi(18f), dpi(10f))
        addView(dot, LayoutParams(dpi(22f), dpi(22f)).apply { marginEnd = dpi(8f) })
        addView(text)
    }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); Light.watch(this) }
    override fun onDetachedFromWindow() { Light.unwatch(this); super.onDetachedFromWindow() }

    override fun onDraw(c: Canvas) {
        glass.radius = height / 2f
        glass.draw(c, width, height, rootView)
    }
}

/**
 * Round-trip time over the last forty pings as a thin line, newest on the right. The line slides
 * left as each reading comes in rather than jumping.
 */
class Sparkline(context: Context) : View(context) {
    private val values = ArrayDeque<Float>()
    private val max = 40
    private var slide = 0f
    private var anim: ValueAnimator? = null
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND; color = Look.secondary }
    private val area = Paint(Paint.ANTI_ALIAS_FLAG)
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Look.accent }
    private val path = Path()
    private val fillPath = Path()

    fun add(ms: Float) {
        values.addLast(ms)
        while (values.size > max) values.removeFirst()
        anim?.cancel()
        if (!Look.motion) { slide = 0f; invalidate(); return }
        anim = ValueAnimator.ofFloat(1f, 0f).apply {
            duration = 420
            interpolator = DecelerateInterpolator()
            addUpdateListener { slide = it.animatedValue as Float; invalidate() }
            start()
        }
    }

    fun clear() { values.clear(); invalidate() }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        area.shader = android.graphics.LinearGradient(0f, 0f, 0f, h.toFloat(), 0x26FFFFFF, 0x00FFFFFF, android.graphics.Shader.TileMode.CLAMP)
    }

    override fun onDraw(c: Canvas) {
        if (values.size < 2) return
        val pad = dp(4f)
        val w = width - pad * 2; val h = height - pad * 2
        var hi = 0f
        for (v in values) hi = max(hi, v)
        // Keep a little headroom, and never scale a quiet line up into a dramatic one.
        hi = max(hi * 1.25f, 8f)
        val step = w / (max - 1)
        val start = pad + w - (values.size - 1 + slide) * step
        path.reset(); fillPath.reset()
        var x = 0f; var y = 0f
        values.forEachIndexed { i, v ->
            x = start + i * step
            y = pad + h - (v / hi) * h
            if (i == 0) { path.moveTo(x, y); fillPath.moveTo(x, pad + h); fillPath.lineTo(x, y) } else { path.lineTo(x, y); fillPath.lineTo(x, y) }
        }
        fillPath.lineTo(x, pad + h); fillPath.close()
        c.save()
        c.clipRect(pad, 0f, pad + w, height.toFloat())
        c.drawPath(fillPath, area)
        line.strokeWidth = dp(1.5f)
        c.drawPath(path, line)
        c.restore()
        c.drawCircle(x, y, dp(3f), dot)
    }
}
