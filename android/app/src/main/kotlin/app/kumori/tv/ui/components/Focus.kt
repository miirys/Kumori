package app.kumori.tv.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.BringIntoViewSpec
import androidx.compose.foundation.gestures.LocalBringIntoViewSpec
import androidx.compose.foundation.hoverable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.composed
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.foundation.Image
import androidx.compose.ui.unit.dp
import app.kumori.tv.ui.motion.Motion
import app.kumori.tv.ui.theme.LocalType
import app.kumori.tv.ui.theme.Palette

/**
 * The one focusable building block. Focus lifts the element onto a white platter on a spring
 * with a little give, the way the Apple TV lifts its buttons; a press sinks it; a hovering
 * mouse moves focus to it, so remote, controller and mouse all drive the same highlight.
 * There is no outline at rest or in focus: the fill and the lift say everything.
 */
@Composable
fun Pressable(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(12.dp),
    focusedScale: Float = 1.05f,
    color: Color = Palette.glass,
    focusedColor: Color = Palette.white,
    @Suppress("UNUSED_PARAMETER") border: Boolean = false,
    focusRequester: FocusRequester? = null,
    content: @Composable BoxScope.(focused: Boolean) -> Unit,
) {
    val source = remember { MutableInteractionSource() }
    val focused by source.collectIsFocusedAsState()
    val pressed by source.collectIsPressedAsState()
    val hovered by source.collectIsHoveredAsState()
    val requester = focusRequester ?: remember { FocusRequester() }
    LaunchedEffect(hovered) {
        if (hovered && !focused) runCatching { requester.requestFocus() }
    }
    val scale by animateFloatAsState(
        targetValue = when {
            pressed -> focusedScale - 0.035f
            focused -> focusedScale
            else -> 1f
        },
        animationSpec = if (pressed) Motion.press() else Motion.lift(),
        label = "scale",
    )
    // 0 at rest, 1 lifted. Drives the platter and its shadow from one value, so they move as one.
    val lift by animateFloatAsState(if (focused) 1f else 0f, Motion.fade(), label = "lift")
    val platter = focusedColor == Palette.white
    Box(
        modifier = modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                this.shape = shape
                shadowElevation = lift * 18.dp.toPx()
                ambientShadowColor = Color.Black
                spotShadowColor = Color.Black
            }
            .drawBehind {
                val outline = shape.createOutline(size, layoutDirection, this)
                if (lift < 1f && color.alpha > 0f) drawOutline(outline, color, alpha = 1f - lift)
                if (lift > 0f) {
                    if (platter) {
                        drawOutline(outline, Brush.verticalGradient(listOf(Palette.white, Palette.whiteLow)), alpha = lift)
                    } else {
                        drawOutline(outline, focusedColor, alpha = lift)
                    }
                }
            }
            .focusRequester(requester)
            .hoverable(source)
            .clickable(interactionSource = source, indication = null, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        content(focused)
    }
}

/**
 * A soft band of light that crosses artwork once when it gains focus, as light catches a card
 * the Apple TV lifts. Drawn over the content, so it costs nothing when idle.
 */
fun Modifier.glint(focused: Boolean, strength: Float = 0.22f): Modifier = composed {
    val sweep = remember { Animatable(-1f) }
    LaunchedEffect(focused) {
        if (focused) {
            sweep.snapTo(0f)
            sweep.animateTo(1f, tween(900, 120, Motion.arrive))
        } else {
            sweep.snapTo(-1f)
        }
    }
    drawWithContent {
        drawContent()
        val p = sweep.value
        if (p <= 0f || p >= 1f) return@drawWithContent
        val w = size.width
        val band = w * 0.55f
        val x = -band + (w + band * 2) * p
        val fade = if (p < 0.8f) 1f else (1f - p) / 0.2f
        drawRect(
            Brush.linearGradient(
                0f to Color.Transparent,
                0.5f to Color.White.copy(alpha = strength * fade),
                1f to Color.Transparent,
                start = Offset(x, 0f),
                end = Offset(x + band, size.height),
            ),
        )
    }
}

/** Foreground colour for content sitting on a [Pressable]: black on the white focus fill. */
@Composable
fun onFocusColor(focused: Boolean, idle: Color = Palette.text): Color {
    val c by animateColorAsState(if (focused) Palette.black else idle, Motion.fade(), label = "fg")
    return c
}

@Composable
fun GlassButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    primary: Boolean = false,
    focusRequester: FocusRequester? = null,
) {
    Pressable(
        onClick = onClick,
        modifier = modifier,
        shape = RoundedCornerShape(50),
        focusedScale = 1.07f,
        color = if (primary) Palette.glassHeavy else Palette.glass,
        focusRequester = focusRequester,
    ) { focused ->
        val fg = onFocusColor(focused)
        Row(Modifier.padding(horizontal = 18.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
            if (icon != null) {
                Image(icon, null, Modifier.size(13.dp), colorFilter = ColorFilter.tint(fg))
                Spacer(Modifier.width(7.dp))
            }
            BasicText(text, style = LocalType.current.label.copy(color = fg))
        }
    }
}

/**
 * Graphite glass, as the Apple TV app draws its panels: a dark tint over whatever is behind,
 * with light catching the top third. Never a drawn edge.
 */
fun Modifier.glass(shape: Shape = RoundedCornerShape(16.dp), strong: Boolean = false) =
    drawBehind {
        val outline = shape.createOutline(size, layoutDirection, this)
        drawOutline(outline, if (strong) Palette.pane else Palette.glassStrong)
        drawOutline(
            outline,
            Brush.verticalGradient(0f to Color.White.copy(alpha = 0.07f), 0.34f to Color.Transparent, endY = size.height),
        )
    }

/**
 * Keeps the focused item at a fixed place in a scrolling list (a "pivot"), and glides there
 * on a spring instead of jumping, which is what makes long lists feel calm on a TV.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PivotScroll(leadingFraction: Float, content: @Composable () -> Unit) {
    val spec = remember(leadingFraction) {
        object : BringIntoViewSpec {
            @Suppress("OVERRIDE_DEPRECATION")
            override val scrollAnimationSpec: AnimationSpec<Float> = Motion.scroll

            override fun calculateScrollDistance(offset: Float, size: Float, containerSize: Float): Float {
                val target = containerSize * leadingFraction
                return if (size > containerSize - target) offset - (containerSize - size) / 2f else offset - target
            }
        }
    }
    CompositionLocalProvider(LocalBringIntoViewSpec provides spec, content = content)
}
