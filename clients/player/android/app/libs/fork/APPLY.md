# Fork edits to add libdovi to libmpv-android

## Private HTTP response boundary

The current AAR also patches the small JNI wrapper. The source base is
[`GCHOfficial/libmpv-android@3c2f33cd7d09c75dbc340f86b2d34c55e94b7f99`](https://github.com/GCHOfficial/libmpv-android/tree/3c2f33cd7d09c75dbc340f86b2d34c55e94b7f99).
`private-http-response.patch` changes four upstream files; copy
`private_http_response.h` and `private_http_headers.h` beside them. It replaces raw native/Java log forwarding
with a bounded parser that emits only status, validated Retry-After and an HTTP
origin without credentials, path or query. `ready=2` is synchronous after native
initialization. The client uses `terminal-default`; Kotlin enables narrow FFmpeg
tracing only after that capability signal and restores its quiet level on stop
or destruction. It keeps tracing after FILE_LOADED for later HLS segments.

Capability version 2 also accepts `tvbro/http-request-headers` through the
existing string setter. Its ASCII framing is `v1;<count>;<byteLength>:<hex>...`;
the native adapter validates at most 128 fields, 8 KiB per decoded field and
64 KiB per encoded payload, then applies one typed `MPV_FORMAT_NODE_ARRAY`.
Literal commas, backslashes and UTF-8 survive without mpv string-list escaping.
Malformed UTF-8, invalid field names, CR/LF/NUL and oversized input fail before
changing the previous array. `v1;0;` clears it. Backing strings remain alive until
the synchronous `mpv_set_property` call returns. Java/JNI signatures are unchanged.

For a wrapper-only rebuild, retain the original AAR with SHA-256
`e8ad90ca2d23d68918b1062e0acd15182d16aaca7e63519526aa68bfee2ed99e`
(the previous Git LFS revision, or the saved exact baseline). Run:

```text
python android/app/libs/fork/rebuild-private-http.py --input BASELINE.aar --output PRIVATE.aar --work-dir NEW_EMPTY_DIRECTORY --ndk ANDROID_SDK/ndk/28.2.13676358 --cmake ANDROID_SDK/cmake/3.22.1/bin/cmake --ninja ANDROID_SDK/cmake/3.22.1/bin/ninja
```

On Windows append `.exe` to CMake and Ninja. Python 3, NDK, CMake and Ninja must
already be installed. No FFmpeg, libmpv, Rust or Gradle build runs. The script
downloads only the pinned wrapper sources and two public headers, checks their
Git blob hashes, applies the versioned patch, links all four ABIs to the AAR's
existing `libmpv.so`/`libavcodec.so`, and verifies identical JNI exports. An
optional `--source-cache DIR` provides verified `source/` and `include/` files
for an offline build. It never overwrites its input or deletes a build directory.
`PRIVATE.aar.provenance.json` records input/output and every entry hash; exactly
four `jni/*/libplayer.so` entries may change. `classes.jar`, codecs, libmpv and
the C++ runtime remain byte-identical. Compiler version and build paths can
change wrapper build IDs; this is a reproducible source/build recipe, not a
claim of identical binaries across toolchains.

Run the standalone parser/privacy/lifecycle checks with a host C++ compiler:

```sh
c++ -std=c++11 -O2 android/app/libs/fork/test_private_http_response.cpp -o /tmp/tvbro-http-parser
/tmp/tvbro-http-parser
```

On Windows, run `cl /EHsc /std:c++17 test_private_http_response.cpp` from a
Visual Studio developer shell, then run the resulting executable. The suite
includes 70 checks and 500,000 healthy/decoder messages producing zero metadata callbacks.
Actual engine traffic, redirects and log volume still require the APK runtime
fixtures; host parser tests do not prove FFmpeg event timing.

For the existing full fork workflow, copy the patch, both headers and test into
`tvbro-private-http/` at the fork root, then copy `build.yaml` as below. Its new
step applies the patch and runs the host test before the existing codec build.
Keep upstream JNI sources unmodified before that step, so patch-context errors
stop the build. No remote fork/release publication is required for a local
wrapper-only rebuild. The resulting AAR is tracked through the application's
normal Git LFS workflow; ordinary clean CI checkouts need no wrapper compilation
once the updated LFS object is included.

## Original libdovi build

Base your fork on `jarnedemeulemeester/libmpv-android` @ the tag/commit matching
the AAR you currently use (it ships libplacebo 7.360.1 / ffmpeg 8.1 / mpv 0.41.0
/ NDK 29.x). Apply the four edits below, plus copy the two files in this folder:

- `scripts-dovi.sh` → `buildscripts/scripts/dovi.sh` (`chmod +x`)
- `build.yaml`      → `.github/workflows/build.yaml`

Then push to your fork's `main` (or run the workflow via *Actions → Run
workflow*). Download the `libmpv-release.aar` artifact and follow the parent
[`../README.md`](../README.md) → "Wire the AAR into the app".

---

## 1. `buildscripts/include/depinfo.sh`

Add a version under the others, e.g. after `v_libplacebo=7.360.1`:

```bash
v_dovi=libdovi-3.3.2
```

In the dependency tree, add a `dovi` node and make libplacebo depend on it so it
builds first:

```bash
dep_dovi=()
dep_libplacebo=(dovi)        # was: dep_libplacebo=()
```

## 2. `buildscripts/include/download-deps.sh`

Add a clone just before the `libplacebo` clone:

```bash
# dovi (libdovi — Dolby Vision RPU parser)
[ ! -d dovi ] && git clone --depth 1 --branch $v_dovi https://github.com/quietvoid/dovi_tool.git dovi
```

## 3. `buildscripts/scripts/libplacebo.sh`

Add `-Dlibdovi=enabled` to the `meson setup` line:

```bash
meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	-Dvulkan=disabled -Ddemos=false -Dlibdovi=enabled
```

Meson finds `dovi.pc` via `PKG_CONFIG_LIBDIR` (set by `path.sh`). The configure
summary should report **Dolby Vision: enabled**. If meson can't find libdovi,
confirm `dovi.sh` ran for this ABI and `$prefix_dir/lib/pkgconfig/dovi.pc` exists.

## 4. `buildscripts/scripts/dovi.sh`

Copy `scripts-dovi.sh` from this folder. It builds libdovi with cargo-c for the
ABI's Rust target and installs `libdovi.a` + `dovi.pc` into the prefix.

---

## Notes / troubleshooting
- The final `libmpv.so` link must pull `libdovi.a`. libplacebo's `.pc` carries it
  as a static dependency, and mpv links libplacebo with `pkg-config --static`, so
  this is automatic. If the link reports undefined `dovi_*` symbols, verify
  `libplacebo.pc` lists the dovi dependency and that pkg-config `--static` is in use.
- libdovi is a Rust `staticlib` (bundles std), so no extra runtime `.so`.
- Keep ABIs minimal (`--arch arm64`, optionally `x86_64` for the emulator) to keep
  the AAR small; ffmpeg needs no libdovi (it already exports HEVC RPU side data).
