package app.kumori.link

import android.app.Activity
import android.content.Context
import android.hardware.input.InputManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import app.kumori.link.ui.LinkScreen
import app.kumori.link.ui.Look
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * The whole app: one screen that must stay open, because Android only gives controller
 * input to the app in front.
 */
class LinkActivity : Activity(), InputManager.InputDeviceListener {
    private lateinit var screen: LinkScreen
    private val main = Handler(Looper.getMainLooper())
    private var focused = true

    private val pads = Pads(onChange = ::changed, onGone = ::gone)
    private var usbPads: app.kumori.link.usb.UsbPadDriver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        Look.load(this)
        screen = LinkScreen(this)
        setContentView(screen)

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
        showStats(Link.relay.stats())
        main.postDelayed(recheck, 250)
    }

    override fun onDestroy() {
        (getSystemService(Context.INPUT_SERVICE) as InputManager).unregisterInputDeviceListener(this)
        Link.relay.onStats = null
        Link.relay.onRumble = null
        usbPads?.stop()
        main.removeCallbacks(recheck)
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
        // Menu on the remote shows the version and where the log page is.
        if (event.action == KeyEvent.ACTION_UP && (event.keyCode == KeyEvent.KEYCODE_MENU || event.keyCode == KeyEvent.KEYCODE_INFO)) { screen.info(); return true }
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

    private fun snapshot(p: Pad, flags: Int = 0): Snapshot {
        // A pad read over USB keeps working behind other apps. Android's own pads don't.
        if ((!focused && !p.usb) || flags != 0) return Snapshot(p.slot, 0, 0, 0, 0, 0, 0, 0, flags or if (!focused && !p.usb) Relay.FLAG_PAUSED else 0)
        val now = android.os.SystemClock.uptimeMillis()
        val (lx, ly) = p.left(now)
        val (rx, ry) = p.right(now)
        return Snapshot(p.slot, p.buttons, p.ltByte(), p.rtByte(), p.stick(lx, false), p.stick(ly, true), p.stick(rx, false), p.stick(ry, true), 0)
    }

    // A stick that has gone still sends no more events, so the correction for its resting
    // point would never go out. Look again a few times a second and send it if it changed.
    private val lastSent = HashMap<Int, Snapshot>()
    private val recheck = object : Runnable {
        override fun run() {
            for (p in pads.all.values) {
                val s = snapshot(p)
                if (lastSent[p.deviceId] != s) { lastSent[p.deviceId] = s; Link.relay.update(s) }
            }
            main.postDelayed(this, 250)
        }
    }

    private fun changed(p: Pad) {
        val s = snapshot(p)
        lastSent[p.deviceId] = s
        Link.relay.update(s)
        screen.show(p, focused)
    }

    private fun gone(p: Pad) {
        Link.relay.update(snapshot(p, Relay.FLAG_GONE))
        screen.remove(p.deviceId)
        refreshStatus()
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

    private fun refreshStatus() {
        lastStats?.let { screen.status(it, ip(), focused) }
    }

    // Stats arrive with every packet while playing. Listing the network interfaces each time
    // made the screen stutter, so the address is looked up at most every few seconds.
    private var ipAt = 0L
    private var ip: String? = null
    private fun ip(): String? {
        val now = android.os.SystemClock.uptimeMillis()
        if (ipAt == 0L || now - ipAt > 4000) { ip = addresses().firstOrNull()?.second; ipAt = now }
        return ip
    }

    private var lastStats: Relay.Stats? = null

    private fun showStats(s: Relay.Stats) { lastStats = s; refreshStatus() }

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
    /** The name the Apple TV lists this box under. Kumori remembers the box by it, so it must not change. */
    val name get() = "Kumori Link · ${Build.MODEL}"
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
        relay.start(name)
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
