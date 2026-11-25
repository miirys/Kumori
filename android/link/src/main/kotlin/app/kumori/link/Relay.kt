package app.kumori.link

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** One controller's state, copied on the main thread and sent from the relay thread. */
data class Snapshot(
    val slot: Int, val buttons: Int, val lt: Int, val rt: Int,
    val lx: Int, val ly: Int, val rx: Int, val ry: Int, val flags: Int,
)

/**
 * Sends controller state to one Apple TV over UDP. The Apple TV finds this box over Bonjour,
 * says HELLO, and from then on gets every change the moment it happens. See
 * docs/kumori-link-protocol.md.
 */
class Relay(private val context: Context) {
    companion object {
        const val PORT = 47820
        const val SERVICE = "_kumorilink._udp."
        const val VERSION = 1
        const val HELLO = 1; const val INFO = 2; const val STATE = 3; const val PING = 4; const val PONG = 5
        const val BYE = 6; const val RUMBLE = 7
        const val FLAG_PAUSED = 1; const val FLAG_GONE = 2
        private const val SUBSCRIBER_TIMEOUT_MS = 5000L
    }

    data class Stats(
        val subscriber: String?, val subscriberName: String?, val rttMs: Double?, val rttMinMs: Double?, val rttMaxMs: Double?,
        val sent: Long, val sentPerSecond: Int, val port: Int, val lost: Int,
    )

    private val thread = HandlerThread("relay", Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }
    private val handler = Handler(thread.looper)
    private lateinit var socket: DatagramSocket
    private var multicast: WifiManager.MulticastLock? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null

    @Volatile private var subscriber: SocketAddress? = null
    @Volatile private var subscriberName: String? = null
    @Volatile private var session = 0
    private var lastHeard = 0L
    private var seq = 0
    private val latest = arrayOfNulls<Snapshot>(4)
    private val changedAt = LongArray(4)
    private var lastFull = 0L
    @Volatile private var sent = 0L
    private var sentWindow = ArrayDeque<Long>()
    private var pingId = 0
    private val pings = HashMap<Int, Long>()
    private var rtt = ArrayDeque<Double>()
    private var lostPings = 0
    @Volatile private var stats = Stats(null, null, null, null, null, 0, 0, PORT, 0)
    var onStats: ((Stats) -> Unit)? = null

