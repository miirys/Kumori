package app.kumori.link.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.TextUtils
import android.util.TypedValue
import android.view.Choreographer
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.DecelerateInterpolator
import android.view.animation.PathInterpolator
import android.widget.LinearLayout
import android.widget.TextView
import app.kumori.link.Link
import app.kumori.link.LogServer
import app.kumori.link.Pad
import app.kumori.link.PadView
import app.kumori.link.Relay
import app.kumori.link.BuildConfig
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sin

fun View.dp(v: Float) = Look.dp(context, v)
fun View.dpi(v: Float) = Look.dp(context, v).toInt()

fun Context.label(size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
    setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
    setTextColor(color)
    typeface = if (bold) Look.bold else Look.regular
    includeFontPadding = false
}

/** Changes a label's text with a short cross-fade. */
fun TextView.say(value: CharSequence) {
    if (text.toString() == value.toString()) return
    if (!Look.motion || !isLaidOut) { text = value; return }
    animate().cancel()
    animate().alpha(0f).setDuration(120).withEndAction {
        text = value
        animate().alpha(1f).setDuration(220).setInterpolator(DecelerateInterpolator()).start()
    }.start()
}

/**
 * Everything on screen. The activity hands it controllers and connection readings; it never
 * touches input or the network itself.
 *
 * One controller at a time, large, under a light, with its name above it, the way Apple shows
 * a product. With more than one, a glass switcher along the bottom shows who's playing, and
 * the stage follows whoever pressed something last. The connection sits in a glass capsule in
 * the top corner. Instructions appear only while something needs doing.
 */
class LinkScreen(context: Context) : ViewGroup(context), Choreographer.FrameCallback {
    private val stage = StageView(context)
    private val pad = PadView(context)
    private val reflection = Reflection(context, pad)
    private val title = context.label(30f, Look.primary, bold = true).apply {
        gravity = Gravity.CENTER; isSingleLine = true; ellipsize = TextUtils.TruncateAt.END; letterSpacing = -0.015f
    }
    private val subtitle = context.label(17f, Look.secondary).apply { gravity = Gravity.CENTER; isSingleLine = true }
    private val hint = context.label(15f, Look.tertiary).apply { gravity = Gravity.CENTER; isSingleLine = true; ellipsize = TextUtils.TruncateAt.END }
    private val status = StatusPill(context, stage)
    private val switcher = PlayerSwitcher(context, stage)

    private val pads = LinkedHashMap<Int, Pad>()
    private var shown: Pad? = null
    private var focused = true
    private var connected = false
    private var ip: String? = null
    private var infoUntil = 0L

    // Motion.
    private var tiltX = 0f; private var tiltY = 0f; private var lift = 0f
    private var energy = 0f
    private var lastFrame = 0L
    private var lastInput = 0L
    private var frame = 0
    private var running = false
    private val born = System.nanoTime()

    init {
        addView(stage); addView(reflection); addView(pad)
        addView(title); addView(subtitle); addView(hint); addView(status); addView(switcher)
        clipChildren = false
        switcher.visibility = View.GONE
        pad.cameraDistance = 14000f * resources.displayMetrics.density
        reflection.cameraDistance = pad.cameraDistance
        refreshTitle()
    }

    // Layout.

