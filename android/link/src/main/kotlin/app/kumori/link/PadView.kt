package app.kumori.link

import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.view.View
import android.view.animation.AnimationUtils
import app.kumori.link.ui.Light
import app.kumori.link.ui.Look
import kotlin.math.atan2
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin

/**
 * A live drawing of one controller: what the Apple TV is being told, as it happens.
 *
 * Presses light the button white and send a pink ring out from it. Sticks move their caps and
 * show their direction on the rim. Triggers fill from the bottom. Left alone for a few seconds
 * the controller settles into a slow float with light sliding across it.
 *
 * With no pad it draws an empty outline that breathes, for the "no controller yet" screen.
 */
class PadView(context: Context) : View(context) {
    var pad: Pad? = null
        set(value) { field = value; poke() }

    /** Dims the drawing while input is paused. */
    var paused = false
        set(value) { if (field != value) { field = value; invalidate() } }

    // Layout, in design units. The controller is 100 wide; bumpers and triggers sit above it.
    private companion object {
        const val UX0 = -2f; const val UY0 = -14f; const val UW = 104f; const val UH = 84f
        // Bits in the order we keep their animation state.
        val BITS = intArrayOf(Btn.A, Btn.B, Btn.X, Btn.Y, Btn.UP, Btn.DOWN, Btn.LEFT, Btn.RIGHT,
            Btn.LB, Btn.RB, Btn.BACK, Btn.START, Btn.GUIDE, Btn.LS, Btn.RS)
        const val IA = 0; const val IB = 1; const val IX = 2; const val IY = 3
        const val IUP = 4; const val IDOWN = 5; const val ILEFT = 6; const val IRIGHT = 7
        const val ILB = 8; const val IRB = 9; const val IVIEW = 10; const val IMENU = 11; const val IGUIDE = 12
        const val ILS = 13; const val IRS = 14
    }

    private var s = 1f
    private var ox = 0f
    private var oy = 0f
    private fun X(u: Float) = ox + (u - UX0) * s
    private fun Y(v: Float) = oy + (v - UY0) * s

    private val body = Path()
    private val unit = Path().apply {
        moveTo(50f, 8f)
        cubicTo(62f, 8f, 71f, 5f, 80f, 6f)
        cubicTo(90f, 7f, 95f, 14f, 97.5f, 26f)
        cubicTo(100f, 38f, 101.5f, 52f, 98.5f, 60f)
        cubicTo(96f, 67f, 87.5f, 68f, 83.5f, 61.5f)
        cubicTo(80f, 55.5f, 76f, 49f, 68f, 48f)
        cubicTo(60f, 47f, 40f, 47f, 32f, 48f)
        cubicTo(24f, 49f, 20f, 55.5f, 16.5f, 61.5f)
        cubicTo(12.5f, 68f, 4f, 67f, 1.5f, 60f)
        cubicTo(-1.5f, 52f, 0f, 38f, 2.5f, 26f)
        cubicTo(5f, 14f, 10f, 7f, 20f, 6f)
        cubicTo(29f, 5f, 38f, 8f, 50f, 8f)
        close()
    }
    private val m = Matrix()

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private val bodyFill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bodySheen = Paint(Paint.ANTI_ALIAS_FLAG)
    private val sweep = Paint(Paint.ANTI_ALIAS_FLAG)
    private var sweepShader: LinearGradient? = null
    private val sweepM = Matrix()
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val r = RectF()
    private val glyph = Path()

    // Animation state.
    private val level = FloatArray(BITS.size)
    private val ring = FloatArray(BITS.size) { -1f }
    private var lastButtons = 0
    private var shownLx = 0f; private var shownLy = 0f; private var shownRx = 0f; private var shownRy = 0f
    private var shownLt = 0f; private var shownRt = 0f
    private var lastFrame = 0L
    private var lastInput = 0L
    private val born = AnimationUtils.currentAnimationTimeMillis()

