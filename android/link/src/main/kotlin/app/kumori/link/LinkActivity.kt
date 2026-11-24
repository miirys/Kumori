package app.kumori.link

import android.app.Activity
import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.input.InputManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.TypedValue
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * The whole app: one screen that must stay open, because Android only gives controller
 * input to the app in front.
 */
class LinkActivity : Activity(), InputManager.InputDeviceListener {
    private lateinit var regular: Typeface
    private lateinit var bold: Typeface
    private lateinit var status: TextView
    private lateinit var detail: TextView
    private lateinit var address: TextView
    private lateinit var padsRow: LinearLayout
    private lateinit var empty: TextView
    private val views = HashMap<Int, PadView>()
    private val main = Handler(Looper.getMainLooper())
    private var focused = true

    private val pads = Pads(onChange = ::changed, onGone = ::gone)
    private var usbPads: app.kumori.link.usb.UsbPadDriver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        regular = resources.getFont(R.font.inter_medium)
        bold = resources.getFont(R.font.inter_semibold)
        setContentView(layout())

        Link.start(applicationContext, ::header, ::stateJson)
        // 2.4 GHz dongles the box's kernel can't read (8BitDo's included) are read directly.
        usbPads = app.kumori.link.usb.UsbPadDriver(
            applicationContext,
            onState = { key, name, state -> main.post { pads.usb(key, name, state) } },
            onGone = { key -> main.post { pads.usbGone(key) } },
        ).also { it.start() }
        Link.relay.onStats = { main.post { showStats(it) } }
        Link.relay.onRumble = { slot, low, high, ms -> main.post { rumble(slot, low, high, ms) } }

