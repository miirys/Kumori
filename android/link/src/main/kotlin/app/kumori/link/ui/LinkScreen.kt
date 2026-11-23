package app.kumori.link.ui

import android.content.Context
import android.view.Gravity
import android.view.View
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import app.kumori.link.Link
import app.kumori.link.LogServer
import app.kumori.link.Pad
import app.kumori.link.PadView
import app.kumori.link.Relay

/**
 * Everything on screen. The activity hands it controllers and connection readings; it never
 * touches input or the network itself.
 *
 *  ┌──────────────────────────────────────────────────────────────┐
 *  │ Kumori Link                              ( ● Connected to … ) │
 *  │                                                              │
 *  │        [ Player 1 card ]        [ Player 2 card ]            │
 *  │                                                              │
 *  │ ┌ What to do next, or how the connection is doing ──── delay ┐│
 *  │ Leave this open while you play.                 Logs: http://… │
 *  └──────────────────────────────────────────────────────────────┘
 */
class LinkScreen(context: Context) : FrameLayout(context) {
    private val chip = StatusChip(context)
    private val grid = PadGrid(context)
    private val empty = LinearLayout(context)
    private val title = context.label(19f, Look.primary, bold = true)
    private val body = context.label(15f, Look.secondary)
    private val meter = LinearLayout(context)
    private val spark = Sparkline(context)
    private val delay = context.label(22f, Look.primary, bold = true)
    private val address = context.label(13f, Look.tertiary)
    private val cards = HashMap<Int, PadCard>()
    private var lastRtt: Double? = null

    init {
        addView(LightView(context), LayoutParams(-1, -1))

        val col = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            // TV overscan: everything stays inside the safe area.
            setPadding(dpi(56f), dpi(30f), dpi(56f), dpi(24f))
            clipChildren = false
            clipToPadding = false
        }
        addView(col, LayoutParams(-1, -1))