    private val playStation get() = pad?.let { it.vendor == 0x054c || it.name.contains("DualSense", true) || it.name.contains("DualShock", true) } ?: false

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    /** Called whenever the pad's state changes. */
    fun poke() {
        val p = pad ?: return
        val b = p.buttons
        val down = b and lastButtons.inv()
        if (down != 0) {
            for (i in BITS.indices) if (down and BITS[i] != 0) ring[i] = 0f
            Light.kick(0.22f)
        }
        lastButtons = b
        lastInput = AnimationUtils.currentAnimationTimeMillis()
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        s = min(w / UW, h / UH)
        ox = (w - UW * s) / 2f
        oy = (h - UH * s) / 2f
        m.setScale(s, s)
        m.postTranslate(ox - UX0 * s, oy - UY0 * s)
        body.reset()
        unit.transform(m, body)
        bodyFill.shader = LinearGradient(0f, Y(5f), 0f, Y(68f), 0xFF2B2B2E.toInt(), 0xFF161618.toInt(), Shader.TileMode.CLAMP)
        bodySheen.shader = LinearGradient(0f, Y(5f), 0f, Y(28f), 0x1AFFFFFF, 0x00FFFFFF, Shader.TileMode.CLAMP)
        // A soft diagonal band of light, slid across the body while it rests.
        val bw = 22f * s
        sweepShader = LinearGradient(0f, 0f, bw, bw * 0.35f,
            intArrayOf(0x00FFFFFF, 0x12FFFFFF, 0x00FFFFFF), floatArrayOf(0f, 0.5f, 1f), Shader.TileMode.CLAMP)
        sweep.shader = sweepShader
        label.typeface = Look.bold
    }

    override fun onDraw(c: Canvas) {
        val now = AnimationUtils.currentAnimationTimeMillis()
        // The first frame shows the pad as it is, without easing in from rest.
        val dt = if (lastFrame == 0L) 1f else ((now - lastFrame) / 1000f).coerceIn(0f, 0.1f)
        lastFrame = now
        val motion = Look.motion
        val p = pad
        var busy = false

        // Rest: how settled the controller is, 0 while in use, 1 a few seconds after the last input.
        val rest = if (p == null) 1f else ((now - lastInput - 2500L) / 1500f).coerceIn(0f, 1f)
        val t = (now - born) / 1000f
        val float = if (motion) sin(t * 1.1f) * 1.1f * s * rest else 0f

        c.save()
        c.translate(0f, float)
        if (paused) c.saveLayerAlpha(0f, -float, width.toFloat(), height - float, 110)

        if (p == null) {
            drawGhost(c, t, motion)
            if (paused) c.restore()
            c.restore()
            if (motion) postInvalidateDelayed(33)
            return
        }

        // Ease presses in fast and out a little slower, and run the rings.
        val b = p.buttons
        for (i in BITS.indices) {
            val target = if (b and BITS[i] != 0) 1f else 0f
            val tau = if (target > level[i]) 0.02f else 0.14f
            level[i] = if (motion) level[i] + (target - level[i]) * (1f - exp(-dt / tau)) else target
            if (kotlin.math.abs(target - level[i]) > 0.004f) busy = true else level[i] = target
            if (ring[i] >= 0f) {
                ring[i] += dt / 0.55f
                if (ring[i] >= 1f || !motion) ring[i] = -1f else busy = true
            }
        }
        fun follow(shown: Float, target: Float, tau: Float): Float {
            if (!motion) return target
            val v = shown + (target - shown) * (1f - exp(-dt / tau))
            if (kotlin.math.abs(target - v) > 0.002f) busy = true else return target
            return v
        }
        shownLx = follow(shownLx, p.lx, 0.03f); shownLy = follow(shownLy, p.ly, 0.03f)
        shownRx = follow(shownRx, p.rx, 0.03f); shownRy = follow(shownRy, p.ry, 0.03f)
        shownLt = follow(shownLt, p.ltByte() / 255f, 0.025f); shownRt = follow(shownRt, p.rtByte() / 255f, 0.025f)

        trigger(12f, 30f, shownLt, "LT")
        trigger(70f, 88f, shownRt, "RT")
        bumper(9f, 34f, level[ILB], ring[ILB], "LB")
        bumper(66f, 91f, level[IRB], ring[IRB], "RB")

        c.drawPath(body, bodyFill)
        c.drawPath(body, bodySheen)
        if (motion && rest > 0f) {
            // Every seven seconds a band of light crosses from left to right.
            val phase = (t % 7f) / 7f
            val x = X(-30f + 160f * phase)
            sweepM.setTranslate(x, Y(0f))
            sweepShader?.setLocalMatrix(sweepM)
            sweep.alpha = (255 * rest).toInt()
            c.drawPath(body, sweep)
        }
        stroke.color = 0x24FFFFFF
        stroke.strokeWidth = maxOf(1f, 0.35f * s)
        c.drawPath(body, stroke)

        stick(22f, 25f, shownLx, shownLy, level[ILS], ring[ILS])
        stick(66f, 39f, shownRx, shownRy, level[IRS], ring[IRS])
        dpad(34f, 39f)
        face(78f, 25f)
        pill(42.5f, 25f, level[IVIEW], ring[IVIEW], false)
        pill(57.5f, 25f, level[IMENU], ring[IMENU], true)
        guide(50f, 15.5f, level[IGUIDE], ring[IGUIDE])

        if (paused) c.restore()
        c.restore()
        if (busy) postInvalidateOnAnimation()
        else if (motion && rest > 0f) postInvalidateDelayed(33)
        else if (motion) postInvalidateDelayed((2500L - (now - lastInput)).coerceIn(16L, 2500L))
    }

