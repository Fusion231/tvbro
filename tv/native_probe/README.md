# Existing Dart execution probe

This R02 qualification harness executes the original `app/lib/` files through
`package:iptvs` imports. The thin [`tv/app/main.dart`](../app/main.dart)
registers the Tizen player and delegates to the original application `main()`;
the host harness calls the original main directly with its host backend. It
contains synthetic HTTP responses and assertions, with no provider parser,
source factory, repository, startup sequence or application UI copy.

Run from this checkout with the already cached Flutter SDK and package graph:

```powershell
./tv/native_probe/run.ps1
```

The runner creates its host Flutter test project in ignored
`tv/output/native-probe/`. It derives a package config from the existing
`app/.dart_tool/package_config.json` and the resolved package graph, preserving
every original package location and binding `iptvs` to `app/`; it adds only the
harness package. No `pub get`,
dependency install, global Flutter configuration or main-project generation runs.
The SQLite hook reads the already cached host DLL at
`app/.dart_tool/lib/sqlite3.dll`; the bootstrap uses the existing
`app/windows/libmpv/libmpv-2.dll` through MediaKit's `LIBMPV_LIBRARY_PATH`.
Parameters can select cached SDK/cache/library locations (`-MpvLibrary` for
libmpv). The selected Flutter SDK must match the original package graph's
`flutter` root; a mismatch fails before execution. Missing prerequisites fail
without installing them.

The runner executes four phases sequentially, each with its own Flutter test
process and log. The first phase retains the original three reuse tests and
passes the **original** `app/test/epg_grid_test.dart` as another absolute CLI
argument; that test file and its widget/navigation logic are not copied.
The core/EPG phase builds test assets locally in the ignored host project,
including Flutter's cached Material shader required by the original dialog
focus test. The storage phases keep test-asset generation disabled. The fourth
phase builds assets and runs the original application bootstrap.

The generated host manifest derives its Flutter asset/font declaration from the
original `app/pubspec.yaml`. The runner stages the referenced logo and three
Inter files only into ignored output, preserving their original asset keys and
recording matching source/staged SHA-256 hashes in `asset-staging.json`. The
bootstrap loads those same keys through `rootBundle` and verifies their bytes;
real font families from the generated `FontManifest.json`, including Inter and
MaterialIcons, are loaded for the screenshot. No maintained asset copy is added.

The core and EPG phase exercises:

- `SourceConfig` serialization and its original `build()` dispatch for all four
  source kinds; Stalker and Demo are constructed only.
- M3U over loopback HTTP through the original factory, parser, stable opaque
  identity, `LibraryRepository`, SQLite write/read, encrypted locator cache and
  play-time reveal. A fresh source instance browses the cache without HTTP.
- Xtream over loopback HTTP through the original factory, authentication,
  live/movie/series catalog mapping, configured live container and stream URL
  resolution. Stream URLs are inspected only; no media connection is opened.
- The existing EPG grid's selection, D-pad events, accessibility semantics,
  details and programme reveal through its existing 13 widget tests. They use
  their original host FFI/test setup; they do not qualify TV remote hardware.

The storage write/read phases use the original cached
`FlutterSecureStorageWindows.registerWith()` implementation (Dart FFI and
Windows DPAPI), with the default secure-storage constructors in TVBro. They
exercise `AppDatabase.open()`, `SourceStore`, `LocalProfileStore`,
`SecureLocalStorage`, and the database's `SecretLocatorVault`. No storage mock,
replacement encryption or native Windows application build is used. Flutter's
test target override is set to the actual Windows host because `FLUTTER_TEST`
otherwise selects Android secure-storage options; no TV identity is simulated.

Each run creates one fresh `tv/output/native-probe/storage-<guid>/` directory.
A host-only `PathProviderPlatform` implementation sends application-support and
temporary paths only to that directory; the storage test resolves the original
`iptvs` package to enforce this boundary. The real plugin's encrypted file and
`iptv.db` therefore cannot use the user's application data. All configurations,
metadata credentials and session strings are synthetic, and these phases make
no provider, cloud or media connection.

The write process persists source/settings, profile snapshot and selection,
startup preference, session, OS-protected cache key and a sealed channel cache.
The read process checks a different process ID, restores those values through
their canonical APIs and resolves the cached locator through the original
repository using the persisted key. It also checks session removal. Direct
plugin key reads before/after `open()` prevent the vault's in-memory fallback
from disguising missing storage. This qualifies **host DPAPI persistence**,
not Tizen/webOS secure storage.

