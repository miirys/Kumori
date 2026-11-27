# 01. The project: what it is and where things live

## What Kumori is

Kumori is an unofficial client for NVIDIA GeForce NOW (GFN), the cloud gaming service. It signs in with a GFN account, shows the account's game library, starts a cloud session on one of NVIDIA's servers (a "rig"), and plays the stream on the TV with a controller.

It is not made by or affiliated with NVIDIA. It talks to the same web services the official clients use, which are not documented and change without notice. Most of the hard work in this project has been finding out how those services really behave. That knowledge is in 04 and 11.

## Where it came from

Knowing the history explains several odd corners of the code.

1. OpenNOW. The project started as work on a fork of OpenNOW, an open source GFN client with a Qt/QML desktop app and Rust parts.
2. Cloudlight. That fork became Cloudlight: an Android TV rewrite plus a restyled Windows and Linux desktop app. Many desktop and Android lessons date from here (see 15).
3. Kumori. The project was then split into its own repo and renamed Kumori. The Android TV app was carried over and continued for a while. The Apple TV app was then written and became the main focus. The Android TV app is no longer developed; its last release is 1.2.1.

The native NVST receiver for tvOS (the code in `tvos/Kumori/NVST`) is ported from the tvOS client in Lacrowx/OpenNOW, which is MIT licensed. The private HDMI mode switching technique also came from that work. Keep their license files and credit in `THIRD_PARTY_NOTICES.md`, `tvos/Kumori/NVST/LICENSE`, `tvos/Kumori/NVST/Licenses` and `tvos/Kumori/NVST/UPSTREAM.json`.

## Status of each part

| Part | Folder | Status |
| --- | --- | --- |
| Apple TV app | `tvos/` | Main app, actively developed |
| Kumori Link | `android/link` | Small Android helper that relays USB controllers to the Apple TV. Maintained alongside the tvOS app |
| Android TV app | `android/app` | Frozen. Keep it building, but new features go to tvOS |
| Rust NVST library for Android | `android/nvst` | Used by the Android app only |
| Desktop app | `desktop/` | Electron app for Windows and Linux. Builds in CI, low activity |

## Repo layout

```
AGENTS/              this guide
README.md            user facing readme
THIRD_PARTY_NOTICES.md
assets/              brand art used by README and the apps
docs/                release notes (release-<version>.md), kumori-link-protocol.md, tvos-controllers.md
android/             Android TV app, Kumori Link (android/link), Rust NVST (android/nvst)
desktop/             Electron app: main.js, preload.js, app/ (index.html, style.css, js/), test/e2e.cjs
tvos/                the Apple TV app (below)
.github/workflows/   android.yml, desktop.yml, release.yml, tvos.yml, tvos-input.yml, tvos-simulator.yml
```

## The Apple TV app, folder by folder

The Xcode project is not checked in. XcodeGen generates it from `tvos/project.yml`, which includes the `Kumori` folder by glob, so a new Swift file in any subfolder is picked up without touching the project file.

### tvos/Kumori/App

App wide state and services.

- `KumoriApp.swift`: the entry point. Debug builds launched with `-fixture <name>` show a fixture screen instead of the app.
- `AppModel.swift`: the signed in account, the library, the current session, play history.
- `Player.swift`: everything between pressing Play and the stream ending. Picks the route, runs the mode ladder, starts the native or WebRTC engine, ends sessions, resumes sessions, remembers how each session was started. It is the biggest and most delicate file. Read 04 before changing it.
- `Settings.swift`: user settings, stored in user defaults.
- `HDMIMode.swift`: switching the HDMI output to 120 Hz and back (see 05).
- `DisplayChain.swift`, `DisplayProbe.swift`: what the HDMI chain allows, and what rate it is really running at.
- `LocalAPI.swift`, `APIReport.swift`: the read only HTTP API on port 8090 (see 03).
- `StreamHistory.swift`: the last 50 streams and the current stream's stats samples.
- `LogReport.swift`: saved log reports, served by the local API.
- `Awake.swift`: keeps the screen saver away while a relayed controller is used, and the focus click sound for Link moves.
- `Keychain.swift`: token storage.

### tvos/Kumori/Launch

Pure logic with Foundation only, so it can be unit tested on Linux without a simulator. If you can express a launch decision as a pure function, put it here and test it.

