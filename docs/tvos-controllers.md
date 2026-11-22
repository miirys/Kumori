# Controllers on Apple TV

## Will my 8BitDo Ultimate 2C Wireless work?

Probably not, and no app can fix it if it doesn't. 8BitDo documents the Ultimate 2C Wireless for Windows (2.4G receiver or cable) and Android (Bluetooth). It is not on 8BitDo's Apple list, which names other models such as the Ultimate 2 Wireless. Other owners report that it pairs with an Apple TV over Bluetooth but tvOS never offers it to apps as a game controller. The Apple TV has no USB port for the 2.4G receiver.

Kumori only sees what tvOS hands it. If tvOS doesn't recognise the pad as a game controller, Kumori can't read it, and neither can any other Apple TV app.

### Try this once

1. Update the controller's firmware with 8BitDo Ultimate Software on a PC first.
2. Turn off any nearby PC, phone or console the pad might reconnect to.
3. Slide the switch on the back to **BT**. Press Home to turn it on, then hold the small **Pair** button for 3 seconds until the LEDs blink fast.
4. On the Apple TV, open **Settings › Remotes and Devices › Bluetooth** and pick "8BitDo Ultimate 2C Wireless".
5. Open Kumori, go to **Settings › Controllers**.

What you see there tells you the answer:

| Controllers page says | Meaning |
|---|---|
| **Controller ready**, with the 8BitDo listed as *Full controller*, and the sticks and triggers move in **Test** | It works. Play a game. |
| **…isn't a full controller here** (listed as *Limited*) | tvOS gave it only a few buttons. Games won't get sticks or triggers. |
| **No game controller**, though Bluetooth settings show it as connected | tvOS paired it but doesn't treat it as a game controller. It won't work in any app. |
| Not in Bluetooth settings at all | It didn't pair. Forget it in Bluetooth settings, charge it, and repeat once. |

If it doesn't work, use a controller Apple supports: Xbox Wireless (the model with the Share button, or any with current firmware), PlayStation DualSense or DualShock 4, Nintendo Switch Pro, or an 8BitDo model on [8BitDo's Apple list](https://www.8bitdo.com/apple/). Check the exact model name before buying. 8BitDo sells several similarly named "Ultimate 2C" variants that behave differently.

## How Kumori handles controllers

- **Settings › Controllers** lists every connected controller, whether it's a full controller, its battery, and a live readout of every button, stick and trigger. It works with the Siri Remote alone.
- When a game starts with no game controller, Kumori says so, and the Siri Remote acts as a simple pad (clickpad edges are the D-pad, a centre click is A, Play/Pause is B).
- The first time a game starts with a controller, Kumori shows how to open its menu.
- **Hold Menu (☰) for 0.6 s** to open Kumori's menu. A short tap is the game's Start button. On the Siri Remote, Back opens the menu. Home always works as normal.
- A button you're still holding when you close the menu (the A on Resume, or B) is kept from the game until you let go, so it doesn't land as a game press.
- Controllers that connect or disconnect mid-game show a notice. Other players keep their numbers.
- **Click both sticks in (L3 + R3)** to switch mouse mode on or off, for launchers and menus that only take a mouse (the Wuthering Waves launcher is one). Left stick moves the pointer, right stick scrolls, A is a left click, B a right click, X a middle click. The game sees the pad at rest while it's on.
- Turn on **Stats** in the stream menu to see the input line: `input v3 · 1520 sent`. "input waiting" means the server hasn't opened input yet, and a "refused" count means reports aren't getting through.

## Why a connected controller did nothing in the game

tvOS read the controller fine, and Kumori sent its reports, but GeForce NOW ignored them. Three things were missing, all now fixed:

1. **The pad was never registered.** The server only reads a pad after a neutral report on the ordered input channel (`input_channel_v1`, framed as a single event) announces it. Kumori now sends that first, before any state, and again whenever a pad comes or goes. A pad that leaves is released under the old bitmap first, so a held button can't stick.
2. **The connected bitmap lacked the XInput bits.** Each slot is two bits: `slot` (connected) and `slot + 8` (an XInput pad). One controller is `0x0101`, not `0x0001`. Without the second bit the rig accepts the packet and drops it.
3. **The session didn't ask for a gamepad.** The launch request now says `availableSupportedControllers: [2]`, `preferredController: 2` and `appLaunchMode: 2` (gamepad-friendly), as the PC client and OpenNOW do.

The idle keepalive is also every 100 ms now, as OpenNOW sends it. All of this matches OpenNOW's `docs/native-gamepad-input.md`, and the bytes are checked against the desktop encoder in `tvos/InputTests`.

## Device check (when the Apple TV is back)

Record tvOS version, Kumori version and the controller's exact model and firmware.

1. Pair the 8BitDo as above and note what **Settings › Controllers** shows.
2. With a supported pad (Xbox or DualSense), open **Settings › Controllers** and check every button, both sticks to all four edges, and both triggers from 0 to 255 in **Test**.
3. Start a game at 1080p60 with Stats on. Check the input line goes from "input waiting" to "input v… · N sent" and the count rises when you move.
4. In game: move, press A, pull both triggers. The game responds.
5. Tap Menu: the game sees Start once. Hold Menu: Kumori's menu opens and the game doesn't see Start.
6. In the menu, press Resume with A. The game doesn't get an A press.
7. Open the menu, press B to close it. The game doesn't get B.
8. Siri Remote Back opens the menu. Home leaves the app.
9. Leave running, open the same game again and repeat 4–7. Nothing is stuck or doubled.
10. On a mouse-only launcher, click both sticks in: the notice says mouse mode is on, the pointer follows the left stick, A clicks. Click both sticks again to go back.
11. Turn the controller off mid-game: a notice appears and the character stops moving. Turn it back on: a notice appears and it plays again.
