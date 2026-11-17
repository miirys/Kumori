package app.kumori.tv.ui.components

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.kumori.tv.ui.motion.Motion
import app.kumori.tv.ui.motion.reveal
import app.kumori.tv.ui.theme.LocalType
import app.kumori.tv.ui.theme.Palette
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/**
 * Where the focused row is, so one highlight can glide from row to row instead of each row
 * lighting up on its own. Also carries the focused row's hint for the footer.
 */
@Stable
class SettingsFocus(
    /**
     * When true, left and right change a value as soon as its row is focused (fine for a
     * single column like the in-game menu). When false, OK starts changing the value, so left
     * and right stay free for moving between columns.
     */
    val inlineValues: Boolean = false,
) {
    var top by mutableFloatStateOf(0f)
    var height by mutableFloatStateOf(0f)
    var active by mutableStateOf(false)
    var hint by mutableStateOf<String?>(null)
    internal var owner by mutableIntStateOf(0)
    internal var next = 0
}

private val LocalSettingsFocus = compositionLocalOf<SettingsFocus?> { null }

/**
 * A plain list of settings with a single white highlight that slides to the focused row.
 * Rows are separated by hairlines; nothing is boxed.
 */
@Composable
fun SettingsList(state: SettingsFocus = remember { SettingsFocus() }, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val top = remember { Animatable(0f) }
    val height = remember { Animatable(0f) }
    var placed by remember { mutableStateOf(false) }
    LaunchedEffect(state.top, state.height, state.active) {
        if (!state.active) return@LaunchedEffect
        if (!placed) {
            // First focus: appear in place rather than flying in from the top.
            top.snapTo(state.top)
            height.snapTo(state.height)
            placed = true
            return@LaunchedEffect
        }
        coroutineScope {
            launch { top.animateTo(state.top, Motion.springOf(0.3f, 0.88f)) }
            launch { height.animateTo(state.height, Motion.springOf(0.3f, 0.88f)) }
        }
    }
    val alpha by animateFloatAsState(if (state.active) 1f else 0f, Motion.fade(), label = "highlight")
    CompositionLocalProvider(LocalSettingsFocus provides state) {
        Box(modifier.fillMaxWidth()) {
            Box(
                Modifier
                    .offset { IntOffset(0, top.value.roundToInt()) }
                    .fillMaxWidth()
                    .height(with(LocalDensity.current) { height.value.toDp() })
                    .graphicsLayer { this.alpha = alpha }
                    .background(Palette.white, RoundedCornerShape(12.dp)),
            )
            Column { content() }
        }
    }
}

/** Shared plumbing for a row: focus reporting, hover-to-focus, layout tracking. */
@Composable
private fun SettingRowBase(
    hint: String?,
    onKey: (KeyEvent) -> Boolean,
    onClick: () -> Unit,
    focusRequester: FocusRequester? = null,
    onFocus: (Boolean) -> Unit = {},
    content: @Composable (focused: Boolean) -> Unit,
) {
    val state = LocalSettingsFocus.current
    val id = remember { (state?.next ?: 0).also { state?.next = it + 1 } + 1 }
    var focused by remember { mutableStateOf(false) }
    var top by remember { mutableFloatStateOf(0f) }
    var h by remember { mutableFloatStateOf(0f) }
    val source = remember { MutableInteractionSource() }
    val hovered by source.collectIsHoveredAsState()
    val requester = focusRequester ?: remember { FocusRequester() }
    LaunchedEffect(hovered) { if (hovered && !focused) runCatching { requester.requestFocus() } }
    LaunchedEffect(focused, top, h, hint) {
        if (focused && state != null) {
            state.owner = id
            state.top = top
            state.height = h
            state.hint = hint
            state.active = true
        } else if (!focused && state != null && state.owner == id) {
            state.active = false
        }
    }
    // A focused row that is removed never sees its focus end, so let go of the highlight here.
    DisposableEffect(Unit) {
        onDispose { if (state != null && state.owner == id) state.active = false }
    }
    Box(
        Modifier
            .fillMaxWidth()
            .reveal(id, distance = 22.dp)
            .onGloballyPositioned {
                top = it.positionInParent().y
                h = it.size.height.toFloat()
            }
            .focusRequester(requester)
            .onFocusChanged {
                focused = it.isFocused
                onFocus(it.isFocused)
            }
            .onPreviewKeyEvent { e -> onKey(e) }
            .hoverable(source)
            .clickable(interactionSource = source, indication = null, onClick = onClick),
    ) {
        content(focused)
    }
}

