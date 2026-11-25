Apple TV only. Android, Windows and Linux stay on 1.2.1.

## Files

- `Kumori-1.3.0-tvos-unsigned.ipa` for Apple TV (tvOS 17 or newer), build 10300

Nothing here is signed. The Apple TV build has to be sideloaded.

## New

- Live stats: frames reaching the screen, decoder rate, target, the TV's refresh rate and dropped frames, with a warning that says why when the picture stays below its target
- Play time: the in-game menu shows the hours left this month, and idle sessions end after 15, 30 or 60 minutes (or never), with a 2-minute warning first
- Debug page: a display chain check for 120 Hz and HDR, Send Log with a QR code, and the local API address
- Local API on port 8090 (read only, local network only, never returns tokens or email)
- Settings › Controllers lists every connected controller with a live readout of its buttons and sticks
- Kumori Link: a controller plugged into an Android box can drive the Apple TV app and games
- New parallax app icon and Top Shelf banner
- Rebuilt screens: black theme, glass cards, a shorter Home banner, and a game page that opens out of its card

## Fixes

- Game launch: a refused 120 fps mode now drops to 60 fps before dropping the resolution, and the stream uses the mode the service actually accepted
- One deadline while waiting for the server's offer, so a slow server no longer gets cut off at 12 seconds
- Each launch leaves a record that the error screen and Settings › About show, and a failed launch offers a one-tap retry at 1080p60
- The display mode lookup that crashed 1.2.1 is guarded
- Audio comes back after an interruption
- Controllers hand off cleanly when a stream ends, a held stick is sent the moment the game is ready, and full left on a stick really is full left
- Holding Menu opens the in-game menu without also pressing Start, and buttons still held when the menu closes don't reach the game
- The in-game menu, stream notices and Settings notes no longer spill out of place

## Not tested

The stream and controller fixes were checked by unit tests and Simulator UI tests in CI. Only part of them has been tried on a real Apple TV with a live GeForce NOW session.
