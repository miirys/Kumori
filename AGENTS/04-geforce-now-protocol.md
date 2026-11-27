# 04. How GeForce NOW works, as far as Kumori knows

None of this is documented by NVIDIA. It was learned from the official clients, from OpenNOW's clients, and from many failed launches on real hardware. When something here stops being true, see 11, and update this file.

## The services

| Service | Address | Used for |
| --- | --- | --- |
| Sign in | `login.nvidia.com` (`/device/authorize`, `/token`, `/client_token`) | Device code sign in, token renewal |
| Service URLs | `pcs.geforcenow.com/v1/serviceUrls` | Which session service (region) the account uses |
| Catalog | `games.geforce.com/graphql` | Library, store rails, game details, art |
| Subscription | `mes.geforcenow.com/v4/subscriptions` | Membership tier, allowed modes, hours left (`remainingTimeInMinutes`) |
| Session service | `prod.cloudmatchbeta.nvidiagrid.net` and the regional addresses it names | Create, poll, claim (resume), end sessions |
| Region ping | the regions' `v2/serverInfo` (no sign in needed) | Latency per region |
| Play history | `api-prod.nvidia.com/gfn-paywall-api/api/v2/userplaytime/sessionshistory` | Past sessions for the Playtime page (not working yet, see below) |

## Signing in and tokens

Sign in uses the device code flow: the TV shows a code and a link, the player approves on a phone or computer, and the TV polls `/token` until it gets tokens.

- `access` and `id` tokens last about a day. The `client` token is long lived and renews them. A `refresh` token is not always given to device sign ins, so renewal tries the client token first, then the refresh token, under each client id the sign in may belong to.
- GFN services take the ID token while it is valid, otherwise the access token.
- A 401 before a token's expiry (revoked, or the TV's clock is off) means: renew and send the request once more. Do not fail the launch or show "sign in expired" for it.
- A 5xx from the sign in service is not a reason to sign the user out. An early version signed users out on any server error, which logged people out during NVIDIA outages. Only a definite refusal of the client token signs out.
- Tokens live in the keychain (`Keychain.swift`). They never go into logs, the local API, crash reports or user defaults.

## Client identities and routes

GFN keeps a separate list of allowed stream sizes for each kind of client. The same account gets different answers depending on who Kumori says it is. `RequestIdentity.swift` defines them:

- `web`: Chrome on a PC. Asked on the wire as the TV client (see `wire`).
- `tv`: the smart TV web client. NVIDIA lists it up to 4K, but in practice it is held to 1080p at 60 fps.
- `desktop`: the PC app's identity with the stream over WebRTC.
- `native`: the PC app's identity with the native NVST stream (RTSPS control and SRTP media), the way the official PC app streams.

What was proven on real Apple TVs:

1. The TV client over WebRTC gets its offer and streams reliably, but always at 1920 by 1080 and at most 60 fps, even when 4K or 120 fps is asked for. The server accepts the request and then quietly streams 1080p60.
2. The PC client identity over WebRTC gets signed in and then receives only heartbeats. The rig never sends an offer. Do not try this route again without new evidence.
3. The PC client identity with the native NVST stream gets 4K60 and 1440p120 on an Apple TV. This is how OpenNOW's tvOS client streams, and Kumori's `NVST` code is ported from it.

So the rule in Kumori is:

- Up to 1080p at 60 fps: ask as the TV client, stream over WebRTC.
- Anything above 1080p, or above 60 fps: ask as the native client, stream over NVST.
- If the native route fails (refused, no picture, handshake error): fall back to the TV client at 1080p60 and tell the player in one plain sentence that the stream fell back and why.

The `transport` of a route decides the receiver. A native session never sends a WebRTC offer, and a WebRTC session has no RTSPS endpoint, so a session must always be played by the receiver that matches how it was asked for. Polls, claims and ends must also use the same identity the session was created with.

The same device ids are used for every request one Apple TV makes (as the PC app does), so the session list, the session and the end request all name the same device.

## The mode ladder

When the player picks a mode, Kumori builds a list of modes to try, best first (`ModeLadder.swift`, `NativeRequest.swift`, `RequestIdentity.swift`):

- Native candidates first, for modes the TV client cannot give. 4K is asked at 60 fps at most, because the Apple TV has no 4K 120 Hz output. 1440p keeps 120 fps only where the display chain can show 120 Hz. So a 4K choice tries 4K60, then 1440p120 (if the display allows), then 1440p60.
- Then the TV client's 1080p60, which every membership and every route accepts.

Each size is tried at the chosen rate, then at 60 fps, before going smaller. The service refuses a frame rate with the same codes it uses for a size, so keeping 120 fps on every rung would fail them all.

A native failure is remembered only for the rest of that launch, so the ladder does not try native again on the next rung of the same launch. An earlier version remembered native failures for 24 hours, so one bad launch silently disabled 4K for a day. Do not bring that back.

