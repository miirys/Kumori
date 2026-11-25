package app.kumori.tv.ui.stream

import app.kumori.tv.ui.screens.ModeSetting
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import app.kumori.tv.ui.components.glass
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ExitToApp
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import app.kumori.tv.Settings
import app.kumori.tv.StatsCorner
import app.kumori.tv.StatsMode
import app.kumori.tv.input.NavAction
import app.kumori.tv.input.PadHub
import app.kumori.tv.stream.Keymap
import app.kumori.tv.stream.Streamer
import app.kumori.tv.ui.components.ActionSetting
import app.kumori.tv.ui.components.SettingsFocus
import app.kumori.tv.ui.components.SettingsGroup
import app.kumori.tv.ui.components.SettingsList
import app.kumori.tv.ui.components.SwitchSetting
import app.kumori.tv.ui.components.ValueSetting
import app.kumori.tv.ui.components.GameLogo
import app.kumori.tv.ui.components.GlassButton
import app.kumori.tv.ui.components.PivotScroll
import app.kumori.tv.ui.components.Pressable
import app.kumori.tv.ui.components.onFocusColor
import app.kumori.tv.ui.motion.Motion
import app.kumori.tv.ui.motion.RevealPage
import app.kumori.tv.ui.motion.reveal
import app.kumori.tv.ui.theme.LocalType
import app.kumori.tv.ui.theme.Palette
import kotlinx.coroutines.delay

/**
 * The in-stream menu, over the running game: a glass pane on the left with the ways out first,
 * then stream, sound and control settings, and the session's numbers on the right. The game
 * keeps running behind it.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun StreamMenu(streamer: Streamer, settings: Settings, hub: PadHub) {
    val type = LocalType.current
    val resume = remember { FocusRequester() }
    var confirmEnd by remember { mutableStateOf(false) }
    val slide = remember { Animatable(0f) }
    val px = with(LocalDensity.current) { 56.dp.toPx() }

    BackHandler(enabled = !confirmEnd, onBack = streamer::closeMenu)
    LaunchedEffect(Unit) {
        slide.animateTo(1f, Motion.springOf(0.55f, 0.84f))
    }
    LaunchedEffect(Unit) {
        delay(60)
        runCatching { resume.requestFocus() }
    }
    // Start closes the menu again.
    LaunchedEffect(hub) {
        hub.actions.collect { if (it == NavAction.MENU && !confirmEnd) streamer.closeMenu() }
    }

    Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.72f), Color.Black.copy(alpha = 0.28f))))) {
        RevealPage(key = "menu") {
            Row(Modifier.fillMaxSize().padding(horizontal = 36.dp, vertical = 28.dp)) {
                Column(
                    Modifier
                        .width(392.dp)
                        .fillMaxHeight()
                        .graphicsLayer {
                            alpha = slide.value.coerceIn(0f, 1f)
                            translationX = (1f - slide.value) * -px
                        }
                        .glass(RoundedCornerShape(24.dp), strong = true)
                        .padding(start = 18.dp, end = 18.dp, top = 20.dp),
                ) {
                    val g = streamer.game
                    Box(Modifier.reveal(0).padding(start = 8.dp).heightIn(max = 40.dp).widthIn(max = 240.dp)) {
                        GameLogo(g?.logo, g?.title ?: "Game", Modifier.heightIn(max = 40.dp).widthIn(max = 240.dp), style = type.title)
                    }
                    Spacer(Modifier.height(10.dp))
                    SessionFacts(streamer, settings, Modifier.reveal(1).padding(start = 8.dp))
                    Spacer(Modifier.height(14.dp))
                    val menuFocus = remember { SettingsFocus(inlineValues = true) }
                    PivotScroll(leadingFraction = 0.35f) {
                        Column(
                            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).focusGroup().padding(bottom = 20.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Column(Modifier.reveal(2), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                MenuAction("Resume", Icons.Rounded.PlayArrow, streamer::closeMenu, focusRequester = resume)
                                MenuAction("Leave running", Icons.Rounded.ExitToApp, streamer::leave)
                                MenuAction("End Game", Icons.Rounded.Close, { confirmEnd = true }, danger = true)
                            }
                            Spacer(Modifier.height(6.dp))

                            SettingsList(menuFocus, Modifier.reveal(3)) {
                                SettingsGroup("Stream")
                                ModeSetting(settings.mode, streamer.playing ?: settings.mode, streamer.app, streamer::changeMode)
                                ValueSetting(
                                    "Stats",
                                    StatsMode.entries.map { it.label },
                                    settings.stats.ordinal,
                                    { settings.setStatsMode(StatsMode.entries[it]) },
                                )
                                ValueSetting(
                                    "Stats position",
                                    StatsCorner.entries.map { it.label },
                                    settings.statsCorner.ordinal,
                                    { settings.cycleCorner(it - settings.statsCorner.ordinal) },
                                )
                                ActionSetting("Refresh picture", streamer::refreshPicture)

                                SettingsGroup("Sound")
                                ValueSetting(
                                    "Volume",
                                    (0..10).map { "${it * 10} %" },
                                    settings.volume / 10,
                                    { streamer.stepVolume(it - settings.volume / 10) },
                                )
                                SwitchSetting("Mute", streamer.muted, streamer::toggleMute)

                                SettingsGroup("Controls")
                                SwitchSetting("Controller as mouse", streamer.controllerMouse, streamer::toggleControllerMouse)
                                val mi = Settings.MOUSE_SPEEDS.indexOfFirst { it >= settings.mouseSpeed - 0.01f }.coerceAtLeast(0)
                                ValueSetting(
                                    "Mouse speed",
                                    Settings.MOUSE_SPEEDS.map { "${(it * 100).toInt()} %" },
                                    mi,
                                    { streamer.stepMouseSpeed(it - mi) },
                                )

                                SettingsGroup("Session")
                                IdleSetting(settings)
                            }

                            SettingsGroup("Keys")
                            FlowRow(
                                Modifier.reveal(4).fillMaxWidth().padding(horizontal = 12.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                KeyChip("Keyboard") { streamer.openKeyboard() }
                                KeyChip("Esc") { streamer.sendCombo(Keymap.ESCAPE) }
                                KeyChip("Enter") { streamer.sendCombo(Keymap.ENTER) }
                                KeyChip("Tab") { streamer.sendCombo(Keymap.TAB) }
                                KeyChip("Alt + Tab") { streamer.sendCombo(Keymap.ALT, Keymap.TAB) }
                                KeyChip("Alt + Enter") { streamer.sendCombo(Keymap.ALT, Keymap.ENTER) }
                                KeyChip("Windows") { streamer.sendCombo(Keymap.WIN) }
                                KeyChip("F11") { streamer.sendCombo(Keymap.F11) }
                            }
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                SessionCard(streamer, Modifier.reveal(3).graphicsLayer { alpha = slide.value.coerceIn(0f, 1f) })
            }
        }
        EndConfirmation(
            visible = confirmEnd,
            title = streamer.game?.title,
            onCancel = { confirmEnd = false },
            onEnd = { confirmEnd = false; streamer.quit() },
        )
    }
}

/** The idle timer: how long without input before the session is ended for you. */
@Composable
fun IdleSetting(settings: Settings) {
    val i = Settings.IDLE_CHOICES.indexOf(settings.idleMinutes).coerceAtLeast(0)
    ValueSetting(
        "End when idle",
        Settings.IDLE_CHOICES.map { if (it == 0) "Off" else "After $it min" },
        i,
        { settings.stepIdle(it - i) },
    )
}

