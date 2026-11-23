package app.kumori.tv.debug

import android.content.Context
import android.os.Build
import android.os.Process
import app.kumori.tv.BuildConfig
import app.kumori.tv.CrashLog
import app.kumori.tv.Diagnostics
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Send Log: one plain-text report of everything worth knowing when something goes wrong,
 * saved on the box and served by the local API at /logs/latest, so it can be opened on a
 * phone from the QR code in Debug. Nothing is uploaded anywhere.
 */
object LogReport {
    data class Saved(val name: String, val bytes: Long, val savedAt: Long)

    private const val KEEP = 10

    private fun dir(context: Context) = File(context.filesDir, "logs").apply { mkdirs() }

    fun build(context: Context, r: ApiReport): String = buildString {
        appendLine("Kumori ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) on Android TV")
        appendLine("Report made ${ApiReport.iso(System.currentTimeMillis())}")
        appendLine("${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}), ${Build.HARDWARE}")
        appendLine()
        section("Status", r.status().toString(2))
        section("Stream", r.stats().toString(2))
        section("Session", r.session().toString(2))
        section("Settings", r.settings().toString(2))
        section("Account", r.account().toString(2))
        section("Display chain", DisplayChain.read(context).text())
        section("Launch steps", r.launch().toString(2))
        Diagnostics.lastRefusal?.let { section("Last refusal", it) }
        section("Past streams", r.history().toString(2))
        CrashLog.latest(context)?.let { p -> section("Last problem", "${CrashLog.format(p.whenMs)}: ${p.summary}\n${p.detail}") }
        CrashLog.crashLog(context)?.let { section("Crash log", it.takeLast(200).joinToString("\n")) }
        section("System log (this app)", ownLog())
    }

    private fun StringBuilder.section(title: String, body: String) {
        appendLine("== $title ==")
        appendLine(body.trimEnd())
        appendLine()
    }

    /** This app's recent lines from the system log. Android lets an app read its own. */
    private fun ownLog(): String = runCatching {
        val p = ProcessBuilder("logcat", "-d", "-v", "time", "-t", "1500", "--pid=${Process.myPid()}").redirectErrorStream(true).start()
        val text = p.inputStream.bufferedReader().readText()
        p.waitFor()
        text
    }.getOrElse { "Not readable: ${it.message}" }

    /** Builds a report and saves it. Returns what was saved. */
    fun save(context: Context, r: ApiReport): Saved {
        val text = build(context, r)
        val name = "kumori-" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + ".txt"
        val f = File(dir(context), name)
        f.writeText(text)
        saved(context).drop(KEEP).forEach { File(dir(context), it.name).delete() }
        return Saved(name, f.length(), f.lastModified())
    }

    fun saved(context: Context): List<Saved> =
        (dir(context).listFiles { f -> f.name.startsWith("kumori-") && f.name.endsWith(".txt") } ?: emptyArray())
            .sortedByDescending { it.lastModified() }
            .map { Saved(it.name, it.length(), it.lastModified()) }

    fun read(context: Context, name: String): String? {
        if (!Regex("kumori-[0-9-]+\\.txt").matches(name)) return null
        return runCatching { File(dir(context), name).readText() }.getOrNull()
    }
}