The bootstrap phase creates a separate fresh `bootstrap-<guid>/` directory after
the storage phases and uses the same path-boundary helper and actual DPAPI
plugin. It imports and calls `package:iptvs/main.dart`, which executes the original
MediaKit initialization, `AppDatabase.open()`, source-identity migrations,
language/parental/provider-protection initialization and DVR resolver setup.
The test then uses the existing language selection, profile picker, Home and
source-management screens. It enters a synthetic non-Xtream-shaped M3U URL in
the original form, saves through `SourceStore`, and remains on the source list;
it does not return to Home to load that provider or start media playback.

Only the existing build defines `TVBRO_CLOUD_ENABLED=false` and
`DISTRIBUTION_CHANNEL=development` control cloud/updater startup. Outbound HTTP
connections are blocked and counted in this phase; the successful run made
zero attempts. The Flutter runner and original DVR service use host loopback.
MediaKit loads the real host DLL and its `mpv_client_api_version` export is
verified, without a media engine/surface mock. Rendered-state readiness uses
bounded futures completed by Flutter frame events, with no polling loop.
The original UI, DVR scheduler/service, image-cache resource and database are
closed before platform delegates are restored. The test records cleanup status
and a single `sources-1280x720.png` screenshot. This is the actual Windows host
with the normal width-based layout; `isTelevision` stays false throughout.

`test.log`/`tests.jsonl`, `storage-write.log`/`storage-write-tests.jsonl`,
`storage-read.log`/`storage-read-tests.jsonl`,
`bootstrap.log`/`bootstrap-tests.jsonl`, and `evidence.json` stay in the
output directory. The aggregate evidence records every phase's terminal status,
SDK versions, the actual `iptvs` and storage-plugin package roots, and hashes of
the **selected** protected source/config/manifest/plugin/fixture inputs, not the
complete application import graph. It reports changes to those inputs.
Each storage directory also retains `storage-write-evidence.json` and
`storage-read-evidence.json` with process IDs and storage paths, without secret
values; the bootstrap directory retains `bootstrap-evidence.json` and its PNG.
A failed write skips its dependent read; a failed core phase remains a
failure even when independent storage phases succeed.

Validated on **24 October 2026** with the cached Flutter **3.47.7** / Dart
**3.13.5**: core + original EPG **16/16**, storage write **1/1**, storage read
**1/1**, original app bootstrap **1/1** — **19 tests passed**. The run completed
at **13:59:38 UTC**; all four phases reported `succeeded`, with
`changedProtectedPaths: []`. The two storage processes had
different IDs and restored/decrypted the same isolated cache using the actual
DPAPI plugin; the read phase also verified session removal. The bootstrap
reported `mpvClientApiVersion: 131078`, zero outbound connection attempts,
successful source-form persistence and `cleanupCompleted: true`. See the
[preserved aggregate evidence](../output/continuation-20261024/verified-19-bootstrap/evidence.json),
[bootstrap evidence](../output/continuation-20261024/verified-19-bootstrap/bootstrap-evidence.json)
and [original source-screen capture](../output/continuation-20261024/verified-19-bootstrap/sources-1280x720.png).

The [earlier 18-pass result](../output/continuation-20261024/verified-18-first/evidence.json)
remains preserved separately. An intervening check encountered an undefined
`_firstString` in a concurrent database edit; that owner-side issue is resolved
in the sources used by the 19-pass run. The TV work did not edit that file.
Qualification applies to the source hashes recorded by each run, not
automatically to later changes in this shared checkout.

Scoped static analysis from `app/` used
`dart analyze tv/native_probe` with the cached SDK and
`DASH__SUPPRESS_ANALYTICS=true`: **0 errors, 11 visible-for-testing warnings,
8 infos** (exit 1). The [recorded command/output](../output/continuation-20261024/verified-19-bootstrap/scoped-analyze.log)
is retained without another analyzer run. This nested harness is interpreted
under the app-root manifest during that command; its generated TV manifest
declares the platform-plugin dependencies. The existing nested test fixtures
also trigger visible-for-testing diagnostics. No app dependency changes or
diagnostic suppressions were made; this is not a clean-analysis claim.

This is **host Flutter VM execution**, not a native TV build or a finished TV
client. The core tests still use `AppDatabase.openAt()` and
`FlutterSecureStorage.setMockInitialValues()`, and their test-only request-gate
reset removes pacing between synthetic requests. The original EPG tests may
use the vault's host fallback. The separate storage processes use production
`open()` and host DPAPI; on Windows, `open()` still selects host FFI SQLite.
None of these phases proves Tizen/webOS database selection, TV secure storage
or lifecycle. Full browsing/player orchestration, playback, cloud services,
native TV input/plugin registration, signing and device compatibility remain
outside this proof. The bootstrap's MediaKit DLL initialization is a host result,
not evidence of a Tizen player. R02 remains open until the native SDK/dependency and
adapter gates are separately qualified; this harness does not close R03 or
device acceptance.
