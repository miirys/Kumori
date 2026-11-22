# Kumori Link protocol

Kumori Link is a small Android app (`android/link`) that reads controllers on an Android box
and sends them to Kumori on an Apple TV on the same network. It exists because tvOS refuses some
controllers (the 8BitDo Ultimate 2C, for one) that Android takes without trouble.

Android only gives controller input to the app in front, so Kumori Link must stay open while
you play.

## Finding the box

Kumori Link announces itself over Bonjour as `_kumorilink._udp` on UDP port **47820**, with TXT
keys `v` (protocol version), `model` and `http` (log page port). The Apple TV browses for that
type, or takes an IP typed by hand.

## Packets

UDP, little endian. Every packet starts with four bytes:

| offset | size | value |
|---|---|---|
| 0 | 2 | `K` `L` |
| 2 | 1 | protocol version, 1 |
| 3 | 1 | type |

| type | name | direction | body after the header |
|---|---|---|---|
| 1 | HELLO | Apple TV → box | u32 session, u16 name length, UTF-8 name |
| 2 | INFO | box → Apple TV | u32 session (echoed), u8 connected slot mask, u16 log page port, u16 + model, u16 + app version |
| 3 | STATE | box → Apple TV | see below, 28 bytes |
| 4 | PING | either way | u32 id, u64 sender time in µs |
| 5 | PONG | either way | the PING body, unchanged |
| 6 | BYE | either way | none |
| 7 | RUMBLE | Apple TV → box | u8 slot, u8 low motor, u8 high motor, u8 0, u16 duration ms |

STATE body:

| offset | size | field |
|---|---|---|
| 0 | 4 | sequence, rises by one for every STATE packet |
| 4 | 8 | box clock, µs |
| 12 | 1 | slot 0–3 |
| 13 | 1 | bit mask of slots in use |
| 14 | 1 | flags: 1 = box app not in front (state is all zero), 2 = this controller left |
| 15 | 1 | 0 |
| 16 | 2 | XInput buttons, same bits as `InputEncoder` |
| 18 | 1 | left trigger 0–255 |
| 19 | 1 | right trigger 0–255 |
| 20 | 8 | i16 left x, left y, right x, right y, −32768…32767, up is positive |

## Session

1. The Apple TV sends HELLO to the box once a second for as long as it wants input. The box
   answers each with INFO, then sends the current state of every controller.
2. The box sends STATE the moment anything changes, on a thread of its own, without waiting for
   the next frame. It sends again anything that changed in the last 150 ms every 20 ms, so a
   lost packet costs at most 20 ms, and everything every 500 ms.
3. The receiver keeps the newest sequence per slot and drops anything older.
4. The box pings once a second; the Apple TV answers with PONG. The round trip shows on the
   box and in its log.
5. A box that hears nothing for 5 s stops sending. Only one Apple TV gets input at a time: the
   last one to say HELLO.

Packets are sent with DSCP EF (46), which puts them in Wi-Fi's voice queue.

## Log page

`http://<box>:47821` shows the live log and controller state, with Copy and Download buttons.
`/log.txt` is the plain log, `/state.json` the current state.

## Testing without an Apple TV

`android/link/tools/fake_appletv.py <box ip>` says HELLO, prints every state and answers pings.
