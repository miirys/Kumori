# Where this code comes from

The `nvst-protocol` and `nvst-transport` crates and `src/nvst_rtsp.rs` come from
[OpenNOW](https://github.com/OpenCloudGaming/OpenNOW) (MIT, see `THIRD_PARTY_NOTICES.md`
at the repo root), dev commits 3002e5c67 and 52791d1d4.

Changed here: the JNI layer in `src/lib.rs`, bundled TLS roots, and no RTSP TEARDOWN on
a local stop or reconnect.

Opus is built from source through `audiopus_sys`. Its license is in `OPUS-LICENSE`.