    private val out = ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN)

    fun start(deviceName: String) {
        socket = try {
            DatagramSocket(null).apply { reuseAddress = true; bind(InetSocketAddress(PORT)) }
        } catch (e: Exception) {
            LogBook.add("net", "port $PORT busy (${e.message}), using a free one")
            DatagramSocket(0)
        }
        // DSCP EF (46): Wi-Fi puts these in the voice queue, which skips ahead of bulk traffic.
        runCatching { socket.trafficClass = 0xB8 }
        runCatching { socket.broadcast = true }
        LogBook.add("net", "listening on UDP ${socket.localPort}")
        Thread(::receive, "relay-rx").apply { priority = Thread.MAX_PRIORITY; isDaemon = true; start() }

        runCatching {
            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicast = wifi.createMulticastLock("kumori-link").apply { setReferenceCounted(false); acquire() }
        }.onFailure { LogBook.add("net", "no multicast lock: ${it.message}") }
        register(deviceName)
        handler.post(tick)
    }

    fun stop() {
        handler.removeCallbacksAndMessages(null)
        subscriber?.let { to -> handler.post { packet(BYE); flush(to) } }
        handler.post {
            runCatching { registration?.let { nsd?.unregisterService(it) } }
            runCatching { multicast?.release() }
            runCatching { socket.close() }
        }
    }

    private fun register(name: String) {
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = SERVICE
            port = socket.localPort
            runCatching {
                setAttribute("v", VERSION.toString())
                setAttribute("model", Build.MODEL)
                setAttribute("http", LogServer.PORT.toString())
            }
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(s: NsdServiceInfo) = LogBook.add("net", "Bonjour: announced as \"${s.serviceName}\" ($SERVICE)")
            override fun onRegistrationFailed(s: NsdServiceInfo, code: Int) = LogBook.add("net", "Bonjour: announce failed, code $code")
            override fun onServiceUnregistered(s: NsdServiceInfo) = LogBook.add("net", "Bonjour: withdrawn")
            override fun onUnregistrationFailed(s: NsdServiceInfo, code: Int) = LogBook.add("net", "Bonjour: withdraw failed, code $code")
        }
        runCatching {
            nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
            nsd!!.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            registration = listener
        }.onFailure { LogBook.add("net", "Bonjour unavailable: ${it.message}") }
    }

    /** Called on the main thread with every change. Sent at once on the relay thread. */
    fun update(s: Snapshot) {
        handler.postAtFrontOfQueue {
            latest[s.slot] = if (s.flags and FLAG_GONE != 0) null else s
            changedAt[s.slot] = SystemClock.uptimeMillis()
            subscriber?.let { send(s, it) }
        }
    }

    private fun connectedMask(): Int {
        var m = 0
        for (i in 0..3) if (latest[i] != null) m = m or (1 shl i)
        return m
    }

    private fun send(s: Snapshot, to: SocketAddress) {
        packet(STATE)
        out.putInt(++seq)
        out.putLong(SystemClock.elapsedRealtimeNanos() / 1000)
        out.put(s.slot.toByte())
        out.put(connectedMask().toByte())
        out.put(s.flags.toByte())
        out.put(0)
        out.putShort(s.buttons.toShort())
        out.put(s.lt.toByte())
        out.put(s.rt.toByte())
        out.putShort(s.lx.toShort()); out.putShort(s.ly.toShort())
        out.putShort(s.rx.toShort()); out.putShort(s.ry.toShort())
        flush(to)
    }

    private fun packet(type: Int) {
        out.clear()
        out.put('K'.code.toByte()); out.put('L'.code.toByte()); out.put(VERSION.toByte()); out.put(type.toByte())
    }

    private fun flush(to: SocketAddress) {
        try {
            socket.send(DatagramPacket(out.array(), out.position(), to))
            sent++
            sentWindow.addLast(SystemClock.uptimeMillis())
        } catch (e: Exception) {
            LogBook.add("net", "send failed: ${e.message}")
        }
    }

    /**
     * Every 20 ms: send again anything that changed in the last 150 ms, so one lost packet
     * costs at most 20 ms. Twice a second, send everything, so the Apple TV knows we're here.
     */
    private val tick = object : Runnable {
        override fun run() {
            val now = SystemClock.uptimeMillis()
            val to = subscriber
            if (to != null) {
                if (now - lastHeard > SUBSCRIBER_TIMEOUT_MS) {
                    LogBook.add("net", "Apple TV $to went quiet, waiting for it")
                    subscriber = null
                    subscriberName = null
                } else {
                    val full = now - lastFull >= 500
                    if (full) lastFull = now
                    for (i in 0..3) {
                        val s = latest[i] ?: continue
                        if (full || now - changedAt[i] < 150) send(s, to)
                    }
                    if (now / 1000 != (now - 20) / 1000) ping(to)
                }
            }
            while (sentWindow.isNotEmpty() && now - sentWindow.first() > 1000) sentWindow.removeFirst()
            publish()
            handler.postDelayed(this, 20)
        }
    }

    private fun ping(to: SocketAddress) {
        val now = SystemClock.elapsedRealtimeNanos()
        // A ping unanswered for 3 s is lost.
        val stale = pings.filterValues { now - it > 3_000_000_000L }.keys
        if (stale.isNotEmpty()) {
            lostPings += stale.size
            stale.forEach { pings.remove(it) }
        }
        val id = ++pingId
        pings[id] = now
        packet(PING)
        out.putInt(id)
        out.putLong(now / 1000)
        flush(to)
    }

    private fun publish() {
        val r = rtt
        val s = Stats(
            subscriber?.toString()?.removePrefix("/"), subscriberName,
            r.lastOrNull(), r.minOrNull(), r.maxOrNull(), sent, sentWindow.size, socket.localPort, lostPings,
        )
        if (s != stats) {
            stats = s
            onStats?.invoke(s)
        }
    }

    fun stats() = stats

    private fun receive() {
        val buf = ByteArray(512)
        while (!socket.isClosed) {
            val p = DatagramPacket(buf, buf.size)
            try { socket.receive(p) } catch (e: Exception) { if (socket.isClosed) return else continue }
            val b = ByteBuffer.wrap(p.data, 0, p.length).order(ByteOrder.LITTLE_ENDIAN)
            if (p.length < 4 || b.get() != 'K'.code.toByte() || b.get() != 'L'.code.toByte()) continue
            val version = b.get().toInt()
            val type = b.get().toInt()
            val from = p.socketAddress
            val arrived = SystemClock.elapsedRealtimeNanos()
            val body = ByteArray(p.length - 4).also { b.get(it) }
            handler.postAtFrontOfQueue { handle(version, type, body, from, arrived) }
        }
    }

    private fun handle(version: Int, type: Int, body: ByteArray, from: SocketAddress, arrived: Long) {
        val b = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN)
        if (from == subscriber) lastHeard = SystemClock.uptimeMillis()
        when (type) {
            HELLO -> {
                val id = if (b.remaining() >= 4) b.int else 0
                val name = if (b.remaining() >= 2) {
                    val n = b.short.toInt() and 0xffff
                    if (b.remaining() >= n) String(ByteArray(n).also { b.get(it) }) else null
                } else null
                if (from != subscriber || id != session) {
                    LogBook.add("net", "HELLO from ${name ?: "?"} at $from (protocol v$version, session $id)${subscriber?.let { " replaces $it" } ?: ""}")
                    rtt.clear(); pings.clear(); lostPings = 0
                }
                subscriber = from
                subscriberName = name
                session = id
                lastHeard = SystemClock.uptimeMillis()
                packet(INFO)
                out.putInt(id)
                out.put(connectedMask().toByte())
                out.putShort(LogServer.PORT.toShort())
                val me = Build.MODEL.toByteArray()
                out.putShort(me.size.toShort()); out.put(me)
                val ver = BuildConfig.VERSION_NAME.toByteArray()
                out.putShort(ver.size.toShort()); out.put(ver)
                flush(from)
                // Bring the new Apple TV up to date at once.
                for (i in 0..3) latest[i]?.let { send(it, from) }
            }
            PING -> {
                // Echo the body as is.
                packet(PONG)
                out.put(body, 0, minOf(body.size, 32))
                flush(from)
            }
            PONG -> {
                if (b.remaining() < 4) return
                val id = b.int
                val at = pings.remove(id) ?: return
                val ms = (arrived - at) / 1e6
                rtt.addLast(ms)
                if (rtt.size > 30) rtt.removeFirst()
                if (id % 10 == 0) {
                    LogBook.add("net", "round trip %.2f ms (last 30: min %.2f, max %.2f, avg %.2f), lost pings %d, sent %d/s".format(
                        ms, rtt.min(), rtt.max(), rtt.average(), lostPings, sentWindow.size,
                    ))
                }
            }
            BYE -> if (from == subscriber) {
                LogBook.add("net", "Apple TV $from said goodbye")
                subscriber = null
                subscriberName = null
            }
            RUMBLE -> if (b.remaining() >= 6) {
                val slot = b.get().toInt() and 3
                val low = b.get().toInt() and 0xff
                val high = b.get().toInt() and 0xff
                b.get()
                val ms = b.short.toInt() and 0xffff
                onRumble?.invoke(slot, low, high, ms)
            }
            else -> LogBook.add("net", "unknown packet type $type from $from")
        }
    }

    var onRumble: ((slot: Int, low: Int, high: Int, ms: Int) -> Unit)? = null
}
