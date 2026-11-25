package app.kumori.tv.ui.components

import android.graphics.Bitmap
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import android.os.SystemClock
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.sin
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import coil.compose.AsyncImage
import coil.request.ImageRequest
import coil.size.Size
import coil.transform.Transformation
import app.kumori.tv.ui.motion.Motion
import app.kumori.tv.ui.theme.Palette

/**
 * The living background, as on the Apple TV: the focused game's art blurred into soft glass,
 * darkened so text stays readable and drifting very slowly, with the sharp art dissolving in
 * from the top right. A new game's art blooms in over the old one. [glow] swaps the art for
 * Settings' background: true black with a few soft white lights wandering behind the glass.
 */
@Composable
fun Backdrop(url: String?, modifier: Modifier = Modifier, sharpArt: Boolean = true, glow: Boolean = false, moving: Boolean = true) {
    val artAlpha by animateFloatAsState(if (glow) 0f else 1f, tween(if (glow) 700 else 500, easing = Motion.arrive), label = "art")
    // One slow breath for the whole background, read only while drawing, so it never recomposes.
    val drift = if (moving) {
        rememberInfiniteTransition(label = "drift").animateFloat(
            0f, 1f, infiniteRepeatable(tween(28_000, easing = LinearEasing), RepeatMode.Reverse), label = "drift",
        )
    } else null
    Box(modifier.fillMaxSize().background(Palette.base)) {
        if (artAlpha > 0f) {
            Box(Modifier.fillMaxSize().graphicsLayer { alpha = artAlpha }) {
                AnimatedContent(
                    targetState = url,
                    // The new art covers the old before the old goes, so the screen never dims between.
                    transitionSpec = { fadeIn(tween(1100, easing = Motion.arrive)) togetherWith fadeOut(tween(300, 1000)) },
                    label = "backdrop",
                ) { u ->
                    Box(Modifier.fillMaxSize()) {
                        if (u != null) {
                            AsyncImage(
                                model = ImageRequest.Builder(LocalContext.current)
                                    .data(u)
                                    .size(Size(384, 216))
                                    .transformations(BlurTransformation(radius = 10, passes = 3))
                                    .memoryCacheKey("blur:$u")
                                    .build(),
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize().graphicsLayer {
                                    val d = drift?.value ?: 0f
                                    // Slow push in and a sideways wander: never still, never noticeable.
                                    val s = 1.08f + 0.06f * d
                                    scaleX = s
                                    scaleY = s
                                    translationX = (d - 0.5f) * size.width * 0.03f
                                    translationY = (0.5f - d) * size.height * 0.02f
                                    alpha = 0.6f
                                },
                            )
                            if (sharpArt) {
                                AsyncImage(
                                    model = ImageRequest.Builder(LocalContext.current).data(u).size(Size(1280, 720)).build(),
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    alignment = Alignment.TopEnd,
                                    modifier = Modifier
                                        .fillMaxWidth(0.72f)
                                        .fillMaxHeight(0.82f)
                                        .align(Alignment.TopEnd)
                                        .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                                        .drawWithContent {
                                            drawContent()
                                            // Fade the art out towards the left and the bottom.
                                            drawRect(
                                                Brush.horizontalGradient(0f to Color.Transparent, 0.45f to Color.Black.copy(alpha = 0.85f), 1f to Color.Black),
                                                blendMode = BlendMode.DstIn,
                                            )
                                            drawRect(
                                                Brush.verticalGradient(0f to Color.Black, 0.55f to Color.Black.copy(alpha = 0.8f), 1f to Color.Transparent),
                                                blendMode = BlendMode.DstIn,
                                            )
                                        },
                                )
                            }
                        }
                    }
                }
                // The veil: text on the left and shelves at the bottom stay readable on any art.
                Box(
                    Modifier.fillMaxSize().drawBehind {
                        drawRect(Brush.horizontalGradient(0f to Color.Black.copy(alpha = 0.74f), 0.5f to Color.Black.copy(alpha = 0.32f), 1f to Color.Black.copy(alpha = 0.06f)))
                        drawRect(Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.3f), 0.45f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.86f)))
                        // A soft vignette, so the edges sit back and the middle glows.
                        drawRect(Brush.radialGradient(0.45f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.45f), center = center, radius = size.maxDimension * 0.75f))
                    },
                )
            }
        }
        GlowLights(visible = glow && moving)
    }
}

