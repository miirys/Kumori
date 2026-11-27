# 10. Bug log

Bugs that cost real time, what caused them, and how they were fixed. Before you fix a bug, search this file: several of these came back more than once. When you fix a new one, add it here in the same shape, in the right section, newest at the bottom of its section.

Entry shape:

```
### Short name of the bug
- Symptom: what the player saw.
- Cause: what was actually wrong.
- Fix: what changed, with the file or type.
- Avoid: the rule that stops it coming back.
```

## Launching and sessions

### Asking for 4K or 120 fps got 1080p60
- Symptom: Settings said 4K or 1440p120, the stream was 1920 by 1080 at 60 fps.
- Cause: the TV client identity over WebRTC is held to 1080p60 by GFN no matter what is asked. The server accepts the request and streams 1080p60 anyway.
- Fix: modes above 1080p60 go through the native NVST route as the PC client (`RequestIdentity`, `NativeRequest`, `Player.tryNative`).
- Avoid: never trust that the mode asked for is the mode streamed. Check the rig's own `monitorSettings` and the decoded size.

### The PC client route over WebRTC never started
- Symptom: launch hung on "connecting" and timed out.
- Cause: asked as the PC client with a WebRTC stream, the rig answers the sign in and then sends only heartbeats, never an offer.
- Fix: that route was removed. The PC client identity is only used with the native stream.
- Avoid: do not reintroduce it without new evidence from a real device.

### Launches died while the rig was still starting
- Symptom: "the server dropped the connection" on games that take a while to start.
- Cause: a version 3 signaling sign in got no offer, and a 12 second re sign in timer fought a separate 30 second watchdog. Each new sign in under the old peer name got `peerRemoved`.
- Fix: version 2 sign in, a new peer name per sign in, one 80 second wait for the offer, at most 3 sign ins and only after a socket closed (`SignalingPolicy`, `SignIn`).
- Avoid: sign in once and wait. Do not add timers that re sign in.

### One failed native launch disabled 4K for a day
- Symptom: 4K stopped working after one bad launch, until the next day.
- Cause: native failures were remembered for 24 hours.
- Fix: a native failure is remembered only within the current launch.
- Avoid: do not cache negative results about routes across launches.

### Resume came back at 60 fps with wrong colours
- Symptom: a 4K or 120 fps session picked up again streamed at 60 fps and looked washed out.
- Cause: every resume asked as the TV client.
- Fix: remember each session's route and mode (`Player.remember`, `Player.recall`), and resume with `adopt` at the session's own mode, as the client that mode needs.
- Avoid: polls, claims and ends must always use the identity the session was created with.

### A picked up session sent no picture forever
- Symptom: resuming a session sat on a black screen.
- Cause: some picked up sessions never send an offer.
- Fix: after 40 seconds without a picture, end the session once and start fresh at 1080p60 as the TV client.
- Avoid: every wait needs a limit and a single, visible recovery step.

### End Game left the game running
- Symptom: after End Game, the session was still listed, or the next launch failed.
- Cause: a session started as one client may refuse an end asked as another, and a single DELETE can fail.
- Fix: `endForSure` sends DELETE to the owning rig and then the region, as the original identity, then as native and TV, and retries until the session is gone. Orphans of this device are swept after backing out.
- Avoid: treat "end" as a loop with a goal, not one request.

### A new launch right after End got a 403
- Symptom: start a game right after ending one, get an error.
- Cause: the old session was still ending on NVIDIA's side.
- Fix: wait up to 30 seconds for an ending session to finish before the new launch.
- Avoid: expect NVIDIA's state to lag a few seconds behind your requests.

### Backing out while a rig was requested showed a "cancelled" error
- Symptom: pressing Back during "Requesting a rig" reopened the stream screen with an error.
- Cause: a cancelled URLSession request throws `URLError(.cancelled)`, not `CancellationError`, so it was treated as a failure.
- Fix: check `Task.isCancelled` and `URLError.cancelled` in the catch.
- Avoid: in Swift concurrency, treat both kinds of cancellation as a cancel.

### Play could restart a running stream
- Symptom: a Play or Resume press from the screen underneath restarted the stream.
- Cause: presses reached the browsing screens while a stream was up or starting.
- Fix: Play and Resume on browsing screens are ignored while a stream is up or starting (logged as "ignored Play/Resume").
- Avoid: when a screen is covered, it must not act on input.

### Play stuck after a stream screen failed to open
- Symptom: Play did nothing until the app was restarted.
- Cause: a launch whose stream screen never came up kept its "starting" state.
- Fix: the state is cleared when the screen does not arrive, and a stream screen asked to go while still being presented is taken down once it arrives.
- Avoid: every state that blocks input needs a way out that does not depend on a callback arriving.

### Games with their own launcher could not be started
- Symptom: some games (often gacha games with a publisher launcher) would not launch or vanished.
- Cause: their store value is NONE or UNKNOWN, and code filtered those out as junk.
- Fix: NONE and UNKNOWN are valid, meaning the publisher's own launcher.
- Avoid: never filter catalog values because they look odd.

