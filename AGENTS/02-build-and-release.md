# 02. Building, CI and releases

## Building the Apple TV app

You need a Mac with a recent Xcode (CI uses the newest Xcode on a macOS 26 runner), XcodeGen, and the Metal toolchain (the Settings background is a Metal shader).

1. Build the native stream libraries once: `python3 tvos/scripts/build-nvst-libs.py`. This builds the OpenSSL and usrsctp xcframeworks the NVST code links against. It is slow, so CI caches the result.
2. In `tvos/`, run `xcodegen` to generate `Kumori.xcodeproj` from `project.yml`.
3. Build the `Kumori` scheme for tvOS.

Facts about the project:

- Bundle id prefix `app.kumori.tv`. A sideload tool may append a team suffix to it on the device. Never commit a personal team suffix.
- Deployment target tvOS 17. Liquid Glass and some materials need tvOS 26 and fall back to an opaque panel below it.
- `MARKETING_VERSION` in `tvos/project.yml` is the version. CI sets the build number from it: major times 10000, plus minor times 100, plus patch. So 1.4.0 is 10400. Every release therefore has a higher build number than the last, which tvOS needs to install over an older copy.
- CI sets `KUMORI_COMMIT` to the first 7 characters of the commit being built. The app shows it in About and puts it in `Info.plist` as `KumoriCommit`. On a pull request build this is GitHub's temporary merge commit, not the head of your branch, so do not be surprised when the hash on the TV matches no commit you pushed.
- Fixture code is Debug only. The Release build step fails if fixture symbols end up in the binary.

## CI workflows

| Workflow | File | Runs on | What it does |
| --- | --- | --- | --- |
| Apple TV | `tvos.yml` | PRs touching `tvos/`, pushes to main | Launch logic tests on Linux (`swift test` on `tvos/Package.swift`), then Build IPA on macOS: an unsigned Release build packaged as `Kumori-<version>-tvos-unsigned.ipa`, uploaded as the `kumori-tvos` artifact |
| Apple TV Simulator | `tvos-simulator.yml` | PRs touching `tvos/` | Unit and UI tests on a tvOS simulator, fixture screenshots as the `kumori-tvos-captures` artifact. Takes around 25 minutes |
| Apple TV input tests | `tvos-input.yml` | Changes to the input files | `swift test --package-path tvos/InputTests` |
| Android | `android.yml` | Android changes | Rust library, Android APK, Kumori Link APK |
| Desktop | `desktop.yml` | Desktop changes | Linux and Windows builds with an end to end test |
| Release | `release.yml` | Manual dispatch only | Checks versions, builds the chosen apps, creates the GitHub release |

Things to know about CI:

- Each workflow cancels an older run of itself on the same branch when a new commit is pushed. If you push twice quickly, the first build is cancelled. That is expected, not a failure.
- The IPA is ready as soon as the Build IPA job is green. Testers do not need to wait for the simulator job. Point them at the Build IPA artifact the moment it exists.
- When a build fails, the "Errors" step prints the unique `error:` lines. Read those first.
- A Swift file that compiles on Linux (Launch logic) but uses something Apple only, or the reverse, will fail one of the two jobs. Keep `Kumori/Launch` Foundation only.

## Versions

Each app has its own version in its own file:

- Apple TV: `MARKETING_VERSION` in `tvos/project.yml`.
- Android TV: `versionName` in `android/app/build.gradle.kts`.
- Kumori Link: `versionName` in `android/link/build.gradle.kts`. Link has its own version numbers, separate from the app versions. Its versionCode follows the same major, minor, patch formula.
- Desktop: `version` in `desktop/package.json`.

## Cutting a release

Releases are made only through the Release workflow, by manual dispatch with two inputs:

- `version`: the version to release, like 1.4.0.
- `apps`: `all`, `tvos`, or `tvos-and-link`.

Before you dispatch it:

1. Set the version in the source files for every app being released. With `all`, the desktop and Android versions must match too. With `tvos` or `tvos-and-link`, only the tvOS version is checked against the input.
2. Write `docs/release-<version>.md`. The check step fails without it. Follow the style of the existing notes: what changed for the player, in plain words, newest first. For `tvos-and-link`, the notes must name the Link file exactly as `KumoriLink-<link version>.apk`.
3. Merge to main.

The workflow creates the tag itself. Agents usually cannot push tags, so do not try to tag by hand; dispatch the workflow.

## Release notes style

Release notes are read by players, not developers. Write what they will notice ("Streams at 1440p 120 now start on the first try"), not the code change. No internal names, no commit hashes, no blame. Keep them short. Look at `docs/release-1.4.0.md` for the current shape.
