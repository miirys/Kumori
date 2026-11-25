package app.kumori.link

import android.content.Context
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.view.View
import app.kumori.link.ui.Look
import app.kumori.link.ui.Soft
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.min

/**
 * One controller, drawn like a product shot under a single light from above: what the Apple TV
 * is being told, as it happens.
 *
 * A pressed button sinks and lights from inside. Sticks move their caps. Triggers and bumpers
 * brighten with how far they're pulled. The highlight on the shell follows [lightX] and
 * [lightY], which the screen moves as the controller tilts.
 *
 * With no pad it draws the shell alone, faint, for the "no controller" state.
 *
 * Animation is advanced by [step] once a frame. [render] only draws, so the floor reflection can
 * draw the same controller without moving anything twice.
 */
class PadView(context: Context) : View(context) {
    var pad: Pad? = null
        set(value) { if (field !== value) { field = value; lastButtons = value?.buttons ?: 0; snap = true }; invalidate() }

    /** Where the light hits the shell, -1..1 each way from the middle. */
    var lightX = 0f
    var lightY = 0f

    private companion object {
        // Design units: the controller is 100 wide. Bumpers and triggers rise above it.
        const val UX0 = -1f; const val UY0 = -4f; const val UW = 102f; const val UH = 74f
        val BITS = intArrayOf(Btn.A, Btn.B, Btn.X, Btn.Y, Btn.UP, Btn.DOWN, Btn.LEFT, Btn.RIGHT,
            Btn.LB, Btn.RB, Btn.BACK, Btn.START, Btn.GUIDE, Btn.LS, Btn.RS)
        const val IA = 0; const val IB = 1; const val IX = 2; const val IY = 3
        const val IUP = 4; const val IDOWN = 5; const val ILEFT = 6; const val IRIGHT = 7
        const val ILB = 8; const val IRB = 9; const val IVIEW = 10; const val IMENU = 11; const val IGUIDE = 12
        const val ILS = 13; const val IRS = 14

        // Where things sit, in design units.
        const val LSX = 22f; const val LSY = 25f
        const val RSX = 64f; const val RSY = 39f
        const val DPX = 36f; const val DPY = 39f
        const val FX = 78f; const val FY = 25f; const val FD = 6.3f
    }

    private var s = 1f
    private var ox = 0f
    private var oy = 0f
    private fun X(u: Float) = ox + (u - UX0) * s
    private fun Y(v: Float) = oy + (v - UY0) * s

    private val unit = Path().apply {
        moveTo(50f, 9f)
        cubicTo(61f, 9f, 70f, 6.5f, 79f, 6.5f)
        cubicTo(89.5f, 6.5f, 95.5f, 14f, 98f, 26f)
        cubicTo(100.5f, 38f, 101.5f, 52f, 98.5f, 60.5f)
        cubicTo(96f, 67.5f, 87.5f, 68.5f, 83.5f, 62f)
        cubicTo(80f, 56f, 76f, 49.5f, 68f, 48.5f)
        cubicTo(60f, 47.5f, 40f, 47.5f, 32f, 48.5f)
        cubicTo(24f, 49.5f, 20f, 56f, 16.5f, 62f)
        cubicTo(12.5f, 68.5f, 4f, 67.5f, 1.5f, 60.5f)
        cubicTo(-1.5f, 52f, -0.5f, 38f, 2f, 26f)
        cubicTo(4.5f, 14f, 10.5f, 6.5f, 21f, 6.5f)
        cubicTo(30f, 6.5f, 39f, 9f, 50f, 9f)
        close()
    }
    private val bumperL = Path().apply {
        moveTo(8f, 10f); cubicTo(9f, 3f, 14f, 1f, 22f, 1f); cubicTo(28f, 1f, 33f, 2f, 36f, 4.5f); lineTo(36f, 9f); close()
    }
    private val triggerL = Path().apply {
        moveTo(11f, 4f); cubicTo(11.5f, 0f, 14f, -2.2f, 21f, -2.2f); cubicTo(28f, -2.2f, 30.5f, 0f, 31f, 4f); close()
    }
    private val dpadUnit = Path().apply {
        val a = 2.1f; val l = 5.6f; val r = 0.9f
        addRoundRect(RectF(DPX - a, DPY - l, DPX + a, DPY + l), r, r, Path.Direction.CW)
        op(Path().apply { addRoundRect(RectF(DPX - l, DPY - a, DPX + l, DPY + a), r, r, Path.Direction.CW) }, Path.Op.UNION)
    }

