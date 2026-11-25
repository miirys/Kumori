package app.kumori.link

import android.os.SystemClock
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Everything the app noticed, kept in memory for the log page. Newest last. */
object LogBook {
    private const val MAX = 6000
    private val lines = ArrayDeque<String>(MAX)
    private val clock = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val started = SystemClock.elapsedRealtime()
    @Volatile var total = 0L
        private set

    fun add(tag: String, text: String) {
        val line = "${clock.format(Date())} ${tag.padEnd(5)} $text"
        synchronized(lines) {
            if (lines.size == MAX) lines.removeFirst()
            lines.addLast(line)
            total++
        }
        android.util.Log.i("KumoriLink", "$tag $text")
    }

    fun text(): String = synchronized(lines) { lines.joinToString("\n") }

    /** Lines after [from] (a value of [total]), for the page's live tail. */
    fun since(from: Long): Pair<Long, List<String>> = synchronized(lines) {
        val skip = (from - (total - lines.size)).coerceAtLeast(0).toInt()
        total to lines.drop(skip)
    }

    fun clear() = synchronized(lines) { lines.clear(); add("log", "cleared") }

    fun uptime(): String {
        val s = (SystemClock.elapsedRealtime() - started) / 1000
        return "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60)
    }
}
