# Kumori agent guide

This folder is for anyone, person or AI agent, who works on Kumori or a fork of it. It holds what earlier work on the project learned the hard way: how the app is built, how GeForce NOW actually behaves, which designs and animations were approved and which were thrown out, which bugs came up and how they were fixed, and the small details that are easy to miss.

Kumori is an unofficial GeForce NOW client. The main app is for Apple TV (tvOS). There is also an Android TV app that is no longer developed, a small Android helper called Kumori Link, and an Electron desktop app.

## How to read this folder

Do not read every file up front. Read this page, then open only the topic files your task touches. Each file stands on its own.

| File | Read it when you are |
| --- | --- |
| 01-project.md | new to the repo: what Kumori is, its history, where everything lives |
| 02-build-and-release.md | building, changing CI, bumping versions or cutting a release |
| 03-testing-on-a-device.md | installing on a real Apple TV, reading logs, using the local API |
| 04-geforce-now-protocol.md | touching sign-in, session requests, signaling, launch routes, End Game or resume |
| 05-streaming.md | touching the picture, the native NVST receiver, frame pacing, HDR or 120 Hz output |
| 06-input.md | touching controllers, the remote, mouse and keyboard, rumble or Kumori Link |
| 07-ui-rules.md | changing any screen, layout, text or visual style |
| 08-motion.md | changing any animation or transition |
| 09-performance.md | adding anything that runs per frame, per focus move, or per item in a list |
| 10-bug-log.md | fixing a bug (check whether it happened before) |
| 11-keeping-up-with-geforce-now.md | something that used to work stopped working |
| 12-adding-features.md | adding a new feature, setting, screen or endpoint |
| 13-common-mistakes.md | about to finish a change (read it as a checklist) |
| 14-working-process.md | planning how to work, test, report and commit |
| 15-android-desktop-and-link.md | working on the Android app, the desktop app, or Kumori Link |

The files in `docs/` at the repo root are for users and protocol readers (release notes, the Kumori Link protocol, the controller guide). This folder is for the people changing the code.

## The rules that matter most

These come up again and again. Each is explained in its topic file.

1. Never say a fix works until it has been seen working on a real device. Say "built, not yet tested on a TV" instead.
2. Above 1080p or above 60 fps, GeForce NOW only streams to the PC client's identity, and that only works over the native NVST stream, not WebRTC. See 04.
3. On tvOS, log at notice level or higher. Info and debug lines never reach the device log that testers can read. See 03.
4. Do not scale or move the Home screen behind an opening game page. It brought back a screen jump and black borders twice. See 08.
5. Never show a fallback title text under artwork that has loaded. It shows through every fade. See 07.
6. Never put secrets, tokens, account emails, session ids, IP addresses, device ids or personal details into logs, the local API, docs or commits. See 14.
7. A store name of NONE or UNKNOWN means the game uses its own launcher. It is valid. Hiding or filtering it breaks launches. See 04.
8. Use the system glass material for buttons. Hand-made glass looked jagged and was rejected. See 07.
9. Everything that animates must stay smooth at the display's full rate (60 or 120 Hz), and nothing may do work while it is off screen. See 09.
10. Do not declare something impossible early. 120 Hz output on Apple TV was called impossible and then shipped. See 05.

## Keeping this guide up to date

This guide only stays useful if every agent adds to it. This is a requirement, not a suggestion.

When you finish a change, before you open or update the pull request, update the files here that your work touched:

- You fixed a bug: add an entry to 10-bug-log.md, in the same shape as the others (what happened, the cause, the fix, and how to avoid it again).
- You learned how GeForce NOW behaves (an endpoint, a field, an error code, a limit): add it to 04 or 11.
- A design or animation was approved or rejected: record it in 07 or 08, with the reason, and mark anything it replaces as superseded rather than leaving two rules that disagree.
- You added a feature, a setting, a screen, an API endpoint or a log category: add it to the file that describes that area, and to 12 if it changes how features are added.
- You made a mistake that cost time, or found a small detail that matters: add it to 13.
- A file moved, a workflow changed, or a version rule changed: fix 01 or 02.
- Something here turned out to be wrong: correct it in place and say what changed and why, in one line.

Write in the same format as the existing text:

- Plain English, full sentences, short paragraphs. Write it so a new agent with no context understands it on the first read.
- Few symbols. No arrows, no em dashes, no emoji. Use headings, short lists, and the occasional table.
- Say why, not only what. A rule without its reason gets broken by the next agent.
- Name files and types exactly as they are in the code, in backticks, so they can be searched.
- Keep it general. No names of people, no personal devices or networks, no account details, no IP addresses, no tokens. Describe hardware by model only when the model matters to the bug.
- Put each fact in one place. If it belongs in two topics, write it in one and point to it from the other.
- Keep each file focused. If a file grows past roughly 400 lines, split it and add the new file to the table above.
