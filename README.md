<p align="center">
  <img src="assets/banner.png" width="100%" alt="Kumori">
</p>

<p align="center">
  <a href="https://github.com/miirys/Kumori/releases/latest"><img src="https://img.shields.io/github/v/release/miirys/Kumori?style=for-the-badge&color=F27BA6&labelColor=16111B" alt="Release"></a>
  <a href="https://github.com/miirys/Kumori/releases"><img src="https://img.shields.io/github/downloads/miirys/Kumori/total?style=for-the-badge&color=F27BA6&labelColor=16111B" alt="Downloads"></a>
  <a href="https://github.com/miirys/Kumori/actions/workflows/android.yml"><img src="https://img.shields.io/github/actions/workflow/status/miirys/Kumori/android.yml?branch=main&style=for-the-badge&label=android&labelColor=16111B" alt="Android build"></a>
  <a href="https://github.com/miirys/Kumori/actions/workflows/tvos.yml"><img src="https://img.shields.io/github/actions/workflow/status/miirys/Kumori/tvos.yml?branch=main&style=for-the-badge&label=apple%20tv&labelColor=16111B" alt="Apple TV build"></a>
  <a href="https://github.com/miirys/Kumori/stargazers"><img src="https://img.shields.io/github/stars/miirys/Kumori?style=for-the-badge&color=F27BA6&labelColor=16111B" alt="Stars"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/miirys/Kumori?style=for-the-badge&color=F27BA6&labelColor=16111B" alt="License"></a>
</p>

Kumori is a GeForce NOW client for Android TV and Apple TV, made for the couch.

It is not made by or affiliated with NVIDIA. You need your own GeForce NOW account.

## What it does

- Plays your GeForce NOW library on the TV
- Up to 4K
- Works with a remote or a controller
- Looks the same on both platforms

## Install

Get the files from the [latest release](https://github.com/miirys/Kumori/releases/latest).

**Android TV:** install the APK with adb or a file manager.

**Apple TV:** sideload the IPA. It's unsigned.

## Build

Android needs JDK 17, the Android SDK with NDK 27.2.12479018 and CMake 3.22.1, and Rust.

```
rustup target add aarch64-linux-android armv7-linux-androideabi
cd android
python3 scripts/build_nvst.py
./gradlew :app:assembleRelease
```

`build_nvst.py` builds the native library that 4K streams use. It finds the NDK through `ANDROID_HOME` or `local.properties`; pass the NDK path as the first argument if it is somewhere else. The Gradle release build stops if the library is missing.

Apple TV needs Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
cd tvos
xcodegen
open Kumori.xcodeproj
```

## License

MIT, see [LICENSE](LICENSE). Third-party code is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