@Composable
private fun RowLayout(label: String, focused: Boolean, trailing: @Composable () -> Unit) {
    val fg = onFocusColor(focused)
    Column {
        Row(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            BasicText(label, Modifier.weight(1f), style = LocalType.current.bodyStrong.copy(color = fg))
            trailing()
        }
        Divider()
    }
}

@Composable
private fun Divider() {
    Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth().height(0.75.dp).background(Palette.hairline))
}

/**
 * A setting with a fixed list of values. OK starts changing it: left and right step through
 * the values, and OK, back, up or down finish. (In the in-game menu, left and right change it
 * straight away.) The value slides in from the side it came from.
 */
@Composable
fun ValueSetting(
    label: String,
    options: List<String>,
    index: Int,
    onSelect: (Int) -> Unit,
    hint: String? = null,
    focusRequester: FocusRequester? = null,
) {
    val state = LocalSettingsFocus.current
    val inline = state?.inlineValues ?: true
    var dir by remember { mutableIntStateOf(1) }
    var editing by remember { mutableStateOf(false) }
    var okHeld by remember { mutableStateOf(false) }
    val i = index.coerceIn(0, (options.size - 1).coerceAtLeast(0))
    fun go(d: Int, wrap: Boolean) {
        val n = if (wrap) (i + d).mod(options.size) else (i + d).coerceIn(0, options.lastIndex)
        if (n != i) {
            dir = if (wrap && d > 0 && n < i) 1 else d
            onSelect(n)
        }
    }
    BackHandler(enabled = editing) { editing = false }
    val live = inline || editing
    SettingRowBase(
        hint = if (editing) "Left and right to change, OK when done." else hint,
        onKey = { e ->
            val down = e.type == KeyEventType.KeyDown
            when (e.key) {
                Key.DirectionLeft -> if (live) { if (down) go(-1, false); true } else false
                Key.DirectionRight -> if (live) { if (down) go(1, false); true } else false
                Key.DirectionUp, Key.DirectionDown -> { if (editing) editing = false; false }
                Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> when {
                    inline -> false
                    else -> {
                        // Toggle once per press, however long OK is held.
                        if (down && !okHeld) editing = !editing
                        okHeld = down
                        true
                    }
                }
                else -> false
            }
        },
        onClick = { go(1, true) },
        focusRequester = focusRequester,
        onFocus = { if (!it) editing = false },
    ) { focused ->
        RowLayout(label, focused) {
            val fg = onFocusColor(focused, Palette.textSecondary)
            val arrows by animateFloatAsState(if (focused) (if (live) 1f else 0.3f) else 0f, Motion.fade(), label = "arrows")
            val edit by animateFloatAsState(if (editing) 1f else 0f, Motion.focus(), label = "edit")
            val valueColor = if (editing) Palette.white else fg
            Row(
                Modifier
                    .graphicsLayer { val sc = 1f + 0.04f * edit; scaleX = sc; scaleY = sc }
                    .background(Palette.black.copy(alpha = 0.88f * edit), RoundedCornerShape(50))
                    .padding(horizontal = 4.dp + 4.dp * edit, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                val arrowTint = if (editing) Palette.white else fg
                Image(
                    Icons.AutoMirrored.Rounded.KeyboardArrowLeft, null,
                    Modifier.size(16.dp).graphicsLayer { alpha = arrows * if (i > 0) 1f else 0.25f },
                    colorFilter = ColorFilter.tint(arrowTint),
                )
                AnimatedContent(
                    targetState = i,
                    transitionSpec = {
                        val d = dir
                        (slideInHorizontally(Motion.pageOffset) { it / 3 * d } + fadeIn(Motion.fade()))
                            .togetherWith(slideOutHorizontally(Motion.pageOffset) { -it / 3 * d } + fadeOut(Motion.fade()))
                    },
                    contentAlignment = Alignment.Center,
                    label = "value",
                ) { v ->
                    BasicText(options.getOrElse(v) { "" }, Modifier.padding(horizontal = 4.dp), style = LocalType.current.label.copy(color = valueColor))
                }
                Image(
                    Icons.AutoMirrored.Rounded.KeyboardArrowRight, null,
                    Modifier.size(16.dp).graphicsLayer { alpha = arrows * if (i < options.lastIndex) 1f else 0.25f },
                    colorFilter = ColorFilter.tint(arrowTint),
                )
            }
        }
    }
}

/** An on/off setting. OK flips it (in the in-game menu, left and right also set it). */
@Composable
fun SwitchSetting(label: String, on: Boolean, onToggle: () -> Unit, hint: String? = null) {
    val inline = LocalSettingsFocus.current?.inlineValues ?: true
    SettingRowBase(
        hint = hint,
        onKey = { e ->
            val down = e.type == KeyEventType.KeyDown
            when {
                !inline -> false
                e.key == Key.DirectionLeft -> { if (down && on) onToggle(); true }
                e.key == Key.DirectionRight -> { if (down && !on) onToggle(); true }
                else -> false
            }
        },
        onClick = onToggle,
    ) { focused ->
        RowLayout(label, focused) { SettingSwitch(on, focused) }
    }
}

@Composable
private fun SettingSwitch(on: Boolean, focused: Boolean) {
    val knob by animateFloatAsState(if (on) 1f else 0f, Motion.focus(), label = "knob")
    val track = if (focused) Palette.black.copy(alpha = 0.12f + 0.78f * knob) else Palette.white.copy(alpha = 0.16f + 0.74f * knob)
    val dot = if (focused) (if (on) Palette.white else Palette.black.copy(alpha = 0.5f)) else (if (on) Palette.black else Palette.white)
    Box(Modifier.size(width = 34.dp, height = 20.dp).background(track, RoundedCornerShape(50)).padding(3.dp)) {
        Box(Modifier.offset { IntOffset((knob * 14.dp.toPx()).roundToInt(), 0) }.size(14.dp).background(dot, CircleShape))
    }
}

/** One choice in a [GridSetting]. */
class GridCell(
    /** The one in use now. Drawn greyed and can't be picked again. */
    val current: Boolean = false,
    /** Can't be used here. Drawn greyed, and [note] says why. */
    val blocked: Boolean = false,
    /** A line shown under the list while the cursor is on this cell. */
    val note: String? = null,
    /** A short tag inside the cell, like "Now". */
    val tag: String? = null,
)

/**
 * Two settings that only make sense together, picked from one table: [rows] down the side,
 * [columns] across. OK opens the table, the arrows move through it, OK picks. Touch works the
 * same way: tap the row to open it, tap a cell to pick.
 */
@Composable
fun GridSetting(
    label: String,
    value: String,
    rows: List<String>,
    columns: List<String>,
    cell: (row: Int, column: Int) -> GridCell,
    onPick: (row: Int, column: Int) -> Unit,
    hint: String? = null,
) {
    var open by remember { mutableStateOf(false) }
    var okHeld by remember { mutableStateOf(false) }
    var r by remember { mutableIntStateOf(0) }
    var c by remember { mutableIntStateOf(0) }
    val requester = remember { FocusRequester() }
    fun show() {
        // Start on the choice in use, so the nearest other ones are one step away.
        for (i in rows.indices) for (j in columns.indices) if (cell(i, j).current) { r = i; c = j }
        open = true
    }
    fun pick(i: Int, j: Int) {
        val it = cell(i, j)
        r = i
        c = j
        if (it.current || it.blocked) return
        onPick(i, j)
        open = false
    }
    BackHandler(enabled = open) { open = false }
    val at = if (open) cell(r, c) else null
    SettingRowBase(
        hint = when {
            at == null -> hint
            at.note != null -> at.note
            at.current -> "This is the one in use."
            else -> "OK to switch."
        },
        onKey = { e ->
            val down = e.type == KeyEventType.KeyDown
            when (e.key) {
                Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                    if (down && !okHeld) { if (open) pick(r, c) else show() }
                    okHeld = down
                    true
                }
                Key.DirectionLeft -> if (open) { if (down && c > 0) c--; true } else false
                Key.DirectionRight -> if (open) { if (down && c < columns.lastIndex) c++; true } else false
                // Past the first or last line the table closes and focus moves on.
                Key.DirectionUp -> if (open && r > 0) { if (down) r--; true } else { if (down) open = false; false }
                Key.DirectionDown -> if (open && r < rows.lastIndex) { if (down) r++; true } else { if (down) open = false; false }
                else -> false
            }
        },
        onClick = {
            runCatching { requester.requestFocus() }
            if (open) open = false else show()
        },
        focusRequester = requester,
        onFocus = { if (!it) open = false },
    ) { focused ->
        val type = LocalType.current
        Column {
            Row(Modifier.fillMaxWidth().height(44.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                BasicText(label, Modifier.weight(1f), style = type.bodyStrong.copy(color = onFocusColor(focused)))
                BasicText(value, style = type.label.copy(color = onFocusColor(focused, Palette.textSecondary)))
            }
            AnimatedVisibility(
                open,
                enter = expandVertically(Motion.springOf(0.42f, 0.9f)) + fadeIn(Motion.fade()),
                exit = shrinkVertically(Motion.springOf(0.34f, 1f)) + fadeOut(Motion.fade()),
            ) {
                // Only ever shown on the white highlight, so everything here is dark on light.
                Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    for (i in rows.indices) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            BasicText(rows[i], Modifier.width(52.dp), style = type.label.copy(color = Palette.black.copy(alpha = 0.6f)))
                            for (j in columns.indices) {
                                GridChip(columns[j], cell(i, j), cursor = r == i && c == j, Modifier.weight(1f)) { pick(i, j) }
                            }
                        }
                    }
                }
            }
            Divider()
        }
    }
}

