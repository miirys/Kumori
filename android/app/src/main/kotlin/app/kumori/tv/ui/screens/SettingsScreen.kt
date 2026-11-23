package app.kumori.tv.ui.screens

import androidx.compose.ui.platform.LocalContext
import app.kumori.tv.ui.components.GridCell
import app.kumori.tv.ui.components.CarouselSetting
import app.kumori.tv.stream.Capabilities
import app.kumori.tv.Resolution
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.unit.IntOffset
import app.kumori.tv.ui.components.Avatar
import app.kumori.tv.ui.components.InfoLine
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Star
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import app.kumori.tv.DlssFrames
import app.kumori.tv.DlssModel
import app.kumori.tv.DlssQuality
import app.kumori.tv.DlssRays
import app.kumori.tv.FramePacing
import app.kumori.tv.GameLanguage
import app.kumori.tv.Settings
import app.kumori.tv.StatsCorner
import app.kumori.tv.StatsMode
import app.kumori.tv.StreamMode
import app.kumori.tv.VideoCodec
import app.kumori.tv.VideoPath
import app.kumori.tv.data.AppState
import app.kumori.tv.input.Btn
import app.kumori.tv.input.PadHub
import app.kumori.tv.input.PadInfo
import app.kumori.tv.ui.components.ActionSetting
import app.kumori.tv.ui.components.GameArt
import app.kumori.tv.ui.components.PivotScroll
import app.kumori.tv.ui.components.Pressable
import app.kumori.tv.ui.components.SettingsFocus
import app.kumori.tv.ui.components.SettingsGroup
import app.kumori.tv.ui.components.SettingsList
import app.kumori.tv.ui.components.SwitchSetting
import app.kumori.tv.ui.components.ValueSetting
import app.kumori.tv.ui.components.onFocusColor
import app.kumori.tv.ui.motion.Motion
import app.kumori.tv.ui.motion.RevealPage
import app.kumori.tv.ui.motion.reveal
import app.kumori.tv.ui.theme.LocalType
import app.kumori.tv.ui.theme.Palette

private enum class Page(val label: String, val icon: ImageVector) {
    STREAM("Stream", Icons.Rounded.PlayArrow),
    GAME("In game", Icons.Rounded.Settings),
    CONTROLLERS("Controllers", Icons.Rounded.Star),
    ACCOUNT("Account", Icons.Rounded.AccountCircle),
    ABOUT("About", Icons.Rounded.Info),
}

