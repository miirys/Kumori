Apple TV and Kumori Link. The Android TV app is no longer developed and stays on 1.2.1; Windows and Linux stay on 1.2.1 too.

## Files

- `Kumori-1.4.0-tvos-unsigned.ipa` for Apple TV (tvOS 17 or newer), build 10400
- `KumoriLink-0.3.0.apk` for the Android box that relays controllers to the Apple TV

Nothing here is signed. The Apple TV build has to be sideloaded.

## New

- Controller rumble: on streams above 1080p60, the game's rumble reaches the controller, both motors on pads that have two (Xbox, DualSense), and controllers on Kumori Link too
- Settings › Playtime: the month at a glance with a usage bar, every session from the account's play history (on any device), and a By Game tab
- Screenshots on a game page open at full 4K resolution, and left and right step through them
- The game page opens out of its tile and shrinks back into it on Back, with one continuous motion that can be reversed halfway
- Option buttons in the stream settings and the in-game menu are Liquid Glass

## Better picture and smoother screens

- Full-screen game art is fetched at 3840 wide, pixel for pixel what an Apple TV 4K draws (it was 2560, upscaled)
- The Settings background costs the GPU less than half of what it did, so Settings stays at the full frame rate
- The Library no longer sorts the whole library again on every redraw
- Native streams: a rig a hair faster than the TV no longer keeps a standing frame or two of delay
- The TV stays at 60 Hz for the interface, and a 120 fps stream hands back the TV's own mode afterwards, HDR included (it came back in SDR before)

## Fixes

- Play history: asked the way NVIDIA's account site asks, a month at a time, so hours played and Last played fill in
- A game page's Last played row uses the play history as well as the library
- Time left this month reads "12 h" or "1 h 30 min" everywhere, never "1 hours", and "None" when it has run out
- The idle warning's hourglass stays still with Reduce Motion on
- Controllers that reconnect mid-game work again, and Play or Resume can't restart a stream that is running
- No black screen when backing out while the stream screen is still coming up
- End Game is readable when focused
- A short Kumori Link packet can no longer crash the app

## Kumori Link 0.3.0

- Rumble from the game, for controllers Android reads and for pads read over USB (Xbox 360 and Xbox One style)
- Two-motor rumble on Android 12 and newer, where the pad exposes both motors
- Wi-Fi is held out of power save while relaying, so a button press doesn't wait for the radio to wake
- Two USB pads, one plugged in after another was unplugged, could be taken for the same pad. Fixed
- The relay's thread ends with the app

## Not tested

The changes were checked by unit tests, Simulator UI tests and screenshots in CI. Rumble, the HDR hand-back and the play history request have not been tried on a real Apple TV with a live GeForce NOW session yet. Rumble on 1080p60 and slower streams (the TV client's WebRTC route) isn't wired up: what the server sends for it there isn't known yet, and this build logs it so it can be.