    // Parts.

    private fun ringAt(cx: Float, cy: Float, radius: Float, k: Float) {
        if (k < 0f) return
        val e = 1f - (1f - k) * (1f - k)
        stroke.color = Look.alpha(Look.accent, 0.7f * (1f - k))
        stroke.strokeWidth = s * (0.9f - 0.6f * k)
        c?.drawCircle(cx, cy, radius + s * 4.5f * e, stroke)
    }

    // The canvas for the parts above. Set for the length of one onDraw.
    private var c: Canvas? = null
    override fun draw(canvas: Canvas) { c = canvas; super.draw(canvas); c = null }

    private fun keyFill(k: Float) = Look.mix(Look.control, 0xFFF4F4F4.toInt(), k)
    private fun keyText(k: Float) = Look.mix(Look.tertiary, Look.ink, k)

    private fun circleKey(cx: Float, cy: Float, rad: Float, k: Float, ringK: Float) {
        val c = c ?: return
        ringAt(cx, cy, rad, ringK)
        // A slight press: the key sinks a little as it lights.
        val rr = rad * (1f - 0.06f * k)
        fill.color = keyFill(k)
        c.drawCircle(cx, cy, rr, fill)
        stroke.color = Look.alpha(0xFFFFFFFF.toInt(), 0.10f * (1f - k))
        stroke.strokeWidth = maxOf(1f, 0.3f * s)
        c.drawCircle(cx, cy, rr, stroke)
    }

    private fun text(str: String, cx: Float, cy: Float, size: Float, color: Int) {
        label.textSize = size * s
        label.color = color
        c?.drawText(str, cx, cy + label.textSize * 0.36f, label)
    }

    private fun trigger(u0: Float, u1: Float, v: Float, name: String) {
        val c = c ?: return
        r.set(X(u0), Y(-13f), X(u1), Y(-5f))
        val rad = 3f * s
        fill.color = Look.control
        c.drawRoundRect(r, rad, rad, fill)
        if (v > 0.001f) {
            c.save()
            c.clipRect(r.left, r.bottom - r.height() * v, r.right, r.bottom)
            fill.color = Look.accent
            c.drawRoundRect(r, rad, rad, fill)
            c.restore()
        }
        text(name, r.centerX(), r.centerY(), 2.6f, Look.mix(Look.tertiary, Look.ink, (v - 0.35f) * 4f))
    }

