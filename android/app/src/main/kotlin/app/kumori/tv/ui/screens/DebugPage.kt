package app.kumori.tv.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.kumori.tv.CrashLog
import app.kumori.tv.Settings
import app.kumori.tv.data.AppState
import app.kumori.tv.data.Nvidia
import app.kumori.tv.data.SessionLog
import app.kumori.tv.debug.DisplayChain
import app.kumori.tv.debug.LocalApi
import app.kumori.tv.debug.LogReport
import app.kumori.tv.ui.components.ActionSetting
import app.kumori.tv.ui.components.InfoLine
import app.kumori.tv.ui.components.PivotScroll
import app.kumori.tv.ui.components.QrCode
import app.kumori.tv.ui.components.SettingsFocus
import app.kumori.tv.ui.components.SettingsGroup
import app.kumori.tv.ui.components.SettingsList
import app.kumori.tv.ui.motion.Motion
import app.kumori.tv.ui.motion.RevealPage
import app.kumori.tv.ui.motion.reveal
import app.kumori.tv.ui.theme.LocalType
import app.kumori.tv.ui.theme.Palette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private fun levelColor(l: DisplayChain.Level): Color = when (l) {
    DisplayChain.Level.OK -> Palette.good
    DisplayChain.Level.WARN -> Palette.warn
    DisplayChain.Level.FAIL -> Palette.danger
    DisplayChain.Level.INFO -> Palette.textTertiary
}

/**
 * Debug: the display chain check with a live 120 Hz test, Send Log, every region timed,
 * the local API, and the last launch step by step.
 */
@Composable
fun DebugPage(app: AppState, settings: Settings) {
    var api by remember { mutableStateOf(false) }
    AnimatedContent(
        targetState = api,
        transitionSpec = { Motion.pages(if (targetState) 1 else -1) },
        modifier = Modifier.fillMaxSize(),
        label = "debug",
    ) { showApi ->
        RevealPage(key = showApi, group = "debug") {
            if (showApi) {
                BackHandler { api = false }
                ApiPage()
            } else {
                DebugList(app, settings, onApi = { api = true })
            }
        }
    }
}

