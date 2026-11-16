Adds Kumori for Linux and Windows. The Android and Apple TV apps are unchanged apart from the version.

## Files

- `Kumori-1.2.0-windows-setup.exe` and `Kumori-1.2.0-windows-x64.zip` for Windows 10 and 11 (64-bit)
- `Kumori-1.2.0-linux-x64.AppImage` and `Kumori-1.2.0-linux-x64.tar.gz` for Linux (64-bit)
- `Kumori-1.2.0.apk` for Android TV and Android
- `Kumori-1.2.0-tvos-unsigned.ipa` for Apple TV (tvOS 17 or newer)

Nothing here is signed. Windows SmartScreen asks once (More info, then Run anyway). The AppImage needs `chmod +x` and FUSE 2. The Apple TV build has to be sideloaded.

## Linux and Windows

- Mouse and keyboard layout: sidebar, search, wheel scrolling, arrow keys, Tab, Enter and Esc
- Optional gamepad layout (Settings, Layout) with the big tiles from the TV apps. The mouse keeps working in it
- Streams over the same route as GeForce NOW in a browser, with H.264, H.265 or AV1, up to 240 fps. 16:9 and ultrawide sizes up to 4K. 4K asks for the PC app's size list and steps down to 1440p if the rig refuses
- Resolution, frame rate, bitrate, codec, server region and DLSS override settings
- Fullscreen with F11, with system keys such as Alt+Tab going to the game while fullscreen
- Reconnects on its own after a network drop, and resumes a session left running
- Ctrl+G opens the in-game menu (Guide, or Back+Start held, on a controller). Up to four controllers
- Stats overlay

## The mouse pointer

The pointer is drawn on your machine, not in the video, so it moves without stream delay. The rig sends each cursor's image and hotspot, and Kumori sets that as the system pointer. When the game hides its cursor for mouse-look, Kumori captures the mouse and sends raw movement, then releases it when the cursor comes back. There are three modes in Settings: System cursor (default), Captured (the mouse stays in the window and Kumori draws the cursor), and Streamed (no local cursor, raw movement only, for games that misbehave).

This uses the cursor channel of the browser route, read from NVIDIA's own web client. Limits that come from the protocol:

- The rig sends cursor shapes and show/hide, and it only reports a position when the game moves the pointer itself. If a game draws its own cursor inside the picture, there is nothing to draw locally and you see the streamed one.
- A game that shows a cursor and also expects raw movement gets positions in System mode. Switch to Captured or Streamed for those.

## Not tested

Tested here: the packaged Linux and Windows apps run in CI against a stand-in rig that speaks the same signalling, input and cursor formats. That covers the library, video playback, keys, mouse buttons and wheel, cursor shapes with hotspots, capture and release, and ending a session.

Not tested: a real GeForce NOW session, on any platform. No account was available. So sign-in, queueing, hardware H.265 and AV1 decoding, real games' cursors, 4K, and controllers on real hardware are unverified.

Missing next to the official apps: microphone, controller rumble, HDR, 5K, G-Sync/VRR control, and Steam Deck specifics.