    private fun bumper(u0: Float, u1: Float, k: Float, ringK: Float, name: String) {
        val c = c ?: return
        r.set(X(u0), Y(-2.5f), X(u1), Y(9f))
        val rad = 4f * s
        if (ringK >= 0f) {
            val e = 1f - (1f - ringK) * (1f - ringK)
            stroke.color = Look.alpha(Look.accent, 0.7f * (1f - ringK))
            stroke.strokeWidth = s * (0.9f - 0.6f * ringK)
            val g = s * 3f * e
            c.drawRoundRect(r.left - g, r.top - g, r.right + g, r.bottom + g, rad + g, rad + g, stroke)
        }
        fill.color = keyFill(k)
        c.drawRoundRect(r, rad, rad, fill)
        text(name, r.centerX(), Y(1.6f), 2.6f, keyText(k))
    }

    private fun stick(u: Float, v: Float, x: Float, y: Float, k: Float, ringK: Float) {
        val c = c ?: return
        val cx = X(u); val cy = Y(v)
        val well = 8.2f * s
        // The well: darker than the body, with a faint rim.
        fill.color = 0xFF0E0E10.toInt()
        c.drawCircle(cx, cy, well, fill)
        stroke.color = 0x1FFFFFFF
        stroke.strokeWidth = maxOf(1f, 0.3f * s)
        c.drawCircle(cx, cy, well, stroke)
        // Direction on the rim, longer and brighter the further the stick is pushed.
        val mag = hypot(x, y).coerceAtMost(1f)
        if (mag > 0.12f) {
            val ang = Math.toDegrees(atan2(y, x).toDouble()).toFloat()
            val sweepDeg = 30f + 70f * mag
            stroke.color = Look.alpha(Look.accent, 0.35f + 0.65f * mag)
            stroke.strokeWidth = 0.9f * s
            r.set(cx - well + 0.9f * s, cy - well + 0.9f * s, cx + well - 0.9f * s, cy + well - 0.9f * s)
            c.drawArc(r, ang - sweepDeg / 2, sweepDeg, false, stroke)
        }
        ringAt(cx, cy, well, ringK)
        // The cap, pushed by the stick and lit when clicked.
        val travel = 3.1f * s
        val px = cx + x * travel; val py = cy + y * travel
        val cap = 5.0f * s
        fill.color = 0x66000000
        c.drawCircle(px, py + 0.6f * s, cap, fill)
        fill.color = Look.mix(0xFF333336.toInt(), 0xFFF4F4F4.toInt(), k)
        c.drawCircle(px, py, cap, fill)
        // The cap's dished top: a ring a little inside the edge.
        stroke.color = Look.alpha(if (k > 0.5f) Look.ink else 0xFFFFFFFF.toInt(), 0.14f)
        stroke.strokeWidth = maxOf(1f, 0.35f * s)
        c.drawCircle(px, py, cap * 0.68f, stroke)
    }

