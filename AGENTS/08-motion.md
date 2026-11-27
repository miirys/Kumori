# 08. Motion: what was approved, what was rejected, and how it is built

Motion is where Kumori has had the most rounds of feedback. The bar is high: every animation must be smooth at the display's full rate, interruptible at any moment, and must play back exactly in reverse.

## Principles

- Springs, not timed curves. A spring can be interrupted and redirected without a jump. Write springs as (response, dampingFraction), like SwiftUI's `.spring(response:dampingFraction:)`.
- No timers or delays to sequence things. When pieces must move one after another, make each piece follow the one before it through its own spring. That gives a natural cascade that also reverses naturally. Fixed delays between items (the "PowerPoint" stagger, where items pop in one by one on a schedule) were rejected.
- Exact reverse. Back must play the opening backwards, through the same geometry. If going back takes a different path or snaps at the end, it will be noticed.
- Interruptible. Pressing A and Back rapidly must stay smooth. A page that is closing and gets A again grows straight back out from wherever it has got to, as if it had never left. Never queue animations or wait for one to finish before accepting input.
- Full frame rate. Animations must hold 60 fps on a 60 Hz interface and 120 fps when the TV is in a 120 Hz mode. The game page's frame driver never runs below 60 a second, whatever the system would prefer for power.
- Blur only while moving. Motion blur on text was liked, but only as a result of lag: a piece blurs while it trails the piece ahead and is sharp the moment it catches up. Never a static blur, never blur on glass.
- Reduce Motion removes all custom pans, zooms, springs and cascades. What remains is a fade of 0.1 s or less, or nothing.
- Nothing that is not moving should redraw. Only publish values that changed, so views watching a spring at rest are not redrawn.

## The game page ("take 5", approved)

Implemented in `UI/GamePageMotion.swift` and `UI/GamePage.swift`. There are no timers or delays: one driver spring, the art's grow, moves the page, and every other piece follows it through springs of its own, ticked once a frame. Springs are stepped by hand in twelve small steps a frame, so even the stiffest link stays stable, and each settles exactly on its target once it is close enough to be still.

Springs:

| Motion | Spring (response, damping) |
| --- | --- |
| Art grow, opening | 0.62, 0.88 |
| Art shrink, closing | 0.6, 0.96 |
| Chain links (each piece following the one before) | 0.075, 0.92 |
| Scroll links (close to rigid) | 0.018, 0.98 |
| Glass morph | 0.34, 0.7 opening, 0.22, 0.9 closing |
| Section reveal | 0.5 plus 0.06 per index, 0.9 |
| Page scroll | 0.55, 0.95 |
| Below the fold dim (reaches 0.62 black) | 0.6, 1.0 |

Opening:

1. The whole first screen lives inside the art's frame. Each piece's final position is mapped into the current art rectangle with a uniform scale that goes from tile width over screen width to 1 as the art spring goes from 0 to 1, anchored bottom left. The text, buttons and caption are already there at tile size and grow out with the art.
2. Chain order: hours left, publisher, title, genre line, description line 1, description line 2, button row, played caption, lower sections. Piece 0 follows the art spring, each later piece follows the one before it.
3. While a piece lags the one ahead, it hangs a little low (70 pt times the lag, scaled), stretches slightly along the motion (clamped to a few percent), and blurs by up to 3 pt (7 times the lag). Opacity is the piece's own value times 2.2, capped at 1.
4. The scrim (the dark gradient from the left and bottom) is a child of the art layer, so it clips with the art, and its opacity follows the art spring. It must never move on its own. When it did, a see through strip appeared at its edge.
5. Tiles beside the one the page grew from are pushed aside as it grows, less the further away they are (70 pt divided by a distance factor). The tile itself hides while the picture covers it.

The glass button row:

- It starts as one round glass drop (Play, 106 pt wide), with the settings button tucked behind it (128 pt to the left, scale 0.62).
- As the glass link passes 0.6, the drop splits: Play widens from 106 to 220 pt, the settings button slides to its place, and the "Play" label unclips and sharpens from an 8 pt blur.
- On closing, the morph runs first: the buttons fold back into one drop, then thin to clear.

Closing:

- The chain reverses. The lower sections lead out, each piece follows the one after it, and the art shrinks into the tile after the title, carrying the text inside it.
- When the art is within 3 percent of the tile, the tile's focus spring gets a small velocity kick (minus 3.2) so it catches the picture with a small dip and bounce. Then the stage hides and the real tile shows.

Scrolling:

- Each chain piece also follows the page's scroll through its own stiff link, with the leading piece in the direction of travel (the top leads going down, the bottom going up), so the block spreads and draws back together instead of folding over itself.
- The art parallaxes at minus 0.22 times the scroll and zooms up to 1.06 by 900 pt of scroll.
- Lower sections start tucked (0.28 opacity, no saturation, 0.7 brightness, 110 pt low, scale 0.96, 8 pt blur). A section reveals when focus reaches the section above it, one step ahead of focus, and tucks again in reverse order when focus leaves upward. This is the only stagger on the page, and it only happens when focus moves.

## Things learned the hard way on the game page

- Do not scale or move Home behind the page. The original spec scaled Home to 0.96 under a black layer. That caused the screen to jump when coming back, other tiles to resize, and the page to end up shrunken with black borders, stuck partway. It happened twice. Home now only dims under the page. This overrides the earlier spec.
- One frame clock. The motion is stepped by a display link, to the time the frame will be on screen, so every frame moves by exactly one frame's time. Stepping by whenever a callback happened to run made motion uneven. A second driver stepping the same frame drew the page twice in one frame.
- But have a backstop. If the display link stops (it can), the page froze partway, photographed at 80 percent size with rounded tile corners still on. `GamePageMotionPulse` uses SwiftUI's animation clock to step the motion only when the display link has gone quiet while something is still moving, and restarts the link.
- The tile morph. A resting tile is a tall poster that morphs into a wider shape under focus. On select, the page grows from that focused shape. The art must scale with the frame in both directions; when it did not, the picture flashed un-animated for a moment. The poster image fades only over the last part of the spring.
- Keep the focused element faintly present (not fully transparent) during the open, so the focus engine always has something to land on.

## The Home banner's Details

Details on the Home banner opens a game page from a picture that is part of the background, not from a tile. Rules:

- The page must land exactly on the banner's own picture crop when it comes back, so there is no jump between the full screen crop and the banner's crop.
- Going back, it sinks into the banner, fading as it shrinks, rather than landing on top of it like a card and waiting to be caught. An earlier version left the picture sitting on top for about 2 seconds before it sank, and then the banner snapped on. Both were rejected.
- The page's words fade out in the first half of the way back, while the picture is still large, so the title never shows doubled over the banner's own title. Opening, they come up in the second half.
- The lower half of the sinking picture keeps covering what is under it until the page's words have gone, then dissolves into the banner's own fade.
- Use one spring with no overshoot, both ways, slower when sinking. On the faster spring, the page was back in the banner a third of a second after Back and the end fade lasted a fifth of a second, which read as a snap.
- A critically damped spring creeps over its last tenth, and anything that fades during that creep reads as a wait at the end. Cut the last stretch off and have everything at rest by then.
- The banner picture itself should move as Details opens (a slow zoom and drift), and that motion must also reverse exactly. A static banner during the transition was called boring.

## Other approved motion

- Home cards opening sideways into banners under focus, with neighbours making room so the row moves as one (`TVMotion` card spring).
- The ambient background: the new art fades in over the old (the old stays fully drawn underneath), with a very slow drift run by Core Animation, so it costs the app nothing per frame (see 09).
- Settings pages arriving slowly, out of a soft blur, settling slowly rather than stopping. Rows arrive after the page. The first version was too fast and generic.
- Switching into and out of Settings must blend: the Settings background fades in over the other tabs' ambient art and back out, never a hard cut.
- Glass arriving with a soft liquid swell and a small settle, as the system's pop ups do. Glass leaving quick and even, so it never lingers.
- The in stream menu: a longer, softer glass blur in and out.
- The low frame rate notice slides in, stays about 5 seconds, then animates itself out.

## Rejected motion

- Fixed delay staggers (items appearing one after another on a timer).
- A plain upward jump for a menu, with all options appearing at once.
- Settings animations that were fast and generic.
- Whole page zoom transitions (from the desktop app era).
- Anything that snaps at the end, jumps on reverse, or takes a different path back.
- Scaling the screen behind a page.
- Breathing, pulsing or looping decorative motion. The Settings light moves continuously, but from noise, so it never loops.

## The Settings background

What was wanted, in the end: a monochrome white light moving through smoke on true black, with random looking paths, well animated. What it is now (`TVGlowBackdrop.swift` with `SettingsLight.metal`): threads and veils of white silk flowing on black, lit by soft lights that wander the whole screen. Only shades of white. Paths come from two layers of noise, slow and quicker, stretched so the light reaches every edge and a little past, so nothing runs on a loop or settles in the middle.

Rejected on the way: coloured ink, soft coloured glows behind glass, glowing circles with no real blur ("looks cheap"), a slow dark gradient, and any composition that sits in the centre.

How it is drawn is in 09.