/**
 * One setting picked from a single sideways strip of choices, like "1440p@120". The strip
 * slides so the cursor stays in the middle, and choices further away shrink and fade. OK
 * starts choosing (in the in-game menu, left and right move straight away), the arrows move
 * the cursor, and OK picks. Up, down and back leave without picking.
 */
@Composable
fun CarouselSetting(
    label: String,
    items: List<String>,
    cell: (Int) -> GridCell,
    onPick: (Int) -> Unit,
    hint: String? = null,
) {
    val state = LocalSettingsFocus.current
    val inline = state?.inlineValues ?: true
    val current = items.indices.firstOrNull { cell(it).current } ?: 0
    var cursor by remember { mutableIntStateOf(current) }
    var editing by remember { mutableStateOf(false) }
    var okHeld by remember { mutableStateOf(false) }
    var focusedNow by remember { mutableStateOf(false) }
    LaunchedEffect(current, focusedNow) { if (!focusedNow) cursor = current }
    BackHandler(enabled = editing) { editing = false; cursor = current }
    val live = inline || editing
    fun pick() {
        val c = cell(cursor)
        if (c.current || c.blocked) return
        onPick(cursor)
        editing = false
    }
    val at = cell(cursor)
    SettingRowBase(
        hint = when {
            !focusedNow -> hint
            at.note != null -> at.note
            at.current -> "This is the one in use."
            live -> "Left and right to look, OK to switch."
            else -> "OK to choose."
        },
        onKey = { e ->
            val down = e.type == KeyEventType.KeyDown
            when (e.key) {
                Key.DirectionLeft -> if (live) { if (down && cursor > 0) cursor--; true } else false
                Key.DirectionRight -> if (live) { if (down && cursor < items.lastIndex) cursor++; true } else false
                Key.DirectionUp, Key.DirectionDown -> { if (editing) { editing = false; cursor = current }; false }
                Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                    if (down && !okHeld) { if (live) pick() else editing = true }
                    okHeld = down
                    true
                }
                else -> false
            }
        },
        onClick = { if (live) pick() else editing = true },
        onFocus = { f ->
            focusedNow = f
            if (!f) editing = false
        },
    ) { focused ->
        val type = LocalType.current
        Column {
            Row(Modifier.fillMaxWidth().height(40.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                BasicText(label, Modifier.weight(1f), style = type.bodyStrong.copy(color = onFocusColor(focused)))
                BasicText(items.getOrElse(current) { "" }, style = type.label.copy(color = onFocusColor(focused, Palette.textSecondary)))
            }
            val chipWidth = 104.dp
            val gap = 8.dp
            val slide by animateFloatAsState(cursor.toFloat(), Motion.springOf(0.38f, 0.82f), label = "strip")
            val lift by animateFloatAsState(if (live && focused) 1f else 0f, Motion.focus(), label = "lift")
            BoxWithConstraints(Modifier.fillMaxWidth().height(46.dp).padding(bottom = 8.dp).clipToBounds()) {
                val density = LocalDensity.current
                val step = with(density) { (chipWidth + gap).toPx() }
                val centre = with(density) { (maxWidth / 2 - chipWidth / 2).toPx() }
                for (i in items.indices) {
                    val c = cell(i)
                    val distance = abs(i - slide)
                    val x = centre + (i - slide) * step
                    val on = (1f - distance).coerceIn(0f, 1f) * lift
                    val dim = c.current || c.blocked
                    val fg = when {
                        on > 0.5f -> if (focused) Palette.white else Palette.black
                        focused -> Palette.black.copy(alpha = if (dim) 0.35f else 0.85f)
                        else -> Palette.white.copy(alpha = if (dim) 0.35f else 0.8f)
                    }
                    val fill = when {
                        focused -> Palette.black.copy(alpha = 0.06f + 0.84f * on)
                        else -> Palette.white.copy(alpha = 0.06f + 0.84f * on)
                    }
                    val ring = if (c.current) (if (focused) Palette.black else Palette.white).copy(alpha = 0.6f) else Palette.black.copy(alpha = 0f)
                    Box(
                        Modifier
                            .offset { IntOffset(x.roundToInt(), 0) }
                            .width(chipWidth)
                            .height(34.dp)
                            .graphicsLayer {
                                val sc = 1f + 0.1f * on - 0.06f * distance.coerceAtMost(3f)
                                scaleX = sc
                                scaleY = sc
                                alpha = (1f - 0.22f * distance).coerceIn(0.15f, 1f)
                            }
                            .background(fill, RoundedCornerShape(50))
                            .border(1.25.dp, ring, RoundedCornerShape(50))
                            .clickable(enabled = !dim) { cursor = i; pick() },
                        contentAlignment = Alignment.Center,
                    ) {
                        BasicText(
                            items[i] + if (c.blocked) " \uD83D\uDD12" else "",
                            style = type.label.copy(color = fg),
                            maxLines = 1,
                        )
                    }
                }
            }
            Divider()
        }
    }
}