    private fun dpad(u: Float, v: Float) {
        val c = c ?: return
        val arm = 3.6f; val len = 4.6f; val rad = 1.2f * s
        fun arm(i: Int, l: Float, t: Float, rr: Float, b: Float, gx: Float, gy: Float) {
            val k = level[i]
            if (ring[i] >= 0f) {
                val e = 1f - (1f - ring[i]) * (1f - ring[i])
                stroke.color = Look.alpha(Look.accent, 0.7f * (1f - ring[i]))
                stroke.strokeWidth = s * (0.9f - 0.6f * ring[i])
                c.drawCircle(X(gx), Y(gy), s * (2.4f + 3.5f * e), stroke)
            }
            fill.color = keyFill(k)
            r.set(X(l), Y(t), X(rr), Y(b))
            c.drawRoundRect(r, rad, rad, fill)
            // A small arrow on each arm.
            fill.color = keyText(k)
            glyph.reset()
            val a = 1.1f * s
            val gxp = X(gx); val gyp = Y(gy)
            when (i) {
                IUP -> { glyph.moveTo(gxp, gyp - a); glyph.lineTo(gxp + a, gyp + a * 0.6f); glyph.lineTo(gxp - a, gyp + a * 0.6f) }
                IDOWN -> { glyph.moveTo(gxp, gyp + a); glyph.lineTo(gxp + a, gyp - a * 0.6f); glyph.lineTo(gxp - a, gyp - a * 0.6f) }
                ILEFT -> { glyph.moveTo(gxp - a, gyp); glyph.lineTo(gxp + a * 0.6f, gyp - a); glyph.lineTo(gxp + a * 0.6f, gyp + a) }
                else -> { glyph.moveTo(gxp + a, gyp); glyph.lineTo(gxp - a * 0.6f, gyp - a); glyph.lineTo(gxp - a * 0.6f, gyp + a) }
            }
            glyph.close()
            c.drawPath(glyph, fill)
        }
        val h = arm / 2
        // The centre square, then each arm reaching out from it.
        fill.color = Look.control
        r.set(X(u - h), Y(v - h), X(u + h), Y(v + h))
        c.drawRect(r, fill)
        arm(IUP, u - h, v - h - len, u + h, v + h * 0.2f, u, v - h - len * 0.5f)
        arm(IDOWN, u - h, v - h * 0.2f, u + h, v + h + len, u, v + h + len * 0.5f)
        arm(ILEFT, u - h - len, v - h, u + h * 0.2f, v + h, u - h - len * 0.5f, v)
        arm(IRIGHT, u - h * 0.2f, v - h, u + h + len, v + h, u + h + len * 0.5f, v)
    }

    private fun face(u: Float, v: Float) {
        val d = 6.4f; val rad = 3.5f * s
        val ps = playStation
        fun key(i: Int, gu: Float, gv: Float, letter: String) {
            circleKey(X(gu), Y(gv), rad, level[i], ring[i])
            val col = keyText(level[i])
            if (!ps) { text(letter, X(gu), Y(gv), 3.1f, col); return }
            // PlayStation pads get their own shapes, in the same places.
            val c = c ?: return
            val cx = X(gu); val cy = Y(gv); val g = 1.45f * s
            stroke.color = col
            stroke.strokeWidth = 0.45f * s
            when (i) {
                IY -> { glyph.reset(); glyph.moveTo(cx, cy - g * 1.05f); glyph.lineTo(cx + g, cy + g * 0.75f); glyph.lineTo(cx - g, cy + g * 0.75f); glyph.close(); c.drawPath(glyph, stroke) }
                IB -> c.drawCircle(cx, cy, g, stroke)
                IA -> { c.drawLine(cx - g, cy - g, cx + g, cy + g, stroke); c.drawLine(cx - g, cy + g, cx + g, cy - g, stroke) }
                else -> c.drawRect(cx - g * 0.9f, cy - g * 0.9f, cx + g * 0.9f, cy + g * 0.9f, stroke)
            }
        }
        key(IY, u, v - d, "Y")
        key(IX, u - d, v, "X")
        key(IB, u + d, v, "B")
        key(IA, u, v + d, "A")
    }