### Signed out during NVIDIA outages
- Symptom: the user was signed out for no reason.
- Cause: any error during token renewal, including a 5xx or 429, was treated as a refusal and wiped the keychain.
- Fix: only a definite refusal signs out. A 401 before expiry renews and retries once.
- Avoid: a server error is never a reason to delete credentials.

### Free tier queue waited forever
- Symptom: "In queue" with no progress on a free account.
- Cause: the queue wanted to show an ad, which Kumori cannot play, and the flag was not read.
- Fix: read the ads flag and say plainly that this membership's queue shows ads this app cannot play.
- Avoid: read every flag the official client reads before a session goes live.

## Picture and display

### Black screen while video was decoding
- Symptom: a 4K stream went live, the stats showed decoded frames, the screen stayed black.
- Cause: WebRTC's Metal view silently skipped frames in formats it cannot draw.
- Fix: draw with `AVSampleBufferDisplayLayer` in `PictureView`.
- Avoid: when frames decode but do not show, look at the display path first.

### 120 fps stream shown at 60 to 100
- Symptom: stats said 120 decoded, the screen showed fewer.
- Cause: the display link ran at the system's default rate, slower than the HDMI mode.
- Fix: ask the display link for the stream's rate. Show the newest frame and skip one after a second of standing backlog.
- Avoid: always set a display link's preferred rate explicitly.

### 4K60 held at about 29 Mbps and 48 fps with micro stutters
- Symptom: soft picture and stutter on native 4K.
- Cause: the VQOS ceiling equalled the starting bitrate, and `linkCapabilityKbps` carried measured throughput.
- Fix: a ceiling of at least 100 Mbps and twice the target, and the official client's flat link figure.
- Avoid: copy the official client's QoS numbers exactly; they feed NVIDIA's rate control.

### Lost frames on longer network paths
- Symptom: frequent keyframes and freezes on connections with more than about 70 ms round trip.
- Cause: a gap was given up 80 ms after it was seen, before a resend could arrive.
- Fix: NACK waits grace plus round trip plus margin, capped at 200 ms.
- Avoid: timeouts on network recovery must scale with the round trip.

### Garbage on screen after a decode error
- Symptom: smeared or broken picture until the next keyframe.
- Cause: after VideoToolbox rejected a frame, a fresh decoder session got delta frames with no reference.
- Fix: re-arm the first keyframe gate with every teardown and ask for a keyframe.
- Avoid: a new decoder session must always start on a keyframe.

### Crash the moment a stream screen opened (tvOS 27)
- Symptom: the app aborted when a stream started.
- Cause: tvOS 27 removed `UIWindow.avDisplayManager`, and the app asked for it unconditionally.
- Fix: check that it exists before use.
- Avoid: guard every API that a new tvOS might remove, especially display and private APIs.

### The interface stuck at 50 Hz after a stream
- Symptom: Home felt laggy after playing.
- Cause: when the saved mode was not listed, the code fell back to the display's "preferred" mode, which can be 4K at 50 Hz.
- Fix: restore only the exact saved mode, and keep the interface at 60 (`keepInterfaceAtSixty`).
- Avoid: never pick a display mode the user did not choose.

### HDR lost after every 120 fps stream
- Symptom: after a stream, the interface was in SDR.
- Cause: the mode to restore was read at stream start, after the system had already left HDR.
- Fix: read the interface's mode at launch and on returning to the foreground, before any stream.
- Avoid: save state before anything has a chance to change it.

### Frozen frame with nothing focused after a 120 Hz stream
- Symptom: after ending a 120 fps game, the screen froze and no button had focus.
- Cause: switching the HDMI mode back while the stream screen was being dismissed stalled the dismissal.
- Fix: switch back only after the stream screen has gone, then refocus.
- Avoid: never change display modes during a transition.

### Audio clipped
- Symptom: loud, distorted game audio.
- Cause: WebRTC's audio source volume was set to 10 (a gain), about 20 dB too loud.
- Fix: 1.0.
- Avoid: check what a "volume" property's scale is before setting it.

## Input

### A connected controller did nothing in the game
- Symptom: the Controllers page showed every press, the game ignored them.
- Cause: the pad was never registered, the connected bitmap lacked the XInput bits, and the session did not ask for a gamepad.
- Fix: see 06, "Getting a gamepad to work in the game at all".
- Avoid: compare bytes with a known good client (`tvos/InputTests` checks against the desktop encoder).

### A pad that reconnected mid game was ignored
- Symptom: after a controller slept and woke, the game stopped responding to it.
- Cause: report sequence numbers restarted at 1, so the rig dropped them as older than its last one.
- Fix: sequence numbers keep counting across reconnects, on both routes.
- Avoid: never reset a counter the server compares against.

