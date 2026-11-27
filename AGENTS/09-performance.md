# 09. Performance: keeping it smooth

The standard is that browsing, focus moves and every animation are perfectly smooth at the display's full rate, on the slowest supported Apple TV, while a library of hundreds of games is loaded. Stutter while scrolling fast through tiles was reported and fixed several times; each cause is listed here so it does not come back.

## Rules

1. Do expensive work once, not per frame. Blurs, image decoding, sorting, shader compiling and layout of large lists belong at load time or on a background thread, with the result cached.
2. Nothing off screen does dynamic work. A tile that is not visible does not animate, fetch, decode or observe anything.
3. Nothing at rest redraws. Publish a value only when it changed. A view that watches a spring at rest, or a list that did not change, must not be redrawn.
4. Use the render server where possible. Core Animation animations run outside the app's main thread. A SwiftUI animation that runs forever steps every layer on the main thread every frame.
5. Run per frame code on the display link, and only while something moves. Stop the link when everything is at rest.
6. Measure on the device. The simulator is far faster than an Apple TV for some work and slower for other work. Use the stats and `/stats/history` for streams, and watch focus moves on a real TV for the interface.

## Specific fixes to keep

### Home and the shelves

- The ambient background frosts each picture once, at load, off the main thread: filled into 480 by 270, blurred with its edges held (radius 14), slightly more saturated (`TVAmbient`). Before, it blurred the art again on the GPU on every frame of every cross fade.
- The ambient drift is a Core Animation animation. As a SwiftUI animation it stepped every layer on the main thread sixty times a second, forever, behind every screen.
- The ambient picture changes only after focus has rested on a game for a moment, so flicking along a shelf does not strobe the screen or trigger a fetch per tile.
- A Home card fetches and decodes its wide picture only after it has been focused (or held open) once. A card that has only ever rested as a poster keeps one picture, not two. This was most of what scrolling quickly through Library used to decode.
- Until the wide picture is decoded, the poster stays over it, so a card never fades to black.
- Rows do not redraw on every focus move. Where each card sits is written as they lay out, without triggering a redraw.
- The library is sorted once when it changes (`AppModel.libraryAToZ`), not on every redraw.
- The app once re-sent an unchanged list of running sessions on every poll, which redrew screens that showed it. Only publish when the list actually changes.

### Artwork

- Full screen art is fetched at 3840 wide, pixel for pixel what an Apple TV 4K draws a page at. 2560 was upscaled by half again and looked soft on a 4K TV.
- Cards and posters are fetched small from the server (a card size hero is a ninth of the pixels). Only full screen backdrops are asked for at 4K.
- Decoded images are cached with a cost limit (room for about a dozen decoded 4K backdrops next to the shelves' art).

### Settings

- The Settings light is drawn by the GPU at a third of the screen's size and scaled up. A field this soft looks the same as full size at a ninth of the cost.
- It runs at the screen's full frame rate, but only while Settings is on screen or fading out. It is stopped the rest of the time.
- Its shaders are compiled in the background at launch. Left to first use, SwiftUI compiled them on the main thread as Settings opened, which held the screen for a fraction of a second.

### Glass

- Glass and similar effects are prepared at launch, so the first screen that shows them does not stutter.

### The game page

- One frame clock for the motion, stepped to the frame's display time (see 08). Two drivers drew the same frame twice.
- Only values that changed are published, so views watching a spring at rest are not redrawn.

### Kumori Link on tvOS

- `LinkNavigator` walks only the screen on top. Walking the screens underneath made every held press slow.
- A held direction waits for a move still in progress instead of piling up moves, which lagged the app.

### Streaming

- Show the newest frame and drop older ones. Never let a queue of frames build up delay.
- Ask the display link for the stream's rate (see 05).
- Keep heavy work off the decode and network threads. Log only the first few problems of a stream.
- Kumori Link on Android: network lookups once ran on every packet and caused stutter. Run them every few seconds.

## Lessons from the other platforms

These come from the desktop and Android apps and apply to any port or fork:

- On Windows, the default timer resolution is about 15 ms. Using it for input polling made the mouse jumpy. Ask for 1 ms timers.
- Read the mouse off the UI thread, and draw a local cursor (as remote desktop clients do) so the pointer never waits on the stream.
- Text rendered into a layer that is later scaled looks pixelated, especially at Windows 125 and 150 percent scaling. Draw text as vectors at its final size.
- On Android, wrapping the hardware decoder in extra layers caused a native crash. Use the decoder directly.
- On Android, release builds' code shrinker (R8) stripped WebRTC classes that are only reached at startup by reflection. Keep rules are needed.
- Pick the codec the box's hardware actually decodes well. On the Amlogic Android box, HEVC was right and AV1 was not.
