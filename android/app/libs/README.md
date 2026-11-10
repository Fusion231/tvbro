# Custom libmpv for Android (gpu-next / Dolby Vision Profile 5)

The Android native player's **fallback** engine is libmpv (`MpvEngine` /
`MpvController`), used only when ExoPlayer can't decode a video track — chiefly
**Dolby Vision Profile 5** on non-DV hardware (e.g. Samsung Galaxy). For DV P5 to
render with correct colors instead of a **green / magenta cast**, libmpv's
libplacebo (`vo=gpu-next`) must be built with **libdovi** (the Dolby Vision RPU
parser). This is the exact same requirement as the Windows path — see
[`windows/libmpv/README.md`](../../../windows/libmpv/README.md).

The stock Maven dependency **`dev.jdtech.mpv:libmpv:1.0.0`** is built *without*
libdovi (its `buildscripts/scripts/libplacebo.sh` runs
`meson setup … -Dvulkan=disabled -Ddemos=false` with no libdovi, and `depinfo.sh`
lists no dovi/dovi_tool). So `gpu-next` can tone-map HDR10 but **cannot reshape
DV P5** → green/magenta. We therefore vendor our own libdovi-enabled AAR here.

> **Status:** done. `libmpv-dovi.aar` is built and vendored here (committed via
> **Git LFS**, ~48 MB — see `/.gitattributes`), `build.gradle.kts` uses it,
> and `MpvController` runs `hwdec=no`. Built from
> [GCHOfficial/libmpv-android@`libdovi`](https://github.com/GCHOfficial/libmpv-android/tree/libdovi)
> (forked off the v1.0.0 tag for `MPVLib` API parity). Verified: the packaged
> `libmpv.so` contains `pl_dovi_metadata` / `dovi_rpu` / reshaping.

The JNI wrapper additionally has a private HTTP response boundary: raw mpv logs
are not copied into logcat or Java observers. Its only log callback payloads are
the synchronous `ready=2` capability and bounded status/Retry-After/origin fields.
Kotlin enables narrow response tracing only when that capability is present.
Version 2 also supplies a bounded typed request-header array through the existing
JNI setter, preserving literal commas, backslashes and UTF-8 without escaping.
The wrapper-only rebuild and provenance procedure is in
[`fork/APPLY.md`](fork/APPLY.md#private-http-response-boundary); it replaces four
small `libplayer.so` entries while retaining all codec, libmpv and Java bytes.
The local updated AAR SHA-256 is
`aa359ae2c98c86f9adc319d60de2318691b947b7ec994d65c3e74a8069382f0e`.

**Open transport limitation:** typed headers preserve their literal values but
do not isolate credentials by origin. A controlled Android wire test confirmed
that the bundled FFmpeg forwards custom `Authorization` and `Cookie` through an
HTTP redirect to a second origin. Its HLS transport also inherits IO options for
nested requests. The private response parser runs after requests and cannot
prevent that forwarding. A complete fix needs an origin-aware transport boundary
before each redirect or nested request; global redirect blocking would break
valid CDN streams. This is separate from the verified log privacy and
Retry-After handling, and Windows transport tests do not qualify Android here.

## How to build the AAR (GitHub Actions on a fork)

The build runs only on Linux (NDK + Rust). This host is Windows with no WSL, so
build it on **GitHub Actions in a fork** of
[`jarnedemeulemeester/libmpv-android`](https://github.com/jarnedemeulemeester/libmpv-android)
(keep its pinned libplacebo 7.360.1 / ffmpeg 8.1 / mpv 0.41.0 / NDK 29.x for
ABI/API parity with the stock AAR).

Ready-to-drop fork files + the exact edits are in [`fork/`](fork/):
- [`fork/APPLY.md`](fork/APPLY.md) — the four small edits (depinfo.sh,
  download-deps.sh, libplacebo.sh `-Dlibdovi=enabled`, dep tree) + where each file
  goes.
- [`fork/scripts-dovi.sh`](fork/scripts-dovi.sh) → `buildscripts/scripts/dovi.sh`
  (builds libdovi with `cargo cinstall` for each ABI's Rust target → `libdovi.a` +
  `dovi.pc` in the prefix; libplacebo links it via pkg-config).
- [`fork/build.yaml`](fork/build.yaml) → `.github/workflows/build.yaml` (upstream CI
  + Rust toolchain + `cargo-c`).

Push the fork; Actions uploads a `libmpv-release.aar` artifact. (libdovi is pinned
to `libdovi-3.3.2`; ffmpeg needs no libdovi — it already exports HEVC RPU side
data. Trim ABIs in `build.sh`/the workflow to keep the AAR small.)

## Wire the AAR into the app

1. Drop the built file here as **`android/app/libs/libmpv-dovi.aar`** (large
   binary — track with Git LFS or git-ignore + document, same as the Windows DLL).
2. In [`android/app/build.gradle.kts`](../build.gradle.kts), replace
   ```kotlin
   implementation("dev.jdtech.mpv:libmpv:1.0.0")
   ```
   with the local AAR:
   ```kotlin
   implementation(files("libs/libmpv-dovi.aar"))
   ```
   (or a `flatDir` repo). The package name stays `dev.jdtech.mpv`, so
   `MpvController` needs no source changes. Keep the existing
   `packaging.jniLibs.pickFirsts += "**/libmpv.so"` — and **re-verify the kept
   `libmpv.so` is ours** (it should contain libplacebo + libdovi; media_kit's
   ships separate `libav*.so`). If the wrong one wins, exclude media_kit's.
3. In [`MpvController.kt`](../src/main/kotlin/com/gchofficial/iptvs/player/MpvController.kt),
   set software decode for the fallback so libplacebo gets clean frames to reshape:
   ```kotlin
   setOptionString("hwdec", "no")   // was "mediacodec"
   ```
   Keep `vo=gpu-next` and the SDR tone-map config (`tone-mapping=auto`,
   `hdr-compute-peak=yes`, `gamut-mapping-mode=perceptual`) — mpv still can't
   signal HDR to an Android surface, so DV P5 is reshaped then tone-mapped to a
   correct, watchable SDR image.

## Verifying it loaded

Play the DV P5 title ("Maul"). Expected: ExoPlayer reports the track unsupported →
`fallbackToMpv()` (Logcat `iptvs.hdr: falling back to libmpv`) → **correct colors,
no green/magenta**. HDR10/HDR10+/HLG still go through ExoPlayer (true HDR) and
never hit this fallback.