### Holding Menu also paused the game
- Symptom: opening Kumori's menu opened the game's pause menu too.
- Cause: Start was sent as soon as Menu went down.
- Fix: a tap is Start, a 0.6 s hold is Kumori's menu (`PadLogic`).
- Avoid: decide what a press means before sending anything.

### Resume or Back landed in the game as a press
- Symptom: closing the menu with A or B also pressed A or B in the game.
- Fix: buttons held when the game gets control back are suppressed until released.

### Players reshuffled when one controller left
- Fix: fixed slots that a pad keeps while connected, with a neutral report for the one that left.

### The camera drifted on its own
- Symptom: the game camera crept with no one touching the stick.
- Cause: a resting stick is never exactly centred.
- Fix: a 10 percent radial dead zone on both sticks in the game path, 8 percent at the Link box.

### Full diagonals reached only 70 percent
- Cause: the stick vector was capped to the unit circle.
- Fix: clamp each axis instead.

### A ended up on the wrong card with Kumori Link
- Symptom: pressing A with a Link controller opened the neighbouring game.
- Cause: selection used whichever accessibility element overlapped the focused card while the row was still resizing.
- Fix: A runs the focused card's own action.

### Held directions kept repeating, or flicked back the other way
- Cause: a stick springing back past centre read as a flick; a lost release never ended the repeat; a release went only to a pad that had left.
- Fix: rebounds after a release are ignored, a silence longer than the box's resend interval ends the repeat, and dropping the lead pad resets the navigator.

### A pad stuck or deaf after a Link box restart
- Cause: the box sends a pad's "left" packet only once, and per slot sequence checks outlived a box restart, so every new packet looked old.
- Fix: the newest packet's slot mask drops pads it no longer lists, a slot quiet for 1.2 s is let go and dropped at 3.5 s, a sequence far behind means a restart, and BYE clears sequences (`LinkFreshness` in `PadLogic.swift`, with tests).

### Kumori Link packet crash
- Symptom: the app crashed on a malformed packet.
- Cause: a packet shorter than 4 bytes was read past its end.
- Fix: length check before reading.
- Avoid: check lengths before reading any network data.

### Link B closed the app
- Cause: `.onExitCommand` on the root screen let B fall through to the system.
- Fix: `.onBack(perform:)` from `LinkBack.swift`, and the root screen keeps B.

### A swallowed after a stream ended
- Cause: controllers were not handed back to the interface when the stream screen went.
- Fix: hand them back when the screen closes.

## Interface

### Home jumped and the game page ended up shrunken with black borders
- Symptom: opening or closing a game page made the screen jump; the page sometimes stopped at about two thirds size with rounded corners and black borders.
- Cause: Home was scaled behind the page, and the motion had two frame drivers and no backstop.
- Fix: Home only dims. One display link clock with a SwiftUI backstop (see 08).
- Avoid: never scale the screen behind a page. This came back twice.

### Ghost title through fades
- Cause: a fallback text title sat under loaded art.
- Fix: placeholders hide their name and panel once the picture is in memory.

### Banner Details snapped back
- Symptom: going back from the banner's Details, the picture sat on top for about 2 seconds, then the banner snapped on.
- Fix: see 08, "The Home banner's Details".

### Blank game page with no way back
- Cause: a page opened while the previous one was still being dismissed.
- Fix: do not open a page while the last is dismissing, and take the picture away if the page never comes up.

### End Game confirmation reported both End and Cancel
- Cause: a 0.35 s fallback that ends the session when the dialog's dismissal is not reported cleared the confirmation, so the late dismissal also called cancel. Caught by the focus tests.
- Fix: mark the presentation handled when the fallback ends it.

### Text 160 pt from the edge
- Cause: `TVTokens.safeX` added inside a full screen view that already has the system safe area.
- Fix: no extra inset outside `TVPage`.

### Settings sidebar pushed Sign Out off the screen
- Cause: a new row was added without checking the column's height.
- Avoid: check every list at the largest text size.

### Search said "Nothing found" while loading
- Cause: results started empty and errors were turned into an empty list.
- Fix: loading, empty and error are separate states (`TVStatusView`).

### Screen saver blocked on the "stream stopped" screen
- Cause: the idle timer was released only when the stream screen disappeared.
- Fix: release it when the stream ends.

## Local API and diagnostics

### The local API held connections and stalled the interface
- Cause: a connection that never finished its request was held forever; an old listener's late cancel marked the new one stopped; `/log` walked every log line on the main actor.
- Fix: idle connections are dropped, a replaced listener's late states are ignored, HEAD gets no body, the log is filtered in the store and read off the main thread.

### An ended stream reported as live
- Cause: `/stats` said live while the ended screen was up, and input counters read zero because they had moved.
- Fix: report the last stream as ended, with its last counters.

### Play history lines never reached the device log
- Cause: they were logged below notice level.
- Fix: every history request is kept and served at `/playtime`.
