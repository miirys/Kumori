package app.kumori.tv.data

import android.util.Log

/**
 * One line for each step of starting and ending a session, kept for Debug, the local API and
 * the saved log. Never holds tokens, session ids or addresses.
 */
object SessionLog {
    private const val MAX = 200
    private val lines = ArrayDeque<String>()

    fun add(tag: String, text: String) {
        val line = "${java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US).format(java.util.Date())} $tag: $text"
        Log.i("Kumori", line)
        synchronized(lines) {
            lines.addLast(line)
            while (lines.size > MAX) lines.removeFirst()
        }
    }

    fun ended(step: String, http: Int?, ok: Boolean) =
        add("end", "$step, ${http?.let { "HTTP $it" } ?: "no answer"}, ${if (ok) "ended" else "not ended"}")

    fun all(): List<String> = synchronized(lines) { lines.toList() }
}
