package app.kumori.tv.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import app.kumori.tv.R

/**
 * Kumori's colours, the same as the Apple TV app: true black, neutral graphite glass and white.
 * Game artwork brings the colour. Focus is a white platter with dark ink on it. Kumori pink is
 * kept for the few things that are live (a running session, a stream that is playing).
 */
object Palette {
    /** Ink on the focused (white) platter. */
    val black = Color(0xFF121212)
    /** The page: #080808. */
    val base = Color(0xFF080808)
    /** Opaque panels: #202020. */
    val raised = Color(0xFF202020)
    /** The focused platter. */
    val white = Color(0xFFF7F7F7)
    /** The platter's lower edge, for its top-lit gradient. */
    val whiteLow = Color(0xFFE3E3E3)
    val accent = Color(0xFFF27BA6)
    val text = Color(0xFFFFFFFF)
    /** #C5C5C5: 11.6:1 on the page. */
    val textSecondary = Color(0xFFC5C5C5)
    val textTertiary = Color(0xFF8E8E93)
    /** A control at rest: neutral graphite, opaque enough that warm art behind doesn't tint it. */
    val glass = Color(0x8A333333)
    val glassStrong = Color(0xB8383838)
    /** The current choice when focus is elsewhere. */
    val glassHeavy = Color(0xE66B6B6B)
    /** The glass panel's own graphite. */
    val pane = Color(0xC4131313)
    val hairline = Color(0x14FFFFFF)
    val hairlineStrong = Color(0x29FFFFFF)
    val scrim = Color(0xCC000000)
    val good = Color(0xFF7DDE9B)
    val warn = Color(0xFFFFCF70)
    /** Ending something, on dark: #FF6B61. */
    val danger = Color(0xFFFF6B61)
    /** Ending something, on the white platter: #C4161C. */
    val dangerInk = Color(0xFFC4161C)
}

private val inter = FontFamily(
    Font(R.font.inter_regular, FontWeight.Normal),
    Font(R.font.inter_medium, FontWeight.Medium),
    Font(R.font.inter_semibold, FontWeight.SemiBold),
    Font(R.font.inter_bold, FontWeight.Bold),
)

private val interDisplay = FontFamily(
    Font(R.font.interdisplay_semibold, FontWeight.SemiBold),
    Font(R.font.interdisplay_bold, FontWeight.Bold),
)

/** Sizes are for the 960 × 540 dp layout space the whole app is drawn in (see MainActivity). */
class Type(
    val display: TextStyle,
    val title: TextStyle,
    val headline: TextStyle,
    val body: TextStyle,
    val bodyStrong: TextStyle,
    val label: TextStyle,
    val caption: TextStyle,
    val overline: TextStyle,
)

val KumoriType = Type(
    display = TextStyle(fontFamily = interDisplay, fontWeight = FontWeight.Bold, fontSize = 34.sp, lineHeight = 38.sp, letterSpacing = (-0.6).sp, color = Palette.text),
    title = TextStyle(fontFamily = interDisplay, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 27.sp, letterSpacing = (-0.3).sp, color = Palette.text),
    headline = TextStyle(fontFamily = inter, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, lineHeight = 18.sp, letterSpacing = (-0.1).sp, color = Palette.text),
    body = TextStyle(fontFamily = inter, fontWeight = FontWeight.Normal, fontSize = 11.5.sp, lineHeight = 16.5.sp, color = Palette.textSecondary),
    bodyStrong = TextStyle(fontFamily = inter, fontWeight = FontWeight.Medium, fontSize = 11.5.sp, lineHeight = 16.5.sp, color = Palette.text),
    label = TextStyle(fontFamily = inter, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, lineHeight = 14.sp, color = Palette.text),
    caption = TextStyle(fontFamily = inter, fontWeight = FontWeight.Medium, fontSize = 9.5.sp, lineHeight = 13.sp, color = Palette.textSecondary),
    overline = TextStyle(fontFamily = inter, fontWeight = FontWeight.SemiBold, fontSize = 8.5.sp, lineHeight = 11.sp, letterSpacing = 1.2.sp, color = Palette.textTertiary),
)

val LocalType = staticCompositionLocalOf { KumoriType }

@Composable
fun KumoriTheme(content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalType provides KumoriType, content = content)
}
