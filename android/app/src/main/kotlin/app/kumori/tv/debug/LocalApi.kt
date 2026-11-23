package app.kumori.tv.debug

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import app.kumori.tv.Settings
import app.kumori.tv.data.AppState
import app.kumori.tv.input.PadHub
import app.kumori.tv.stream.Streamer
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.util.concurrent.Executors

/**
 * A small read-only JSON API on port 8090, for logging or grabbing anything the app knows:
 * what is playing and how well, past streams, settings, the account, the display chain.
 * It only takes GET, and only answers addresses on the home network. It runs as long as the
 * app does, from launch.
 */
object LocalApi {
    const val PORT = 8090

    val ENDPOINTS = listOf(
        "/" to "This list, the app and its version",
        "/status" to "Signed in, what is playing, time left, idle timer",
        "/stats" to "The stream now: frame rate, target, drops, codec, latency, bitrate",
        "/stats/history" to "The current stream, one sample a second, last 10 minutes",
        "/session" to "The game playing and how its stream was set up",
        "/sessions" to "Games running in the cloud on this account",
        "/history" to "Past streams with their averages and how they ended",
        "/games" to "The library: id, title, store, last played",
        "/games/{id}" to "One game",
        "/settings" to "Every Kumori setting",
        "/account" to "Plan, play time left, streaming modes",
        "/device" to "This box, its display and the HDMI chain check",
        "/launch" to "The last launch, step by step",
        "/input" to "Controllers and how they're connected",
        "/log" to "A full report built now, as text",
        "/logs" to "Reports saved with Send Log",
        "/logs/latest" to "The newest saved report, as text",
    )

    var running by mutableStateOf(false)
        private set
    var problem by mutableStateOf<String?>(null)
        private set
    var served by mutableIntStateOf(0)
        private set

    @Volatile private var report: ApiReport? = null
    private var context: Context? = null
    private var started = false
    private val pool = Executors.newFixedThreadPool(3) { r -> Thread(r, "kumori-api").apply { isDaemon = true } }

    /** Points the API at the app's state. Safe to call again when the activity is recreated. */
    fun start(context: Context, app: AppState, streamer: Streamer, settings: Settings, hub: PadHub) {
        this.context = context.applicationContext
        report = ApiReport(context.applicationContext, app, streamer, settings, hub)
        if (started) return
        started = true
        Thread({ listen() }, "kumori-api-accept").apply { isDaemon = true }.start()
    }

    private fun listen() {
        var wait = 1000L
        while (true) {
            try {
                ServerSocket().use { server ->
                    server.reuseAddress = true
                    server.bind(InetSocketAddress(PORT))
                    running = true
                    problem = null
                    wait = 1000L
                    while (true) {
                        val c = server.accept()
                        pool.execute { serve(c) }
                    }
                }
            } catch (t: Throwable) {
                running = false
                problem = "Port $PORT: ${t.message ?: t.javaClass.simpleName}"
                Log.w("Kumori", "local API stopped", t)
            }
            // Another app may hold the port for a moment; keep trying, more slowly each time.
            Thread.sleep(wait)
            wait = (wait * 2).coerceAtMost(30_000L)
        }
    }

    /** Only this network: private IPv4 ranges, link-local, loopback, and IPv6 unique-local and link-local. */
    fun isLocal(a: InetAddress): Boolean = when (a) {
        is Inet4Address -> a.isSiteLocalAddress || a.isLinkLocalAddress || a.isLoopbackAddress
        is Inet6Address -> a.isLoopbackAddress || a.isLinkLocalAddress || (a.address[0].toInt() and 0xFE) == 0xFC ||
            a.isIPv4CompatibleAddress && isLocal(InetAddress.getByAddress(a.address.copyOfRange(12, 16)))
        else -> false
    }