/** Time played, play time left on the membership and the idle timer, ticking. */
@Composable
private fun SessionFacts(streamer: Streamer, settings: Settings, modifier: Modifier = Modifier) {
    val type = LocalType.current
    val played = elapsed(streamer.liveSince)
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(30_000)
            tick++
        }
    }
    val left = remember(tick, streamer.app.membership, streamer.liveSince) { streamer.hoursLeft() }
    val unlimited = streamer.app.membership?.unlimited == true
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
        Fact(played, "played")
        when {
            unlimited -> Fact("Unlimited", "play time")
            left != null -> Fact(hoursText(left), "left this month", warn = left < 1.0)
        }
        Fact(if (settings.idleMinutes == 0) "Off" else "${settings.idleMinutes} min", "idle timer")
    }
}

private fun hoursText(h: Double): String = when {
    h >= 10 -> "%.0f h".format(h)
    h >= 1 -> "%.1f h".format(h)
    else -> "${(h * 60).toInt()} min"
}

@Composable
private fun Fact(value: String, label: String, warn: Boolean = false) {
    val type = LocalType.current
    Column {
        BasicText(value, style = type.headline.copy(fontFeatureSettings = "tnum", color = if (warn) Palette.warn else Palette.text))
        BasicText(label, style = type.caption)
    }
}

/** A full-width action on the menu's glass: quiet at rest, a white platter in focus. */
@Composable
private fun MenuAction(label: String, icon: ImageVector, onClick: () -> Unit, danger: Boolean = false, focusRequester: FocusRequester? = null) {
    Pressable(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth().height(40.dp),
        shape = RoundedCornerShape(12.dp),
        focusedScale = 1.03f,
        color = Palette.glass,
        focusRequester = focusRequester,
    ) { focused ->
        val fg = when {
            danger && focused -> Palette.dangerInk
            danger -> Palette.danger
            else -> onFocusColor(focused)
        }
        Row(Modifier.fillMaxSize().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(icon, null, Modifier.size(15.dp), colorFilter = ColorFilter.tint(fg))
            Spacer(Modifier.width(12.dp))
            BasicText(label, style = LocalType.current.bodyStrong.copy(color = fg))
        }
    }
}