    private fun pill(u: Float, v: Float, k: Float, ringK: Float, menu: Boolean) {
        val c = c ?: return
        val cx = X(u); val cy = Y(v)
        val rad = 2.1f * s
        ringAt(cx, cy, rad, ringK)
        fill.color = keyFill(k)
        c.drawCircle(cx, cy, rad, fill)
        // View: two overlapping squares. Menu: three lines.
        stroke.color = keyText(k)
        stroke.strokeWidth = 0.32f * s
        val g = 0.85f * s
        if (menu) {
            for (j in -1..1) c.drawLine(cx - g, cy + j * g * 0.75f, cx + g, cy + j * g * 0.75f, stroke)
        } else {
            c.drawRect(cx - g, cy - g, cx + g * 0.35f, cy + g * 0.35f, stroke)
            c.drawRect(cx - g * 0.35f, cy - g * 0.35f, cx + g, cy + g, stroke)
        }
    }

    private fun guide(u: Float, v: Float, k: Float, ringK: Float) {
        val c = c ?: return
        val cx = X(u); val cy = Y(v)
        val rad = 3.3f * s
        ringAt(cx, cy, rad, ringK)
        fill.color = Look.mix(0xFF1F1F22.toInt(), 0xFFF4F4F4.toInt(), k)
        c.drawCircle(cx, cy, rad, fill)
        stroke.color = Look.mix(0x40FFFFFF, Look.accent, k)
        stroke.strokeWidth = 0.4f * s
        c.drawCircle(cx, cy, rad - 0.2f * s, stroke)
        // Kumori's mark: a small cloud.
        fill.color = keyText(k)
        val g = s
        c.drawCircle(cx - 0.9f * g, cy + 0.3f * g, 0.9f * g, fill)
        c.drawCircle(cx + 0.2f * g, cy - 0.3f * g, 1.2f * g, fill)
        c.drawCircle(cx + 1.2f * g, cy + 0.4f * g, 0.75f * g, fill)
        r.set(cx - 1.8f * g, cy + 0.2f * g, cx + 1.95f * g, cy + 1.15f * g)
        c.drawRoundRect(r, 0.5f * g, 0.5f * g, fill)
    }

    /** The empty outline for when nothing is connected: it breathes, and light runs along its edge. */
    private fun drawGhost(c: Canvas, t: Float, motion: Boolean) {
        val breathe = if (motion) 0.5f + 0.5f * sin(t * 1.25f) else 0.5f
        stroke.strokeWidth = maxOf(1f, 0.4f * s)
        stroke.color = Look.alpha(0xFFFFFFFF.toInt(), 0.16f + 0.08f * breathe)
        c.drawPath(body, stroke)
        fill.color = Look.alpha(0xFFFFFFFF.toInt(), 0.025f + 0.015f * breathe)
        c.drawPath(body, fill)
        if (motion) {
            val phase = (t % 7f) / 7f
            sweepM.setTranslate(X(-30f + 160f * phase), Y(0f))
            sweepShader?.setLocalMatrix(sweepM)
            sweep.alpha = 255
            c.drawPath(body, sweep)
        }
        stroke.color = Look.alpha(0xFFFFFFFF.toInt(), 0.14f + 0.06f * breathe)
        stroke.strokeWidth = maxOf(1f, 0.32f * s)
        for ((u, v, rad) in listOf(Triple(22f, 25f, 8.2f), Triple(66f, 39f, 8.2f))) c.drawCircle(X(u), Y(v), rad * s, stroke)
        val d = 6.4f
        for ((u, v) in listOf(78f to 25f - d, 78f - d to 25f, 78f + d to 25f, 78f to 25f + d)) c.drawCircle(X(u), Y(v), 3.5f * s, stroke)
        r.set(X(34f - 1.8f), Y(39f - 6.4f), X(34f + 1.8f), Y(39f + 6.4f)); c.drawRoundRect(r, 1.2f * s, 1.2f * s, stroke)
        r.set(X(34f - 6.4f), Y(39f - 1.8f), X(34f + 6.4f), Y(39f + 1.8f)); c.drawRoundRect(r, 1.2f * s, 1.2f * s, stroke)
        c.drawCircle(X(50f), Y(15.5f), 3.3f * s, stroke)
    }
}