@Composable
private fun DebugList(app: AppState, settings: Settings, onApi: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var chain by remember { mutableStateOf(DisplayChain.read(context)) }
    var testing by remember { mutableStateOf(false) }
    var measured by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(LogReport.saved(context).firstOrNull()) }
    var pinging by remember { mutableStateOf(false) }
    var pings by remember { mutableStateOf<List<Nvidia.Region>?>(null) }
    val focus = remember { SettingsFocus() }

    PivotScroll(leadingFraction = 0.3f) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            SettingsList(focus) {
                SettingsGroup("Display chain")
                for (f in chain.findings) InfoLine(f.title, f.value, dot = levelColor(f.level), detail = f.detail?.takeIf { f.level != DisplayChain.Level.OK })
                ActionSetting(
                    if (testing) "Testing 120 Hz" else "Test 120 Hz now",
                    {
                        if (testing) return@ActionSetting
                        testing = true
                        scope.launch {
                            val (hz, mode) = runCatching { DisplayChain.test120(context) }.getOrDefault(0.0 to null)
                            measured = when {
                                hz <= 0 -> "Couldn't measure"
                                hz >= 118 -> "%.1f Hz, working".format(hz)
                                else -> "%.1f Hz${mode?.let { " (asked for $it)" } ?: ""}".format(hz)
                            }
                            chain = DisplayChain.read(context)
                            testing = false
                        }
                    },
                    value = measured,
                )

                SettingsGroup("Log")
                ActionSetting(
                    if (saving) "Saving" else "Send Log",
                    {
                        if (saving) return@ActionSetting
                        saving = true
                        scope.launch {
                            saved = withContext(Dispatchers.IO) { LocalApi.report()?.let { runCatching { LogReport.save(context, it) }.getOrNull() } } ?: saved
                            saving = false
                        }
                    },
                    value = saved?.let { "%.0f KB".format(it.bytes / 1024.0) },
                )
                saved?.let { s ->
                    val url = "${LocalApi.baseUrl()}/logs/${s.name}"
                    Row(Modifier.padding(start = 16.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(88.dp).background(Color.White, RoundedCornerShape(10.dp)).padding(6.dp)) { QrCode(url, Modifier.fillMaxSize()) }
                        Spacer(Modifier.width(16.dp))
                        Column {
                            BasicText("Scan on the same network, or open", style = LocalType.current.caption)
                            Spacer(Modifier.height(4.dp))
                            BasicText(url, style = LocalType.current.bodyStrong)
                            Spacer(Modifier.height(2.dp))
                            BasicText("Saved ${CrashLog.format(s.savedAt)}", style = LocalType.current.caption)
                        }
                    }
                }

                SettingsGroup("Region ping")
                ActionSetting(
                    if (pinging) "Timing every region" else "Time every region",
                    {
                        if (pinging) return@ActionSetting
                        pinging = true
                        scope.launch {
                            pings = runCatching { Nvidia.regions(app.streamingBase, app.serviceToken()) }.getOrNull() ?: pings
                            pinging = false
                        }
                    },
                    value = pings?.firstOrNull { it.pingMs != null }?.let { "Fastest: ${it.name}" },
                )
                for (r in (pings ?: app.regions).take(24)) {
                    InfoLine(r.name, r.pingMs?.let { "$it ms" } ?: "No answer", dot = when {
                        r.pingMs == null -> Palette.textTertiary
                        r.pingMs < 35 -> Palette.good
                        r.pingMs < 70 -> Palette.warn
                        else -> Palette.danger
                    })
                }

                SettingsGroup("Local API")
                ActionSetting("API", onApi, value = if (LocalApi.running) "Port ${LocalApi.PORT}" else "Not running")

                SettingsGroup("Last launch")
                val steps = SessionLog.all().takeLast(10)
                if (steps.isEmpty()) InfoLine("Steps", "None yet")
                for (l in steps) InfoLine(l.substringAfter(' ').substringBefore(':'), l.substringAfter(": ", l).take(60))
                for (l in settings.log4k.lines().filter { it.isNotBlank() }.takeLast(3)) InfoLine("4K", l.take(70))
            }
        }
    }
}

/** What the local API is, where to reach it, and every endpoint. */
@Composable
private fun ApiPage() {
    val type = LocalType.current
    val base = LocalApi.baseUrl()
    PivotScroll(leadingFraction = 0.3f) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 24.dp)) {
            Row(Modifier.reveal(0), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(96.dp).background(Color.White, RoundedCornerShape(10.dp)).padding(6.dp)) { QrCode(base, Modifier.fillMaxSize()) }
                Spacer(Modifier.width(18.dp))
                Column {
                    BasicText("API", style = type.title)
                    Spacer(Modifier.height(4.dp))
                    BasicText(base, style = type.headline)
                    Spacer(Modifier.height(4.dp))
                    BasicText(
                        "Read-only JSON. Answers devices on your home network while Kumori is open.",
                        style = type.caption,
                    )
                    Spacer(Modifier.height(4.dp))
                    BasicText(
                        if (LocalApi.running) "Running, ${LocalApi.served} requests answered" else (LocalApi.problem ?: "Starting"),
                        style = type.caption.copy(color = if (LocalApi.running) Palette.good else Palette.warn),
                    )
                }
            }
            Spacer(Modifier.height(16.dp))
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                for ((i, e) in LocalApi.ENDPOINTS.withIndex()) {
                    Row(Modifier.reveal(1 + i).fillMaxWidth()) {
                        BasicText(e.first, Modifier.width(140.dp), style = type.bodyStrong.copy(fontFeatureSettings = "tnum"))
                        BasicText(e.second, Modifier.weight(1f), style = type.body)
                    }
                }
            }
        }
    }
}