        // Top: the name on the left, the connection on the right.
        val top = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        top.addView(context.label(22f, Look.primary, bold = true).apply { text = "Kumori Link" })
        top.addView(View(context), LinearLayout.LayoutParams(0, 1, 1f))
        top.addView(chip, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dpi(24f) })
        col.addView(top)

        // Middle: the controllers, or an empty outline waiting for one.
        val stage = FrameLayout(context).apply { clipChildren = false; clipToPadding = false }
        stage.addView(grid, LayoutParams(-1, -1))
        empty.apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            addView(PadView(context), LinearLayout.LayoutParams(dpi(340f), 0, 1f).apply { topMargin = dpi(8f) })
            addView(context.label(22f, Look.primary, bold = true).apply { text = "No controller yet"; gravity = Gravity.CENTER; setPadding(0, dpi(16f), 0, 0) })
            addView(context.label(16f, Look.secondary).apply { text = "Turn one on, or press any button on it."; gravity = Gravity.CENTER; setPadding(0, dpi(10f), 0, dpi(8f)) })
        }
        stage.addView(empty, LayoutParams(-1, -1))
        col.addView(stage, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = dpi(16f); bottomMargin = dpi(18f) })

        // Bottom: what to do next, or how the connection is doing.
        val panel = GlassRow(context, dp(22f)).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dpi(26f), dpi(16f), dpi(26f), dpi(16f))
        }
        val words = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        body.setPadding(0, dpi(7f), 0, 0)
        words.addView(title); words.addView(body)
        panel.addView(words, LinearLayout.LayoutParams(0, -2, 1f))

        meter.apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; visibility = View.GONE }
        meter.addView(spark, LinearLayout.LayoutParams(dpi(150f), dpi(40f)).apply { marginEnd = dpi(18f) })
        val nums = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.END }
        delay.gravity = Gravity.END
        nums.addView(delay)
        nums.addView(context.label(12f, Look.tertiary).apply { gravity = Gravity.END; setPadding(0, dpi(5f), 0, 0); text = "Delay to Apple TV" })
        meter.addView(nums, LinearLayout.LayoutParams(dpi(120f), -2))
        panel.addView(meter, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dpi(24f) })
        col.addView(panel, LinearLayout.LayoutParams(-1, -2))

        val foot = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; setPadding(dpi(4f), dpi(12f), dpi(4f), 0) }
        foot.addView(context.label(13f, Look.tertiary).apply { text = "Leave this open while you play. Back on the remote closes it." }, LinearLayout.LayoutParams(0, -2, 1f))
        foot.addView(address)
        col.addView(foot)
    }

    /** Adds the pad's card the first time, then redraws it with the pad's latest state. */
    fun show(p: Pad, focused: Boolean) {
        var card = cards[p.deviceId]
        if (card == null) {
            card = PadCard(context, p.slot, p.name, p.usb)
            cards[p.deviceId] = card
            grid.add(card)
            refreshEmpty()
        }
        card.paused(!focused && !p.usb)
        card.pad.pad = p
    }

    fun remove(deviceId: Int) {
        cards.remove(deviceId)?.let(grid::removeView)
        refreshEmpty()
    }

    private fun refreshEmpty() {
        val none = cards.isEmpty()
        val shown = empty.visibility == View.VISIBLE && empty.alpha > 0.5f
        if (none == shown) return
        empty.animate().cancel()
        if (!isLaidOut || !Look.motion) {
            // Before the first frame, just show the right thing.
            empty.visibility = if (none) View.VISIBLE else View.GONE
            empty.alpha = 1f; empty.translationY = 0f
            return
        }
        if (none) {
            empty.visibility = View.VISIBLE
            empty.alpha = 0f
            empty.translationY = dp(16f)
            empty.animate().alpha(1f).translationY(0f).setStartDelay(220).setDuration(420).setInterpolator(DecelerateInterpolator()).start()
        } else {
            empty.animate().alpha(0f).translationY(-dp(10f)).setStartDelay(0).setDuration(200).withEndAction { empty.visibility = View.GONE }.start()
        }
    }

    /** The connection, in words, plus the delay meter while an Apple TV is listening. */
    fun status(s: Relay.Stats, ip: String?, focused: Boolean) {
        val tv = s.subscriberName?.takeIf { it.isNotBlank() } ?: "Apple TV"
        when {
            ip == null -> {
                chip.dot.mode = StatusDot.Mode.OFFLINE
                chip.text.say("No network")
                title.say("This box isn't on a network")
                body.say("Connect it to the same Wi-Fi or wired network as your Apple TV.")
            }
            !focused -> {
                chip.dot.mode = StatusDot.Mode.PAUSED
                chip.text.say("Paused")
                title.say("Paused while Kumori Link is in the background")
                body.say("Android only sends controller input to the app on screen. Open Kumori Link again to carry on.")
            }
            s.subscriber != null -> {
                chip.dot.mode = StatusDot.Mode.CONNECTED
                chip.text.say("Connected to $tv")
                title.say("Your controllers are going to $tv")
                body.say(when {
                    cards.isEmpty() -> "Turn on a controller and it shows up here."
                    s.lost > 0 -> "${s.lost} ${if (s.lost == 1) "reply" else "replies"} from the Apple TV went missing. If buttons feel late, try a cable."
                    else -> "What you press shows up above, the same as the Apple TV sees it."
                })
            }
            else -> {
                chip.dot.mode = StatusDot.Mode.LOOKING
                chip.text.say("Waiting for Apple TV")
                title.say("Connect your Apple TV")
                body.say("On the Apple TV, open Kumori and go to Settings > Controllers. Choose “${Link.name}” there.")
            }
        }

        val connected = s.subscriber != null && ip != null
        Light.linked(connected)
        // A new point on the line each time the Apple TV answers a ping, about once a second.
        if (connected && s.rttMs != null && s.rttMs != lastRtt) spark.add(s.rttMs.toFloat())
        lastRtt = s.rttMs
        if (connected != (meter.visibility == View.VISIBLE)) {
            if (connected) {
                meter.visibility = View.VISIBLE
                meter.alpha = 0f
                meter.translationX = dp(12f)
                meter.animate().alpha(1f).translationX(0f).setDuration(360).setInterpolator(DecelerateInterpolator()).start()
            } else {
                meter.visibility = View.GONE
                spark.clear()
            }
        }
        // Stats arrive with every packet sent while playing, so only touch text that changed.
        set(delay, s.rttMs?.let { if (it < 10) "%.1f ms".format(it) else "%.0f ms".format(it) } ?: "...")
        set(address, if (ip != null) "Logs: http://$ip:${LogServer.PORT}" else "")
    }

    private fun set(v: TextView, value: String) { if (v.text.toString() != value) v.text = value
    }
}
