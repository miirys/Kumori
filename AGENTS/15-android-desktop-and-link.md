# 15. The Android TV app, the desktop app and Kumori Link

## Android TV app (`android/app`)

The Android TV app is no longer developed; its last release is 1.2.1. Keep it building in CI. It is still useful as a second, working implementation of the same GFN services (see 11).

Structure, under `android/app/src/main/kotlin/app/kumori/tv`:

- `data/`: `Nvidia.kt` (sign in), `Cloudmatch.kt` (sessions), `AppState.kt`, `Models.kt`, `History.kt`.
- `stream/`: `StreamEngine.kt` (WebRTC), `NativeTransport.kt` and `NvstBridge.kt` (the Rust NVST library), `DirectDecoder.kt` (MediaCodec straight to a surface), `Streamer.kt`, `Capabilities.kt`, `InputEncoder.kt`, `VideoHooks.kt`.
- `input/`: `PadHub.kt`, `UsbPadDriver.kt` (userspace USB pads), `HidGamepad.kt`.
- `debug/`: its own local API and log reports.
- `ui/`: Compose for TV screens, motion and theme.

The Rust NVST library is in `android/nvst`, with its upstream record in `UPSTREAM.md`. Build it with `python3 android/scripts/build_nvst.py` (it finds the NDK through `ANDROID_HOME` or `local.properties`, or takes the NDK path as its first argument) after `rustup target add aarch64-linux-android armv7-linux-androideabi`. The release build stops if the library is missing.

Lessons from the Android app:

- R8 stripped WebRTC classes reached only by reflection at startup. Keep rules for `org.webrtc`, `org.jni_zero` and `VideoHooks` are in `proguard-rules.pro`. Any release only crash on startup: check the keep rules first.
- Wrapping the hardware decoder in extra layers caused a native crash. Feed MediaCodec directly.
- Show the newest decoded frame and skip stale ones.
- On the Amlogic box it was tested on, HEVC was the right codec, not AV1.
- A native 4K keyframe at high bitrate can exceed a 2 MiB access unit limit, be dropped, trigger a keyframe request, and loop. Size the limit for 4K keyframes.
- The codec chosen and the codec advertised must come from the same list, or no codec is agreed and the screen stays black.
- A pad that sleeps and reconnects can get a new device id. Forget the old one, or dead pads take slots.
- Forcing a claim on a USB pad unbinds the kernel driver, and nothing reattaches it when the app goes to the background, so the pad stays dead in other apps.
- Plugging in or waking a USB dongle during a game can raise a system dialog over the stream. Avoid re-requesting permission on every attach.
- A display capability change (an HDMI hotplug that changes HDR support) can recreate the activity and drop the stream unless `configChanges` covers it.
- Writes from several threads to a crash marker file need a lock, or a later crash is blamed on the wrong step and the app changes settings it should not.
- The release signing key in the repo was flagged as a risk: anyone can sign an APK that installs over the real app. Do not rely on it for anything security related.

## Desktop app (`desktop/`)

An Electron app (Node 22) for Windows and Linux. `main.js` and `preload.js` are the Electron shell; `app/index.html`, `app/style.css` and `app/js/*.js` are the client: `api.js`, `cloudmatch.js`, `signaling.js`, `sdp.js`, `stream.js`, `player.js`, `input.js`, `cursor.js`, `state.js`, `ui.js`, `http.js`. `test/e2e.cjs` is the end to end test CI runs on both platforms.

`desktop/app/js/input.js` is the reference encoder for mouse and keyboard records; the tvOS input tests check their bytes against it.

Lessons from the desktop work (some from the earlier Qt based Cloudlight desktop app):

- Windows' default timer resolution of about 15 ms made the mouse jumpy. Use 1 ms timers.
- Read the mouse off the UI thread, and draw a local cursor so the pointer never waits on the stream.
- Text rendered into a scaled layer looked pixelated at 125 and 150 percent Windows scaling. Draw text as vectors at final size, and test at those scales.
- In the in game menu (Ctrl+G), a click on a submenu reached the dimmed game behind and closed the menu. Overlays must swallow every click they receive. This failed twice before it was fixed; reproduce on a Windows build rather than assuming.
- No whole page zoom transitions, no 1 px borders, no thin fonts. The same visual rules as tvOS apply (see 07).
- No "OpenNOW" anywhere in the user interface, including About and update lines.
- Raw store enum values must be handled carefully: NONE and UNKNOWN are publisher launchers and must stay launchable (see 04), even if a store count or filter list does not show them as stores.

## Kumori Link (`android/link`)

The Android helper that relays controllers to the Apple TV. See 06 for how it works and its lessons, and `docs/kumori-link-protocol.md` for the wire format.

Files, under `android/link/src/main/kotlin/app/kumori/link`: `LinkActivity.kt` (the screen), `Relay.kt` (the UDP relay and Bonjour), `Pads.kt` (controller state, rest point learning, dead zone), `usb/` (the userspace USB driver for dongles the kernel does not know), `PadView.kt` (the live controller drawing), `LogServer.kt` and `LogBook.kt` (the log page on port 47821).

Its interface follows the same design rules as tvOS: black, monochrome, system style glass where available, no pills or outlines.
