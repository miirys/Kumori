package app.kumori.link.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.os.SystemClock
import android.view.Choreographer
import android.view.View
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.random.Random

/**
 * The light behind everything: a few soft pools of white drifting over true black, the same as
 * Settings on the Apple TV. It answers what's happening: a press on any controller lifts it a
 * little, and when an Apple TV connects the light opens up and a faint pink pool joins in.
 *
 * Glass panels read the same pools to draw the light diffused through themselves, so the light
 * and the glass always agree.
 */
object Light {
    class Pool(
        val pink: Boolean, val alpha: Float,
        val x: Float, val y: Float, val radius: Float,
        val wanderX: Float, val wanderY: Float, val period: Float, val phase: Float,
    ) {
        // Where it is this frame, in pixels of the backdrop, and how strong.
        var cx = 0f; var cy = 0f; var r = 0f; var a = 0f
    }

    val pools = listOf(
        Pool(false, 0.15f, 0.14f, 0.82f, 0.26f, 0.12f, 0.08f, 47f, 0f),
        Pool(false, 0.12f, 0.88f, 0.16f, 0.22f, 0.08f, 0.10f, 59f, 1.7f),
        Pool(false, 0.09f, 0.58f, 0.96f, 0.24f, 0.14f, 0.05f, 71f, 3.1f),
        Pool(false, 0.07f, 0.40f, 0.04f, 0.18f, 0.10f, 0.05f, 83f, 4.4f),
        Pool(true, 0.11f, 0.74f, 0.64f, 0.24f, 0.09f, 0.07f, 67f, 2.3f),
    )

    private var width = 1f
    private var height = 1f
    private var energy = 0f
    private var linked = 0f
    private var linkedTarget = 0f
    private var last = 0L
    private val listeners = LinkedHashSet<View>()

    /** Something was pressed: the light lifts for a moment. */
    fun kick(amount: Float) { energy = min(1f, energy + amount) }

    fun linked(on: Boolean) { linkedTarget = if (on) 1f else 0f }

    /** Glass that should redraw when the light moves. */
    fun watch(v: View) { listeners.add(v) }
    fun unwatch(v: View) { listeners.remove(v) }

    /** Whether anything is changing quickly enough to want every frame instead of every other. */
    val lively get() = energy > 0.02f || kotlin.math.abs(linked - linkedTarget) > 0.01f

    internal fun step(w: Int, h: Int, now: Long) {
        width = max(1, w).toFloat(); height = max(1, h).toFloat()
        val dt = if (last == 0L) 0f else ((now - last) / 1000f).coerceIn(0f, 0.1f)
        last = now
        energy *= exp(-dt / 0.9f)
        // Ease toward linked, quick to start and long to settle, over about a second and a half.
        linked += (linkedTarget - linked) * (1f - exp(-dt / 0.45f))
        val t = if (Look.motion) now / 1000f else 0f
        val lift = 1f + 0.55f * energy
        for (p in pools) {
            val ang = t / p.period * 6.2831855f + p.phase
            p.cx = (p.x + p.wanderX * sin(ang)) * width
            p.cy = (p.y + p.wanderY * sin(ang * 1.37f + 0.8f)) * height
            val bloom = if (p.pink) linked else 0.82f + 0.18f * linked
            p.r = p.radius * width * (0.78f + 0.22f * bloom) * (1f + 0.05f * sin(ang * 0.73f)) * (1f + 0.06f * energy)
            p.a = (p.alpha * bloom * lift).coerceAtMost(1f)
        }
        for (v in listeners) v.invalidate()
    }

    /** A soft round fall-off, drawn once and scaled for every pool. */
    val white: Bitmap by lazy { pool(Color.WHITE) }
    val pink: Bitmap by lazy { pool(Look.accent) }

    private fun pool(color: Int): Bitmap {
        val n = 192
        val bmp = Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888)
        val px = IntArray(n * n)
        val rnd = Random(7)
        val c = (n - 1) / 2f
        for (y in 0 until n) for (x in 0 until n) {
            val d = kotlin.math.hypot(x - c, y - c) / c
            // Gaussian body with a smooth end at the edge, so nothing draws a rim when scaled.
            val edge = (1f - d).coerceIn(0f, 1f)
            val v = exp(-d * d * 3.2f) * edge * edge * (3f - 2f * edge)
            // A little dither, so the fall-off doesn't step on an 8-bit screen.
            val a = (v * 255f + rnd.nextFloat() - 0.5f).coerceIn(0f, 255f).toInt()
            px[y * n + x] = (a shl 24) or (color and 0xFFFFFF)
        }
        bmp.setPixels(px, 0, n, 0, 0, n, n)
        return bmp
    }
}

