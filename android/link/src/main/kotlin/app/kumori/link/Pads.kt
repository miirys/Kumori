package app.kumori.link

import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import kotlin.math.abs
import kotlin.math.roundToInt

/** XInput button bits. These go on the wire unchanged and match Kumori's InputEncoder. */
object Btn {
    const val UP = 0x0001; const val DOWN = 0x0002; const val LEFT = 0x0004; const val RIGHT = 0x0008
    const val START = 0x0010; const val BACK = 0x0020; const val LS = 0x0040; const val RS = 0x0080
    const val LB = 0x0100; const val RB = 0x0200; const val GUIDE = 0x0400
    const val A = 0x1000; const val B = 0x2000; const val X = 0x4000; const val Y = 0x8000
}

class Pad(val deviceId: Int, val name: String, val slot: Int, val vendor: Int, val product: Int, val positional: Boolean, val sticksOnRx: Boolean) {
    var keys = 0
    var hat = 0
    var l2Key = false
    var r2Key = false
    var lt = 0f; var rt = 0f
    var lx = 0f; var ly = 0f; var rx = 0f; var ry = 0f
    var events = 0L

    val buttons get() = keys or hat
    fun ltByte() = ((if (l2Key) 1f else lt).coerceIn(0f, 1f) * 255).roundToInt()
    fun rtByte() = ((if (r2Key) 1f else rt).coerceIn(0f, 1f) * 255).roundToInt()
    /** Android's Y axes point down. XInput's point up. */
    fun stick(v: Float, flip: Boolean) = ((if (flip) -v else v).coerceIn(-1f, 1f) * 32767).roundToInt()
}

/** Turns Android key and motion events into one XInput-style state per controller. */
class Pads(private val onChange: (Pad) -> Unit, private val onGone: (Pad) -> Unit) {
    val all = LinkedHashMap<Int, Pad>()
    private val notPads = HashSet<Int>()

    fun isPad(dev: InputDevice?): Boolean {
        if (dev == null || dev.isVirtual) return false
        if (all.containsKey(dev.id)) return true
        if (dev.id in notPads) return false
        val s = dev.sources
        val claims = s and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
            s and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK
        // A TV remote that says it is a gamepad has no face buttons and no stick. Keep it
        // out, so its Back key still closes the app.
        val real = claims && (
            dev.hasKeys(KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_BUTTON_1, KeyEvent.KEYCODE_BUTTON_START).any { it } ||
                dev.getMotionRange(MotionEvent.AXIS_X, InputDevice.SOURCE_JOYSTICK) != null
            )
        if (!real) {
            notPads.add(dev.id)
            if (claims) LogBook.add("input", "ignored ${dev.name} (id ${dev.id}): says gamepad but has no buttons or stick")
        }
        return real
    }

    fun padFor(dev: InputDevice): Pad? {
        all[dev.id]?.let { return it }
        val used = all.values.map { it.slot }.toSet()
        val slot = (0..3).firstOrNull { it !in used } ?: return null
        fun has(axis: Int) = dev.getMotionRange(axis, InputDevice.SOURCE_JOYSTICK) != null
        val named = dev.hasKeys(KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_BUTTON_C, KeyEvent.KEYCODE_BUTTON_THUMBL, KeyEvent.KEYCODE_BUTTON_1)
        // Same rules as Kumori on Android: C without THUMBL, or numbered buttons, is a plain
        // HID pad in report order.
        val positional = (named[1] && !named[2]) || (named[3] && !named[0])
        val sticksOnRx = has(MotionEvent.AXIS_RX) && has(MotionEvent.AXIS_RY) &&
            has(MotionEvent.AXIS_Z) && has(MotionEvent.AXIS_RZ) &&
            !has(MotionEvent.AXIS_LTRIGGER) && !has(MotionEvent.AXIS_RTRIGGER) &&
            !has(MotionEvent.AXIS_BRAKE) && !has(MotionEvent.AXIS_GAS)
        val pad = Pad(dev.id, dev.name, slot, dev.vendorId, dev.productId, positional, sticksOnRx)
        all[dev.id] = pad
        LogBook.add("input", "player ${slot + 1}: ${dev.name} (id ${dev.id}, %04x:%04x) layout=%s sticks=%s".format(
            dev.vendorId, dev.productId, if (positional) "positional" else "standard", if (sticksOnRx) "Z/RZ triggers" else "Z/RZ right stick",
        ))
        return pad
    }

    fun removed(deviceId: Int) {
        notPads.remove(deviceId)
        all.remove(deviceId)?.let {
            LogBook.add("input", "player ${it.slot + 1} left: ${it.name}")
            onGone(it)
        }
    }