private val PageItemHeight = 34.dp
private val PageItemGap = 4.dp

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun SettingsScreen(hub: PadHub, app: AppState, settings: Settings) {
    var page by remember { mutableStateOf(Page.STREAM) }
    var pageDir by remember { mutableIntStateOf(1) }
    fun open(p: Page) {
        if (p == page) return
        pageDir = if (p.ordinal > page.ordinal) 1 else -1
        page = p
    }
    val entry = LocalSectionEntry.current
    val pageFocus = remember { Page.entries.associateWith { FocusRequester() } }
    val pillY by animateDpAsState((PageItemHeight + PageItemGap) * page.ordinal, Motion.glide(), label = "pill")
    Row(Modifier.fillMaxSize().padding(start = 40.dp, end = 40.dp, top = TopBarHeight + 18.dp)) {
        Box(
            Modifier
                .width(176.dp)
                .reveal(0)
                // Coming back from the list always lands on the open page.
                .focusProperties { enter = { pageFocus.getValue(page) } }
                .focusGroup(),
        ) {
            Box(Modifier.offset(y = pillY).fillMaxWidth().height(PageItemHeight).background(Palette.glassStrong, RoundedCornerShape(50)))
            Column(verticalArrangement = Arrangement.spacedBy(PageItemGap)) {
                for (p in Page.entries) {
                    Pressable(
                        onClick = { open(p) },
                        shape = RoundedCornerShape(50),
                        focusedScale = 1.03f,
                        color = Color.Transparent,
                        border = false,
                        focusRequester = pageFocus.getValue(p),
                        modifier = Modifier.fillMaxWidth().height(PageItemHeight).then(
                            if (p == page && entry != null) Modifier.focusRequester(entry) else Modifier,
                        ),
                    ) { focused ->
                        LaunchedEffect(focused) { if (focused) open(p) }
                        val fg = onFocusColor(focused, if (p == page) Palette.text else Palette.textSecondary)
                        Row(Modifier.fillMaxSize().padding(start = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Image(p.icon, null, Modifier.size(14.dp), colorFilter = ColorFilter.tint(fg))
                            Spacer(Modifier.width(10.dp))
                            BasicText(p.label, style = LocalType.current.label.copy(color = fg))
                        }
                    }
                }
            }
        }
        Spacer(Modifier.width(36.dp))
        AnimatedContent(
            targetState = page,
            modifier = Modifier.fillMaxSize(),
            transitionSpec = {
                Motion.pages(pageDir)
            },
            label = "page",
        ) { p ->
            RevealPage(key = p, dy = pageDir, group = "settings") {
                when (p) {
                    Page.STREAM -> ListPage { StreamPage(settings, app) }
                    Page.GAME -> ListPage { GamePage(settings) }
                    Page.CONTROLLERS -> ControllerPage(hub)
                    Page.ACCOUNT -> ListPage { AccountPage(app) }
                    Page.ABOUT -> AboutPage(app, settings)
                }
            }
        }
    }
}

/** A scrolling settings list with the focused row's hint underneath. */
@Composable
private fun ListPage(content: @Composable () -> Unit) {
    val focus = remember { SettingsFocus() }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            PivotScroll(leadingFraction = 0.3f) {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
                    SettingsList(focus) { content() }
                }
            }
        }
        // One line of help for the focused row, in the same place every time.
        AnimatedContent(
            targetState = if (focus.active) focus.hint else null,
            transitionSpec = { fadeIn(Motion.fade()) togetherWith fadeOut(Motion.fade()) },
            modifier = Modifier.fillMaxWidth().height(48.dp).padding(start = 16.dp, top = 6.dp),
            label = "hint",
        ) { h ->
            if (h != null) BasicText(h, style = LocalType.current.body)
        }
    }
}

private fun modeLabel(height: Int, fps: Int) = "${if (height >= 2160) "4K" else "${height}p"} at $fps fps"

private fun gbPerHour(mbps: Int) = mbps * 3600 / 8 / 1000.0

/**
 * Resolution and frame rate as one sideways strip of modes, like "1440p@120". [active] is the
 * mode in use (the stream on screen, or the saved choice when nothing is playing); it is
 * ringed and can't be picked again.
 */
@Composable
fun ModeSetting(chosen: StreamMode, active: StreamMode, app: AppState, onPick: (StreamMode) -> Unit) {
    val context = LocalContext.current
    val modes = remember { Resolution.entries.reversed().flatMap { r -> StreamMode.RATES.map { StreamMode(r, it) } } }
    val verdicts = remember(app.membership) { modes.map { Capabilities.check(it, app, context) } }
    CarouselSetting(
        "Resolution",
        modes.map { "${it.resolution.label}@${it.fps}" },
        cell = { i ->
            val mode = modes[i]
            val v = verdicts[i]
            when {
                mode == active -> GridCell(current = true, note = v.note)
                v.blocked -> GridCell(blocked = true, note = v.note)
                mode == chosen -> GridCell(note = "This was asked for, but GeForce NOW sent ${active.label}. OK to try again.")
                else -> GridCell(note = v.note)
            }
        },
        onPick = { onPick(modes[it]) },
        hint = if (chosen != active) "${chosen.label} was asked for. GeForce NOW sent ${active.label}." else Capabilities.check(active, app, context).note,
    )
}

