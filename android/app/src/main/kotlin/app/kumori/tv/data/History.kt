package app.kumori.tv.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** One stream that has finished, as the local API and Debug show it. */
data class PastStream(
    val gameId: String?,
    val game: String,
    val startedAt: Long,
    val endedAt: Long,
    val seconds: Long,
    val mode: String,
    val codec: String?,
    val avgFps: Double?,
    val minFps: Double?,
    val framesDropped: Long,
    val avgRttMs: Double?,
    val avgMbps: Double?,
    val endedBy: String,
) {
    fun json(): JSONObject = JSONObject()
        .put("gameId", gameId ?: JSONObject.NULL)
        .put("game", game)
        .put("startedAt", startedAt)
        .put("endedAt", endedAt)
        .put("seconds", seconds)
        .put("mode", mode)
        .put("codec", codec ?: JSONObject.NULL)
        .put("avgFps", avgFps ?: JSONObject.NULL)
        .put("minFps", minFps ?: JSONObject.NULL)
        .put("framesDropped", framesDropped)
        .put("avgRttMs", avgRttMs ?: JSONObject.NULL)
        .put("avgMbps", avgMbps ?: JSONObject.NULL)
        .put("endedBy", endedBy)

    companion object {
        fun from(j: JSONObject) = PastStream(
            gameId = j.optString("gameId").takeIf { it.isNotEmpty() && it != "null" },
            game = j.optString("game"),
            startedAt = j.optLong("startedAt"),
            endedAt = j.optLong("endedAt"),
            seconds = j.optLong("seconds"),
            mode = j.optString("mode"),
            codec = j.optString("codec").takeIf { it.isNotEmpty() && it != "null" },
            avgFps = j.optDouble("avgFps").takeIf { !it.isNaN() },
            minFps = j.optDouble("minFps").takeIf { !it.isNaN() },
            framesDropped = j.optLong("framesDropped"),
            avgRttMs = j.optDouble("avgRttMs").takeIf { !it.isNaN() },
            avgMbps = j.optDouble("avgMbps").takeIf { !it.isNaN() },
            endedBy = j.optString("endedBy"),
        )
    }
}

/** Past streams, newest first, kept in a small file on the box. */
object History {
    private const val KEEP = 100
    private var file: File? = null
    private var items: List<PastStream> = emptyList()

    fun init(context: Context) {
        val f = File(context.filesDir, "history.json")
        file = f
        items = runCatching {
            val a = JSONArray(f.readText())
            (0 until a.length()).map { PastStream.from(a.getJSONObject(it)) }
        }.getOrDefault(emptyList())
    }

    @Synchronized
    fun all(): List<PastStream> = items

    @Synchronized
    fun add(p: PastStream) {
        items = (listOf(p) + items).take(KEEP)
        val f = file ?: return
        runCatching {
            val a = JSONArray()
            for (i in items) a.put(i.json())
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(a.toString())
            tmp.renameTo(f)
        }
    }
}
