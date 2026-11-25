package app.kumori.tv.ui.motion

import android.os.SystemClock
import androidx.compose.animation.togetherWith
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.scaleOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.fadeIn
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.Spring
import androidx.compose.ui.unit.IntOffset
import kotlin.math.PI
import kotlin.math.pow

/**
 * How the app moves.
 *
 * Two kinds of motion, kept apart:
 *  - Things the user drives directly (focus, presses, the highlight following the cursor) run
 *    on springs, so they can change course mid-flight without a hitch.
 *  - Changes of place (another tab, another settings page, into a game and back) are timed.
 *    The old view leaves quickly and gets out of the way; the new one arrives a little
 *    slower on a long ease-out, and its parts follow one after another.
 *
 * Where something comes from says where you went: tabs move sideways like the bar above
 * them, settings pages move up and down like the list beside them, and opening a game moves
 * in depth, with back undoing it.
 */
object Motion {
    /** Converts an iOS-style response (seconds) to a Compose spring stiffness. */
    fun stiffness(response: Float) = (2 * PI / response).pow(2).toFloat()

    fun <T> springOf(response: Float, damping: Float, visibility: T? = null): SpringSpec<T> =
        androidx.compose.animation.core.spring(dampingRatio = damping, stiffness = stiffness(response), visibilityThreshold = visibility)

    /** Focus lift on tiles and buttons: quick with a hint of bounce. */
    fun <T> focus(): SpringSpec<T> = springOf(response = 0.32f, damping = 0.72f)

    /** A row or button lifting under focus: a little overshoot, then settled (tvOS lift). */
    fun <T> lift(): SpringSpec<T> = springOf(response = 0.44f, damping = 0.68f)

    /** Press feedback: fast and firm. */
    fun <T> press(): SpringSpec<T> = springOf(response = 0.18f, damping = 0.9f)

    /** Screens and large panels: a calm glide that lands without bounce. */
    fun <T> page(): SpringSpec<T> = springOf(response = 0.5f, damping = 0.92f)

    /** A marker that follows the selection (tab pill, page pill, list highlight): direct, no bounce. */
    fun <T> glide(): SpringSpec<T> = springOf(response = 0.4f, damping = 0.9f)

    /** Scrolling a rail or list to keep the focused item in place. */
    val scroll: SpringSpec<Float> = springOf(response = 0.42f, damping = 0.95f)

    /** Colours and glow: soft, never overshoots. */
    fun <T> fade(): SpringSpec<T> = springOf(response = 0.36f, damping = 1f)

    val pageOffset: SpringSpec<IntOffset> = springOf(response = 0.5f, damping = 0.92f, visibility = IntOffset(1, 1))

    val gentle: AnimationSpec<Float> = androidx.compose.animation.core.spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = stiffness(0.6f))

    // ---------- Changes of place ----------

    /** Arriving: most of the distance early, then a long, soft landing. */
    val arrive = CubicBezierEasing(0.16f, 1f, 0.3f, 1f)

    /** Leaving: picks up speed and is gone. */
    val leave = CubicBezierEasing(0.4f, 0f, 1f, 1f)

    /** The old view is out in this long. */
    const val OUT_MS = 150

    /** The new view starts once the old one is mostly gone, so the two never fight. */
    const val GAP_MS = 90

    /** The new view's own travel. */
    const val IN_MS = 440

    /** Between one part of a page and the next. */
    const val STAGGER_MS = 42L

    /** Parts beyond this many arrive together with the last, so long pages don't drag. */
    const val STAGGER_STEPS = 7

    private fun <T> inSpec() = tween<T>(IN_MS, GAP_MS, arrive)
    private fun <T> outSpec() = tween<T>(OUT_MS, 0, leave)

    /**
     * Between tabs. The page slides a short way along the bar's direction; [dir] is 1 going
     * right, -1 going left. The page's own parts add the rest of the movement (see [reveal]).
     */
    fun tabs(dir: Int): ContentTransform =
        (fadeIn(tween(260, GAP_MS, arrive)) + slideInHorizontally(inSpec()) { it / 28 * dir })
            .togetherWith(fadeOut(outSpec()) + slideOutHorizontally(outSpec()) { -it / 40 * dir })

    /** Between settings pages, up or down like the list of pages; [dir] is 1 going down. */
    fun pages(dir: Int): ContentTransform =
        (fadeIn(tween(240, GAP_MS, arrive)) + slideInVertically(inSpec()) { it / 22 * dir })
            .togetherWith(fadeOut(outSpec()) + slideOutVertically(outSpec()) { -it / 32 * dir })

    /** Going into something: it comes forward from slightly behind. */
    val open: EnterTransition = fadeIn(tween(280, 40, arrive)) + scaleIn(tween(IN_MS, 40, arrive), initialScale = 0.955f)

    /** Going back out of it: it falls away the way it came, quicker than it arrived. */
    val close: ExitTransition = fadeOut(tween(190, 0, leave)) + scaleOut(tween(220, 0, leave), targetScale = 0.965f)
}

