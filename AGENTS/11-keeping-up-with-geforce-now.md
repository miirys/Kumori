# 11. Keeping up when GeForce NOW changes

GeForce NOW's services are private and change without notice. The official clients update silently, and an unofficial client finds out when something breaks. This file is how to find what changed and fix it without guessing.

## First, find where it stops

Do not start by changing code. Find the exact step that fails.

1. `/launch` on the local API shows the last launch step by step and the furthest step it reached (`LaunchTrace`). The steps run from the session request through queueing, seat ready, signaling sign in, offer, ICE, the native RTSPS handshake and PLAY, to the first picture.
2. The error screen and About show the same trace, and the service's own error code. A player can photograph it.
3. The device log, at notice level, in the `launch`, `session`, `signaling` and `native` categories.
4. `/session` shows which route and transport were used and what mode was asked for and given. `/account` shows the modes the plan allows.

What each failure point usually means:

| Stops at | Likely cause |
| --- | --- |
| Sign in or token renewal | Login service changed a client id, a grant or a required header |
| Session request refused | A new required field, a changed error code, a membership rule, or a changed client identity check |
| Queued forever | A new queue condition (ads, priority) the app does not read |
| Seat ready, no signaling | Signaling endpoint selection changed (usage numbers, path, query, subprotocol) |
| Signed in, no offer | Sign in version or peer naming changed, or the identity is no longer served over WebRTC |
| Offer, no picture | SDP or codec negotiation changed, or ICE candidates changed shape |
| RTSPS handshake fails | NVST protocol change on the native route |
| Picture but input ignored | Input protocol version or framing changed |

## Then, compare with a client that works

The reference implementations, in order of usefulness:

1. NVIDIA's own clients: the browser client at play.geforcenow.com, whose requests can be read in the browser's developer tools, and the PC app.
2. OpenNOW and its forks (the desktop, Android, macOS and tvOS clients). They track the same services, are open source, and are often fixed first. Kumori's native receiver came from OpenNOW's tvOS client, so its upstream commit is recorded in `tvos/Kumori/NVST/UPSTREAM.json`. Compare against newer upstream commits when the native route breaks.
3. Kumori's own Android app (`android/`), which used the same services and has its own working code for several of them.

Compare field by field: URL, method, headers (user agent, origin, client ids, device ids), body keys and their types, and the order of steps. Most breakages so far were a single field or header.

## Rules while fixing

- Change one thing at a time and test it on a device. Several changes at once make it impossible to know which one worked.
- Keep the old behaviour as a fallback when you can, if the new one is not proven. GFN sometimes rolls changes out by region or account.
- Record the finding in 04 the moment it is confirmed, including the evidence (which build, what the server answered). Mark guesses as guesses.
- Add the new decision to the pure logic in `tvos/Kumori/Launch` with a test, so the next change is caught by CI rather than by a player.
- Keep the error code visible. A refusal that shows only "Something went wrong" cannot be diagnosed from a photo.
- Never log tokens, session ids or addresses while investigating. Use `LaunchTrace`'s safe values or counts and shapes (field names, types, status codes) instead of contents. `/playtime` is an example: it records the status, NVIDIA's error code and the shape of the answer, nothing else.

## Things most likely to change

- Client identities: which identity gets which modes, user agents, client version strings in `NativeRequest.userAgent`.
- Error codes in `Refusal.classify`. New codes default to "other", which stops the launch. If a new code should step down instead, add it with a test.
- The catalog's GraphQL queries and field names (art keys, store names). An unknown store value must still be shown, never dropped.
- Session request fields, especially controller, DLSS and audio fields.
- The signaling and NVST protocols, rarely, and usually first seen in OpenNOW.

## When Apple changes tvOS

- New tvOS versions remove APIs. tvOS 27 removed `UIWindow.avDisplayManager`, and calling it crashed the app. Guard APIs that might disappear, and check every private API at runtime (as `HDMIMode` does).
- Liquid Glass and new materials arrive with new tvOS versions. Keep the fallback for older versions working.
- Retest the 120 Hz path on every major tvOS update. It depends on private QuartzCore calls.