    private val body = Path(); private val bl = Path(); private val br = Path(); private val tl = Path(); private val tr = Path()
    private val dpad = Path()
    private val m = Matrix()
    private val mirror = Matrix().apply { setScale(-1f, 1f, 50f, 0f) }

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val shell = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rim = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val shine = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val shineM = Matrix()
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private val glow = Paint(Paint.FILTER_BITMAP_FLAG)
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    private val r = RectF()
    private val glyph = Path()
    private var key: Shader? = null
    private var keyDown: Shader? = null
    private var well: Shader? = null
    private var cap: Shader? = null
    private val shaderM = Matrix()

    // Animation state.
    private val level = FloatArray(BITS.size)
    private var lastButtons = 0
    private var snap = true
    private var shownLx = 0f; private var shownLy = 0f; private var shownRx = 0f; private var shownRy = 0f
    private var shownLt = 0f; private var shownRt = 0f

    /** Where the controller's lowest edge meets the floor, in this view's pixels. */
    val floorY get() = Y(68.3f)

    /** The left stick as drawn, so the screen can tilt the controller with it. */
    val leftX get() = shownLx
    val leftY get() = shownLy

    private val playStation get() = pad?.let { it.vendor == 0x054c || it.name.contains("DualSense", true) || it.name.contains("DualShock", true) } ?: false

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    /** True when something was newly pressed since the last call. */
    fun pressedSinceLast(): Boolean {
        val b = pad?.buttons ?: 0
        val down = b and lastButtons.inv()
        lastButtons = b
        return down != 0
    }