@Composable
private fun StreamPage(settings: Settings, app: AppState) {
    SettingsGroup("Picture")
    ModeSetting(settings.mode, settings.mode, app, settings::chooseMode)
    settings.log4k.lines().lastOrNull { it.isNotBlank() }?.let { InfoLine("Last 4K try", it) }
    val regions = app.regions
    if (regions.isNotEmpty()) {
        val ri = regions.indexOfFirst { it.name == settings.region } + 1
        ValueSetting(
            "Server location",
            listOf("Automatic") + regions.map { r -> r.pingMs?.let { "${r.name}, $it ms" } ?: r.name },
            ri,
            { if (it == 0) settings.chooseRegion("", "") else settings.chooseRegion(regions[it - 1].name, regions[it - 1].url) },
            hint = if (ri == 0) "Uses the nearest server, and tries the next closest ones if it can't start your resolution." else "Always streams from this location.",
        )
    }
    val bi = Settings.BITRATES.indexOf(settings.bitrateMbps).coerceAtLeast(0)
    ValueSetting(
        "Maximum bitrate",
        Settings.BITRATES.map { "$it Mbps" },
        bi,
        { settings.stepBitrate(it - bi) },
        hint = "Up to %.0f GB an hour. Lower it if the picture stutters.".format(gbPerHour(settings.bitrateMbps)),
    )
    ValueSetting(
        "Video codec",
        VideoCodec.entries.map { it.label },
        settings.codec.ordinal,
        { settings.cycleCodec(it - settings.codec.ordinal) },
        hint = "Automatic picks the best one your TV can decode.",
    )
    ValueSetting(
        "Video output",
        VideoPath.entries.map { it.label },
        settings.videoPath.ordinal,
        { settings.cycleVideoPath(it - settings.videoPath.ordinal) },
        hint = when (settings.videoPath) {
            VideoPath.AUTO -> "Picks the fastest output this box handles, and falls back if it fails."
            VideoPath.DIRECT -> "Lowest delay. Switch to Compatible if streams close the app."
            VideoPath.COMPATIBLE -> "Works on more TVs, with a little more delay."
        },
    )
    ValueSetting(
        "Frame pacing",
        FramePacing.entries.map { it.label },
        settings.framePacing.ordinal,
        { settings.cycleFramePacing(it - settings.framePacing.ordinal) },
        hint = when (settings.framePacing) {
            FramePacing.SMOOTH -> "Waits for the screen on every frame. Can cap 120 fps streams near 90."
            FramePacing.FASTEST -> "Never waits for the screen, so every frame is decoded. Best for 120 fps."
        },
    )
    ValueSetting(
        "DLSS model",
        DlssModel.entries.map { it.label },
        settings.dlssModel.ordinal,
        { settings.cycleDlssModel(it - settings.dlssModel.ordinal) },
        hint = when (settings.dlssModel) {
            DlssModel.GAME -> "Games use their own DLSS model. The others apply from the next game you start."
            DlssModel.RECOMMENDED -> "NVIDIA picks the model for each quality mode. Only for games with DLSS turned on."
            DlssModel.K -> "Preset K, the all-round model. Only for games with DLSS turned on."
            DlssModel.L -> "Preset L, made for Ultra Performance at 4K. Only for games with DLSS turned on."
            DlssModel.M -> "Preset M, made for Performance mode. Only for games with DLSS turned on."
        },
    )
    ValueSetting(
        "DLSS quality",
        DlssQuality.entries.map { it.label },
        settings.dlssQuality.ordinal,
        { settings.cycleDlssQuality(it - settings.dlssQuality.ordinal) },
        hint = "How much DLSS upscales, whatever the game is set to. Applies from the next game you start.",
    )
    ValueSetting(
        "Ray Reconstruction model",
        DlssRays.entries.map { it.label },
        settings.dlssRays.ordinal,
        { settings.cycleDlssRays(it - settings.dlssRays.ordinal) },
        hint = "Used when Ray Reconstruction is on in the game. Needs Performance or Ultimate.",
    )
    ValueSetting(
        "Frame generation",
        DlssFrames.entries.map { it.label },
        settings.dlssFrames.ordinal,
        { settings.cycleDlssFrames(it - settings.dlssFrames.ordinal) },
        hint = "Turn frame generation on in the game first. Dynamic needs an Ultimate RTX 5080 rig.",
    )
    settings.fixes?.let { f ->
        ActionSetting(
            "Undo automatic fixes",
            settings::clearFixes,
            value = f,
            hint = "Turned on after streams closed the app. Undo them to try the defaults again.",
        )
    }
    SwitchSetting("10-bit colour", settings.tenBit, settings::toggleTenBit, hint = "Smoother skies and shadows. Needs HEVC or AV1.")
    SwitchSetting(
        "Highest refresh rate",
        settings.maxRefresh,
        settings::toggleMaxRefresh,
        hint = "Runs the TV at its fastest mode, for smoother menus and 120 fps streams.",
    )
    SettingsGroup("Game")
    SwitchSetting("NVIDIA Reflex", settings.lowLatency, settings::toggleLowLatency, hint = "Lower input lag in supported games at 120 fps.")
    ValueSetting(
        "Game language",
        GameLanguage.entries.map { it.label },
        settings.language.ordinal,
        { settings.cycleLanguage(it - settings.language.ordinal) },
        hint = "Used by games that offer more than one language.",
    )
}

