# Kumori tvOS design system

This is the guide for anyone (person or agent) building a Kumori Apple TV screen. It covers the
tokens and components in `Kumori/UI/Design`, the debug fixture harness in `Kumori/Fixtures`, and
how to test a screen on the tvOS Simulator without an Apple TV. The reasoning and sources behind
each rule are in the project research (`kumori/research/01-tvos-design-guide.md` and
`03-design-tokens.md`).

## The rules

1. **Let tvOS do focus.** Use native buttons. Artwork goes inside a `.borderless` button with
   `.hoverEffect(.highlight)` on the image (that is what `TVLockup` does). The system lifts,
   lights and tilts it. Never add your own scale, shadow, ring, glow or sheen on focus.
2. **One safe edge.** `TVPage` owns the horizontal safe area. Inside it, every shelf, grid and
   heading insets by exactly `TVTokens.safeX` (80 pt). Never add the safe inset twice. Artwork
   and video may bleed to the screen edge; text and buttons never do. A full-screen view that is *not*
   inside `TVPage` (detail, stream screens) already gets the system's 80 pt safe area: give it
   no `TVTokens.safeX` of its own, or its text lands at 160 pt.
3. **One grid.** Tile widths come from `TVLayout.tileWidth`, never a literal. On the full
   1760 pt safe width that is 4 × 410 landscape or 6 × 260 posters with 40 pt gutters.
   Bigger text gives fewer, wider tiles (`TVTokens.columns`).
4. **System type.** Use `TVType` (SF text styles). No fixed point sizes, no rounded design.
   Text must grow with tvOS 27 Large Text and still fit (test at `-typeSize ax3`).
