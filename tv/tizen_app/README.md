# Isolated Tizen application staging

`stage.py` creates generated packaging inputs on Linux ext4. The original
application is mounted read-only at `/owner`; `iptvs` resolves directly there.
Builds must use `--target=/owner/tv/app/main.dart`. No original Dart source,
UI, repository or state implementation is copied into the wrapper.

The generated pubspec takes the owner's `1.0.7+2008` version, `^3.13.5`
SDK contract, existing dependency overrides and complete Flutter asset/font
declaration. Declared files retain their original asset keys and SHA-256.
The owner lock is seeded into the isolated wrapper: existing versions and
sources are retained, path metadata is rebased to `/owner`, and `iptvs` is
added as a path dependency. Pub resolution runs only in this wrapper.

Four non-endorsed platform packages are explicit exact-version dependencies:
`path_provider_tizen 2.3.3`, `flutter_secure_storage_tizen 0.1.6`,
`package_info_plus_tizen 1.2.0`, and `url_launcher_tizen 2.1.7`.
The URL launcher repository's `2.1.8` is not a published package version.
There are no new dependency overrides. Unused `shared_preferences_tizen` and
`sqflite_tizen` are not added.

The wrapper also declares the local `tvbro_tizen_player` package. It pins
`video_player_avplay 0.8.22`; the original application's pubspec/lock stay
unchanged. `tv/app/main.dart` registers this native engine and surface before
calling the original `main()`. Both existing player factories and the original
overlay use the narrow `PlaybackBackend` boundary. Tizen does not initialize
libmpv, construct a MediaKit video controller, or launch desktop Linux mpv.
See [Samsung installation requirements](SAMSUNG_TESTING.md).

## Prepare and create

Use the existing pinned Linux image/toolchain. Mount `/owner` read-only and
the output directory on writable ext4. Python 3 and an existing PyYAML are
required; the script never installs dependencies. `--yaml-module` may point
to the engine checkout's existing `third_party/pyyaml/lib` directory.

```bash
python3 /owner/tv/tizen_app/stage.py prepare \
  --owner /owner --project /output/tvbro_tizen \
  --yaml-module /yaml
```

When the isolated CLI is ready, create the native skeleton in that same
wrapper. Its repository must be pinned to
`22bcec9058fbe1e0943e6c6fda21792f24868e91`, and its configured Flutter checkout
must already match the owner's qualified framework pin
`abaf9c523780a608bd46686fd5e53740a07077f8`.

```bash
python3 /owner/tv/tizen_app/stage.py create-native \
  --owner /owner --project /output/tvbro_tizen \
  --yaml-module /yaml \
  --flutter-tizen /opt/tvbro-tizen-toolchain/flutter-tizen/bin/flutter-tizen
```

The pinned CLI generates the C# `App.cs`, project and native manifest with
`create --platforms=tizen --tizen-language=csharp --empty --no-pub`.
Newly generated sample Dart entrypoint/test files are removed; the original
target stays outside the wrapper. Before invocation the generator rejects
tracked/untracked changes in the SDK template subtree, which upstream create
cleans. It also prevents the CLI bootstrap from resetting a mismatched Flutter
checkout.
Create emits a sample lock even with `--no-pub`; the generator records its hash
and restores the exact owner-derived seed bytes before wrapper resolution.

The generated native manifest takes version `1.0.7`, profile `tv`, API `6.0`,
the `TVBro` label, and Internet/URL-launch privileges. The generated C# target
is aligned to `tizen60`; upstream currently generates `tizen80`. Its referenced
native icon is replaced byte-for-byte with the existing
`assets/brand/tvbro-icon.png` from the owner launcher configuration. That input
and copy have protected hashes. Build number `2008` remains in the wrapper
pubspec and evidence. No handwritten C# template or plugin registration is
maintained here.

## Resolution and safety

The toolchain owner runs ordinary `pub get`, never `pub upgrade`, from the
generated wrapper with an isolated writable cache. Afterwards:

```bash
python3 /owner/tv/tizen_app/stage.py verify-lock \
  --owner /owner --project /output/tvbro_tizen --yaml-module /yaml
```

Verification rejects changed common package versions, sources, hosted hashes
or Git refs, additional overrides, changed asset bytes, or an `iptvs` package
root outside `/owner`. Removed unused owner packages and newly needed platform
packages are listed separately. Protected source/manifest hashes are recorded
before and after every action. Concurrent edits to the owner are preserved;
they require a new staging baseline instead of being reverted.

`.tvbro/build-defines.json` keeps cloud bootstrap disabled and selects the
development distribution. Every build must pass the recorded required target
and `--dart-define-from-file` arguments from `.tvbro/prepare.json`.
This generator performs no pub resolution, TPK build or runtime test.

`.tvbro/runtime-dependencies.json` records the complete owner dependency
surface. The TV entrypoint selects the AVPlay adapter while ordinary entrypoints
retain MediaKit initialization and their existing backends. Tizen reports Linux to Dart, so the existing
database route selects `databaseFactoryFfi`; registering `sqflite_tizen` would
not change that route. The default stage introduces no database factory or
sqlite native-assets hook. File picker and transitive app links also have no implementation
supplied here. The original external-app URL requests use the published
launcher's legacy launch path; success still requires an installed URL handler
(which may be absent on a TV emulator). Staging does not qualify any of these
runtime dependencies.

An explicit TV-only system SQLite candidate can be configured after the SDK
audit, while no build is running. Source `tv/tizen_builder/env.sh` first so
`TIZEN_SDK` identifies the audited isolated SDK:

```bash
python3 /owner/tv/tizen_app/stage.py configure-sqlite \
  --owner /owner --project /path/to/the/generated/project --yaml-module /yaml \
  --sqlite-proof /owner/tv/output/tizen-app/20261024/sqlite-audit/proof.json
```

The action requires schema-v1 proof, the actual API 6 SDK library hash/ARM ELF
and completed SDK-package log hash. It changes only the generated pubspec's
SQLite hook to Linux `system`, named `/usr/lib/libsqlite3.so.0`; no SDK library
is copied to the package. Runtime, FTS and optional status/session APIs remain
unqualified. The normal lock/owner verification still applies after pub get.
The primary hook contract is the locked `sqlite3 3.7.1` package's `doc/hook.md`
and `lib/src/hook/compile/description.dart`.

Generated projects, `.dart_tool`, locks, native files and evidence belong in
ignored `tv/output` or the isolated Linux workspace, never this source folder.

## Measured qualification

Official create, ordinary wrapper pub get, lock verification and managed C#
compilation passed. The first local TPK was signed using the installed SDK
1.1.7 `Sign` task after fixing the real SDK Secret Service dependency. All
33 captured binary/resource files match the resulting archive; no Dart source
was recompiled during signing. The [report](../VALIDATION.md) links the package,
exact hashes, kernel-source provenance and remaining runtime boundaries.
The first package predates the AVPlay integration. The current player, device
detection and TV input seams have host test coverage; actual decoding, storage
execution and Samsung installation still require a physical-device run.

Primary references: [pinned create command](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/lib/commands/create.dart),
[C# template](https://github.com/flutter-tizen/flutter-tizen/tree/22bcec9058fbe1e0943e6c6fda21792f24868e91/templates/ui-app/csharp),
[TV profile](https://developer.samsung.com/tizen/Smart-TV/Quickstarts/Creating-an-application.html),
[Tizen 6 .NET target](https://developer.samsung.com/tizen/blog/en/2019/06/13/using-tizennetsdk-as-sdk-style),
[Tizen platform packages](https://github.com/flutter-tizen/plugins/tree/main/packages).
