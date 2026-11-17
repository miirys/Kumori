Fixes for Android TV and Apple TV from a code review. Linux and Windows are unchanged apart from the version.

## Files

- `Kumori-1.2.1.apk` for Android TV and Android
- `Kumori-1.2.1-tvos-unsigned.ipa` for Apple TV (tvOS 17 or newer)
- `Kumori-1.2.1-windows-setup.exe` and `Kumori-1.2.1-windows-x64.zip` for Windows 10 and 11 (64-bit)
- `Kumori-1.2.1-linux-x64.AppImage` and `Kumori-1.2.1-linux-x64.tar.gz` for Linux (64-bit)

Nothing here is signed. The Apple TV build has to be sideloaded.

## Android TV

- A stream stopped while it was still connecting no longer carries on in the background
- The picture recovers on its own if the video decoder stops putting out frames
- Opening the menu, the keyboard or picture-in-picture lets go of a click held with the controller mouse
- USB controllers that send buttons and sticks in separate reports no longer lose one or the other
- Play on a game that is already running picks up that session instead of starting a new one
- A physical keyboard types into the on-screen typing bar while it is open, not into the game
- Home shows a card for a running session even when the game isn't in your library
- Sign-in stops on a real error from NVIDIA instead of retrying it as a network blip, and a cancelled sign-in no longer saves the account

## Apple TV

- A cancelled sign-in no longer saves the account
- 4K ways that failed are tried again after a day even if the app stays open

## Both

- A long queue no longer gives up after 20 scattered network errors; only 20 in a row count

## Not tested

These fixes were built in CI but not tried on a device or against a real GeForce NOW session.