    override fun onMeasure(wSpec: Int, hSpec: Int) {
        val w = MeasureSpec.getSize(wSpec); val h = MeasureSpec.getSize(hSpec)
        setMeasuredDimension(w, h)
        fun exact(v: View, cw: Int, ch: Int) = v.measure(MeasureSpec.makeMeasureSpec(cw, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(ch, MeasureSpec.EXACTLY))
        fun loose(v: View, maxW: Int) = v.measure(MeasureSpec.makeMeasureSpec(maxW, MeasureSpec.AT_MOST), MeasureSpec.makeMeasureSpec(h, MeasureSpec.AT_MOST))
        exact(stage, w, h)
        val pw = min(w * 0.42f, h * 0.46f * 102f / 74f).toInt()
        val ph = (pw * 74f / 102f).toInt()
        exact(pad, pw, ph); exact(reflection, pw, ph)
        loose(status, w / 3)
        loose(title, w - dpi(112f)); loose(subtitle, w - dpi(112f))
        loose(hint, w - dpi(112f))
        loose(switcher, w - dpi(112f))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val w = r - l; val h = b - t
        val sx = dpi(56f); val top = dpi(34f)
        fun place(v: View, x: Int, y: Int) = v.layout(x, y, x + v.measuredWidth, y + v.measuredHeight)
        place(stage, 0, 0)
        place(status, w - sx - status.measuredWidth, top)
        val ty = top + status.measuredHeight + dpi(14f)
        place(title, (w - title.measuredWidth) / 2, ty)
        place(subtitle, (w - subtitle.measuredWidth) / 2, ty + title.measuredHeight + dpi(8f))
        val py = subtitle.bottom + dpi(22f)
        place(pad, (w - pad.measuredWidth) / 2, py)
        // The reflection is the controller flipped about the line where it meets the floor.
        val floor = py + pad.floorY
        place(reflection, pad.left, (2 * floor - pad.bottom).toInt())
        reflection.pivotY = 0f
        if (abs(stage.horizon - floor / h) > 0.001f) { stage.horizon = floor / h; stage.rebuild() }
        val bottom = h - dpi(30f)
        place(switcher, (w - switcher.measuredWidth) / 2, bottom - switcher.measuredHeight)
        val hy = if (switcher.visibility == View.VISIBLE) switcher.top - dpi(18f) - hint.measuredHeight else bottom - hint.measuredHeight - dpi(6f)
        place(hint, (w - hint.measuredWidth) / 2, hy)
    }

    // What's shown.

    /** Adds the pad the first time, then shows its latest state. */
    fun show(p: Pad, focused: Boolean) {
        val fresh = !pads.containsKey(p.deviceId)
        pads[p.deviceId] = p
        if (fresh) {
            switcher.set(pads.values.sortedBy { it.slot })
            refreshSwitcher()
        }
        if (this.focused != focused) { this.focused = focused; refreshTitle() }
        // The stage follows whoever pressed something last.
        if (shown == null || (shown !== p && p.buttons != 0)) swap(p)
        if (shown === p) {
            if (pad.pressedSinceLast()) { energy = min(1f, energy + 0.35f) }
            lastInput = System.nanoTime()
        }
        pad.invalidate()
    }

    fun remove(deviceId: Int) {
        val gone = pads.remove(deviceId) ?: return
        switcher.set(pads.values.sortedBy { it.slot })
        refreshSwitcher()
        if (shown === gone) swap(pads.values.minByOrNull { it.slot })
    }

    private fun refreshSwitcher() {
        val want = pads.size > 1
        if (want == (switcher.visibility == View.VISIBLE)) return
        switcher.visibility = if (want) View.VISIBLE else View.GONE
        if (want && Look.motion) {
            switcher.alpha = 0f; switcher.translationY = dp(14f)
            switcher.animate().alpha(1f).translationY(0f).setDuration(380).setInterpolator(DecelerateInterpolator()).start()
        }
        requestLayout()
    }

    /** Puts [p] on the stage, fading the last one out and this one in. */
    private fun swap(p: Pad?) {
        if (shown === p) return
        shown = p
        switcher.select(p?.deviceId)
        if (!Look.motion || !isLaidOut) { pad.pad = p; refreshTitle(); return }
        pad.animate().cancel()
        pad.animate().alpha(0f).scaleX(0.97f).scaleY(0.97f).setDuration(140).withEndAction {
            pad.pad = p
            refreshTitle()
            pad.animate().alpha(if (p != null && !focused && !p.usb) 0.45f else 1f).scaleX(1f).scaleY(1f).setDuration(320).setInterpolator(PathInterpolator(0.2f, 0f, 0f, 1f)).start()
        }.start()
    }

    private fun refreshTitle() {
        val p = shown
        if (p == null) {
            title.say("No Controller")
            subtitle.say("Turn on a controller, or press any of its buttons.")
        } else {
            title.say(p.name.trim().ifEmpty { "Controller" })
            subtitle.say(if (!focused && !p.usb) "Player ${p.slot + 1}, paused" else "Player ${p.slot + 1}")
        }
        if (pad.animate() != null && pad.scaleX == 1f) pad.alpha = if (p != null && !focused && !p.usb) 0.45f else 1f
    }

    /** Shows the version and the log page address for a few seconds. Menu on the remote. */
    fun info() {
        infoUntil = System.currentTimeMillis() + 8000
        refreshHint()
        postDelayed({ refreshHint() }, 8100)
    }

    private var lastStats: Relay.Stats? = null

    /** The connection, from the relay's latest reading. */
    fun status(s: Relay.Stats, ip: String?, focused: Boolean) {
        lastStats = s
        this.ip = ip
        if (this.focused != focused) { this.focused = focused; refreshTitle() }
        connected = s.subscriber != null && ip != null
        when {
            ip == null -> status.set("No Network", null, false)
            !focused -> status.set("Paused", null, false)
            s.subscriber != null -> status.set(s.subscriberName?.takeIf { it.isNotBlank() } ?: "Apple TV",
                s.rttMs?.let { if (it < 10) "%.1f ms".format(it) else "%.0f ms".format(it) }, true)
            else -> status.set("Not Connected", null, false)
        }
        refreshHint()
    }

    private fun refreshHint() {
        val text = when {
            System.currentTimeMillis() < infoUntil -> "Kumori Link ${BuildConfig.VERSION_NAME}. Logs at http://${ip ?: "(no network)"}:${LogServer.PORT}"
            ip == null -> "Connect this box to the same network as your Apple TV."
            !connected -> "On Apple TV, open Kumori, go to Settings > Controllers and choose “${Link.name}”."
            else -> ""
        }
        if (hint.text.toString() == text) return
        hint.say(text)
        hint.post { requestLayout() }
    }

    // Motion: one frame callback moves the controller, its light and its reflection together.

    override fun onAttachedToWindow() { super.onAttachedToWindow(); running = true; lastFrame = 0; Choreographer.getInstance().postFrameCallback(this) }
    override fun onDetachedFromWindow() { running = false; Choreographer.getInstance().removeFrameCallback(this); super.onDetachedFromWindow() }

    override fun doFrame(now: Long) {
        if (!running) return
        Choreographer.getInstance().postFrameCallback(this)
        val dt = if (lastFrame == 0L) 0.016f else ((now - lastFrame) / 1e9f).coerceIn(0f, 0.1f)
        lastFrame = now
        frame++
        val motion = Look.motion
        val busy = pad.step(dt)

        // Left alone for a few seconds, the controller turns slowly under the light.
        val t = (now - born) / 1e9f
        val rest = if (shown == null) 1f else ((now - lastInput) / 1e9f - 3f).coerceIn(0f, 1.5f) / 1.5f
        var ty = pad.leftX * 10f * (1f - rest)
        var tx = -pad.leftY * 7f * (1f - rest)
        var ly = 0f
        if (motion) {
            ty += rest * 7f * sin(t * 0.42f)
            tx += rest * 3f * sin(t * 0.29f + 1.1f)
            ly = rest * dp(4f) * sin(t * 0.7f)
        }
        val k = if (motion) 1f - exp(-dt / 0.14f) else 1f
        val moved = abs(ty - tiltY) + abs(tx - tiltX) + abs(ly - lift) > 0.01f
        tiltY += (ty - tiltY) * k; tiltX += (tx - tiltX) * k; lift += (ly - lift) * k
        energy *= exp(-dt / 0.6f)
        stage.energy = if (energy < 0.005f) 0f else energy

        // Idle motion is slow, so every other frame is plenty and the main thread stays free
        // for controller input. Anything the player did gets every frame.
        val draw = busy || (moved && (rest < 1f || frame % 2 == 0))
        if (!draw) return
        pad.rotationY = tiltY; pad.rotationX = tiltX; pad.translationY = -lift
        reflection.rotationY = tiltY; reflection.rotationX = -tiltX; reflection.translationY = lift
        reflection.scaleX = pad.scaleX; reflection.scaleY = pad.scaleY; reflection.alpha = pad.alpha
        pad.lightX = tiltY / 10f; pad.lightY = tiltX / 7f
        Lighting.angle = -90f - tiltY * 4f
        pad.invalidate(); reflection.invalidate()
    }
}

/** The small Apple TV mark beside the connection status. */
class TvGlyph(context: Context) : View(context) {
    var on = false
        set(v) { if (field != v) { field = v; invalidate() } }
    private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private val r = RectF()

