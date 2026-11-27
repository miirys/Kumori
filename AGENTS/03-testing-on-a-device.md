# 03. Testing on a real Apple TV, logs and the local API

Most of what matters in Kumori (launch routes, frame rate, HDMI modes, controllers) only shows on real hardware with a real GeForce NOW account. The simulator is good for layout, focus and screenshots, and nothing else. Treat every streaming or input change as untested until it has run on a TV.

## Installing

The CI artifact is an unsigned IPA. It has to be signed for the device before it installs. Common ways:

- Xcode on a Mac, with the Apple TV paired. This is the simplest and gives full debugging.
- A sideloading tool. The project has used atvloadly, running in Docker on a Linux machine on the same network, signing with a free Apple ID and re-signing every night (free signatures expire after 7 days).

Lessons from sideloading:

- Use a spare Apple ID for signing, not a personal main account. The tool signs in as if it were a Mac.
- Developer Mode must be on in the Apple TV's settings, or a sideloaded app will not open.
- atvloadly's Apple sign in once failed with HTTP 403 because of the letter case of one identity header (it sent "mac" where Apple expects "Mac"). A one line patch fixed it. If you update the tool from its own web page, a local patch like that is lost and the 403 comes back.
- The tool needs an anisette server (it provides the device identity data Apple's sign in wants). A local anisette container works. An anisette error with HTTP 502 is usually transient; retry once before investigating.
- After an install, check that the right build is on the TV by reading `KumoriCommit` from the app's `Info.plist`, or by asking the local API (`/` and `/device` show the build). Remember that a PR build carries the merge commit hash (see 02).
- An Apple TV without a USB port (the newer models) cannot be reached by tools that need the developer disk image for that model. On those, there is no remote launch, no injected input and no screenshots from Linux tools. Plan testing around the local API and the device log instead, and have a person press the buttons.

## Reading the device log

Kumori logs with `os.Logger`, subsystem `app.kumori.tv`. Categories in use: `api`, `av1`, `controller`, `hdmi`, `input`, `launch`, `link`, `native`, `picture`, `player`, `playtime`, `session`, `signaling`.

The important rule: tools that read the device log over the network (syslog relay, for example through plumesign or idevicesyslog) only receive lines at notice level and above. Info and debug lines never arrive. If you add a log line that a tester needs to see, log it with `.notice` or higher, and mark values `privacy: .public` where they are safe, or they show as `<private>`.

What never goes into a log: access tokens, ID tokens, refresh tokens, session ids, account emails, IP addresses of the rig or the home network, full SDP, or anything read from an auth response. `LaunchTrace` enforces this for launch traces by only accepting compile time literal text and small safe values. Follow the same idea elsewhere.

## The local API

Kumori runs a small read only HTTP server on port 8090 while the app is open, so a tester or an agent can see the app's state from another machine on the same network. It is the main debugging tool on a TV you cannot attach a debugger to.

Rules the API follows. Keep them when you add to it:

- GET only. It never changes state.
- It answers only addresses on the local network (`LocalAPI.local`).
- It never returns tokens, emails, session ids or other secrets.
- Its JSON must be valid even when a number is NaN or infinite (a stat before the first frame, say). `JSONSerialization` refuses NaN, so one bad number would break the whole answer. `APIReport` turns every non finite number into null; route new values through it.

Endpoints:

| Path | What it returns |
| --- | --- |
| `/` | The endpoint list, the app and its version, build and commit |
| `/status` | Signed in, what is playing, time left, idle timer |
| `/stats` | The stream now: frame rate on screen and decoded, target, drops, codec, latency, bitrate |
| `/stats/history` | The current stream, one sample a second, last 10 minutes |
| `/session` | The game playing and how its stream was set up (native or WebRTC, mode asked and mode playing) |
| `/sessions` | Games running in the cloud on this account |
| `/history` | Past streams with their averages and how they ended (left, ended, idle, error, switched) |
| `/games`, `/games/{id}` | The library: id, title, store, last played. Or one game |
| `/settings` | Every Kumori setting |
| `/account` | Plan, play time left, streaming modes the plan allows |
| `/playtime` | The play history requests and what NVIDIA answered (status and shape only) |
| `/device` | This Apple TV, its display, HDR eligibility, thermal state, and the HDMI chain check |
| `/launch` | The last launch, step by step, and the furthest step it reached |
| `/input` | Controllers, Kumori Link and input report counters |
| `/log` | A full report built now, as text |
| `/logs`, `/logs/latest` | Reports saved with Send Log, and the newest one as text |

The list lives in `LocalAPI.endpoints`, which also feeds the API page in Settings, Debug. Add new endpoints there and in the switch in `LocalAPI.swift`, and describe them here.

Stats field names, so you can read them without opening the code: `fps` (shown), `decodedFps`, `targetFps`, `refreshHz`, `averageFps`, `minimumFps`, `averageRttMs`, `framesShown`, `framesDropped` (dropped by the screen), `framesDroppedDecoder`.

How to tell what is wrong from the stats:

- `refreshHz` lower than `targetFps`: the TV is running a slower mode than the stream (a 50 Hz or 60 Hz mode for a 120 fps stream). The HDMI switch did not take. See 05.
- `decodedFps` lower than `targetFps`: frames arrive slowly. The network or the rig.
- `decodedFps` fine but `fps` low, or `framesDropped` rising: the Apple TV is not getting frames onto the screen. A pacing problem. See 05.

## The app container

The app's data container can be copied off the device through house_arrest for debugging (settings, saved reports). Never copy or share `Cache.db` or anything under `Caches`: it can hold cached HTTP responses from the sign in service, which contain tokens.

## Fixtures and the simulator

Debug builds launched with `-fixture <name>` show one synthetic screen with fake data, so screens can be checked without an account. `tvos/scripts/capture-fixtures.sh` captures every fixture screen. The simulator workflow also runs focus tests and uploads screenshots. Use these for layout, text size (for example `-typeSize ax3`), Reduce Motion and Reduce Transparency checks. Fixture screenshots are a good way to show a design change before it reaches a TV.

The simulator cannot tell you anything about streaming, frame rate, HDMI modes, real controllers or GeForce NOW's answers.
