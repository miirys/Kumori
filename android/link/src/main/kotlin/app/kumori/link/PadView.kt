package app.kumori.link

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.view.View

/** A live drawing of one controller: what the Apple TV is being told, as it happens. */
class PadView(context: Context, private val font: Typeface) : View(context) {
    var pad: Pad? = null
        set(value) { field = value; invalidate() }

    private val accent = 0xFFF27BA6.toInt()
    private val idle = 0xFF2A2530.toInt()
    private val dim = 0xFF9A93A3.toInt()
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = font; textAlign = Paint.Align.CENTER }
    private val r = RectF()

    override fun onDraw(c: Canvas) {
        val p = pad ?: return
        val w = width.toFloat()
        val h = height.toFloat()
        val u = minOf(w / 16f, h / 9f)
        val b = p.buttons
        fun on(bit: Int) = b and bit != 0
        stroke.strokeWidth = u * 0.12f
        label.textSize = u * 0.55f

        fun button(cx: Float, cy: Float, rad: Float, pressed: Boolean, text: String) {
            fill.color = if (pressed) accent else idle
            c.drawCircle(cx, cy, rad, fill)
            label.color = if (pressed) 0xFF16111B.toInt() else dim
            c.drawText(text, cx, cy + label.textSize * 0.36f, label)
        }
        fun pill(x: Float, y: Float, pw: Float, ph: Float, pressed: Boolean, text: String) {
            fill.color = if (pressed) accent else idle
            r.set(x - pw / 2, y - ph / 2, x + pw / 2, y + ph / 2)
            c.drawRoundRect(r, ph / 2, ph / 2, fill)
            label.color = if (pressed) 0xFF16111B.toInt() else dim
            c.drawText(text, x, y + label.textSize * 0.36f, label)
        }
        fun trigger(x: Float, y: Float, tw: Float, th: Float, v: Int, text: String) {
            fill.color = idle
            r.set(x - tw / 2, y - th / 2, x + tw / 2, y + th / 2)
            c.drawRoundRect(r, th / 2, th / 2, fill)
            if (v > 0) {
                fill.color = accent
                r.set(x - tw / 2, y - th / 2, x - tw / 2 + tw * v / 255f, y + th / 2)
                c.drawRoundRect(r, th / 2, th / 2, fill)
            }
            label.color = if (v > 128) 0xFF16111B.toInt() else dim
            c.drawText(text, x, y + label.textSize * 0.36f, label)
        }
        fun stick(cx: Float, cy: Float, rad: Float, x: Float, y: Float, pressed: Boolean) {
            stroke.color = if (pressed) accent else idle
            c.drawCircle(cx, cy, rad, stroke)
            fill.color = accent
            c.drawCircle(cx + x * rad * 0.75f, cy + y * rad * 0.75f, rad * 0.28f, fill)
        }

        trigger(w * 0.2f, u * 0.8f, u * 3.4f, u * 0.9f, p.ltByte(), "LT")
        trigger(w * 0.8f, u * 0.8f, u * 3.4f, u * 0.9f, p.rtByte(), "RT")
        pill(w * 0.2f, u * 2.0f, u * 3.4f, u * 0.9f, on(Btn.LB), "LB")
        pill(w * 0.8f, u * 2.0f, u * 3.4f, u * 0.9f, on(Btn.RB), "RB")

        val row = h * 0.56f
        // D-pad
        val dx = w * 0.17f
        val d = u * 0.95f
        button(dx, row - d, u * 0.5f, on(Btn.UP), "▲")
        button(dx, row + d, u * 0.5f, on(Btn.DOWN), "▼")
        button(dx - d, row, u * 0.5f, on(Btn.LEFT), "◀")
        button(dx + d, row, u * 0.5f, on(Btn.RIGHT), "▶")
        // Face buttons, Xbox positions
        val fx = w * 0.83f
        button(fx, row + d, u * 0.55f, on(Btn.A), "A")
        button(fx + d, row, u * 0.55f, on(Btn.B), "B")
        button(fx - d, row, u * 0.55f, on(Btn.X), "X")
        button(fx, row - d, u * 0.55f, on(Btn.Y), "Y")
        // Middle
        pill(w * 0.41f, row - u * 0.9f, u * 1.6f, u * 0.75f, on(Btn.BACK), "View")
        pill(w * 0.59f, row - u * 0.9f, u * 1.6f, u * 0.75f, on(Btn.START), "Menu")
        button(w * 0.5f, row + u * 0.1f, u * 0.5f, on(Btn.GUIDE), "⌂")
        // Sticks
        val sy = h - u * 1.6f
        stick(w * 0.36f, sy, u * 1.3f, p.lx, p.ly, on(Btn.LS))
        stick(w * 0.64f, sy, u * 1.3f, p.rx, p.ry, on(Btn.RS))
    }
}