/** Full-bleed black with the light drifting on it, a vignette and fine grain. */
class LightView(context: Context) : View(context), Choreographer.FrameCallback {
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val dst = RectF()
    private val vignette = Paint()
    private val grain = Paint()
    private var frame = 0
    private var running = false

    init {
        // Grain, at screen resolution. It hides the banding that dark gradients get on TVs.
        val n = 128
        val bmp = Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888)
        val rnd = Random(11)
        val px = IntArray(n * n) { val v = rnd.nextInt(256); (rnd.nextInt(10) shl 24) or (v shl 16) or (v shl 8) or v }
        bmp.setPixels(px, 0, n, 0, 0, n, n)
        grain.shader = BitmapShader(bmp, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT)
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        vignette.shader = RadialGradient(w / 2f, h * 0.45f, max(w, h) * 0.75f,
            intArrayOf(0x00000000, 0x00000000, 0x8C000000.toInt()), floatArrayOf(0f, 0.45f, 1f), Shader.TileMode.CLAMP)
        Light.step(w, h, SystemClock.uptimeMillis())
    }

    override fun onAttachedToWindow() { super.onAttachedToWindow(); running = true; Choreographer.getInstance().postFrameCallback(this) }
    override fun onDetachedFromWindow() { running = false; Choreographer.getInstance().removeFrameCallback(this); super.onDetachedFromWindow() }

    override fun doFrame(frameTimeNanos: Long) {
        if (!running) return
        // The drift is slow, so every other frame is plenty and leaves the main thread free for
        // controller input. A press or a new connection gets every frame until it settles.
        frame++
        if (Light.lively || frame % 2 == 0) Light.step(width, height, frameTimeNanos / 1_000_000)
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun onDraw(c: Canvas) {
        c.drawColor(Look.canvas)
        for (p in Light.pools) {
            if (p.a < 0.004f) continue
            paint.alpha = (p.a * 255).toInt()
            dst.set(p.cx - p.r, p.cy - p.r, p.cx + p.r, p.cy + p.r)
            c.drawBitmap(if (p.pink) Light.pink else Light.white, null, dst, paint)
        }
        c.drawPaint(vignette)
        c.drawPaint(grain)
    }
}

/**
 * Graphite glass: the light behind, spread wider and softer as if through frosting, a dark tint
 * over it, a sheen where light catches the top, and a hairline edge.
 */
class Glass(private val view: View, var radius: Float) {
    private val tint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Look.alpha(Look.glass, 0.62f) }
    private val frost = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val whiteShader = BitmapShader(Light.white, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
    private val pinkShader = BitmapShader(Light.pink, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
    private val sheen = Paint(Paint.ANTI_ALIAS_FLAG)
    private val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = Look.hairline }
    private val m = Matrix()
    private val rect = RectF()
    private val at = IntArray(2)
    private var sheenH = -1

    fun draw(c: Canvas, w: Int, h: Int, origin: View) {
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
        if (sheenH != h) {
            sheenH = h
            sheen.shader = android.graphics.LinearGradient(0f, 0f, 0f, h * 0.38f, 0x14FFFFFF, 0x00FFFFFF, Shader.TileMode.CLAMP)
        }
        c.drawRoundRect(rect, radius, radius, tint)
        view.getLocationInWindow(at)
        val ox = at[0].toFloat(); val oy = at[1].toFloat()
        origin.getLocationInWindow(at)
        val x0 = ox - at[0]; val y0 = oy - at[1]
        for (p in Light.pools) {
            if (p.a < 0.004f) continue
            val r = p.r * 1.35f
            if (p.cx + r < x0 || p.cx - r > x0 + w || p.cy + r < y0 || p.cy - r > y0 + h) continue
            val s = 2f * r / Light.white.width
            m.setScale(s, s)
            m.postTranslate(p.cx - r - x0, p.cy - r - y0)
            val sh = if (p.pink) pinkShader else whiteShader
            sh.setLocalMatrix(m)
            frost.shader = sh
            frost.alpha = (p.a * 0.85f * 255).toInt().coerceAtMost(255)
            c.drawRoundRect(rect, radius, radius, frost)
        }
        c.drawRoundRect(rect, radius, radius, sheen)
        edge.strokeWidth = max(1f, view.resources.displayMetrics.density * 0.75f)
        val e = edge.strokeWidth / 2
        rect.inset(e, e)
        c.drawRoundRect(rect, radius - e, radius - e, edge)
    }
}
