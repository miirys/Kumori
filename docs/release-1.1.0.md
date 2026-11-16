Adds GeForce NOW's DLSS overrides to both apps, and fixes a long list of bugs.

## Files

- `Kumori-1.1.0.apk` for Android TV and Android
- `Kumori-1.1.0-tvos-unsigned.ipa` for Apple TV (tvOS 17 or newer)

The Apple TV build is not signed, so it has to be sideloaded.

## DLSS overrides

GeForce NOW added these to its own apps in October. They are in Settings on both apps:

- DLSS model: the game's choice, Recommended, or preset K, L or M
- DLSS quality: the game's choice, DLAA, Quality, Balanced, Performance or Ultra Performance
- Ray Reconstruction model: the game's choice or Recommended
- Frame generation: the game's choice, the recommended model, or dynamic up to 3x or 4x

The cloud rig applies them when a game starts, so a change counts from the next game you launch. The game has to support DLSS and have it turned on. Ray Reconstruction needs Performance or Ultimate, and dynamic frame generation needs an Ultimate RTX 5080 rig. Some games opt out.

## Fixes

About a hundred bugs found in a review of both apps, among them:

- Frame pacing "Fastest" no longer waits for the screen
- Reconnecting asks for the size the session was started with
- Realtek decoders get their own handling
- Controller, USB and Siri Remote input fixes
- The tvOS build number now follows the version

## Not tested yet

Both apps build in CI. None of this release has run on real hardware. The DLSS values are the ones the official client sends, taken from the OpenNOW project's reading of it, and have not been checked against a live session. If a game ignores them or a session fails to start with them set, put everything back to "Game's choice" and open an issue.