    /** Moves animation on by [dt] seconds. Returns whether anything is still moving. */
    fun step(dt: Float): Boolean {
        val p = pad ?: return false
        val motion = Look.motion && !snap
        snap = false
        var busy = false
        val b = p.buttons
        for (i in BITS.indices) {
            val target = if (b and BITS[i] != 0) 1f else 0f
            // In quickly, out a little slower, like a key light fading.
            val tau = if (target > level[i]) 0.018f else 0.12f
            level[i] = if (motion) level[i] + (target - level[i]) * (1f - exp(-dt / tau)) else target
            if (abs(target - level[i]) > 0.004f) busy = true else level[i] = target
        }
        fun follow(shown: Float, target: Float, tau: Float): Float {
            if (!motion) return target
            val v = shown + (target - shown) * (1f - exp(-dt / tau))
            if (abs(target - v) > 0.002f) busy = true else return target
            return v
        }
        shownLx = follow(shownLx, p.lx, 0.03f); shownLy = follow(shownLy, p.ly, 0.03f)
        shownRx = follow(shownRx, p.rx, 0.03f); shownRy = follow(shownRy, p.ry, 0.03f)
        shownLt = follow(shownLt, p.ltByte() / 255f, 0.025f); shownRt = follow(shownRt, p.rtByte() / 255f, 0.025f)
        return busy
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        s = min(w / UW, h / UH)
        ox = (w - UW * s) / 2f
        oy = (h - UH * s) / 2f
        m.setScale(s, s)
        m.postTranslate(ox - UX0 * s, oy - UY0 * s)
        fun place(src: Path, dst: Path, flip: Boolean = false) {
            dst.reset()
            if (flip) { val t = Path(); src.transform(mirror, t); t.transform(m, dst) } else src.transform(m, dst)
        }
        place(unit, body); place(bumperL, bl); place(bumperL, br, true); place(triggerL, tl); place(triggerL, tr, true)
        place(dpadUnit, dpad)
        // The shell: lit from above, falling to near black at the grips.
        shell.shader = LinearGradient(0f, Y(6f), 0f, Y(68f), intArrayOf(0xFF3A3A3E.toInt(), 0xFF222225.toInt(), 0xFF0F0F11.toInt()), floatArrayOf(0f, 0.45f, 1f), Shader.TileMode.CLAMP)
        // The rim catches the light along the top and loses it toward the bottom.
        rim.shader = LinearGradient(0f, Y(6f), 0f, Y(50f), 0x59FFFFFF, 0x00FFFFFF, Shader.TileMode.CLAMP)
        rim.strokeWidth = 0.45f * s
        shine.shader = BitmapShader(Soft.white, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        // Buttons and stick parts are domes lit from the top left; one gradient each, moved
        // into place per part.
        key = RadialGradient(-0.35f, -0.45f, 1.5f, intArrayOf(0xFF4A4A4F.toInt(), 0xFF2A2A2D.toInt(), 0xFF18181A.toInt()), floatArrayOf(0f, 0.55f, 1f), Shader.TileMode.CLAMP)
        keyDown = RadialGradient(0f, 0f, 1f, intArrayOf(0xFFFFFFFF.toInt(), 0xFFF0F0F0.toInt(), 0xFFD0D0D4.toInt()), floatArrayOf(0f, 0.6f, 1f), Shader.TileMode.CLAMP)
        well = RadialGradient(0f, 0.25f, 1.1f, intArrayOf(0xFF050506.toInt(), 0xFF0B0B0C.toInt(), 0xFF1E1E21.toInt()), floatArrayOf(0f, 0.75f, 1f), Shader.TileMode.CLAMP)
        cap = RadialGradient(-0.3f, -0.4f, 1.4f, intArrayOf(0xFF505055.toInt(), 0xFF2C2C30.toInt(), 0xFF161618.toInt()), floatArrayOf(0f, 0.5f, 1f), Shader.TileMode.CLAMP)
        label.typeface = Look.bold
    }

    override fun onDraw(canvas: Canvas) = render(canvas)

    /** Draws the controller as it is now. Moves nothing. */
    fun render(c: Canvas) {
        val p = pad
        if (p == null) { ghost(c); return }

        trigger(c, tl, shownLt)
        trigger(c, tr, shownRt)
        bumper(c, bl, level[ILB])
        bumper(c, br, level[IRB])

        c.drawPath(body, shell)
        // The light's reflection on the shell: a broad soft patch that slides as the
        // controller turns under the light.
        val hw = 46f * s; val hh = 20f * s
        val hx = X(50f - lightX * 20f); val hy = Y(14f - lightY * 6f)
        shineM.setScale(2 * hw / Soft.white.width, 2 * hh / Soft.white.height)
        shineM.postTranslate(hx - hw, hy - hh)
        shine.shader.setLocalMatrix(shineM)
        shine.alpha = 46
        c.drawPath(body, shine)
        c.drawPath(body, rim)

        stick(c, LSX, LSY, shownLx, shownLy, level[ILS])
        stick(c, RSX, RSY, shownRx, shownRy, level[IRS])
        dpadDraw(c)
        face(c)
        small(c, 43f, 25f, level[IVIEW], false)
        small(c, 57f, 25f, level[IMENU], true)
        guide(c, 50f, 16f, level[IGUIDE])
    }

    // Parts.

    private fun dome(c: Canvas, cx: Float, cy: Float, rad: Float, k: Float, base: Shader?) {
        // Light from inside when pressed: a soft spill on the shell around the key.
        if (k > 0.01f) {
            val g = rad * 2.6f
            glow.alpha = (k * 110).toInt()
            r.set(cx - g, cy - g, cx + g, cy + g)
            c.drawBitmap(Soft.white, null, r, glow)
        }
        // Pressed keys sink a little.
        val rr = rad * (1f - 0.05f * k)
        shaderM.setScale(rr, rr); shaderM.postTranslate(cx, cy)
        base?.setLocalMatrix(shaderM)
        fill.shader = base
        fill.alpha = 255
        c.drawCircle(cx, cy, rr, fill)
        if (k > 0.01f) {
            keyDown?.setLocalMatrix(shaderM)
            fill.shader = keyDown
            fill.alpha = (k * 255).toInt()
            c.drawCircle(cx, cy, rr, fill)
            fill.alpha = 255
        }
        fill.shader = null
        // A thin dark seam where the key meets the shell.
        stroke.shader = null
        stroke.color = 0x99000000.toInt()
        stroke.strokeWidth = 0.35f * s
        c.drawCircle(cx, cy, rr + 0.2f * s, stroke)
    }

    private fun ink(k: Float) = Look.mix(0xFF8E8E93.toInt(), 0xFF1C1C1E.toInt(), k)

    private fun text(c: Canvas, str: String, cx: Float, cy: Float, size: Float, color: Int) {
        label.textSize = size * s
        label.color = color
        c.drawText(str, cx, cy + label.textSize * 0.36f, label)
    }

    private fun trigger(c: Canvas, path: Path, v: Float) {
        fill.shader = null
        fill.color = Look.mix(0xFF1A1A1C.toInt(), 0xFFE8E8EA.toInt(), v)
        c.drawPath(path, fill)
        rim.alpha = 255
        c.drawPath(path, rim)
    }

    private fun bumper(c: Canvas, path: Path, k: Float) {
        fill.shader = null
        fill.color = Look.mix(0xFF26262A.toInt(), 0xFFF2F2F4.toInt(), k)
        c.drawPath(path, fill)
        c.drawPath(path, rim)
    }

    private fun stick(c: Canvas, u: Float, v: Float, x: Float, y: Float, k: Float) {
        val cx = X(u); val cy = Y(v)
        val wr = 7.8f * s
        shaderM.setScale(wr, wr); shaderM.postTranslate(cx, cy)
        well?.setLocalMatrix(shaderM)
        fill.shader = well
        c.drawCircle(cx, cy, wr, fill)
        fill.shader = null
        stroke.color = 0x14FFFFFF
        stroke.strokeWidth = 0.3f * s
        c.drawCircle(cx, cy, wr, stroke)
        // The cap leans the way it's pushed: it moves, and its shadow stays behind.
        val travel = 2.9f * s
        val px = cx + x * travel; val py = cy + y * travel
        val cr = 5.3f * s
        fill.color = 0x8C000000.toInt()
        c.drawCircle(cx + x * travel * 0.4f, cy + y * travel * 0.4f + 0.9f * s, cr, fill)
        dome(c, px, py, cr, k, cap)
        // The dished top: a soft ring inside the edge.
        stroke.color = Look.alpha(if (k > 0.5f) 0xFF000000.toInt() else 0xFFFFFFFF.toInt(), 0.10f)
        stroke.strokeWidth = 0.5f * s
        c.drawCircle(px, py, cr * 0.66f, stroke)
    }

    private fun dpadDraw(c: Canvas) {
        shaderM.setScale(6f * s, 6f * s); shaderM.postTranslate(X(DPX), Y(DPY))
        key?.setLocalMatrix(shaderM)
        fill.shader = key
        c.drawPath(dpad, fill)
        fill.shader = null
        stroke.color = 0x99000000.toInt(); stroke.strokeWidth = 0.35f * s
        c.drawPath(dpad, stroke)
        val a = 2.1f; val l = 5.6f
        fun arm(i: Int, l0: Float, t0: Float, r0: Float, b0: Float, gx: Float, gy: Float, dir: Int) {
            val k = level[i]
            if (k > 0.01f) {
                val g = 5f * s
                glow.alpha = (k * 100).toInt()
                r.set(X(gx) - g, Y(gy) - g, X(gx) + g, Y(gy) + g)
                c.drawBitmap(Soft.white, null, r, glow)
                fill.color = Look.alpha(0xFFF2F2F4.toInt(), k)
                r.set(X(l0), Y(t0), X(r0), Y(b0))
                c.drawRoundRect(r, 0.9f * s, 0.9f * s, fill)
            }
            fill.color = ink(k)
            glyph.reset()
            val q = 0.9f * s
            val x = X(gx); val y = Y(gy)
            when (dir) {
                0 -> { glyph.moveTo(x, y - q); glyph.lineTo(x + q, y + q * 0.55f); glyph.lineTo(x - q, y + q * 0.55f) }
                1 -> { glyph.moveTo(x, y + q); glyph.lineTo(x + q, y - q * 0.55f); glyph.lineTo(x - q, y - q * 0.55f) }
                2 -> { glyph.moveTo(x - q, y); glyph.lineTo(x + q * 0.55f, y - q); glyph.lineTo(x + q * 0.55f, y + q) }
                else -> { glyph.moveTo(x + q, y); glyph.lineTo(x - q * 0.55f, y - q); glyph.lineTo(x - q * 0.55f, y + q) }
            }
            glyph.close()
            c.drawPath(glyph, fill)
        }
        arm(IUP, DPX - a, DPY - l, DPX + a, DPY - a, DPX, DPY - l * 0.62f, 0)
        arm(IDOWN, DPX - a, DPY + a, DPX + a, DPY + l, DPX, DPY + l * 0.62f, 1)
        arm(ILEFT, DPX - l, DPY - a, DPX - a, DPY + a, DPX - l * 0.62f, DPY, 2)
        arm(IRIGHT, DPX + a, DPY - a, DPX + l, DPY + a, DPX + l * 0.62f, DPY, 3)
    }

    private fun face(c: Canvas) {
        val rad = 3.4f * s
        val ps = playStation
        fun key(i: Int, gu: Float, gv: Float, letter: String) {
            val k = level[i]
            val cx = X(gu); val cy = Y(gv)
            dome(c, cx, cy, rad, k, key)
            val col = ink(k)
            if (!ps) { text(c, letter, cx, cy, 2.9f, col); return }
            // PlayStation pads get their own symbols, in the same places.
            val g = 1.35f * s
            stroke.color = col
            stroke.strokeWidth = 0.42f * s
            when (i) {
                IY -> { glyph.reset(); glyph.moveTo(cx, cy - g * 1.05f); glyph.lineTo(cx + g, cy + g * 0.75f); glyph.lineTo(cx - g, cy + g * 0.75f); glyph.close(); c.drawPath(glyph, stroke) }
                IB -> c.drawCircle(cx, cy, g, stroke)
                IA -> { c.drawLine(cx - g, cy - g, cx + g, cy + g, stroke); c.drawLine(cx - g, cy + g, cx + g, cy - g, stroke) }
                else -> c.drawRect(cx - g * 0.9f, cy - g * 0.9f, cx + g * 0.9f, cy + g * 0.9f, stroke)
            }
        }
        key(IY, FX, FY - FD, "Y")
        key(IX, FX - FD, FY, "X")
        key(IB, FX + FD, FY, "B")
        key(IA, FX, FY + FD, "A")
    }

    private fun small(c: Canvas, u: Float, v: Float, k: Float, menu: Boolean) {
        val cx = X(u); val cy = Y(v)
        dome(c, cx, cy, 1.9f * s, k, key)
        stroke.color = ink(k)
        stroke.strokeWidth = 0.3f * s
        val g = 0.75f * s
        if (menu) {
            for (j in -1..1) c.drawLine(cx - g, cy + j * g * 0.7f, cx + g, cy + j * g * 0.7f, stroke)
        } else {
            c.drawRect(cx - g, cy - g, cx + g * 0.3f, cy + g * 0.3f, stroke)
            c.drawRect(cx - g * 0.3f, cy - g * 0.3f, cx + g, cy + g, stroke)
        }
    }

    private fun guide(c: Canvas, u: Float, v: Float, k: Float) {
        val cx = X(u); val cy = Y(v)
        dome(c, cx, cy, 3.2f * s, k, key)
        // Kumori's mark: a small cloud.
        fill.shader = null
        fill.color = ink(k)
        val g = 0.95f * s
        c.drawCircle(cx - 0.9f * g, cy + 0.3f * g, 0.9f * g, fill)
        c.drawCircle(cx + 0.2f * g, cy - 0.3f * g, 1.2f * g, fill)
        c.drawCircle(cx + 1.2f * g, cy + 0.4f * g, 0.75f * g, fill)
        r.set(cx - 1.8f * g, cy + 0.2f * g, cx + 1.95f * g, cy + 1.15f * g)
        c.drawRoundRect(r, 0.5f * g, 0.5f * g, fill)
    }

    /** The shell alone, barely there, for when nothing is connected. */
    private fun ghost(c: Canvas) {
        fill.shader = null
        fill.color = 0x0DFFFFFF
        c.drawPath(body, fill)
        rim.alpha = 140
        c.drawPath(body, rim)
        rim.alpha = 255
        stroke.color = 0x14FFFFFF
        stroke.strokeWidth = 0.35f * s
        c.drawCircle(X(LSX), Y(LSY), 7.8f * s, stroke)
        c.drawCircle(X(RSX), Y(RSY), 7.8f * s, stroke)
        c.drawPath(dpad, stroke)
        for ((u, v) in listOf(FX to FY - FD, FX - FD to FY, FX + FD to FY, FX to FY + FD)) c.drawCircle(X(u), Y(v), 3.4f * s, stroke)
        c.drawCircle(X(50f), Y(16f), 3.2f * s, stroke)
    }
}
