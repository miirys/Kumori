package app.kumori.tv

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.app.Instrumentation
import android.hardware.display.DisplayManager
import android.hardware.input.InputManager
import android.hardware.usb.UsbManager
import android.util.Rational
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import app.kumori.tv.data.AppState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.Executors
import app.kumori.tv.input.Btn
import app.kumori.tv.input.NavAction
import app.kumori.tv.input.PadHub
import app.kumori.tv.input.PadState
import app.kumori.tv.input.UsbPadDriver
import app.kumori.tv.stream.Keymap
import app.kumori.tv.stream.Streamer
import app.kumori.tv.ui.screens.AppRoot
import app.kumori.tv.ui.theme.KumoriTheme
import kotlin.math.abs

class MainActivity : ComponentActivity() {

    private lateinit var hub: PadHub
    private lateinit var usb: UsbPadDriver
    private lateinit var settings: Settings
    private lateinit var app: AppState
    private lateinit var streamer: Streamer
    private val scope = MainScope()

    /** Bluetooth (or kernel-recognised) pads that Android reads for us. */
    private class AndroidPad(val name: String, val route: String, val layout: Layout) {
        var keys = 0
        var hat = 0
        /** ZL/ZR style triggers that are plain buttons. */
        var leftTrigger = false
        var rightTrigger = false
        var axes = PadState.Idle
        var state = PadState.Idle
    }

    /** How a pad's keys and axes are laid out, which depends on the key layout Android picked. */
    private class Layout(
        /** Buttons arrive in report order (BUTTON_1.., or A B C X Y Z..) with no names to trust. */
        val positional: Boolean,
        /** Right stick on RX/RY and triggers on Z/RZ, as Android's generic layout reports xpad devices. */
        val sticksOnRx: Boolean,
    )

    private val androidPads = HashMap<Int, AndroidPad>()

    /** Window width in pixels. Compose state, so the interface rescales when the output changes. */
    private var widthPx by mutableIntStateOf(0)

    private val padWatcher = object : InputManager.InputDeviceListener {
        override fun onInputDeviceAdded(deviceId: Int) = Unit
        override fun onInputDeviceChanged(deviceId: Int) = Unit
        override fun onInputDeviceRemoved(deviceId: Int) {
            notPads.remove(deviceId)
            if (androidPads.remove(deviceId) != null) hub.gone("android:$deviceId")
        }
    }