Default native bitrates (from OpenNOW's tvOS client, unless the player sets one): 50 Mbps for 4K60, 38 Mbps for 1440p120.

## Refusals

When the session service refuses a request, `Refusal.classify` (in `ModeLadder.swift`, with tests) sorts the error code into one of four kinds, and the ladder acts on it:

- Account: about the account or sign in (membership, hours, region, concurrent session and similar codes). Asking another way will not help. Stop and show the reason.
- Mode: the size or rate was refused. Step down to the next rung.
- Server: a failure on NVIDIA's side. Another server, or a smaller mode, often works.
- Other: stop and show it.

Always keep the service's own error code on screen and in the trace. It is the only thing that tells one refusal from another when a player reports a problem.

A queue that wants to show an ad first cannot be served by Kumori. Say so plainly instead of waiting forever.

## The session request

The request body is built in `Cloudmatch.swift` for WebRTC and adapted in `NativeRequest.swift` for native. Important fields:

- `"availableSupportedControllers": [2]`, `"preferredController": 2` and `"appLaunchMode": 2`. These tell the rig that a gamepad is the main input and ask launchers to open their controller friendly view. Without them some games start in mouse and keyboard mode and ignore the pad.
- Whether the game is owned on its store. Unowned games must say false.
- Audio: `requestedAudioFormat` 0 for stereo, 2 for 5.1, 3 for 7.1, with the channel count in `surroundAudioInfo`.
- DLSS overrides (model, quality, ray reconstruction, frame generation) only on a new session and only when something is overridden. A resumed session keeps what it started with.
- The native request uses the PC app's user agent (`NativeRequest.userAgent`).

Session status: 1 is setting up or queued, 2 is ready, 3 is streaming. Once a seat is ready, talk to that rig's own address, not the load balancer.

## Signaling (WebRTC route)

- Sign in to the rig's signaling server with the version 2 sign in that OpenNOW's clients use: `wss://<host>/nvst/sign_in?peer_id=...&version=2&peer_role=1&pairing_id=<session>`. A version 3 sign in was tried; the rig never sent an offer to it.
- Use a new peer name for every sign in. The server drops a peer for good, and signing in again under the old name only returns `peerRemoved`.
- Pick the signaling endpoint the way OpenNOW does: the usage 14 entry with an address, then any usage 14 entry, then a wss entry of usage 16. Add any query and subprotocols the session lists.
- Sign in once and wait. A rig can take more than a minute to start a game. The policy (`SignalingPolicy.swift`) is one 80 second wait for the offer, then 30 seconds from the offer to the first picture, and at most 3 sign ins, each only after a socket actually closed. An earlier design signed in again every 12 seconds and had a separate 30 second watchdog; they fought each other and killed launches that would have worked.

## Picking up a running session (resume)

- Remember how each session was started: route and mode (`Player.remember` and `Player.recall`). Resume it the same way. An earlier version resumed every session as the TV client, which capped a 4K or 120 fps session at 60 fps and gave wrong colours.
- With `adopt`, ask for the size and rate the session is already running at, whatever Settings say, and as the client that size needs. A rig asked to resume at a different mode can fail to come back.
- A session still queued or setting up can only be followed, not claimed. Follow it until it is ready, then claim it.
- If a picked up session gives no picture within 40 seconds, end it once and start fresh at 1080p60. Do not loop.
- While a stream is up, ignore Play or Resume presses that arrive from the browsing screens underneath (they can come through from a controller). The log line says "ignored Play/Resume".

## Ending a session (End Game)

Ending reliably was a long fight. What works (`endForSure` in `Player.swift`, `Cloudmatch` end):

- Send DELETE to the rig that owns the session, then its region, asking as the identity the session was started with, then as the native and the TV client. A session started one way may refuse an end asked another way.
- Retry until the session is gone. A session the server no longer knows counts as ended.
- After the player backs out of a stream, sweep for orphan sessions of this device and end them.
- Right after End, a new launch can get a 403 because the old session is still ending. Wait up to 30 seconds for it to finish ending before starting the new one, instead of showing an error.

## Store names

Each game lists the store or launcher it runs from (Steam, Epic, Ubisoft and so on).

- A raw store value of NONE or UNKNOWN means the publisher's own launcher (a direct launch). It is valid. Never hide, filter or "fix" these games. Doing so once broke launching them.
- Short store names (for example `KUROGAMESLAUNCHER` shown as "Kuro") are only for the small hours caption next to the buttons. The store picker button keeps the full name.

## Hours left and play history

- Hours left come from `mes.geforcenow.com/v4/subscriptions`, field `remainingTimeInMinutes`.
- Play history is meant to come from `userplaytime/sessionshistory` with `subType=TIME_CAPPED`, `spanStartDate`, `spanEndDate`, `locale` and paging parameters. NVIDIA's account website sends the ID token in an `idtoken` header. Kumori asks one calendar month at a time, splits a span that returns 400, and tries both header and parameter variants. So far every request from the app has returned 400, and this has not been confirmed working on a device. The `/playtime` API endpoint shows each request's status and the service's `errorCode`. If you work on this, start there, and capture what the official website sends.

## Region ping

Region latency uses each region's unauthenticated `v2/serverInfo`. It needs no sign in, so it can run before the user signs in.
