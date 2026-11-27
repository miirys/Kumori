# 06. Input: controllers, the Siri Remote, mouse and keyboard, rumble, Kumori Link

Player facing controller help is in `docs/tvos-controllers.md`. The Link wire format is in `docs/kumori-link-protocol.md`. This file is about how the code works and what went wrong.

## Where the code is

- `Stream/Gamepads.swift`: watches GameController, owns the timers, feeds `PadLogic`, sends reports. Main queue only.
- `Stream/PadLogic.swift`: the decisions, with no GameController or network, so they are tested in `tvos/InputTests` on any machine. Slots, the Menu gesture, held button suppression, who owns input, dead zones, report routing.
- `Stream/InputEncoder.swift`: builds the binary input packets.
- `Stream/PadRumble.swift`: drives controller motors from the game's rumble.
- `Stream/ControllerCenter.swift`: lists controllers for the Controllers page. It only watches.
- `Stream/KumoriLink.swift`, `LinkNavigator.swift`, `LinkBack.swift`: the Apple TV side of Kumori Link.
- `android/link`: the Kumori Link app on Android.

## Getting a gamepad to work in the game at all

A controller that tvOS reads perfectly can still do nothing in the game. Three things were missing at first, and all three are needed:

1. Register the pad. The server only reads a pad after a neutral report on the ordered input channel (`input_channel_v1`, framed as a single lone event) announces it. Send that first, before any state, and again whenever a pad comes or goes. Release a pad that leaves under the old bitmap first, so a held button cannot stick.
2. Set both bits per slot in the connected bitmap. Each slot is two bits: the slot itself (connected) and slot plus 8 (an XInput pad). One controller is 0x0101, not 0x0001. Without the second bit, the rig accepts the packet and silently drops it.
3. Ask for a gamepad in the session request: `availableSupportedControllers: [2]`, `preferredController: 2`, `appLaunchMode: 2` (see 04).

Also:

- Send the idle keepalive every 100 ms, as OpenNOW does.
- Report sequence numbers must keep counting across reconnects of the input channel. Restarting at 1 made the rig drop every report after a reconnect. `InputEncoder` has a reset for a new slot, but it is not used mid stream.
- From input protocol version 3, each record is wrapped with a microsecond timestamp and a framing byte. Before version 3 records are sent bare. The version comes from the server's first message on the input channel; wait for it.
- Use the unordered channel for normal reports (a late report is useless), and the ordered one only when the unordered one is not open.
- Keep counters of reports sent, sent ordered, sent before the server said hello, and refused. They are shown in the stats line and `/input`, and they tell "the pad never reached Kumori" apart from "Kumori sent it and the game ignored it".

Wire values: sticks are signed 16 bit (minus 32768 to 32767) with up positive, triggers 0 to 255, buttons as XInput bits. Map full left to exactly minus 32768; a symmetric multiply by 32767 never reaches it. Anything that is not a number counts as centre.

## Slots

Four player slots. A controller keeps its slot as long as it stays connected, and a new one takes the lowest free slot. Player 2 stays player 2 when player 1 drops out. An early version rebuilt slots from the current controller order on every change and sent no neutral report for the pad that left, which left sticks held and reshuffled players.

## The Menu button

- A short tap of Menu is the game's Start button (pressed, then released after 0.1 s).
- Holding Menu for 0.6 s opens Kumori's menu, and the game never sees Start. An early version sent Start as soon as Menu went down, so most games opened their own pause menu underneath Kumori's.
- A press that began while Kumori's menu was open belongs to the menu, even if the menu has closed by the time it is released.
- Buttons held at the moment the game gets control back are kept from the game until released. Without this, the A that pressed Resume or the B that closed the menu reached the game as a fresh press.
- On the Siri Remote, Back opens the menu. The TV or Home button always works as normal.
- The in stream menu must always open with something focused. With nothing focused, Back travels up the responder chain and sends the app to the Home screen.

## Dead zones and drift

- A resting stick is never exactly centred, and the leftover tilt reached the rig as real input: the camera crept on its own. The game path uses a radial dead zone of 10 percent. Radial means the two axes are judged by their combined length, so diagonals are not flattened and the stick does not snap to an axis. Travel past the zone is rescaled so full tilt still reaches the ends.
- Do not cap the stick vector to the unit circle. A pad with a square gate reports about (1, 1) in a corner, and capping cut a full diagonal to 70 percent per axis. Clamp each axis instead.
- Kumori Link trims at the box too. Both zones only pull toward centre, so a larger one simply wins.