/**
 * When the current page appeared and which way it came from, so its parts can follow from
 * the same side. [dx] is -1 (from the left) or 1 (from the right), [dy] is -1 (from above)
 * or 1 (from below); both 0 means it simply rises into place. [step] is the wait between
 * parts, 0 when pages are being flicked through and a stagger would only get in the way.
 */
class RevealEpoch(val startedAt: Long, val dx: Int = 0, val dy: Int = 0, val step: Long = Motion.STAGGER_MS)

val LocalReveal = compositionLocalOf { RevealEpoch(0L) }

private val lastPageAt = HashMap<String, Long>()

/**
 * Starts a new staggered entrance for everything inside that uses [reveal]. Pages that
 * replace each other share a [group], so flicking through them can be told from arriving.
 */
@Composable
fun RevealPage(key: Any?, dx: Int = 0, dy: Int = 0, group: String = "", content: @Composable () -> Unit) {
    val epoch = remember(key) {
        val now = SystemClock.uptimeMillis()
        // A second page within a moment of the last means someone is passing through.
        val passing = now - (lastPageAt[group] ?: 0L) < 320
        lastPageAt[group] = now
        RevealEpoch(now, dx, dy, if (passing) 0L else Motion.STAGGER_MS)
    }
    CompositionLocalProvider(LocalReveal provides epoch, content = content)
}

/**
 * Staggered entrance: the element waits its turn, then fades up while it travels the last
 * few points into place from the side the page came from. No scaling and no bounce, so text
 * stays crisp and a full page settles as one piece. Elements composed well after the page
 * appeared (scrolled into view later) show immediately.
 */
fun Modifier.reveal(index: Int, distance: Dp = 28.dp, soft: Boolean = false): Modifier = composed {
    revealAt(LocalReveal.current.step * index.coerceAtMost(Motion.STAGGER_STEPS), distance, soft)
}

/** [reveal] with an exact delay, for grids where rows and columns stagger differently. */
fun Modifier.revealAt(delayMs: Long, distance: Dp = 28.dp, soft: Boolean = false): Modifier = composed {
    val epoch = LocalReveal.current
    val late = remember { SystemClock.uptimeMillis() - epoch.startedAt > 700 }
    val p = remember { Animatable(if (late) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (!late) {
            // Wait for the old page to clear before the first part moves.
            delay(Motion.GAP_MS + delayMs.coerceIn(0L, Motion.STAGGER_MS * Motion.STAGGER_STEPS))
            p.animateTo(1f, tween(Motion.IN_MS, easing = Motion.arrive))
        }
    }
    val px = with(LocalDensity.current) { distance.toPx() } * 0.6f
    graphicsLayer {
        val v = p.value
        val rest = 1f - v
        // Opacity leads the motion so nothing is seen sliding while still transparent.
        alpha = (v * 2.2f).coerceIn(0f, 1f)
        translationX = epoch.dx * rest * px
        translationY = if (epoch.dx == 0 && epoch.dy == 0) rest * px else epoch.dy * rest * px
        // "Soft" parts (logos, pictures) also settle from slightly larger. This used to be a
        // blur, which costs a full-screen render pass per frame on TV GPUs.
        if (soft) {
            val s = 1f + 0.03f * rest
            scaleX = s
            scaleY = s
        }
    }
}
