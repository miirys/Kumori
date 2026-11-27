# 05. The stream: picture, sound, native NVST, frame pacing and HDMI modes

Kumori has two stream engines, chosen by the route (see 04):

- WebRTC (`Stream/StreamEngine.swift`) for the TV client route, up to 1080p60.
- Native NVST (`Native/` and `NVST/`) for the PC client route, above 1080p or above 60 fps.

Both put their frames on screen through `Stream/PictureView.swift`.

## Putting frames on screen

`PictureView` shows frames with `AVSampleBufferDisplayLayer`, the layer Apple's own players use on Apple TV. It replaced WebRTC's Metal view for a reason worth remembering: a 4K launch once decoded video (the stats showed decoded frames and the stream went live) but the screen stayed black. WebRTC's Metal view only draws 8 bit NV12, BGRA and I420, compiles its shaders on the device, and silently skips any frame it cannot draw. The sample buffer layer takes whatever VideoToolbox decodes, in any bit depth or range. A frame that lives in WebRTC's own memory is copied into a pixel buffer from a pool.

Lesson: if the stats say frames are decoded but the screen is black, the problem is between the decoder and the layer, not the network.

## Frame pacing

Native frames are shown on the display's own beat:

- A display link ticks once per refresh, on its own thread, and shows the newest waiting frame. Always show the newest frame and drop older ones that missed their refresh. Showing every frame in order builds up delay.
- The display link must be asked for the stream's rate. A display link left at the system's default rate may tick slower than the HDMI mode, and every skipped tick drops a frame from the small queue. That once made a 120 fps stream show at 60 to 100.
- If a frame is still waiting at the end of every refresh for a whole second, that is standing delay, not a burst being smoothed. The pacer then skips one frame to catch up.
- Count frames shown and frames dropped by the screen separately from frames dropped by the decoder. The stats and the low frame rate notice use them to say where the problem is (see 03).

## The native NVST receiver

The receiver in `tvos/Kumori/NVST` is ported from OpenNOW's tvOS client (MIT). `Native/NativeStream.swift` is Kumori's driver for it: it takes Kumori's session and options, sends Kumori's controller state, and leaves out OpenNOW's iOS only paths (touch, HID and DualSense passthrough, microphone).

The handshake is RTSPS (OPTIONS, DESCRIBE, SETUP, ANNOUNCE, PLAY) to the control endpoints the rig advertises. Connect to exactly the endpoints the session lists. Never assume or rewrite an address. Media then comes over SRTP. `LaunchTrace` records each handshake step, so a failed native launch shows how far it got.

Fixes that made native streams smooth. Keep them:

- Announce a video QoS (VQOS) maximum bitrate of at least 100 Mbps (the official client's figure) and never below twice the target. When the ceiling equalled the starting target, the rate control had no headroom: one 0.1 percent loss burst throttled a 50 Mbps 4K60 stream to about 29 Mbps with micro stutters, and it never recovered.
- In the QoS feedback, `linkCapabilityKbps` is a flat capability class, not a measurement. Reporting measured throughput there closed the rate control loop and starved the stream. Send the official client's flat figure.
- NACK (asking the rig to resend lost packets): wait a 4 ms reorder grace before asking, then keep the gap open for grace plus round trip plus a margin, capped at 200 ms. A gap used to be given up 80 ms after it was seen whatever the round trip, so on any path above about 70 ms a resent packet could never arrive in time, the frame was lost and cost a keyframe.
- When a frame is lost for good, ask for a keyframe. A picture loss indication on a feedback channel that is not open can be silently discarded; the rig also accepts an explicit IDR command on its reliable control channel.
- When VideoToolbox rejects a frame and the decoder session is rebuilt, re-arm the "wait for the first keyframe" gate. Decoding delta frames into a fresh session with no reference frames put garbage on screen until the next keyframe.
- Frame acks to the rig's frame pacer must take their frame number and counters inside the lock. Two decode completions once sent acks with the same frame number.
- Before switching resolution or frame rate mid game, wait for the old native stream's RTSPS TEARDOWN (and a short settle) before claiming the session again. Otherwise the old stream's teardown tore down the new one.
- Native mouse input goes on the control channel. It was once not sent at all because the call was missing.

Native video formats are announced as "8bit_420", "10bit_420", "8bit_444" or "10bit_444". Audio channels are 2, 6 or 8. Sizes larger than a few megabytes per access unit occur on 4K keyframes at high bitrates. Size the reassembly limits for that, or big keyframes are dropped and requested again in a loop (this happened on Android).

## Codecs

- H.264 and HEVC decode through VideoToolbox on every supported Apple TV.
- AV1 decodes in hardware only on Apple TV models whose chip supports it. `Stream/AV1Decoder.swift` builds the decoder from the sequence header that every keyframe carries. WebRTC hands over one temporal unit per call, in low overhead OBU format; strip temporal delimiters before handing it to VideoToolbox.
- Log only the first few decode failures of a stream, at notice level, so a broken stream does not flood the log.

## Sound

- WebRTC's audio source volume is a gain where 1.0 is normal. An early version set it to 10, which boosted audio about 20 dB and made it clip. Keep it at 1.0 or below.
- 5.1 and 7.1 are requested through the session request (see 04). Check `AVAudioSession` for the output's channel count before offering surround.

## HDMI output at 120 Hz

tvOS has no public way to switch the HDMI output to 120 Hz. `AVDisplayCriteria` asking for 120 Hz leaves the display at 60 Hz. But the newer Apple TV 4K does list 120 Hz modes below 4K (2560 by 1440 and 1920 by 1080), and QuartzCore's private `CADisplay` can switch to them (`TVOut`, `availableModes`, `setCurrentMode`). This was found by u/Lacrowx on r/appletv and follows their OpenNOW port. It was first declared impossible by an earlier agent and later proven to work. Do not declare platform limits without trying.

How `App/HDMIMode.swift` does it, and why:

- Every private call is checked at runtime first, so a tvOS that renames them just stays at 60 Hz. It only works in sideloaded builds.
- tvOS keeps a mode set this way even after the app quits or crashes. So the TV's own mode is saved first (`hdmiModeToRestore`) and put back when the stream ends, when the app goes to the background, and at the next launch if the app died while holding a mode.
- Put back only the exact saved mode. Falling back to the display's "preferred" mode once picked 4K at 50 Hz and left the whole interface running at 50 frames a second, which made Home feel laggy. `keepInterfaceAtSixty` and `sixty(like:)` exist for the same reason: the interface should never be left in a 50 Hz mode by Kumori.
- Read the interface's mode at launch and on coming back to the foreground, before any stream. By the time a stream asks for 120 Hz, the system may already have taken the TV out of HDR for the picture, and handing back that moment's mode left the interface in SDR after every 120 fps stream.
- Do the 120 Hz switch on its own, without also setting `AVDisplayCriteria`, while `HDMIMode.holding` is true, and keep the system's own frame rate matching off meanwhile, so it does not ask for a different mode on top of Kumori's.
- The TV does not always take a mode, for example when the system is switching it out of HDR at the same moment. Look again after about 2.5 seconds, once it has re-synced, and ask again, up to 3 times.
- While the TV re-syncs after a switch, it lists no modes for about a second. Do not read that as "no 120 Hz".
- Pick the widest SDR mode at the stream's rate that is not wider than the stream. A 4K stream at 120 fps gets 1440p120, the largest 120 Hz mode the box offers.
- Do not switch back while the stream screen is closing. A mode change during the dismissal stalled it, and the app sat on a frozen frame with nothing focused. Switch back once the stream screen has gone (`streamScreenClosed`), or after a few seconds if it stays up. After the TV re-syncs, make sure something on screen has focus again.

The display chain matters. Some receivers and HDMI 2.0 links pass 1080p120 but not 1440p120. Settings has a 120 Hz test that holds the TV in a 120 Hz mode for a few seconds and times the real refresh rate (`DisplayProbe`). `DisplayChain` reads what the chain offers and explains what to change when 120 Hz or HDR is missing. When a player reports "120 fps but it looks like 60", check `refreshHz` in `/stats` and the chain in `/device` first.

## HDR

The interface's HDR or Dolby Vision mode is the player's choice and must come back after every stream. See the HDMI notes above about reading it before the stream starts. The native stream can carry 10 bit video; the picture path must keep the frame's colour information through to the layer.

## Low frame rate notice

`StreamSafety` decides when a stream is below what it was set up for (below 90 percent of the expected rate for 5 seconds) and why:

- the TV's refresh is lower than the stream's frame rate,
- frames arrive slower than asked (network or rig), or
- frames arrive but this Apple TV does not get them all on screen.

The notice shows for about 5 seconds, at most once a minute, in natural words with the numbers in them. These numbers were tuned on purpose. Do not make the notice louder, longer or more frequent.

## Keeping the TV awake and leaving cleanly

- A stream keeps the screen saver off from start to end, and releases it when the stream ends, including on the "stream stopped" screen. Leaving the screen saver blocked on an error screen is an OLED burn in risk.
- When the app goes to the background mid stream (the player pressed the TV button), leave the stream properly and end or release the session, instead of freezing with the rig still holding the last controller state.