    private val displayWatcher = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) {
            // A hotplug or TV switch hands out new mode ids, so the old request no longer counts.
            widthPx = resources.displayMetrics.widthPixels.coerceAtLeast(1)
            preferRefresh(settings.maxRefresh, streamer.streamFps)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        CrashLog.install(this)
        settings = Settings(this)
        hub = PadHub(::perform)
        usb = UsbPadDriver(
            this,
            onState = { id, name, s -> hub.update(id, name, "USB", s) },
            onGone = { id -> hub.gone(id) },
        )
        app = AppState(applicationContext, scope)
        streamer = Streamer(applicationContext, scope, app, settings, hub)
        CrashLog.onBackgroundFailure = { streamer.internalFailure(it) }
        // 1.2.0 crashed as the video started because of how it wrapped the decoder, not
        // because of the parts the automatic fixes turned off, so give those back.
        val mark = CrashLog.takeStreamingMark(this)
        val starting = mark != null && mark.second != "live"
        // The app went down while a stream was starting: avoid the part that was starting.
        val change = if (starting) settings.recoverFrom(mark!!.first, mark.second) else null
        // Reading exit traces and the system log can take a second on a slow box, so it stays
        // off the main thread and the first frame doesn't wait for it.
        val context = applicationContext
        scope.launch {
            app.problem = withContext(Dispatchers.IO) {
                val found = CrashLog.take(context)
                    ?: if (starting) CrashLog.Problem(System.currentTimeMillis(), "The app closed during a stream", "", native = true) else null
                // Keep the system's own account of the crash while it is still in the log.
                if (mark != null || found?.native == true) CrashLog.captureLog(context)
                found?.let { p ->
                    if (!starting) return@let p
                    p.copy(
                        summary = "It happened while ${CrashLog.stepName(mark!!.second)} (${p.summary})" +
                            (change?.let { ". The next stream will use $it" } ?: ""),
                    ).also { CrashLog.saveNote(context, it.summary) }
                }
            }
        }
        widthPx = resources.displayMetrics.widthPixels.coerceAtLeast(1)
        (getSystemService(INPUT_SERVICE) as InputManager).registerInputDeviceListener(padWatcher, null)
        (getSystemService(DISPLAY_SERVICE) as DisplayManager).registerDisplayListener(displayWatcher, null)
        setContent {
            // The whole interface is laid out in a fixed 960 × 540 dp space and drawn at the
            // window's real pixel size, so on a 4K output every glyph and edge is 4K-sharp and
            // the layout looks identical at 1080p.
            val px = widthPx
            LaunchedEffect(settings.maxRefresh, streamer.streamFps) { preferRefresh(settings.maxRefresh, streamer.streamFps) }
            // Only a stream keeps the screen awake. Idle menus let the screensaver start.
            val busy = streamer.phase.let { it != null && it !is Streamer.Phase.Ended }
            LaunchedEffect(busy) {
                usb.quiet = busy
                if (busy) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            CompositionLocalProvider(LocalDensity provides Density(px / 960f, 1f)) {
                KumoriTheme {
                    AppRoot(hub, app, settings, streamer, onExit = { finish() })
                }
            }
        }
    }

    /**
     * Many TVs sit at 60 Hz even when they can do more, which caps both the menus and the
     * stream. Ask for the fastest mode at the current resolution (the system changes it back
     * when the app leaves the screen). During a stream, ask for the slowest mode that still
     * shows every frame evenly: the stream's own rate or a whole multiple of it, so a 120 fps
     * stream gets 120 Hz rather than 144. Turning the setting off hands the choice back.
     */
    private fun preferRefresh(fastest: Boolean, streamFps: Int) {
        runCatching {
            @Suppress("DEPRECATION")
            val display = (if (Build.VERSION.SDK_INT >= 30) display else windowManager.defaultDisplay) ?: return
            val now = display.mode
            val modes = display.supportedModes
                .filter { it.physicalWidth == now.physicalWidth && it.physicalHeight == now.physicalHeight }
            fun even(hz: Float): Boolean {
                val ratio = hz / streamFps
                return ratio > 0.98f && abs(ratio - Math.round(ratio)) < 0.02f
            }
            val target = when {
                !fastest -> 0
                streamFps > 0 && even(now.refreshRate) -> now.modeId
                streamFps > 0 && modes.any { even(it.refreshRate) } ->
                    modes.filter { even(it.refreshRate) }.minByOrNull { it.refreshRate }!!.modeId
                else -> modes.maxByOrNull { it.refreshRate }
                    ?.takeIf { it.refreshRate > now.refreshRate + 1f }
                    ?.modeId ?: return
            }
            if (window.attributes.preferredDisplayModeId == target) return
            window.attributes = window.attributes.also { it.preferredDisplayModeId = target }
        }
    }

    /**
     * Controller presses reach the menus as key events we make ourselves, and those can't
     * do what a real remote key does: take the window out of touch mode (where nothing shows
     * focus) or give it its first focus. So do that by hand before the press goes in.
     * Without it a controller did nothing until the remote had been used once.
     */
    private fun wakeFocus() {
        runCatching {
            val decor = window.decorView
            if (decor.isInTouchMode || currentFocus == null) decor.requestFocusFromTouch()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && hub.pads.value.isNotEmpty()) wakeFocus()
    }

    override fun onResume() {
        super.onResume()
        // Pick up sessions started on another device while the app was in the background.
        if (app.signedIn) app.refreshSessions()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        widthPx = resources.displayMetrics.widthPixels.coerceAtLeast(1)
    }

    override fun onDestroy() {
        (getSystemService(INPUT_SERVICE) as InputManager).unregisterInputDeviceListener(padWatcher)
        (getSystemService(DISPLAY_SERVICE) as DisplayManager).unregisterDisplayListener(displayWatcher)
        streamer.leave()
        streamer.close()
        CrashLog.onBackgroundFailure = null
        typing.shutdown()
        scope.cancel()
        super.onDestroy()
    }

    override fun onStart() {
        super.onStart()
        usb.start()
    }

    /** Pressing Home during a game keeps it playing in a small window, like a video app. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!streamer.live || !packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return
        runCatching {
            enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build())
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        streamer.setPip(isInPictureInPictureMode)
        if (isInPictureInPictureMode && streamer.menuOpen) streamer.closeMenu()
    }

    override fun onStop() {
        // Going to the home screen leaves the game running in the cloud, ready to resume.
        when (streamer.phase) {
            null -> Unit
            is Streamer.Phase.Ended -> streamer.dismiss()
            else -> streamer.leave()
        }
        usb.stop()
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Launched again because a controller dongle was plugged in. The system has already
        // asked about this device, so don't ask a second time.
        usb.scan(ask = false)
    }

    /** Turns a controller action into what the menus understand: focus keys, select, back. */
    private fun perform(a: NavAction) {
        when (a) {
            NavAction.UP -> tap(KeyEvent.KEYCODE_DPAD_UP)
            NavAction.DOWN -> tap(KeyEvent.KEYCODE_DPAD_DOWN)
            NavAction.LEFT -> tap(KeyEvent.KEYCODE_DPAD_LEFT)
            NavAction.RIGHT -> tap(KeyEvent.KEYCODE_DPAD_RIGHT)
            NavAction.CONFIRM_DOWN -> inject(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER)
            NavAction.CONFIRM_UP -> inject(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER)
            NavAction.BACK -> onBackPressedDispatcher.onBackPressed()
            else -> Unit // Tabs and menu are read from PadHub.actions by the screens.
        }
    }

    private var confirmDownAt = 0L

    private fun tap(code: Int) {
        inject(KeyEvent.ACTION_DOWN, code)
        inject(KeyEvent.ACTION_UP, code)
    }

    private fun inject(action: Int, code: Int) {
        val now = SystemClock.uptimeMillis()
        val down = if (code == KeyEvent.KEYCODE_DPAD_CENTER) {
            if (action == KeyEvent.ACTION_DOWN) confirmDownAt = now
            confirmDownAt
        } else {
            now
        }
        if (action == KeyEvent.ACTION_DOWN) wakeFocus()
        // Synthetic events come from the virtual keyboard, so dispatchKeyEvent lets them through.
        val event = KeyEvent(down, now, action, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_DPAD)
        if (streamer.keyboardOpen) {
            // The on-screen keyboard only sees keys that come in through the system, so send
            // the press the long way round while it is up. That call may not run on this thread.
            typing.execute {
                if (runCatching { instrumentation.sendKeySync(event) }.isFailure) runOnUiThread { super@MainActivity.dispatchKeyEvent(event) }
            }
            return
        }
        super.dispatchKeyEvent(event)
    }

    private val instrumentation = Instrumentation()
    private val typing = Executors.newSingleThreadExecutor()

    /** Devices that claim to be a gamepad but have no gamepad buttons, such as some remotes. */
    private val notPads = HashSet<Int>()

    private fun isPad(dev: InputDevice?): Boolean {
        if (dev == null || dev.isVirtual) return false
        val s = dev.sources
        val claims = s and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD ||
            s and InputDevice.SOURCE_JOYSTICK == InputDevice.SOURCE_JOYSTICK
        if (!claims || dev.id in notPads) return false
        if (androidPads.containsKey(dev.id)) return true
        // A remote that reports as a gamepad has no face buttons and no stick. Treating it as
        // a pad would send its Back key to the game and leave no way to open the stream menu.
        val real = dev.hasKeys(KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_BUTTON_1, KeyEvent.KEYCODE_BUTTON_START).any { it } ||
            dev.getMotionRange(MotionEvent.AXIS_X, InputDevice.SOURCE_JOYSTICK) != null
        if (!real) notPads.add(dev.id)
        return real
    }

    private fun padFor(dev: InputDevice) = androidPads.getOrPut(dev.id) {
        fun has(axis: Int) = dev.getMotionRange(axis, InputDevice.SOURCE_JOYSTICK) != null
        val named = dev.hasKeys(
            KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_BUTTON_C, KeyEvent.KEYCODE_BUTTON_THUMBL, KeyEvent.KEYCODE_BUTTON_1,
        )
        // Fifteen named buttons with C and Z as gaps is Android's standard layout. Twelve or
        // fewer with C present, or numbered buttons, is a plain HID pad in report order.
        val positional = (named[1] && !named[2]) || (named[3] && !named[0])
        val sticksOnRx = has(MotionEvent.AXIS_RX) && has(MotionEvent.AXIS_RY) &&
            has(MotionEvent.AXIS_Z) && has(MotionEvent.AXIS_RZ) &&
            !has(MotionEvent.AXIS_LTRIGGER) && !has(MotionEvent.AXIS_RTRIGGER) &&
            !has(MotionEvent.AXIS_BRAKE) && !has(MotionEvent.AXIS_GAS)
        val wired = runCatching {
            (getSystemService(USB_SERVICE) as UsbManager).deviceList.values
                .any { it.vendorId == dev.vendorId && it.productId == dev.productId }
        }.getOrDefault(false)
        AndroidPad(dev.name, if (wired) "USB" else "Bluetooth", Layout(positional, sticksOnRx))
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val dev = event.device
        if (isPad(dev)) {
            val p = padFor(dev!!)
            val down = event.action == KeyEvent.ACTION_DOWN
            val code = if (p.layout.positional) positional(event.keyCode) else event.keyCode
            if (code == KeyEvent.KEYCODE_BUTTON_L2 || code == KeyEvent.KEYCODE_BUTTON_R2) {
                if (event.repeatCount == 0) {
                    if (code == KeyEvent.KEYCODE_BUTTON_L2) p.leftTrigger = down else p.rightTrigger = down
                    push(dev.id, p)
                }
                return true
            }
            val bit = keyBit(code)
            if (bit != 0) {
                if (event.repeatCount == 0) {
                    p.keys = if (down) p.keys or bit else p.keys and bit.inv()
                    push(dev.id, p)
                }
                return true
            }
        }
        if (streamer.phase == Streamer.Phase.Live && !streamer.menuOpen && toGame(event)) return true
        return super.dispatchKeyEvent(event)
    }

    /**
     * While a game plays, a keyboard types into it and a TV remote's arrows and OK act as
     * the arrow keys and Enter. Back on a remote, and Ctrl+G on a keyboard, open the menu.
     */
    private fun toGame(event: KeyEvent): Boolean {
        val dev = event.device ?: return false
        if (dev.isVirtual) return false
        val down = event.action == KeyEvent.ACTION_DOWN
        val code = event.keyCode
        when (code) {
            KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_HOME, KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN,
            KeyEvent.KEYCODE_VOLUME_MUTE, KeyEvent.KEYCODE_POWER, KeyEvent.KEYCODE_SETTINGS,
            -> return false
        }
        val keyboard = dev.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC
        if (keyboard && event.isCtrlPressed && code == KeyEvent.KEYCODE_G) {
            if (down && event.repeatCount == 0) streamer.openMenu()
            return true
        }
        val key = when {
            keyboard -> Keymap.of(code)
            code == KeyEvent.KEYCODE_DPAD_CENTER -> Keymap.ENTER
            else -> Keymap.of(code)
        } ?: return keyboard
        if (event.action == KeyEvent.ACTION_MULTIPLE) return true
        streamer.key(down, key, if (keyboard) Keymap.modifiers(event) else 0)
        return true
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        val dev = event.device
        if (isPad(dev) && event.isFromSource(InputDevice.SOURCE_JOYSTICK) && event.action == MotionEvent.ACTION_MOVE) {
            val p = padFor(dev!!)
            fun axis(a: Int): Float {
                val v = event.getAxisValue(a)
                val flat = dev.getMotionRange(a, event.source)?.flat ?: 0f
                return if (abs(v) <= flat) 0f else v
            }
            val hx = event.getAxisValue(MotionEvent.AXIS_HAT_X)
            val hy = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
            var hat = 0
            if (hx < -0.5f) hat = hat or Btn.LEFT
            if (hx > 0.5f) hat = hat or Btn.RIGHT
            if (hy < -0.5f) hat = hat or Btn.UP
            if (hy > 0.5f) hat = hat or Btn.DOWN
            p.hat = hat
            p.axes = if (p.layout.sticksOnRx) {
                // These triggers rest at -1 and reach 1 when fully pulled.
                fun pull(a: Int) = ((event.getAxisValue(a) + 1f) / 2f).coerceIn(0f, 1f).let { if (it < 0.02f) 0f else it }
                PadState(
                    lx = axis(MotionEvent.AXIS_X),
                    ly = axis(MotionEvent.AXIS_Y),
                    rx = axis(MotionEvent.AXIS_RX),
                    ry = axis(MotionEvent.AXIS_RY),
                    lt = pull(MotionEvent.AXIS_Z),
                    rt = pull(MotionEvent.AXIS_RZ),
                )
            } else {
                PadState(
                    lx = axis(MotionEvent.AXIS_X),
                    ly = axis(MotionEvent.AXIS_Y),
                    rx = axis(MotionEvent.AXIS_Z),
                    ry = axis(MotionEvent.AXIS_RZ),
                    lt = maxOf(axis(MotionEvent.AXIS_LTRIGGER), axis(MotionEvent.AXIS_BRAKE)),
                    rt = maxOf(axis(MotionEvent.AXIS_RTRIGGER), axis(MotionEvent.AXIS_GAS)),
                )
            }
            push(dev.id, p)
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }

    private fun push(id: Int, p: AndroidPad) {
        p.state = p.axes.copy(
            buttons = p.keys or p.hat,
            lt = if (p.leftTrigger) 1f else p.axes.lt,
            rt = if (p.rightTrigger) 1f else p.axes.rt,
        )
        hub.update("android:$id", p.name, p.route, p.state)
    }

    /**
     * A plain HID pad reports its buttons in order, either as BUTTON_1.. or squeezed into
     * A B C X Y Z L1 R1 L2 R2 Select Start. Both follow the usual order: four face buttons,
     * two bumpers, two triggers, Select, Start, two stick clicks.
     */
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

    private fun keyBit(code: Int) = when (code) {
        KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_DPAD_CENTER -> Btn.A
        KeyEvent.KEYCODE_BUTTON_B, KeyEvent.KEYCODE_BACK -> Btn.B
        KeyEvent.KEYCODE_BUTTON_X -> Btn.X
        KeyEvent.KEYCODE_BUTTON_Y -> Btn.Y
        KeyEvent.KEYCODE_BUTTON_L1 -> Btn.LB
        KeyEvent.KEYCODE_BUTTON_R1 -> Btn.RB
        KeyEvent.KEYCODE_BUTTON_SELECT -> Btn.VIEW
        KeyEvent.KEYCODE_BUTTON_START -> Btn.MENU
        KeyEvent.KEYCODE_BUTTON_MODE -> Btn.GUIDE
        KeyEvent.KEYCODE_BUTTON_THUMBL -> Btn.LS
        KeyEvent.KEYCODE_BUTTON_THUMBR -> Btn.RS
        KeyEvent.KEYCODE_DPAD_UP -> Btn.UP
        KeyEvent.KEYCODE_DPAD_DOWN -> Btn.DOWN
        KeyEvent.KEYCODE_DPAD_LEFT -> Btn.LEFT
        KeyEvent.KEYCODE_DPAD_RIGHT -> Btn.RIGHT
        else -> 0
    }
}