/**
 * Asks before ending: a glass card over the dimmed game, focus on Cancel so a stray press
 * never ends anything.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun EndConfirmation(visible: Boolean, title: String?, onCancel: () -> Unit, onEnd: () -> Unit) {
    val cancel = remember { FocusRequester() }
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(tween(180)),
        exit = fadeOut(tween(160)),
    ) {
        BackHandler(onBack = onCancel)
        val pop = remember { Animatable(0.92f) }
        LaunchedEffect(Unit) {
            pop.animateTo(1f, Motion.springOf(0.4f, 0.78f))
        }
        LaunchedEffect(Unit) {
            delay(80)
            runCatching { cancel.requestFocus() }
        }
        Box(
            Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)).focusProperties { exit = { FocusRequester.Cancel } }.focusGroup(),
            contentAlignment = Alignment.Center,
        ) {
            val type = LocalType.current
            Column(
                Modifier
                    .width(400.dp)
                    .graphicsLayer { scaleX = pop.value; scaleY = pop.value }
                    .glass(RoundedCornerShape(26.dp), strong = true)
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                PowerGlyph(Modifier.size(34.dp))
                Spacer(Modifier.height(14.dp))
                BasicText(if (title != null) "End $title?" else "End this game?", style = type.title.copy(textAlign = TextAlign.Center), maxLines = 2)
                Spacer(Modifier.height(6.dp))
                BasicText("Anything not saved in the game is lost.", style = type.body.copy(textAlign = TextAlign.Center))
                Spacer(Modifier.height(20.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    DialogButton("Cancel", onCancel, Modifier.weight(1f), focusRequester = cancel)
                    DialogButton("End Game", onEnd, Modifier.weight(1f), danger = true)
                }
            }
        }
    }
}

@Composable
private fun DialogButton(label: String, onClick: () -> Unit, modifier: Modifier, danger: Boolean = false, focusRequester: FocusRequester? = null) {
    Pressable(onClick, modifier.height(40.dp), shape = RoundedCornerShape(50), focusedScale = 1.05f, color = Palette.glass, focusRequester = focusRequester) { focused ->
        val fg = when {
            danger && focused -> Palette.dangerInk
            danger -> Palette.danger
            else -> onFocusColor(focused)
        }
        BasicText(label, style = LocalType.current.bodyStrong.copy(color = fg))
    }
}

/** A power symbol that draws itself in: the ring sweeps round, then the stroke drops in. */
@Composable
private fun PowerGlyph(modifier: Modifier) {
    val p = remember { Animatable(0f) }
    LaunchedEffect(Unit) { p.animateTo(1f, tween(700, easing = Motion.arrive)) }
    Canvas(modifier) {
        val w = size.minDimension * 0.1f
        val ring = (p.value / 0.75f).coerceIn(0f, 1f)
        val bar = ((p.value - 0.45f) / 0.55f).coerceIn(0f, 1f)
        val inset = w / 2 + size.minDimension * 0.08f
        drawArc(
            Palette.danger, -60f, 300f * ring, false,
            topLeft = Offset(inset, inset), size = Size(size.width - inset * 2, size.height - inset * 2),
            style = Stroke(w, cap = StrokeCap.Round),
        )
        if (bar > 0f) {
            drawLine(Palette.danger, Offset(size.width / 2, w), Offset(size.width / 2, w + (size.height * 0.42f) * bar), strokeWidth = w, cap = StrokeCap.Round)
        }
    }
}

@Composable
private fun KeyChip(label: String, onClick: () -> Unit) {
    Pressable(onClick, shape = RoundedCornerShape(10.dp), focusedScale = 1.08f) { focused ->
        BasicText(label, Modifier.padding(horizontal = 13.dp, vertical = 8.dp), style = LocalType.current.label.copy(color = onFocusColor(focused)))
    }
}

@Composable
private fun SessionCard(streamer: Streamer, modifier: Modifier) {
    val type = LocalType.current
    val s = streamer.stats
    val session = streamer.session
    Column(
        modifier.width(240.dp).glass(RoundedCornerShape(20.dp), strong = true).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        BasicText("This session", style = type.headline)
        Spacer(Modifier.height(4.dp))
        Line("Picture", if (s.width > 0) "${s.width} × ${s.height}" else session?.let { "${it.width ?: "–"} × ${it.height ?: "–"}" } ?: "–")
        Line("Frame rate", s.fps?.let { "%.0f fps".format(it) } ?: "–")
        Line("Codec", s.codec ?: "–")
        Line("Bitrate", s.bitrateMbps?.let { "%.1f Mbps".format(it) } ?: "–")
        Line("Latency", s.rttMs?.let { "%.0f ms".format(it) } ?: "–")
        Line("Packet loss", s.packetLossPct?.let { "%.2f %%".format(it) } ?: "–")
        Line("Rig", session?.gpu ?: "–")
    }
}

@Composable
private fun Line(label: String, value: String) {
    val type = LocalType.current
    Row(Modifier.fillMaxWidth()) {
        BasicText(label, Modifier.weight(1f), style = type.caption)
        BasicText(value, style = type.caption.copy(color = Palette.text, fontFeatureSettings = "tnum"))
    }
}