5. **Neutral chrome, art brings colour.** `TVColor.canvas` (#080808) behind everything, white
   and grey text. Text over artwork always has `TVScrim` behind it. All text colours pass
   4.5:1 (unit-tested).
6. **No badges, chips or dots on artwork.** State is said in words where Apple says it: the
   primary button ("Resume" instead of "Play") and a quiet second caption line ("Still
   running"), like the Apple TV app's "Resume" and "12 min left". Never a pill, a coloured dot
   or a glow on the picture.
7. **Quiet motion.** Native focus motion only. Custom motion is limited to panels arriving
   (`TVMotion.panel`, 0.24 s, no bounce) and artwork cross-fading after focus rests 150 ms.
   No Ken Burns, no stagger, no blur-in, no breathing. Read `tvReduceMotion` and drop
   everything except a ≤0.1 s fade when it is on.
8. **Glass only where it means something.** `tvSurface(.overlay)` for dialogs and drawers
   (Liquid Glass on tvOS 26+, frosted before, opaque with Reduce Transparency).
   `tvSurface(.grouped)` for a quiet block on the page. Never glass behind every label.
9. **Stable identity.** Every focusable game is keyed by its game ID
   (`accessibilityIdentifier("lockup-<id>")`). Artwork arriving late never changes a frame.
   Back from a detail screen restores the tile that opened it (`BrowseMemory`).
10. **Ask before ending a game.** Every End/Quit goes through
   `.endSessionConfirmation(isPresented:title:onEnd:)`. Cancel has focus first; Back cancels.
11. **Truthful states.** Loading, empty and error are different (`TVStatusView`) and each has a
    way forward. Never replace content already on screen with a spinner.

## Components

| Component | File | Use |
|---|---|---|
| `TVTokens`, `TVLayout`, `TVType`, `TVColor` | `UI/Design/TVTokens.swift` | Every size, font and colour |
| `TVMotion`, `tvSurface`, `TVScrim`, `tvAppear`, `tvAccessibilityBridge` | `UI/Design/TVMotion.swift` | Motion, materials, Reduce Motion/Transparency |
| `TVArtwork`, `TVArtworkSource`, `TVBackdrop` | `UI/Design/TVArtwork.swift` | Artwork in a fixed frame; full-bleed backdrop with dwell and scrim |
| `GeneratedArt` | `UI/Design/GeneratedArt.swift` | Painted stand-in key art with a title treatment, for fixtures |
| `TVPage`, `TVLockup`, `TVShelf`, `TVGrid`, `TVSectionHeader`, `TVHeroBlock` | `UI/Design/TVLockups.swift` | Page layout, focusable game tiles, shelves, grids, hero |
| `TVStatusView` | `UI/Design/TVStatus.swift` | Loading / empty / error with actions |
| `BrowseMemory` | `UI/Design/BrowseMemory.swift` | Back restoration by stable ID, nearest-neighbour fallback |
| `EndSessionConfirmation` | `UI/EndSessionConfirmation.swift` | The one destructive confirmation |

A shelf of games:

```swift
TVPage {
    ScrollView {
        VStack(alignment: .leading, spacing: TVTokens.section) {
            TVShelf(title: "Recently played", items: games) { game, width in
                TVLockup(id: game.id, title: game.title, art: TVArtworkSource(game.banner), width: width) {
                    open(game)
                }
            }
        }
    }
    .scrollClipDisabled()
}
```

Put `.tvAccessibilityBridge()` once at the root of the real app when the first screen adopts
the system (the fixture root already does), so `tvReduceMotion` and `tvReduceTransparency`
follow the system settings.

## Fixtures: test a screen without an Apple TV

Debug builds launched with `-fixture <name>` show one synthetic screen built from the design
system and `CatalogueFixtures` (fictional games, generated art, no network, no account).
Release builds compile none of it; CI checks the Release binary for fixture symbols.

| Fixture | Shows |
|---|---|
| `gallery` | Type ramp, colour tokens, buttons, lockups (with and without art, running, poster) |
| `home`, `home-loading`, `home-error` | Home direction: hero, shelves, and its status states |
| `shelves`, `art-load` | Two shelves for traversal tests; a tile whose art arrives late |
| `library`, `library-empty` | Poster grid; empty library with actions |
| `restore` | Grid → detail → Back restores the tile |
| `detail`, `detail-long`, `detail-running` | Detail direction, long title, running game with End |
| `confirm-end` | End confirmation with counters (add `-openDialog` to open it) |
| `materials` | Bright artwork, scrim and overlay surface (try `-reduceTransparency 1`) |

Modifiers: `-focus <id>`, `-typeSize default|xl|xxl|xxxl|ax1…ax5`, `-reduceMotion 1`,
`-reduceTransparency 1`, `-safeFrame 1` (draws the 80/60 safe region in red).

Never put `.accessibilityIdentifier` on a stack or other container: SwiftUI gives every
element inside it the same identifier, so UI tests can no longer find the buttons by name.
Put identifiers on the buttons and texts themselves.

To add a fixture: add a case to `FixtureRoot.screen` and the name to `FixtureName.all`, make
the screen set initial focus with `.initialFocus`, and add a line to
`ScreenCaptureTests.captures`.

### Running it

On a Mac with Xcode and XcodeGen, from `tvos/`:

```sh
xcodegen generate
scripts/capture-fixtures.sh captures              # one PNG per fixture
scripts/capture-fixtures.sh captures-xl -typeSize ax3
UDID=$(scripts/find-simulator.sh)
xcodebuild test -project Kumori.xcodeproj -scheme Kumori -destination "id=$UDID"
```

On GitHub, the **Apple TV Simulator** workflow (`.github/workflows/tvos-simulator.yml`) runs
the unit tests, the remote-driven focus tests and the screenshot pass on every push that
touches `tvos/`, and uploads the PNGs as the `kumori-tvos-captures` artifact.

### What the tests check

- `KumoriTests/DesignTokenTests`: 410/260 widths, tiles fill the safe width exactly, fewer
  columns at larger text, narrower pane gives narrower tiles, text contrast ≥ 4.5:1 on canvas
  and panel, white text over the brightest art behind the scrim ≥ 4.5:1.
- `KumoriTests/FixtureTests`: fixture catalogue is stable and covers duplicate titles, long
  title, missing art, bright art, running game and late art; launch arguments parse.
- `KumoriTests/BrowseMemoryTests`: restore by ID, survives reorder, nearest-neighbour fallback.
- `KumoriUITests/FocusTests`: real lockup widths on screen (410 and 260, 560 at ax3);
  left/right edges, crossing shelves both ways; focus stays when art arrives late; no tile
  appears as two buttons; Back from detail restores the tile; End confirmation focuses
  Cancel, Back cancels, End ends exactly once, three times in a row.
- `KumoriUITests/ScreenCaptureTests`: one named screenshot per fixture state.

### Known Simulator limits

- The CI runtime is tvOS 26.5. System-wide text scaling arrived in tvOS 27, so on 26 the
  `-typeSize` argument changes layout (columns, line limits) but the fonts themselves stay at
  default size. Check text scaling again on a tvOS 27 Simulator or the device.
- Captures are 1920 × 1080 (an Apple TV 4K simulator at 1080p), one pixel per point.

### What only the Apple TV can check

The Simulator cannot judge viewing distance, real overscan on the TV, HDR, frame pacing,
Siri Remote touch feel or the 8BitDo controller. Before calling a screen done, the owner's
device pass (task H04) checks: remote navigation Home → detail → play → menu → Home, Back
restores the tile, text readable from the couch at default and large text, no clipped focus
at the screen edges, Reduce Motion and Reduce Transparency on.
