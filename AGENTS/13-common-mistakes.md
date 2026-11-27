# 13. Common mistakes and small details that matter

Read this as a checklist before you finish a change. Every line here cost someone time.

## Claims and testing

- Saying a fix works before it ran on a real device. Write "built, not tested on a TV yet" until it has.
- Testing streaming or input in the simulator and calling it tested. The simulator cannot stream, switch HDMI modes or read real controllers.
- Trusting the requested mode. Check the decoded size and `refreshHz`. GFN accepts a request and streams something else.
- Reading the commit hash on the TV and thinking the wrong build is installed. A PR build carries GitHub's merge commit hash.
- Logging at info level and wondering why the line never shows in the device log. Use notice or higher.
- Declaring something impossible early. 120 Hz output was called impossible and then shipped.

## GeForce NOW

- Filtering out NONE or UNKNOWN store values. They are publisher launchers. Launches break.
- Shortening the store name on the store button. Short names are only for the hours caption.
- Resuming a session as a different client than it was started with.
- Ending a session with one request and assuming it worked.
- Remembering a route failure across launches.
- Adding a re sign in timer to signaling.
- Treating a 5xx as a reason to sign out.
- Hiding the service's error code from the error screen.

## Display

- Changing the HDMI mode while a screen is being dismissed.
- Restoring a mode other than the exact one that was saved.
- Reading the mode to restore after the stream has started.
- Setting `AVDisplayCriteria` while Kumori holds a 120 Hz mode.
- Leaving a display link at the system's default rate.
- Calling an API without checking a new tvOS still has it.

## Input

- Resetting gamepad sequence numbers on reconnect.
- Sending Start when Menu goes down instead of deciding tap or hold first.
- Letting the button that closed a menu reach the game.
- Using `.onExitCommand` instead of `.onBack(perform:)`, so Link's B does nothing.
- Letting B on the root screen close the app.
- Reading a network packet before checking its length.
- Capping stick vectors to the unit circle.

## Interface

- Adding `TVTokens.safeX` inside a full screen view that is not in `TVPage`. Text lands at 160 pt.
- Putting `accessibilityIdentifier` on a container.
- Showing a fallback title behind loaded art.
- Scaling Home behind a page.
- Adding an outline, a pill, a dot, a glow, a thin font or a hairline.
- Writing helper sentences, fun facts, em dashes, middle dots or marketing words in the interface.
- Adding a row without checking that the column still fits at the largest text size.
- Using hand made glass instead of the system's.
- Letting a screen show "Nothing found" while it is loading, or replacing content with a spinner.
- Opening a page while the previous one is still being dismissed.
- Leaving a screen with nothing focused. On tvOS, Back then leaves the app.

## Motion

- Sequencing with timers or delays instead of chained springs.
- An animation that takes a different path back, or snaps at the end.
- Two drivers stepping the same frame.
- No backstop when the display link stops.
- Fading during the slow creep at the end of a critically damped spring, which reads as a wait.
- Forgetting Reduce Motion.

## Performance

- Blurring, decoding or sorting per frame or per redraw.
- Animating forever in SwiftUI instead of Core Animation.
- Fetching every card's wide image instead of only focused ones.
- Publishing an unchanged list, which redraws everything watching it.
- Compiling shaders on first use on the main thread.

## Build and release

- Referencing fixture code from code that ships. The Release check fails.
- Putting Apple only code in `tvos/Kumori/Launch`. The Linux test job fails.
- Forgetting `docs/release-<version>.md`, or not naming `KumoriLink-<version>.apk` in it for a `tvos-and-link` release.
- Versions in the source files not matching the release input.
- Trying to push a tag by hand instead of dispatching the Release workflow.
- Editing the symlinked copies in `tvos/InputTests/Sources` thinking they are separate files. They are the app's own files.
- Waiting for the 25 minute simulator job before installing. The IPA is ready when Build IPA is green.

## Privacy and secrets

- Logging a token, session id, email, IP address, full SDP or anything from an auth response.
- Copying `Cache.db` off a device.
- Committing a personal Apple team suffix, device id, home network address or account detail.
- Putting a person's name, devices or setup into the interface, docs or commits.
