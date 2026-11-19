import SwiftUI

// Kumori's tvOS design tokens.
//
// Every number here comes from Apple's tvOS Human Interface Guidelines (layout, typography,
// focus) or from the project's research notes in kumori/research/03-design-tokens.md. New
// screens take their sizes, type, colours and motion from this file and nowhere else, so the
// whole app lines up on one grid. See tvos/DESIGN-SYSTEM.md for how to use them.

/// Metrics on the 1920 × 1080 pt reference stage.
enum TVTokens {
    // MARK: Stage and safe region

    static let stage = CGSize(width: 1920, height: 1080)
    /// Apple's overscan-safe insets. Controls and text stay inside; artwork and video may bleed.
    static let safeX: CGFloat = 80
    static let safeY: CGFloat = 60

    // MARK: Grid

    /// Horizontal space between tiles in a shelf or grid.
    static let gutter: CGFloat = 40
    /// Apple's minimum distance from one row of artwork to the next. A lockup's caption sits
    /// inside it, so the spacing *between lockups* is `gridRowGap - captionAllowance`.
    static let gridRowGap: CGFloat = 100
    static let captionAllowance: CGFloat = 40

    // MARK: Spacing

    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let group: CGFloat = 24
    /// Space between two sections on a page (shelf to shelf).
    static let section: CGFloat = 56
    /// Room left above and below a shelf so a focused, lifted tile is never clipped.
    static let focusClearance: CGFloat = 32
    /// How far a focused artwork grows past its bottom edge, as a share of its height. The
    /// caption moves down by this much so the lifted art never covers it.
    static let focusLift: CGFloat = 0.06

    // MARK: Shapes

    static let artRadius: CGFloat = 16
    static let panelRadius: CGFloat = 24

    // MARK: Components

    static let rowHeight: CGFloat = 76
    static let rowInsetX: CGFloat = 24
    static let rowInsetY: CGFloat = 12
    static let heroHeight: CGFloat = 480
    static let heroTextWidth: CGFloat = 880
    static let menuWidth: CGFloat = 720
    static let menuInset: CGFloat = 32
    static let dialogWidth: CGFloat = 860

    // MARK: Aspect ratios (width / height)

    static let landscape: CGFloat = 16.0 / 9.0
    static let poster: CGFloat = 2.0 / 3.0
    static let square: CGFloat = 1

    /// The width of one tile when `columns` tiles and their gutters fill `available` points.
    /// 1760 pt (the full safe width) gives 410 for four columns and 260 for six, Apple's
    /// published sizes.
    static func tileWidth(available: CGFloat, columns: Int) -> CGFloat {
        precondition(columns > 0)
        let gaps = CGFloat(columns - 1) * gutter
        return max(0, ((available - gaps) / CGFloat(columns)).rounded(.down))
    }

    /// How many tiles of a kind fit across at a text size. Bigger text needs taller captions
    /// and fewer, wider tiles so titles stay readable.
    static func columns(_ kind: TVLockupShape, at size: DynamicTypeSize) -> Int {
        switch (kind, size) {
        case (.landscape, ...DynamicTypeSize.large): return 4
        case (.landscape, ...DynamicTypeSize.xxxLarge): return 3
        case (.landscape, _): return 2
        case (.poster, ...DynamicTypeSize.large): return 6
        case (.poster, ...DynamicTypeSize.xxxLarge): return 5
        case (.poster, ...DynamicTypeSize.accessibility2): return 4
        case (.poster, _): return 3
        case (.square, ...DynamicTypeSize.large): return 5
        case (.square, ...DynamicTypeSize.xxxLarge): return 4
        case (.square, _): return 3
        }
    }
}

/// The shapes a piece of game artwork can take.
enum TVLockupShape: Hashable {
    case landscape, poster, square

    var aspect: CGFloat {
        switch self {
        case .landscape: return TVTokens.landscape
        case .poster: return TVTokens.poster
        case .square: return TVTokens.square
        }
    }
}

/// The width a page has to lay out in, measured once by `TVPage` and handed down so every
/// shelf and grid on the page shares the same left and right edge.
struct TVLayout: Equatable {
    /// The full width of the page, edge to edge.
    var width: CGFloat

    /// The width inside the safe insets: 1760 on a full-screen page.
    var contentWidth: CGFloat { max(0, width - 2 * TVTokens.safeX) }

    func tileWidth(_ shape: TVLockupShape, at size: DynamicTypeSize) -> CGFloat {
        TVTokens.tileWidth(available: contentWidth, columns: TVTokens.columns(shape, at: size))
    }

    static let reference = TVLayout(width: TVTokens.stage.width)
}

private struct TVLayoutKey: EnvironmentKey {
    static let defaultValue = TVLayout.reference
}

extension EnvironmentValues {
    var tvLayout: TVLayout {
        get { self[TVLayoutKey.self] }
        set { self[TVLayoutKey.self] = newValue }
    }
}

// MARK: Typography

/// Apple's tvOS text styles. They are the system font (SF), and they grow with Settings →
/// Accessibility → Display → Text Size on tvOS 27. Never set a fixed point size on text.
///
/// | Style   | Default size | Use                                      |
/// |---------|-------------:|------------------------------------------|
/// | hero    | 76 | A short game title over hero art, two lines at most |
/// | title   | 57 | Detail screen title                              |
/// | section | 48 | Dialog titles and page headings                  |
/// | shelf   | 38 | Shelf and group headings                         |
/// | body    | 29 | Actions, instructions, descriptions              |
/// | caption | 25 | Lockup titles                                    |
/// | detail  | 23 | Supporting metadata only (store, genre)          |
enum TVType {
    static let hero = Font.title.weight(.bold)
    static let title = Font.title2.weight(.bold)
    static let section = Font.title3.weight(.semibold)
    static let shelf = Font.headline
    static let body = Font.body
    static let callout = Font.callout
    static let caption = Font.caption
    static let detail = Font.caption2
}

// MARK: Colour

/// Neutral chrome. The game artwork brings the colour; Kumori pink marks the few things that
/// need to stand out (a running session, a live indicator). Every pair of text and background
/// below clears WCAG AA (4.5:1) on the canvas and on the opaque panel.
enum TVColor {
    /// The page background: #080808.
    static let canvas = Color(white: 8.0 / 255)
    /// Opaque panels and the Reduce Transparency fallback: #202020.
    static let panel = Color(white: 32.0 / 255)
    /// A lighter panel for missing artwork, so it reads as a tile and not a hole: #2A2A2E.
    static let placeholder = Color(red: 42.0 / 255, green: 42.0 / 255, blue: 46.0 / 255)
    /// Primary text: white. 20:1 on canvas.
    static let primary = Color.white
    /// Secondary text: #C5C5C5. 11.6:1 on canvas, 9.4:1 on panel.
    static let secondary = Color(white: 197.0 / 255)
    /// Tertiary text: #9A9A9A. 7.1:1 on canvas, 5.8:1 on panel. Never lower than this.
    static let tertiary = Color(white: 154.0 / 255)
    /// Kumori pink #F27BA6, for state markers. 7.8:1 on canvas.
    static let accent = Color(red: 0xF2 / 255, green: 0x7B / 255, blue: 0xA6 / 255)
    /// Thin separators.
    static let hairline = Color.white.opacity(0.12)

    /// The scrim behind text that sits on artwork: dark on the text side, nearly clear on the
    /// art side.
    static let scrimNear = 0.78
    static let scrimFar = 0.10
}
