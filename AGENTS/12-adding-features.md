# 12. Adding features

## Before you start

1. Read the topic files for the area (see the table in README.md). Most areas have rules that are not visible in the code.
2. Check 10 for bugs in the same area. Many features broke something that had been fixed before.
3. Decide where the logic goes. If a decision can be a pure function (no UIKit, no network), put it in `tvos/Kumori/Launch` (launch and stream decisions) or `Stream/PadLogic.swift` (input decisions) and test it. Pure logic runs in CI in seconds, on Linux, without a simulator.

## Adding a setting

- Add it to `App/Settings.swift`, stored in user defaults, with a sensible default.
- Put it in the right Settings group (Streaming, Input or General) in `UI/SettingsView.swift`. Name it so it needs no explanation. No helper sentence describing what it technically does.
- Show its current value under the rail item if it is a group's main choice.
- Add it to `/settings` in `APIReport`. `/settings` is documented as every setting, and was once missing several.
- A setting that changes the session request must be honoured on resume only if the session allows it. A resumed session keeps the mode and DLSS settings it started with.
- If it affects the stream, show it in the detailed stats or `/session` so testers can see it took effect.

## Adding a screen

- Build it from the design system in `UI/Design`. Use `TVPage` for pages with the safe edge, `TVStatusView` for loading, empty and error, the system glass for buttons, `tvSurface` for panels.
- Add a fixture for it in `Fixtures/` so it can be checked in the simulator and photographed by CI. Fixtures are Debug only.
- Add focus tests in `tvos/KumoriUITests` if it has non trivial focus. Check that Back works with both the Siri Remote and a Kumori Link controller (`.onBack(perform:)`).
- Check it at the largest text size and with Reduce Motion and Reduce Transparency.
- Make sure focus lands somewhere sensible when it opens, and returns to where it came from when it closes.

## Adding an animation

- Read 08 first. Use springs, follow the chain pattern for sequences, make it interruptible and exactly reversible.
- Name it in `UI/Design/TVMotion.swift` if it is reusable.
- Honour Reduce Motion.
- Check it at 120 Hz if the TV can do it, and on the slowest supported Apple TV.
- Make sure it stops all work when it is at rest and when it is off screen (see 09).

## Adding a local API endpoint

- Add the path and a one line description to `LocalAPI.endpoints`, the handler to the switch in `LocalAPI.swift`, and the report to `APIReport`.
- GET only, local network only, no secrets, non finite numbers turned into null.
- Document it in 03.

## Adding a log line

- Use the existing subsystem and the right category. Add a new category only for a new area, and list it in 03.
- Notice level or higher if a tester needs to see it on a device.
- Mark safe values public, and never log secrets (see 03 and 14).
- Rate limit anything that can happen per packet or per frame.

## Adding a stream feature

- Decide which routes it works on. Some features exist on one route only (rumble is native only). Say so in the interface rather than offering something that silently does nothing.
- Check both engines, WebRTC and native, and both pickup paths, new session and resume.
- Make sure the end of the stream cleans up: motors stop, the screen saver is released, the HDMI mode is restored, controllers return to the interface.

## Adding a Kumori Link feature

- Change `docs/kumori-link-protocol.md` first, keeping the protocol backward compatible (new packet types, not changed ones). Bump the protocol version only if old boxes cannot work with the new app.
- Change both ends: `android/link` and `tvos/Kumori/Stream/KumoriLink.swift`.
- Link has its own version numbers. Bump `versionName` in `android/link/build.gradle.kts`, and name the APK in the release notes when releasing with `tvos-and-link`.

## Finishing

- Read 13 as a checklist.
- Update this guide (see "Keeping this guide up to date" in README.md).
- Add release notes in player language when the change ships.
