package app.kumori.link.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.view.View
import android.widget.FrameLayout
import app.kumori.link.PadView
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.random.Random

/** A soft round fall-off, made once and scaled wherever light spills. */
object Soft {
    val white: Bitmap by lazy {
        val n = 128
        val bmp = Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888)
        val px = IntArray(n * n)
        val rnd = Random(7)
        val c = (n - 1) / 2f
        for (y in 0 until n) for (x in 0 until n) {
            val d = hypot(x - c, y - c) / c
            val e = (1f - d).coerceIn(0f, 1f)
            val v = exp(-d * d * 3f) * e * e * (3f - 2f * e)
            val a = (v * 255f + rnd.nextFloat() - 0.5f).coerceIn(0f, 255f).toInt()
            px[y * n + x] = (a shl 24) or 0xFFFFFF
        }
        bmp.setPixels(px, 0, n, 0, 0, n, n)
        bmp
    }
}

/**
 * The room the controller sits in: black, one broad light overhead, and a floor that catches a
 * little of it. Drawn once into a picture, so nothing behind the controller costs anything per
 * frame. Presses warm the overhead light for a moment; that is the only part that moves.
 */
class StageView(context: Context) : View(context) {
    var picture: Bitmap? = null; private set
    /** Bumped whenever [picture] is redrawn, so glass knows to sample it again. */
    var version = 0; private set
    /** The floor line, as a fraction of the height. Set by the screen before layout. */
    var horizon = 0.8f
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val lift = Paint(Paint.FILTER_BITMAP_FLAG)
    private val r = RectF()
    var energy = 0f
        set(v) { if (field != v) { field = v; invalidate() } }

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = render(w, h)

    /** Draws the room again, after [horizon] moved. */
    fun rebuild() { render(width, height); invalidate() }

    private fun render(w: Int, h: Int) {
        if (w == 0 || h == 0) return
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawColor(0xFF000000.toInt())
        // Dithered, so the dark gradients don't band on a TV.
        val p = Paint(Paint.ANTI_ALIAS_FLAG or Paint.DITHER_FLAG)
        val cx = w / 2f
        val fy = h * horizon
        // The overhead light: a wide oval pool, brightest just above the controller.
        val pool = RadialGradient(0f, 0f, 1f, intArrayOf(0xFF222225.toInt(), 0xFF111113.toInt(), 0xFF060607.toInt(), 0xFF000000.toInt()), floatArrayOf(0f, 0.35f, 0.7f, 1f), Shader.TileMode.CLAMP)
        pool.setLocalMatrix(Matrix().apply { setScale(w * 0.52f, h * 0.62f); postTranslate(cx, h * 0.3f) })
        p.shader = pool
        c.drawRect(0f, 0f, w.toFloat(), h.toFloat(), p)
        // The floor: a touch lighter where the light lands on it, fading toward the front.
        val floor = RadialGradient(0f, 0f, 1f, intArrayOf(0x2EFFFFFF, 0x0DFFFFFF, 0x00FFFFFF), floatArrayOf(0f, 0.5f, 1f), Shader.TileMode.CLAMP)
        floor.setLocalMatrix(Matrix().apply { setScale(w * 0.3f, h * 0.06f); postTranslate(cx, fy + h * 0.03f) })
        p.shader = floor
        // Only below the line where the controller stands, so none of it shows between the grips.
        c.drawRect(0f, fy - h * 0.004f, w.toFloat(), h.toFloat(), p)
        picture = bmp
        version++
    }

    override fun onDraw(c: Canvas) {
        picture?.let { c.drawBitmap(it, 0f, 0f, paint) }
        if (energy > 0.005f) {
            lift.alpha = (energy * 34).toInt()
            val rw = width * 0.42f; val rh = height * 0.4f
            r.set(width / 2f - rw, height * 0.38f - rh, width / 2f + rw, height * 0.38f + rh)
            c.drawBitmap(Soft.white, null, r, lift)
        }
    }
}

/**
 * The controller's reflection on the floor: the same drawing, flipped, fading out quickly.
 */
class Reflection(context: Context, private val pad: PadView) : View(context) {
    private val fade = Paint().apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN) }

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        fade.shader = LinearGradient(0f, 0f, 0f, h * 0.5f, 0x5C000000, 0x00000000, Shader.TileMode.CLAMP)
    }

    override fun onDraw(c: Canvas) {
        val save = c.saveLayer(0f, 0f, width.toFloat(), height.toFloat(), null)
        c.save()
        c.scale(1f, -1f, 0f, height / 2f)
        pad.render(c)
        c.restore()
        c.drawRect(0f, 0f, width.toFloat(), height.toFloat(), fade)
        c.restoreToCount(save)
    }
}

/** Where the light is, as an angle around glass edges. The screen moves it with the controller. */
object Lighting {
    /** Degrees, 0 to the right, -90 straight up. */
    var angle = -90f
        set(v) { if (field != v) { field = v; for (g in glass) g.invalidate() } }
    internal val glass = LinkedHashSet<View>()
}

/**
 * Liquid Glass, as on Apple TV: clear rather than frosted. What's behind shows through,
 * bent at the edges the way a thick lens bends it, with a bright rim where the light catches
 * it and a fainter one opposite. The rim highlights move with [Lighting.angle].
 *
 * It samples [stage]'s picture, so it sits on the stage and never on other glass.
 */