- `ModeLadder.swift`: the order modes are tried in, and how a refusal is classified (account, mode, server, other).
- `RequestIdentity.swift`: which client Kumori says it is (web, TV, desktop, native), how that is put on the wire, and which receiver it needs.
- `NativeRequest.swift`: turns the WebRTC session request into the native NVST client's request.
- `SignalingPolicy.swift`: the timers for waiting on the rig's offer and the first picture.
- `StreamSafety.swift`: the low frame rate judgement and the idle timer.
- `LaunchTrace.swift`: a safe record of each launch's steps, for the error screen, About and the API.
- `BuildInfo.swift`, `KeyText.swift`, `SignIn.swift`, `SignalingEnvelope.swift`.

Tests are in `tvos/Tests/KumoriLaunchTests`, run by `tvos/Package.swift`.

### tvos/Kumori/Net

Talking to NVIDIA's services.

- `Nvidia.swift`: sign in and token refresh.
- `Cloudmatch.swift`: creating, polling, resuming and deleting sessions.
- `Playtime.swift`: hours left and play history.
- `RegionPing.swift`: server region latency.
- `Models.swift`, `JSON.swift`, `HTTP.swift`, `SessionLog.swift`.

### tvos/Kumori/Stream

The WebRTC stream and input.

- `StreamEngine.swift`: the WebRTC stream, using a pinned LiveKit WebRTC xcframework.
- `Signaling.swift`, `SDP.swift`: the signaling socket and SDP munging.
- `PictureView.swift`: puts frames on screen with `AVSampleBufferDisplayLayer`, for both engines, and paces native frames.
- `AV1Decoder.swift`: hardware AV1 through VideoToolbox.
- `Gamepads.swift`, `PadLogic.swift`, `InputEncoder.swift`, `PadRumble.swift`, `ControllerCenter.swift`: controllers (see 06).
- `KumoriLink.swift`, `LinkNavigator.swift`, `LinkBack.swift`: Kumori Link on the tvOS side (see 06).

`PadLogic.swift`, `InputEncoder.swift` and `Launch/KeyText.swift` are also symlinked into `tvos/InputTests/Sources/KumoriInput`, a small Swift package with byte level input tests. Edit the originals; the symlinks follow.

### tvos/Kumori/Native and tvos/Kumori/NVST

- `Native/NativeEngine.swift`, `Native/NativeStream.swift`: Kumori's driver for the native NVST stream.
- `NVST/`: the protocol modules ported from OpenNOW (RTSPS handshake in `Rtsp`, packet handling in `BifrostFree`, decoding in `Video`, plus `Native` and `Handoff`). They need OpenSSL and usrsctp xcframeworks, built by `tvos/scripts/build-nvst-libs.py`. CI caches them.

### tvos/Kumori/UI

- `RootView.swift`: tabs and the main screens.
- `Browse.swift`: Home, Library and Search.
- `GamePage.swift`, `GamePageMotion.swift`: a game's page and its spring driven open and close (see 08).
- `SettingsView.swift`, `KumoriLinkSection.swift`, `PlaytimePage.swift`, `DebugPage.swift`, `DebugTools.swift`, `ControllerStatusView.swift`.
- `StreamView.swift`, `StreamKeyboard.swift`, `EndSessionConfirmation.swift`: the in stream screens.
- `Theme.swift`.
- `Design/`: the design system pieces. `TVTokens` (sizes and spacing), `TVMotion` (named animations), `TVArtwork`, `TVLockups`, `TVExpandingCard` (Home cards), `TVAmbient` (blurred game art background), `TVGlowBackdrop` (Settings light), `TVPanels`, `TVPowerGlyph`, `TVStatus`, `BrowseMemory`, `GeneratedArt`.

### tvos/Kumori/Fixtures

Synthetic screens for screenshots and UI tests. Debug builds only. CI checks that the Release binary contains no fixture symbols, so never reference fixture types from code that ships.

### Other tvOS folders

- `tvos/KumoriTests`: unit tests that need the app (design tokens, fixtures, native stream, browse memory).
- `tvos/KumoriUITests`: focus tests, Link navigation tests, screenshot capture.
- `tvos/scripts`: `build-nvst-libs.py`, `capture-fixtures.sh`, `find-simulator.sh`, `make-brand-assets.py`.
- `tvos/DESIGN-SYSTEM.md`: the original design rules. Parts of it are outdated; 07 and 08 say which.
