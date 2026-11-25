# Third-party notices

Kumori uses the work below. Each keeps its own license.

## OpenNOW

The NVST protocol and transport code in `android/nvst` comes from
[OpenNOW](https://github.com/OpenCloudGaming/OpenNOW). The 120 Hz HDMI mode switch in
`tvos/Kumori/App/HDMIMode.swift` follows the approach of the tvOS port by Lacrowx
([Lacrowx/OpenNOW](https://github.com/Lacrowx/OpenNOW)), under the same license.

```
MIT License

Copyright (c) 2025 Zortos

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Opus

Built from source into the Android native library. BSD 3-Clause.
Full text in `android/nvst/OPUS-LICENSE`.

## WebRTC

Android uses [webrtc-sdk/android](https://github.com/webrtc-sdk/android).
Apple TV uses [livekit/webrtc-xcframework](https://github.com/livekit/webrtc-xcframework).
Both are builds of WebRTC, BSD 3-Clause, Copyright (c) 2011 The WebRTC project authors.
The license and patent grant are at https://webrtc.org/support/license.

## Inter

The Inter typeface, Copyright (c) 2016 The Inter Project Authors.
SIL Open Font License 1.1, https://openfontlicense.org.

## Android libraries

| Library | License |
| --- | --- |
| AndroidX, Jetpack Compose | Apache 2.0 |
| Kotlin, kotlinx.coroutines | Apache 2.0 |
| OkHttp | Apache 2.0 |
| Coil | Apache 2.0 |
| ZXing core | Apache 2.0 |

Apache 2.0: https://www.apache.org/licenses/LICENSE-2.0

## Rust crates

The native library links crates from crates.io, including str0m, rustls, ring,
tungstenite, serde, jni and the RustCrypto crates. They are MIT, Apache 2.0,
BSD or ISC licensed. `android/nvst/Cargo.lock` has the full list with versions.

## Trademarks

GeForce NOW and NVIDIA are trademarks of NVIDIA Corporation. Kumori is not
affiliated with NVIDIA.