        val im = getSystemService(Context.INPUT_SERVICE) as InputManager
        im.registerInputDeviceListener(this, main)
        LogBook.add("input", "devices at start:")
        for (id in InputDevice.getDeviceIds()) InputDevice.getDevice(id)?.let { LogBook.add("input", "  " + Pads.describe(it)) }
        // Claim pads that are already connected, so they show before the first press.
        for (id in InputDevice.getDeviceIds()) InputDevice.getDevice(id)?.let { if (pads.isPad(it)) pads.padFor(it)?.let(::changed) }
        refreshEmpty()
        showStats(Link.relay.stats())
    }

    override fun onDestroy() {
        (getSystemService(Context.INPUT_SERVICE) as InputManager).unregisterInputDeviceListener(this)
        Link.relay.onStats = null
        Link.relay.onRumble = null
        usbPads?.stop()
        if (isFinishing) Link.stop()
        super.onDestroy()
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        // Android normally holds joystick events until the next frame and hands them over in a
        // batch. Ask for each one the moment it arrives instead.
        if (Build.VERSION.SDK_INT >= 30) {
            window.decorView.requestUnbufferedDispatch(InputDevice.SOURCE_JOYSTICK or InputDevice.SOURCE_GAMEPAD)
            LogBook.add("input", "unbuffered joystick dispatch on")
        } else {
            LogBook.add("input", "Android ${Build.VERSION.RELEASE}: joystick events arrive once per frame")
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus == focused) return
        focused = hasFocus
        LogBook.add("app", if (hasFocus) "back in front, controllers live" else "lost focus: controllers sent as released until it's back")
        pads.all.values.forEach(::changed)
        refreshStatus()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (pads.key(event)) return true
        if (event.action == KeyEvent.ACTION_DOWN) LogBook.add("key", "not a controller: ${KeyEvent.keyCodeToString(event.keyCode)} from ${event.device?.name}")
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (pads.motion(event)) return true
        return super.dispatchGenericMotionEvent(event)
    }

    override fun onInputDeviceAdded(id: Int) {
        val dev = InputDevice.getDevice(id) ?: return
        LogBook.add("input", "added " + Pads.describe(dev))
        if (pads.isPad(dev)) pads.padFor(dev)?.let(::changed)
    }

    override fun onInputDeviceRemoved(id: Int) {
        LogBook.add("input", "removed id $id")
        pads.removed(id)
    }

    override fun onInputDeviceChanged(id: Int) {
        InputDevice.getDevice(id)?.let { LogBook.add("input", "changed " + Pads.describe(it)) }
    }

    private fun snapshot(p: Pad, flags: Int = 0): Snapshot =
        // A pad read over USB keeps working behind other apps. Android's own pads don't.
        if ((!focused && !p.usb) || flags != 0) Snapshot(p.slot, 0, 0, 0, 0, 0, 0, 0, flags or if (!focused && !p.usb) Relay.FLAG_PAUSED else 0)
        else Snapshot(p.slot, p.buttons, p.ltByte(), p.rtByte(), p.stick(p.lx, false), p.stick(p.ly, true), p.stick(p.rx, false), p.stick(p.ry, true), 0)

    private fun changed(p: Pad) {
        Link.relay.update(snapshot(p))
        val v = views.getOrPut(p.deviceId) { addPadView(p) }
        v.pad = p
        v.invalidate()
    }

    private fun gone(p: Pad) {
        Link.relay.update(snapshot(p, Relay.FLAG_GONE))
        views.remove(p.deviceId)?.let { padsRow.removeView(it.parent as View) }
        refreshEmpty()
    }

    private fun rumble(slot: Int, low: Int, high: Int, ms: Int) {
        val p = pads.all.values.firstOrNull { it.slot == slot } ?: return
        val dev = InputDevice.getDevice(p.deviceId) ?: return
        @Suppress("DEPRECATION")
        val vib: Vibrator = dev.vibrator
        if (!vib.hasVibrator()) return
        val amp = maxOf(low, high)
        if (amp == 0 || ms == 0) { vib.cancel(); return }
        runCatching { vib.vibrate(VibrationEffect.createOneShot(ms.toLong().coerceIn(1, 5000), amp.coerceIn(1, 255))) }
    }

    // UI

    private fun dp(v: Float) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics)
    private fun text(size: Float, color: Int, face: Typeface = regular) = TextView(this).apply {
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        setTextColor(color)
        typeface = face
        includeFontPadding = false
    }

    private fun layout(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xFF000000.toInt())
            // TV overscan: keep everything inside the safe area.
            setPadding(dp(64f).toInt(), dp(40f).toInt(), dp(64f).toInt(), dp(32f).toInt())
        }
        root.addView(text(30f, 0xFFECE8F0.toInt(), bold).apply { text = "Kumori Link" })
        status = text(20f, 0xFFF27BA6.toInt(), bold).apply { setPadding(0, dp(18f).toInt(), 0, 0) }
        detail = text(15f, 0xFF9A93A3.toInt()).apply { setPadding(0, dp(6f).toInt(), 0, 0) }
        address = text(15f, 0xFF9A93A3.toInt()).apply { setPadding(0, dp(6f).toInt(), 0, 0) }
        root.addView(status); root.addView(detail); root.addView(address)

        val body = FrameLayout(this)
        padsRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER }
        empty = text(18f, 0xFF9A93A3.toInt()).apply {
            gravity = Gravity.CENTER
            text = "No controller yet. Turn one on or press a button."
        }
        body.addView(padsRow, FrameLayout.LayoutParams(-1, -1))
        body.addView(empty, FrameLayout.LayoutParams(-1, -1))
        root.addView(body, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = dp(24f).toInt(); bottomMargin = dp(20f).toInt() })

        root.addView(text(14f, 0xFF6E6876.toInt()).apply {
            text = "Keep this open while you play. Back on the remote closes it."
        })
        return root
    }

    private fun addPadView(p: Pad): PadView {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply { setColor(0xFF110F14.toInt()); cornerRadius = dp(20f); setStroke(dp(1f).toInt(), 0xFF2A2530.toInt()) }
            setPadding(dp(20f).toInt(), dp(16f).toInt(), dp(20f).toInt(), dp(16f).toInt())
        }
        card.addView(text(15f, 0xFFECE8F0.toInt(), bold).apply { text = "Player ${p.slot + 1}"; })
        card.addView(text(13f, 0xFF9A93A3.toInt()).apply { text = p.name; isSingleLine = true; setPadding(0, dp(4f).toInt(), 0, dp(10f).toInt()) })
        val v = PadView(this, bold)
        card.addView(v, LinearLayout.LayoutParams(-1, 0, 1f))
        val lp = LinearLayout.LayoutParams(0, -1, 1f).apply { marginStart = dp(10f).toInt(); marginEnd = dp(10f).toInt() }
        // Keep player order left to right.
        val index = views.values.count { (it.pad?.slot ?: 9) < p.slot }
        padsRow.addView(card, index.coerceAtMost(padsRow.childCount), lp)
        empty.visibility = View.GONE
        return v
    }

    private fun refreshEmpty() { empty.visibility = if (views.isEmpty()) View.VISIBLE else View.GONE }

    private var lastStats: Relay.Stats? = null

    private fun showStats(s: Relay.Stats) { lastStats = s; refreshStatus() }

    private fun refreshStatus() {
        val s = lastStats ?: return
        status.text = when {
            !focused -> "Paused: Kumori Link isn't in front"
            s.subscriber != null -> "Sending to ${s.subscriberName ?: "Apple TV"}"
            else -> "Waiting for Apple TV"
        }
        detail.text = when {
            s.subscriber != null -> buildString {
                append(s.subscriber.substringBefore(':'))
                s.rttMs?.let { append("   ·   round trip %.1f ms".format(it)) }
                append("   ·   ${s.sentPerSecond} packets/s")
                if (s.lost > 0) append("   ·   ${s.lost} pings lost")
            }
            else -> "On the Apple TV, open Kumori › Settings › Controllers and pick this box."
        }
        val ip = addresses().firstOrNull()?.second
        address.text = if (ip != null) "Log page   http://$ip:${LogServer.PORT}" else "No network"
    }

    // Log page

    private fun header(): String = buildString {
        appendLine("Kumori Link ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
        appendLine("Device: ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE}), Android ${Build.VERSION.RELEASE} / API ${Build.VERSION.SDK_INT}")
        appendLine("Uptime: ${LogBook.uptime()}   in front: $focused")
        appendLine("Network: " + addresses().joinToString(", ") { "${it.first} ${it.second}" })
        val s = Link.relay.stats()
        appendLine("Apple TV: ${s.subscriber ?: "none"} ${s.subscriberName ?: ""}  rtt ${s.rttMs?.let { "%.2f".format(it) } ?: "-"} ms (min ${s.rttMinMs?.let { "%.2f".format(it) } ?: "-"}, max ${s.rttMaxMs?.let { "%.2f".format(it) } ?: "-"})  sent ${s.sent}  ${s.sentPerSecond}/s  lost pings ${s.lost}  udp ${s.port}")
        appendLine("Input devices:")
        for (id in InputDevice.getDeviceIds()) InputDevice.getDevice(id)?.let { appendLine("  " + Pads.describe(it)) }
    }

    private fun stateJson(): String {
        val s = Link.relay.stats()
        val list = JSONArray()
        val ps = runCatchingOnMain { pads.all.values.map { p -> JSONObject().apply {
            put("player", p.slot + 1); put("name", p.name); put("buttons", "0x%04x".format(p.buttons))
            put("lt", p.ltByte()); put("rt", p.rtByte())
            put("left", "%.3f, %.3f".format(p.lx, p.ly)); put("right", "%.3f, %.3f".format(p.rx, p.ry))
            put("events", p.events)
        } } } ?: emptyList()
        ps.forEach { list.put(it) }
        return JSONObject().apply {
            put("inFront", focused)
            put("appleTv", s.subscriber ?: JSONObject.NULL)
            put("appleTvName", s.subscriberName ?: JSONObject.NULL)
            put("roundTripMs", s.rttMs ?: JSONObject.NULL)
            put("packetsPerSecond", s.sentPerSecond)
            put("packetsSent", s.sent)
            put("lostPings", s.lost)
            put("controllers", list)
            put("uptime", LogBook.uptime())
        }.toString()
    }

    /** Runs [f] on the main thread and waits up to 200 ms, since pad state lives there. */
    private fun <T> runCatchingOnMain(f: () -> T): T? {
        if (Looper.myLooper() == Looper.getMainLooper()) return f()
        val q = java.util.concurrent.ArrayBlockingQueue<Result<T>>(1)
        main.post { q.offer(runCatching(f)) }
        return q.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS)?.getOrNull()
    }

    private fun addresses(): List<Pair<String, String>> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { nif ->
            nif.inetAddresses.toList().filterIsInstance<Inet4Address>().map { nif.name to it.hostAddress!! }
        }.sortedBy { if (it.first.startsWith("eth")) 0 else 1 }
    }.getOrDefault(emptyList())
}

/** Network parts live as long as the process, so a recreated screen doesn't rebind ports. */
object Link {
    lateinit var relay: Relay
    private var web: LogServer? = null
    private var started = false
    private var header: () -> String = { "" }
    private var state: () -> String = { "{}" }

    fun start(context: Context, header: () -> String, state: () -> String) {
        this.header = header
        this.state = state
        if (started) return
        started = true
        LogBook.add("app", "Kumori Link ${BuildConfig.VERSION_NAME} on ${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}")
        relay = Relay(context)
        relay.start("Kumori Link · ${Build.MODEL}")
        web = LogServer({ this.state() }, { this.header() }).also { it.start() }
    }

    fun stop() {
        if (!started) return
        started = false
        relay.stop()
        web?.stop()
        web = null
    }
}
