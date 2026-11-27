# 14. How to work on Kumori

## The loop

1. Understand the ask. If it can be read more than one way, start on the most likely reading and say which one you chose.
2. Read the relevant topic files and the code they point to.
3. Make the change. Keep pure decisions in tested pure code.
4. Run what you can: `swift test` in `tvos/` for launch logic, `swift test --package-path tvos/InputTests` for input bytes, the simulator for layout and focus.
5. Push and let CI build. Fix compile errors from the "Errors" step's output.
6. Get it onto a device as soon as Build IPA is green, and test the change itself, on the TV.
7. Report honestly: what changed, what was tested and how, what was not tested.
8. Update this guide with what you learned.

## Batching

- One consolidated build per round. If several fixes are in flight, combine them into one branch and one build for the tester, rather than many small installs. Each install takes a person's time.
- When work spans several branches, merge them in dependency order and never let a merge undo newer work. After a merge, check that the newer changes are still there.
- CI cancels an older run when a newer commit lands on the same branch. Push the round's last commit, then wait for that build.

## Reporting

- Lead with the result. Then what it depends on. Keep it short.
- Say exactly what was verified and how ("on the TV, 1440p120, stats showed 120 decoded and 120 shown at 120 Hz"). Say plainly what was not.
- If something failed, say so with the evidence, and what you will try next.
- Give testers direct links (the CI artifact, the PR), not instructions to go looking.
- Do not ask the tester to run commands or tools when you can do it yourself.
- Do not repeat the plan or narrate options you will not pursue.

## Commits and pull requests

- Short, plain commit subjects that say what changed for the user or the code, like the existing history: "Kumori Link: a lost release or a restarted box no longer leaves a pad stuck or deaf". Use the body for the cause and the reasoning.
- Mention the file or type when it helps the next reader search.
- One topic per pull request where possible. A round's combined build can be a merge of several.
- Write release notes in player language (see 02).

## Privacy and safety

Kumori handles a person's GeForce NOW account. Treat everything around it as sensitive.

- Never put tokens, passwords, session ids, account emails, IP addresses, device ids, team ids or home network details into the code, logs, the local API, commits, pull requests, issues or this guide.
- Never commit credentials that a person shares with you to help test, and never repeat them in messages.
- Never copy caches that can hold auth responses (`Cache.db`) off a device.
- Describe test hardware by model only when the model matters (an Apple TV generation, a receiver that cannot pass 1440p120), never by owner or location.
- Credit third party work in the licence files, not in the product's interface.

## Working with the code from the original projects

- `tvos/Kumori/NVST` is ported code with its own licences. Keep its headers, `LICENSE`, `Licenses` and `UPSTREAM.json` intact. When you change ported code, note what changed from upstream in the file's header comment, as `Native/NativeStream.swift` does.
- When pulling newer upstream changes, update `UPSTREAM.json` with the new commit.
- `THIRD_PARTY_NOTICES.md` at the repo root lists everything bundled. Add any new dependency there.

## When you are stuck

- Look at how OpenNOW or the official client does it (see 11).
- Check 10 for the same symptom.
- Add a safe trace or counter, ship a build, and let the device tell you, instead of guessing twice.
- Say clearly what is blocking you and what you need.