    override fun onDraw(c: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        p.color = if (on) Look.primary else Look.tertiary
        p.strokeWidth = dp(1.6f)
        r.set(p.strokeWidth, h * 0.12f, w - p.strokeWidth, h * 0.72f)
        c.drawRoundRect(r, dp(2.5f), dp(2.5f), p)
        c.drawLine(w * 0.32f, h * 0.9f, w * 0.68f, h * 0.9f, p)
    }
}

/** The connection, top right: the Apple TV mark, its name and the delay, on glass. */
class StatusPill(context: Context, stage: StageView) : GlassCapsule(context, stage) {
    private val glyph = TvGlyph(context)
    private val name = context.label(16f, Look.primary, bold = true)
    private val delay = context.label(16f, Look.tertiary)

    init {
        val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        row.addView(glyph, LinearLayout.LayoutParams(dpi(20f), dpi(18f)).apply { marginEnd = dpi(10f) })
        row.addView(name)
        row.addView(delay, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dpi(8f) })
        addView(row, LayoutParams(-2, -2, Gravity.CENTER_VERTICAL))
        setPadding(dpi(18f), 0, dpi(20f), 0)
        minimumHeight = dpi(46f)
    }

    override fun onMeasure(wSpec: Int, hSpec: Int) {
        super.onMeasure(wSpec, MeasureSpec.makeMeasureSpec(dpi(46f), MeasureSpec.EXACTLY))
    }

