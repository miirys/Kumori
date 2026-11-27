# 07. UI rules: the look, what was approved, what was rejected

Kumori's look was reached through many rounds of feedback on a real TV. The rules below are the result. Each comes with the reason, so you can apply it to screens that do not exist yet. Motion has its own file (08).

`tvos/DESIGN-SYSTEM.md` is the original design guide and is still right about the components, tokens and fixture harness. Some of its rules were later changed by approved designs. Where it disagrees with this file, this file wins. The changes are listed at the end.

## The overall look

- Black, not dark grey. The canvas is near black (`TVColor.canvas`, #080808) and Settings is true black. The app is meant for OLED TVs, where black is off. A "dark" background that is visibly grey was rejected.
- Monochrome chrome. Text and controls are white and shades of grey. Colour comes only from game art. No accent colours in the interface, no coloured ink, no pink or green highlights. A hot pink banner from an early version was called out as not belonging.
- Art is the hero. Let game artwork, type and the system's own focus do the work. Decoration competes with the art.
- Restraint like Apple's own apps. When unsure, look at how the Apple TV app, Music or Settings handles the same thing, and do that. Generic "AI made" interfaces were rejected outright: random translucency, pills with glowing dots, cards inside cards, and decorative effects that mean nothing.

## Things that were rejected, and must not come back

- Pills, chips and badges with dots. A "Running" pill with a pulsing dot was rejected twice. Running state is said in words: the button reads "Resume" and a quiet caption says "Still running".
- Glows and halos. Glowing circles, glowing dots, soft coloured glows behind panels.
- Outlines and rings. No 1 px borders, no focus rings, no outline to show the selected choice. A selected choice is a brighter fill. Focus is the system's lift, or a filled white platter, never a stroke.
- Thin fonts and hairlines. No light or thin weights, no hairline dividers, no near identical dark shades side by side.
- Fallback title text under artwork. When a game's art has loaded, no text title may sit behind it. It showed through every fade and cross fade as a faint ghost title. Only show a text title when there is no art at all.
- Repeated helper tags. A resolution picker that said "Shown at 60 Hz" on every row looked like spam. Say a thing once, in one place, or not at all. The current picker is separate Resolution and Frame rate steppers, with no "Shown at 1080p 120 Hz" line.
- Hand made glass. A custom blur and tint for buttons looked like blurred plastic and had jagged, aliased edges, "like a game at 720p with no anti aliasing". Use the system's glass.
- Whole page zoom transitions, Ken Burns drifts on the interface, breathing effects.
- Centred layouts where the content belongs on a left edge.
- Mono ALL CAPS labels as decoration.
- Showing "OpenNOW" anywhere in the user interface. Credit belongs in the licence notices, not in the product.

## Words

The wording rules matter as much as the visuals. Copy that sounds machine written was rejected repeatedly.

- Short, plain, human. Write what a thoughtful person at Apple would put on the screen.
- No "fun fact" notes. Settings rows do not explain what the setting technically does ("renders to screen in low latency mode"). If a choice needs a sentence to be understood, the choice is badly named.
- No filler, no marketing tone, no exclamation marks, no emoji.
- No em dashes and no middle dots as separators in readouts. Use a comma, a line break, or separate labels.
- Fewer full stops in notices. A notice reads as one natural sentence, not several short choppy ones.
- Error messages name the problem and the way forward ("Your plan doesn't include 4K. Streaming at 1440p.").
- Store names: the store button shows the full name. Short names only in the small hours caption (see 04).
- Never say anything about the specific person's own TV or setup in the interface. The app is for everyone.

## Glass

- Use the system glass (`.glass` button style, Liquid Glass on tvOS 26 and later). The Home banner's Play button is the reference: every other glass button must match its edges and material.
- Glass is for controls and things that float: buttons, the in stream menu, pop ups, dialogs. Not behind every label, and not as panels inside panels.
- Reduce Transparency and tvOS before 26 get an opaque neutral panel instead.
- Prewarm glass effects at launch, so the first screen that shows them does not stutter (see 09).

## Layout

- Safe area: text and buttons sit on the 80 pt horizontal safe edge (`TVTokens.safeX`), 60 pt vertical (`safeY`). Artwork and video may bleed to the screen edge.
- A full screen view that is not inside `TVPage` (the game page, the stream screens) already gets the system's 80 pt safe area. Adding `TVTokens.safeX` again puts its text at 160 pt. This mistake was made and shipped once.
- Other tokens: gutter 40 pt, art corner radius 16 pt, panel radius 24 pt, row height 76 pt.
- Never put `accessibilityIdentifier` on a container. It replaces the identifiers of the views inside it, which breaks UI tests and Link selection.
- Every focusable game is keyed by its game id (`lockup-<id>`). Art arriving late must never change a frame's size. Back from a game page restores focus to the tile that opened it (`BrowseMemory`).
- Check that nothing outgrows the screen. Adding a Playtime row to the Settings sidebar once pushed Sign Out off the bottom. A sidebar with too much empty space at the bottom was also called out. Test with larger text (`-typeSize ax3`).
- Text over art always has a scrim behind it. Text colours pass 4.5 to 1 contrast (unit tested).

## The screens as approved

### Home

- A full width banner at the top for recent or featured games, with Play (system glass) and Details. Its picture is the reference crop for the Details transition (see 08).
- Shelves of expanding cards (`TVExpandingCard`), as on the Android app: a poster at rest that, under focus, opens sideways into a wide banner with the title, store and genre, and a few lines about it. Neighbours make room so the row moves as one. Seven posters across at default text size, fewer at larger sizes.
- Up and Down land on the card nearest the column focus came from, so focus moves straight up and down instead of drifting toward the middle of an open card.
- Behind everything, the focused game's art blurred into soft glass, darkened for legibility and drifting very slowly (`TVAmbient`). A new picture fades in over the old one, which stays fully drawn underneath, so the screen never dims and brightens on each move.

### The game page (approved "take 5")

- Opens out of the tile it came from, with the text living inside the art (motion in 08).
- Left column, from the top: hours left, publisher, title, a genre line such as "Action, Adventure, RPG" (no store name in it), then quality badges, then two lines of description, then the button row.
- Quality badges after the genres are the one place badges are allowed: rounded rects with a 7 pt radius, 0.2 white fill, 19 pt bold text with 0.6 tracking, reading for example "1440p" and "120 FPS". 20 pt before the first, 12 pt between. They state the stream quality, not a status, and they sit on the text column, not on the art.
- The button row starts as one glass drop and splits into Play and a settings button.
- A two line caption sits 42 pt after the settings button, centred on the row: "Played yesterday" (25 pt semibold, 0.88 white) and "142 hours on Steam" (23 pt medium, 0.55 white), with the real hours and launcher.
- The right side of the first screen stays empty for the art. The old right hand stats row was removed, and "Auto" was dropped.
- Lower sections are tucked until focus reaches the section above them.
- Earlier rejected versions: Play placed too high, too much empty space, pills for stream details, Play appearing before the open animation and lingering during close.

### Settings

- A rail on the left and a pane on the right. The rail is grouped Streaming, Input and General, and each item shows its current value underneath.
- Selected choices are a brighter fill. No outlines.
- The About page has its own layout and shows only what matters: the app, the build, the display and the decoders. Advanced and diagnostic detail lives on the Debug page (stream stats, connection and server info, codec support, HDMI chain).
- The background is a monochrome light moving through smoke on true black (see 08 and 09 for how it is drawn). Coloured versions, glowing circles and a centred composition were all rejected.
- Pages arrive slowly and settle softly. "Too fast and generic" was the feedback on the first version.

### In stream

- The in stream menu is glass, opens with a longer, softer blur, and always opens with something focused.
- Stats come in a compact line and a detailed mode. The detailed mode shows exact packets lost and resent, jitter, codec, decoder, display refresh and audio.
- The low frame rate notice: about 5 seconds, at most once a minute, one natural sentence, then it animates out.
- Ending a game always asks first (`.endSessionConfirmation`), with Cancel focused first and Back cancelling.

## DESIGN-SYSTEM.md rules that are superseded

- Rule 6 (no badges on artwork) still holds for artwork. The game page's quality badges are an approved exception because they sit in the text column.
- Rule 7 (quiet motion: no stagger, no blur in, only native focus motion) was relaxed by approved designs: the game page's chained springs and lag blur, the expanding Home cards, the drifting ambient background, the moving Settings light, and the Settings page row arrival. Its spirit still applies everywhere else: no decorative motion, and Reduce Motion removes all of it.
- Rule 3's tile counts (6 posters across) were replaced on Home by the expanding cards' 7 posters.

When you change an approved design, update this file and DESIGN-SYSTEM.md together so they never disagree.