    private fun serve(c: Socket) {
        c.use { sock ->
            runCatching {
                sock.soTimeout = 5000
                val remote = sock.inetAddress
                if (remote == null || !isLocal(remote)) {
                    write(sock, "403 Forbidden", "application/json", JSONObject().put("error", "Only answered on the home network.").toString(2))
                    return
                }
                val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
                val first = reader.readLine() ?: return
                // Read the headers to the blank line, then ignore them.
                while (true) {
                    val l = reader.readLine() ?: break
                    if (l.isEmpty()) break
                }
                val parts = first.split(' ')
                if (parts.size < 2) return write(sock, "400 Bad Request", "application/json", err("Not an HTTP request."))
                if (parts[0] != "GET" && parts[0] != "HEAD") return write(sock, "405 Method Not Allowed", "application/json", err("Only GET. This API is read-only."))
                var path = parts[1].substringBefore('?')
                if (path.length > 1) path = path.trimEnd('/')
                served++
                val (status, type, body) = answer(path)
                write(sock, status, type, if (parts[0] == "HEAD") "" else body)
            }
        }
    }

    private fun err(message: String) = JSONObject().put("error", message).toString(2)

    private fun answer(path: String): Triple<String, String, String> {
        val r = report ?: return Triple("503 Service Unavailable", JSON, err("Kumori is still starting."))
        val ctx = context ?: return Triple("503 Service Unavailable", JSON, err("Kumori is still starting."))
        fun json(o: JSONObject) = Triple("200 OK", JSON, o.toString(2).replace("\\/", "/"))
        fun text(s: String) = Triple("200 OK", TEXT, s)
        return when (path) {
            "/" -> json(r.index())
            "/status" -> json(r.status())
            "/stats" -> json(r.stats())
            "/stats/history" -> json(r.statsHistory())
            "/session" -> json(r.session())
            "/sessions" -> json(r.sessions())
            "/history" -> json(r.history())
            "/games" -> json(r.games())
            "/settings" -> json(r.settings())
            "/account" -> json(r.account())
            "/device" -> json(r.device())
            "/launch" -> json(r.launch())
            "/input" -> json(r.input())
            "/log" -> text(LogReport.build(ctx, r))
            "/logs" -> json(JSONObject().put("reports", org.json.JSONArray().apply {
                for (s in LogReport.saved(ctx)) put(JSONObject().put("name", s.name).put("bytes", s.bytes).put("savedAt", ApiReport.iso(s.savedAt)).put("path", "/logs/${s.name}"))
            }))
            "/logs/latest" -> LogReport.saved(ctx).firstOrNull()?.let { LogReport.read(ctx, it.name) }?.let(::text)
                ?: Triple("404 Not Found", JSON, err("No report saved yet. Use Settings, Debug, Send Log."))
            else -> when {
                path.startsWith("/games/") -> {
                    val id = URLDecoder.decode(path.removePrefix("/games/"), "UTF-8")
                    r.game(id)?.let(::json) ?: Triple("404 Not Found", JSON, err("No game with id $id."))
                }
                path.startsWith("/logs/") -> {
                    val name = path.removePrefix("/logs/")
                    LogReport.read(ctx, name)?.let(::text) ?: Triple("404 Not Found", JSON, err("No report named $name."))
                }
                else -> Triple("404 Not Found", JSON, err("No endpoint $path. See / for the list."))
            }
        }
    }

    private const val JSON = "application/json; charset=utf-8"
    private const val TEXT = "text/plain; charset=utf-8"

    private fun write(s: Socket, status: String, type: String, body: String) {
        val bytes = body.toByteArray()
        val head = "HTTP/1.1 $status\r\nContent-Type: $type\r\nContent-Length: ${bytes.size}\r\n" +
            "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        val out = s.getOutputStream()
        out.write(head.toByteArray())
        out.write(bytes)
        out.flush()
    }

    /** This box's address on the home network, for the URLs Debug shows. */
    fun address(): String? = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .sortedBy { if (it.name.startsWith("eth")) 0 else if (it.name.startsWith("wlan")) 1 else 2 }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is Inet4Address && it.isSiteLocalAddress }?.hostAddress
    }.getOrNull()

    fun baseUrl(): String = "http://${address() ?: "this-box"}:$PORT"
}