@Composable
private fun GamePage(settings: Settings) {
    SettingsGroup("Overlay")
    ValueSetting(
        "Performance stats",
        StatsMode.entries.map { it.label },
        settings.stats.ordinal,
        { settings.setStatsMode(StatsMode.entries[it]) },
        hint = "Also in the stream menu while you play.",
    )
    ValueSetting(
        "Stats position",
        StatsCorner.entries.map { it.label },
        settings.statsCorner.ordinal,
        { settings.cycleCorner(it - settings.statsCorner.ordinal) },
    )
    SwitchSetting("Session timer", settings.sessionTimer, settings::toggleTimer, hint = "Shows how long you've played in the stream menu.")
    SettingsGroup("Controls")
    val hi = Settings.HOLD_TIMES.indexOf(settings.holdToOpenMs).coerceAtLeast(0)
    ValueSetting(
        "Hold Start for menu",
        Settings.HOLD_TIMES.map { ms -> (ms / 1000.0).let { v -> if (v == Math.floor(v)) "${v.toInt()} s" else "$v s" } },
        hi,
        { settings.stepHold(it - hi) },
        hint = "A quick press still goes to the game. Guide opens the menu too.",
    )
    val mi = Settings.MOUSE_SPEEDS.indexOfFirst { it >= settings.mouseSpeed - 0.01f }.coerceAtLeast(0)
    ValueSetting(
        "Mouse speed",
        Settings.MOUSE_SPEEDS.map { "${(it * 100).toInt()} %" },
        mi,
        { settings.stepMouseSpeed(it - mi) },
    )
    SettingsGroup("Sound")
    ValueSetting(
        "Game volume",
        (0..10).map { "${it * 10} %" },
        settings.volume / 10,
        { settings.stepVolume(it - settings.volume / 10) },
    )
}

@Composable
private fun AccountPage(app: AppState) {
    val p = app.profile
    val type = LocalType.current
    if (p == null) {
        SettingsGroup("Not signed in")
        BasicText("Sign in from Home.", Modifier.padding(start = 16.dp), style = type.body)
        return
    }
    Row(Modifier.padding(start = 16.dp, top = 16.dp, bottom = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Avatar(p.avatar, Modifier.size(56.dp))
        Spacer(Modifier.width(14.dp))
        Column {
            BasicText(p.name, style = type.title)
            BasicText(listOfNotNull(p.email, app.membership?.tier ?: p.tier).joinToString(", "), style = type.body)
        }
    }
    app.membership?.let { mem ->
        SettingsGroup("Membership")
        mem.modes.maxWithOrNull(compareBy({ it.height }, { it.fps }))?.let { InfoLine("Best stream", modeLabel(it.height, it.fps)) }
        InfoLine("Play time", if (mem.unlimited) "Unlimited" else mem.hoursLeft?.let { "%.1f hours left".format(it) } ?: "Unknown")
    }
    ActionSetting("Refresh library", app::refresh, value = "${app.library.size} games", hint = "Picks up games you added in another app.")
    ActionSetting("Sign out", app::signOut, hint = "You can sign back in with your phone.")
}
