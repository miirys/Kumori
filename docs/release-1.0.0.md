First release of Kumori, a GeForce NOW client for Android TV and Apple TV.

## Files

- `Kumori-1.0.0.apk` for Android TV and Android
- `Kumori-1.0.0-tvos-unsigned.ipa` for Apple TV (tvOS 17 or newer)

The Apple TV build is not signed, so it has to be sideloaded.

## What's in it

- 4K streaming, and 4K at 120 fps on Android where the plan, decoder and display allow it
- One picker for resolution and refresh rate. It marks the mode that's live and blocks the ones your setup can't do, with the reason
- Changing the mode mid-game restarts the stream in the new mode
- HEVC decoder fixes for Amlogic boxes
- New page and tab animations
- Native Apple TV app with Siri Remote and controller support

## Not tested yet

Both apps build in CI. None of this has run on real hardware:

- 4K and 4K at 120 fps against a real account. If the service refuses, the app falls back to 1440p and says so
- The HEVC fixes on the Zidoo Z30 Pro
- The whole Apple TV app. It compiles, but it has never run on an Apple TV

If something breaks, open an issue with the device and what you picked.