@Composable
private fun GridChip(text: String, cell: GridCell, cursor: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val dim = cell.current || cell.blocked
    val on by animateFloatAsState(if (cursor) 1f else 0f, Motion.focus(), label = "cursor")
    val shape = RoundedCornerShape(9.dp)
    // A choice that can be picked fills black under the cursor. One that can't only gets a ring.
    val fill = if (dim) Palette.black.copy(alpha = 0.04f) else Palette.black.copy(alpha = 0.07f + 0.83f * on)
    val fg = when {
        dim -> Palette.black.copy(alpha = 0.34f)
        on > 0.5f -> Palette.white
        else -> Palette.black
    }
    Row(
        modifier
            .height(30.dp)
            .graphicsLayer { val sc = 1f + 0.03f * on; scaleX = sc; scaleY = sc }
            .background(fill, shape)
            .border(1.25.dp, Palette.black.copy(alpha = if (dim) 0.5f * on else 0f), shape)
            .clickable(enabled = !dim, onClick = onClick)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        BasicText(text, Modifier.weight(1f), style = LocalType.current.label.copy(color = fg), maxLines = 1)
        if (cell.tag != null) BasicText(cell.tag, style = LocalType.current.overline.copy(color = fg, letterSpacing = 0.6.sp), maxLines = 1)
    }
}