    fun set(label: String, ms: String?, on: Boolean) {
        glyph.on = on
        name.setTextColor(if (on) Look.primary else Look.secondary)
        val changed = name.text.toString() != label || (delay.visibility == View.VISIBLE) != (ms != null)
        if (name.text.toString() != label) name.text = label
        if (ms == null) delay.visibility = View.GONE else {
            delay.visibility = View.VISIBLE
            if (delay.text.toString() != ms) delay.text = ms
        }
        if (changed) morph()
    }

    /** When the text changes width, the glass stretches to it rather than jumping. */
    private var fromW = -1
    private fun morph() {
        if (!Look.motion || !isLaidOut) { requestLayout(); return }
        fromW = width
        (parent as? View)?.requestLayout()
        post {
            val to = width
            if (fromW <= 0 || to == fromW) return@post
            pivotX = width.toFloat()
            ValueAnimator.ofFloat(fromW / to.toFloat(), 1f).apply {
                duration = 420
                interpolator = PathInterpolator(0.3f, 1.25f, 0.4f, 1f)
                addUpdateListener { scaleX = it.animatedValue as Float }
                start()
            }
        }
    }
}

/**
 * Who's playing, along the bottom, once there's more than one controller. The current one sits
 * under a brighter drop of glass that slides across when the stage moves to another player,
 * stretching a little on the way.
 */