    /** Returns true when the key belonged to a controller and was used. */
    fun key(e: KeyEvent): Boolean {
        val dev = e.device
        if (!isPad(dev)) return false
        val p = padFor(dev!!) ?: return true
        val down = e.action == KeyEvent.ACTION_DOWN
        if (e.action == KeyEvent.ACTION_MULTIPLE) return true
        if (e.repeatCount > 0) return true
        val raw = e.keyCode
        val code = if (p.positional) positional(raw) else raw
        LogBook.add("key", "p${p.slot + 1} ${KeyEvent.keyCodeToString(raw)}${if (code != raw) " as ${KeyEvent.keyCodeToString(code)}" else ""} ${if (down) "down" else "up"} scan=${e.scanCode}")
        p.events++
        when (code) {
            KeyEvent.KEYCODE_BUTTON_L2 -> p.l2Key = down
            KeyEvent.KEYCODE_BUTTON_R2 -> p.r2Key = down
            else -> {
                val bit = bit(code)
                if (bit == 0) {
                    // Swallow it anyway: a stray controller key must not leave the app.
                    LogBook.add("key", "p${p.slot + 1} unmapped ${KeyEvent.keyCodeToString(raw)}")
                    return true
                }
                p.keys = if (down) p.keys or bit else p.keys and bit.inv()
            }
        }
        onChange(p)
        return true
    }

    private val lastLogged = HashMap<Int, Long>()

    fun motion(e: MotionEvent): Boolean {
        val dev = e.device
        if (!isPad(dev) || !e.isFromSource(InputDevice.SOURCE_JOYSTICK) || e.action != MotionEvent.ACTION_MOVE) return false
        val p = padFor(dev!!) ?: return true
        fun axis(a: Int): Float {
            val v = e.getAxisValue(a)
            val flat = dev.getMotionRange(a, e.source)?.flat ?: 0f
            return if (abs(v) <= flat) 0f else v
        }
        val hx = e.getAxisValue(MotionEvent.AXIS_HAT_X)
        val hy = e.getAxisValue(MotionEvent.AXIS_HAT_Y)
        var hat = 0
        if (hx < -0.5f) hat = hat or Btn.LEFT
        if (hx > 0.5f) hat = hat or Btn.RIGHT
        if (hy < -0.5f) hat = hat or Btn.UP
        if (hy > 0.5f) hat = hat or Btn.DOWN
        p.hat = hat
        p.lx = axis(MotionEvent.AXIS_X)
        p.ly = axis(MotionEvent.AXIS_Y)
        if (p.sticksOnRx) {
            // These triggers rest at -1 and reach 1 when fully pulled.
            fun pull(a: Int) = ((e.getAxisValue(a) + 1f) / 2f).coerceIn(0f, 1f).let { if (it < 0.02f) 0f else it }
            p.rx = axis(MotionEvent.AXIS_RX)
            p.ry = axis(MotionEvent.AXIS_RY)
            p.lt = pull(MotionEvent.AXIS_Z)
            p.rt = pull(MotionEvent.AXIS_RZ)
        } else {
            p.rx = axis(MotionEvent.AXIS_Z)
            p.ry = axis(MotionEvent.AXIS_RZ)
            p.lt = maxOf(axis(MotionEvent.AXIS_LTRIGGER), axis(MotionEvent.AXIS_BRAKE))
            p.rt = maxOf(axis(MotionEvent.AXIS_RTRIGGER), axis(MotionEvent.AXIS_GAS))
        }
        p.events++
        // Sticks move hundreds of times a second. Log a sample now and then, not all of them.
        val now = e.eventTime
        if (now - (lastLogged[p.deviceId] ?: 0L) >= 250) {
            lastLogged[p.deviceId] = now
            LogBook.add("axis", "p${p.slot + 1} L(%.2f %.2f) R(%.2f %.2f) LT %.2f RT %.2f hat(%.0f %.0f) batch=%d".format(
                p.lx, p.ly, p.rx, p.ry, p.lt, p.rt, hx, hy, e.historySize,
            ))
        }
        onChange(p)
        return true
    }

    private fun bit(code: Int) = when (code) {
        KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_DPAD_CENTER -> Btn.A
        KeyEvent.KEYCODE_BUTTON_B, KeyEvent.KEYCODE_BACK -> Btn.B
        KeyEvent.KEYCODE_BUTTON_X -> Btn.X
        KeyEvent.KEYCODE_BUTTON_Y -> Btn.Y
        KeyEvent.KEYCODE_BUTTON_L1 -> Btn.LB
        KeyEvent.KEYCODE_BUTTON_R1 -> Btn.RB
        KeyEvent.KEYCODE_BUTTON_SELECT -> Btn.BACK
        KeyEvent.KEYCODE_BUTTON_START, KeyEvent.KEYCODE_MENU -> Btn.START
        KeyEvent.KEYCODE_BUTTON_MODE -> Btn.GUIDE
        KeyEvent.KEYCODE_BUTTON_THUMBL -> Btn.LS
        KeyEvent.KEYCODE_BUTTON_THUMBR -> Btn.RS
        KeyEvent.KEYCODE_DPAD_UP -> Btn.UP
        KeyEvent.KEYCODE_DPAD_DOWN -> Btn.DOWN
        KeyEvent.KEYCODE_DPAD_LEFT -> Btn.LEFT
        KeyEvent.KEYCODE_DPAD_RIGHT -> Btn.RIGHT
        else -> 0
    }