open class GlassCapsule(context: Context, private val stage: StageView) : FrameLayout(context) {
    private val mw = 28; private val mh = 6
    private val verts = FloatArray((mw + 1) * (mh + 1) * 2)
    private var source: Bitmap? = null
    private var builtFor = -1
    private var builtW = 0; private var builtH = 0
    private val at = IntArray(2); private val sat = IntArray(2)
    private val meshPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val mask = Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.DST_IN) }
    private val tint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val shade = Paint(Paint.ANTI_ALIAS_FLAG)
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val band = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private var sweep: SweepGradient? = null
    private val sweepM = Matrix()
    private val rect = RectF()
    /** How much lighter than what's behind. Selected parts use more. */
    var lift = 0.06f

    init { setWillNotDraw(false) }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); Lighting.glass.add(this) }
    override fun onDetachedFromWindow() { Lighting.glass.remove(this); super.onDetachedFromWindow() }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        // Rim light: bright where the light is, a faint second highlight opposite, dark between.
        sweep = SweepGradient(0f, 0f,
            intArrayOf(0xF2FFFFFF.toInt(), 0x33FFFFFF, 0x0AFFFFFF, 0x0AFFFFFF, 0x66FFFFFF, 0x0AFFFFFF, 0x0AFFFFFF, 0x33FFFFFF, 0xF2FFFFFF.toInt()),
            floatArrayOf(0f, 0.08f, 0.2f, 0.4f, 0.5f, 0.6f, 0.8f, 0.92f, 1f))
        shade.shader = LinearGradient(0f, 0f, 0f, h.toFloat(), 0x00000000, 0x33000000, Shader.TileMode.CLAMP)
        builtFor = -1
    }

    /** Samples the stage behind this capsule and bends it at the rim, like thick glass. */
    private fun build() {
        val pic = stage.picture ?: return
        getLocationInWindow(at); stage.getLocationInWindow(sat)
        val x0 = at[0] - sat[0]; val y0 = at[1] - sat[1]
        val w = width; val h = height
        val m = (h * 0.45f).toInt()
        val sx = (x0 - m).coerceAtLeast(0); val sy = (y0 - m).coerceAtLeast(0)
        val sw = (w + 2 * m).coerceAtMost(pic.width - sx); val sh = (h + 2 * m).coerceAtMost(pic.height - sy)
        if (sw <= 0 || sh <= 0) return
        source = Bitmap.createBitmap(pic, sx, sy, sw, sh)
        val rad = h / 2f
        val inner = rad * 0.45f
        val cy = rad
        var i = 0
        for (j in 0..mh) for (k in 0..mw) {
            // Where this grid point of the sample lies, relative to the capsule.
            val px = sx - x0 + sw * k / mw.toFloat()
            val py = sy - y0 + sh * j / mh.toFloat()
            // Nearest point on the capsule's spine, and how far out from it.
            val qx = px.coerceIn(rad, w - rad)
            val vx = px - qx; val vy = py - cy
            val d = hypot(vx, vy)
            var nx = px; var ny = py
            if (d > inner && d > 0.001f) {
                // Squeeze the band from the inner edge out past the rim into the rim, so the
                // world just outside the glass shows bent around its edge.
                val t = ((d - inner) / (rad + m - inner)).coerceIn(0f, 1f)
                val nd = inner + (rad - inner) * (1f - (1f - t) * (1f - t))
                nx = qx + vx / d * nd; ny = cy + vy / d * nd
            }
            verts[i++] = nx; verts[i++] = ny
        }
        builtFor = stage.version; builtW = w; builtH = h
    }

    override fun onDraw(c: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        val rad = h / 2f
        if (builtFor != stage.version || builtW != width || builtH != height) build()
        rect.set(0f, 0f, w, h)
        source?.let {
            val layer = c.saveLayer(0f, 0f, w, h, null)
            c.drawBitmapMesh(it, mw, mh, verts, 0, null, 0, meshPaint)
            c.drawRoundRect(rect, rad, rad, mask)
            c.restoreToCount(layer)
        }
        tint.color = Look.alpha(0xFFFFFFFF.toInt(), lift)
        c.drawRoundRect(rect, rad, rad, tint)
        c.drawRoundRect(rect, rad, rad, shade)
        // The rim: a hairline that's bright where the light hits, and a wider soft band inside
        // it, the light carried through the glass's thick edge.
        sweepM.setRotate(Lighting.angle)
        sweepM.postTranslate(w / 2f, h / 2f)
        sweep?.setLocalMatrix(sweepM)
        val dpx = resources.displayMetrics.density
        band.shader = sweep
        band.alpha = 40
        band.strokeWidth = 5f * dpx
        rect.inset(2.5f * dpx, 2.5f * dpx)
        c.drawRoundRect(rect, rad - 2.5f * dpx, rad - 2.5f * dpx, band)
        rect.set(0f, 0f, w, h)
        edge.shader = sweep
        edge.strokeWidth = max(1f, 1.1f * dpx)
        val e = edge.strokeWidth / 2
        rect.inset(e, e)
        c.drawRoundRect(rect, rad - e, rad - e, edge)
    }
}