class PlayerSwitcher(context: Context, stage: StageView) : GlassCapsule(context, stage) {
    private val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
    private val ids = ArrayList<Int>()
    private var selected: Int? = null
    private var dropL = 0f; private var dropR = 0f
    private var anim: ValueAnimator? = null
    private val drop = Paint(Paint.ANTI_ALIAS_FLAG)
    private val dropEdge = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val r = RectF()

    init {
        addView(row, LayoutParams(-2, -1))
        setPadding(dpi(6f), dpi(6f), dpi(6f), dpi(6f))
    }

    override fun onMeasure(wSpec: Int, hSpec: Int) {
        super.onMeasure(wSpec, MeasureSpec.makeMeasureSpec(dpi(54f), MeasureSpec.EXACTLY))
    }

    fun set(list: List<Pad>) {
        row.removeAllViews(); ids.clear()
        for (p in list) {
            ids += p.deviceId
            val seg = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(dpi(18f), 0, dpi(20f), 0) }
            seg.addView(context.label(15f, Look.primary, bold = true).apply { text = "${p.slot + 1}" }, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dpi(9f) })
            seg.addView(context.label(15f, Look.secondary).apply { text = short(p.name); isSingleLine = true })
            row.addView(seg, LinearLayout.LayoutParams(-2, -1))
        }
        post { place(false) }
        requestLayout()
    }

    /** "Xbox Wireless Controller" is "Xbox", "8BitDo Ultimate 2.4G" is "8BitDo Ultimate". */
    private fun short(name: String): String {
        val words = name.replace("Wireless", "").replace("Controller", "").replace("Gamepad", "").trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        return words.take(2).joinToString(" ").ifEmpty { "Controller" }
    }

    fun select(id: Int?) {
        selected = id
        place(true)
    }

    private fun place(animate: Boolean) {
        val i = ids.indexOf(selected)
        for (k in 0 until row.childCount) {
            val seg = row.getChildAt(k) as LinearLayout
            (seg.getChildAt(1) as TextView).setTextColor(if (k == i) Look.primary else Look.tertiary)
            (seg.getChildAt(0) as TextView).setTextColor(if (k == i) Look.primary else Look.tertiary)
        }
        val seg = row.getChildAt(i) ?: return
        val toL = row.left + seg.left.toFloat(); val toR = row.left + seg.right.toFloat()
        anim?.cancel()
        if (!animate || !Look.motion || dropR <= dropL) { dropL = toL; dropR = toR; invalidate(); return }
        val fromL = dropL; val fromR = dropR
        val right = toL > fromL
        anim = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 460
            interpolator = DecelerateInterpolator(1.6f)
            addUpdateListener {
                val f = it.animatedValue as Float
                // The leading edge goes first and the trailing edge follows, so the drop
                // stretches as it moves and gathers up when it arrives.
                val lead = 1f - (1f - f) * (1f - f)
                val trail = f * f * (3f - 2f * f)
                if (right) { dropR = fromR + (toR - fromR) * lead; dropL = fromL + (toL - fromL) * trail }
                else { dropL = fromL + (toL - fromL) * lead; dropR = fromR + (toR - fromR) * trail }
                invalidate()
            }
            start()
        }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        if (anim?.isRunning != true) place(false)
    }

    override fun dispatchDraw(c: Canvas) {
        if (dropR > dropL) {
            val inset = dp(0f)
            r.set(dropL, paddingTop + inset, dropR, height - paddingBottom - inset)
            val rad = r.height() / 2
            drop.color = 0x26FFFFFF
            c.drawRoundRect(r, rad, rad, drop)
            dropEdge.color = 0x40FFFFFF
            dropEdge.strokeWidth = dp(1f)
            c.drawRoundRect(r, rad, rad, dropEdge)
        }
        super.dispatchDraw(c)
    }
}