    /** A plain HID pad's buttons in report order: four face buttons, bumpers, triggers, Select, Start, stick clicks, Home. */
    private fun positional(code: Int): Int {
        val n = when (code) {
            in KeyEvent.KEYCODE_BUTTON_1..KeyEvent.KEYCODE_BUTTON_16 -> code - KeyEvent.KEYCODE_BUTTON_1
            KeyEvent.KEYCODE_BUTTON_A -> 0
            KeyEvent.KEYCODE_BUTTON_B -> 1
            KeyEvent.KEYCODE_BUTTON_C -> 2
            KeyEvent.KEYCODE_BUTTON_X -> 3
            KeyEvent.KEYCODE_BUTTON_Y -> 4
            KeyEvent.KEYCODE_BUTTON_Z -> 5
            KeyEvent.KEYCODE_BUTTON_L1 -> 6
            KeyEvent.KEYCODE_BUTTON_R1 -> 7
            KeyEvent.KEYCODE_BUTTON_L2 -> 8
            KeyEvent.KEYCODE_BUTTON_R2 -> 9
            KeyEvent.KEYCODE_BUTTON_SELECT -> 10
            KeyEvent.KEYCODE_BUTTON_START -> 11
            KeyEvent.KEYCODE_BUTTON_MODE -> 12
            else -> return code
        }
        return when (n) {
            0 -> KeyEvent.KEYCODE_BUTTON_A
            1 -> KeyEvent.KEYCODE_BUTTON_B
            2 -> KeyEvent.KEYCODE_BUTTON_X
            3 -> KeyEvent.KEYCODE_BUTTON_Y
            4 -> KeyEvent.KEYCODE_BUTTON_L1
            5 -> KeyEvent.KEYCODE_BUTTON_R1
            6 -> KeyEvent.KEYCODE_BUTTON_L2
            7 -> KeyEvent.KEYCODE_BUTTON_R2
            8 -> KeyEvent.KEYCODE_BUTTON_SELECT
            9 -> KeyEvent.KEYCODE_BUTTON_START
            10 -> KeyEvent.KEYCODE_BUTTON_THUMBL
            11 -> KeyEvent.KEYCODE_BUTTON_THUMBR
            12 -> KeyEvent.KEYCODE_BUTTON_MODE
            else -> KeyEvent.KEYCODE_UNKNOWN
        }
    }

    companion object {
        /** One line per input device, with what it can do, for the log. */
        fun describe(dev: InputDevice): String {
            val keys = listOf(
                KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_BUTTON_B, KeyEvent.KEYCODE_BUTTON_C, KeyEvent.KEYCODE_BUTTON_X,
                KeyEvent.KEYCODE_BUTTON_Y, KeyEvent.KEYCODE_BUTTON_Z, KeyEvent.KEYCODE_BUTTON_L1, KeyEvent.KEYCODE_BUTTON_R1,
                KeyEvent.KEYCODE_BUTTON_L2, KeyEvent.KEYCODE_BUTTON_R2, KeyEvent.KEYCODE_BUTTON_THUMBL, KeyEvent.KEYCODE_BUTTON_THUMBR,
                KeyEvent.KEYCODE_BUTTON_START, KeyEvent.KEYCODE_BUTTON_SELECT, KeyEvent.KEYCODE_BUTTON_MODE, KeyEvent.KEYCODE_BUTTON_1,
                KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_DPAD_CENTER,
            )
            val present = dev.hasKeys(*keys.toIntArray())
            val keyNames = keys.filterIndexed { i, _ -> present[i] }.joinToString(" ") { KeyEvent.keyCodeToString(it).removePrefix("KEYCODE_") }
            val axes = dev.motionRanges.joinToString(" ") {
                "${MotionEvent.axisToString(it.axis).removePrefix("AXIS_")}[%.2f..%.2f flat %.2f]".format(it.min, it.max, it.flat)
            }
            return "id ${dev.id} \"${dev.name}\" %04x:%04x sources=0x%08x virtual=${dev.isVirtual} keys: $keyNames axes: $axes".format(
                dev.vendorId, dev.productId, dev.sources,
            )
        }
    }
}