## The Siri Remote as a pad

With no game controller, the Siri Remote acts as a simple pad: clickpad edges are the d-pad, a centre click is A, Play/Pause is B. With `reportsAbsoluteDpadValues` off, the d-pad only moves while a thumb slides on the surface, so a click on the ring's edge could read as A. Check ring clicks on hardware when touching this.

## Mouse and keyboard

- Clicking both sticks in (L3 and R3 together) toggles mouse mode, for launchers that only take a mouse. Left stick moves the pointer, right stick scrolls, A is left click, B right click, X middle click. The game sees the pad at rest while mouse mode is on.
- The mouse and key records are the same ones the desktop app sends (`desktop/app/js/input.js`). Unlike the gamepad record, their fields after the type are big endian. A wheel notch is 120. Buttons are 1 left, 2 middle, 3 right. Keys are Windows virtual key codes with modifier bits.
- On the native route, mouse input goes on the native control channel (see 05).
- `UI/StreamKeyboard.swift` is the on screen keyboard for typing into the game. `Launch/KeyText.swift` turns text into key presses, with tests.

## Rumble

Rumble works on native streams only (the routes above 1080p60). The WebRTC route does not deliver rumble events. A pad that reports separate motor handles (Xbox, DualSense) gets the heavy motor on the left and the light one on the right, as a console does; others get the stronger of the two. Motors stop after the event's duration unless the game sends another, and stop at once when the stream ends or the pad leaves.

## Controllers tvOS refuses

tvOS only hands apps the controllers on Apple's supported list. The 8BitDo Ultimate 2C is an example: it pairs over Bluetooth, and the kernel then logs "Un-authenticated game controller device attached" and never gives it to any app. No app can read Bluetooth HID devices itself. Do not spend time trying to make such a pad work inside the tvOS app. Kumori Link exists for this case.

## Kumori Link

Kumori Link is a small Android app that reads controllers on an Android TV box (USB or Bluetooth) and sends their state to Kumori on the Apple TV over the local network. Protocol summary (full detail in `docs/kumori-link-protocol.md`): UDP port 47820, found by Bonjour as `_kumorilink._udp`, a small log page over HTTP on 47821, packets HELLO, INFO, STATE, PING, PONG, BYE and RUMBLE, each with a 4 byte header.

Lessons on the Android side:

- Android only gives controller input to the app in front, so Link must stay open while playing.
- The 8BitDo 2.4G dongle needed a userspace USB driver with the Xbox 360 style handshake, because the box's old kernel did not know its USB id.
- Learn each stick's rest point and apply an 8 percent radial dead zone at the box.
- Send every sample, and always send the newest state. Never queue states; a queue turns into lag.
- Network lookups once ran on every packet and caused stutter. Run them every few seconds instead.
- A packet shorter than the 4 byte header crashed the app. Check lengths before reading any field, on both ends.

Lessons on the tvOS side:

- tvOS only lets controllers it knows move focus. A relayed controller is not one of them, so `LinkNavigator` does the focus engine's job: it collects every focus item in the window with its frame, picks the nearest item in the pressed direction (straight up and down, items that overlap sideways win over closer ones that do not), and focuses it through a focus request the engine accepts. Arrow events sent through `UIApplication.sendEvent` are only a fallback, for cases like leaving a tab bar.
- Walk only the screen on top. Walking the screens underneath (Home under a game page, the app under the stream) sent focus to hidden buttons and made held presses slow.
- A selects the focused item through its accessibility action. For a game card, A runs that card's own action, so it opens exactly the focused card, not an overlapping neighbour while cards are still resizing. This was a real bug.
- B goes back. Use `.onBack(perform:)` from `LinkBack.swift` on every screen instead of `.onExitCommand`, so a Link controller's B works the same as the remote's Back.
- B on the root screen must not close the app.
- Held directions repeat with the Siri Remote's rhythm: a pause, then steady steps. A held direction waits for a move still in progress instead of piling up moves.
- A stick springing back past centre once read as a flick the other way. A rebound right after a release is ignored.
- The box resends everything every 500 ms. If nothing is heard for longer while a direction is held, the release was lost; stop.
- A held stick counts as released only once it falls well inside the tilt threshold, so a stick hovering at the edge does not flicker.
- tvOS does not restart its screen saver countdown for relayed input, so each Link input holds the screen awake for 30 seconds (`Awake.swift`). It also does not play the focus tick, so `FocusClick` plays one.