/**
 * A few soft white lights on black, small against the screen, wandering on slow Lissajous
 * paths so the drift never visibly repeats. They spread out over a second and a half when
 * they appear. Drawn at 30 frames a second, and not at all when hidden.
 */
@Composable
fun GlowLights(visible: Boolean, modifier: Modifier = Modifier) {
    val bloom by animateFloatAsState(if (visible) 1f else 0f, tween(if (visible) 1600 else 500, easing = Motion.arrive), label = "bloom")
    if (bloom <= 0f) return
    var t by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(visible) {
        if (!visible) return@LaunchedEffect
        val start = SystemClock.uptimeMillis() - (t * 1000).toLong()
        while (true) {
            t = (SystemClock.uptimeMillis() - start) / 1000f
            delay(33)
        }
    }
    Canvas(modifier.fillMaxSize()) {
        for (g in Lights) {
            val a = t / g.period * 2f * PI.toFloat() + g.phase
            val cx = (g.x + g.wx * sin(a)) * size.width
            val cy = (g.y + g.wy * sin(a * 1.37f + 0.8f)) * size.height
            val r = g.radius * size.width * (0.72f + 0.28f * bloom) * (1f + 0.05f * sin(a * 0.73f))
            val c = Offset(cx, cy)
            drawCircle(
                Brush.radialGradient(
                    0f to Color.White.copy(alpha = g.alpha * bloom),
                    0.4f to Color.White.copy(alpha = g.alpha * 0.4f * bloom),
                    0.75f to Color.White.copy(alpha = g.alpha * 0.1f * bloom),
                    1f to Color.Transparent,
                    center = c,
                    radius = r,
                ),
                radius = r,
                center = c,
            )
        }
    }
}

private class Light(val alpha: Float, val x: Float, val y: Float, val radius: Float, val wx: Float, val wy: Float, val period: Float, val phase: Float)

private val Lights = listOf(
    Light(0.13f, 0.16f, 0.80f, 0.24f, 0.12f, 0.08f, 47f, 0f),
    Light(0.10f, 0.86f, 0.18f, 0.20f, 0.08f, 0.10f, 59f, 1.7f),
    Light(0.08f, 0.58f, 0.94f, 0.22f, 0.14f, 0.05f, 71f, 3.1f),
    Light(0.06f, 0.42f, 0.06f, 0.16f, 0.10f, 0.05f, 83f, 4.4f),
)

/**
 * Cheap, good-looking blur: the image is already tiny (384 × 216), so a few box-blur passes
 * approximate a Gaussian in a couple of milliseconds even on a modest TV CPU.
 */
class BlurTransformation(private val radius: Int, private val passes: Int) : Transformation {
    override val cacheKey: String = "blur-$radius-$passes"

    override suspend fun transform(input: Bitmap, size: Size): Bitmap {
        val w = input.width
        val h = input.height
        val src = input.copy(Bitmap.Config.ARGB_8888, true)
        val px = IntArray(w * h)
        src.getPixels(px, 0, w, 0, 0, w, h)
        val tmp = IntArray(w * h)
        repeat(passes) {
            boxBlur(px, tmp, w, h, radius, horizontal = true)
            boxBlur(tmp, px, w, h, radius, horizontal = false)
        }
        src.setPixels(px, 0, w, 0, 0, w, h)
        return src
    }

    private fun boxBlur(inp: IntArray, out: IntArray, w: Int, h: Int, r: Int, horizontal: Boolean) {
        val lines = if (horizontal) h else w
        val len = if (horizontal) w else h
        val div = r * 2 + 1
        for (line in 0 until lines) {
            fun idx(i: Int): Int {
                val c = i.coerceIn(0, len - 1)
                return if (horizontal) line * w + c else c * w + line
            }
            var a = 0; var rr = 0; var g = 0; var b = 0
            for (i in -r..r) {
                val p = inp[idx(i)]
                a += p ushr 24; rr += (p shr 16) and 0xFF; g += (p shr 8) and 0xFF; b += p and 0xFF
            }
            for (i in 0 until len) {
                out[idx(i)] = ((a / div) shl 24) or ((rr / div) shl 16) or ((g / div) shl 8) or (b / div)
                val add = inp[idx(i + r + 1)]
                val sub = inp[idx(i - r)]
                a += (add ushr 24) - (sub ushr 24)
                rr += ((add shr 16) and 0xFF) - ((sub shr 16) and 0xFF)
                g += ((add shr 8) and 0xFF) - ((sub shr 8) and 0xFF)
                b += (add and 0xFF) - (sub and 0xFF)
            }
        }
    }
}