/** A row that does something, with an optional value on the right. */
@Composable
fun ActionSetting(label: String, onClick: () -> Unit, value: String? = null, hint: String? = null) {
    SettingRowBase(hint = hint, onKey = { false }, onClick = onClick) { focused ->
        RowLayout(label, focused) {
            if (value != null) BasicText(value, style = LocalType.current.label.copy(color = onFocusColor(focused, Palette.textSecondary)))
        }
    }
}

/** A read-only line: label and value, not focusable. */
@Composable
fun InfoLine(label: String, value: String) {
    Column {
        Row(Modifier.fillMaxWidth().height(36.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            BasicText(label, Modifier.weight(1f), style = LocalType.current.body)
            Spacer(Modifier.width(12.dp))
            BasicText(value, style = LocalType.current.bodyStrong, maxLines = 1)
        }
        Divider()
    }
}

/** A small heading that starts a group of rows. */
@Composable
fun SettingsGroup(text: String) {
    val state = LocalSettingsFocus.current
    val id = remember { (state?.next ?: 0).also { state?.next = it + 1 } }
    BasicText(text, Modifier.reveal(id, distance = 22.dp).padding(start = 16.dp, top = 18.dp, bottom = 4.dp), style = LocalType.current.caption.copy(color = Palette.textTertiary))
}
