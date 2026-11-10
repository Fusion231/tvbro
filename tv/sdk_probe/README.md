# Tizen SDK qualification probe

Checked **24 October 2026**. Result: **blocked before Tizen AOT**. The current
official Tizen toolchain remains too old for the app's Dart constraint. A newer
host frontend plus the published Tizen compiler also fails an actual compilation;
using the original target platform dill does not fix it.

The separate **Application mode now compiles the full canonical app entrypoint**
with Dart 3.13.5 and the matching cached ARM control compiler. Its successful
result is explicitly **non-Tizen compilation evidence**; the native SDK gate
above remains open.

This directory owns a compilation fixture and an offline PowerShell 7 runner.
Default `SourceFixture` mode imports the original `package:iptvs`
`SourceConfig.build`, `Source` and M3U identity implementation. `Application`
mode uses the shared [`tv/app/main.dart`](../app/main.dart), which calls original
`package:iptvs/main.dart` `main()`. Neither mode copies their implementations or
runs the generated app, providers, a native linker, TPK packaging or a TV.

## Current official pins

Live GitHub API reads, rather than cached branch pages, returned:

| Component | Revision / version |
| --- | --- |
| `flutter-tizen` main | `22bcec9058fbe1e0943e6c6fda21792f24868e91`, pushed 23 October 2026 |
| Latest tool release | `3.47.5-tizen.1.0.1`, `cd5ad06b3e7ba93a392a3636a3b896aee5483eed`, published 20 October 2026 |
| Framework pin | `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`, Flutter 3.47.5 |
| Framework's upstream engine | `af7e796e161ae0bb1ff0758c71a7105418bd9ded` |
| Tizen engine / latest binary release | `a0e550d2b728d26d86bdbd981b33c9e9de7a656b` / `a0e550d2`, published 15 October 2026 |
| Tizen embedder pin on main | `cccce063cdb6783ed2a72ebc772adecc25808697` |
| Dart pin of framework and Tizen engine | `b530c21f7de367b94fb04787bfed9d8e989d75e8`, stable 3.13.4 |
| Existing host used in this experiment | Flutter 3.47.7 `abaf9c523780a608bd46686fd5e53740a07077f8`, upstream engine `deb287481e3ce9468f3434937ced4240a70539ca`, Dart 3.13.5 `04bcd1036cdc799ac6564988f159ee454d42c822` |

The tool repository had only `main` and the older `master` branch. The engine
repository's newest release branch was `flutter-3.47.5`; its `master` still pins
Dart 3.8 dev. There was no published newer compatible SDK or open upgrade PR in
the inspected repositories. This is a dated inventory, not a promise about later
releases.

Primary sources: [tool branches](https://api.github.com/repos/flutter-tizen/flutter-tizen/branches?per_page=100),
[tool releases](https://github.com/flutter-tizen/flutter-tizen/releases),
[framework pin](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/bin/internal/flutter.version),
[engine pin](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/bin/internal/engine.version),
[engine branches](https://api.github.com/repos/flutter-tizen/flutter/branches?per_page=100),
[engine release](https://github.com/flutter-tizen/flutter/releases/tag/a0e550d2),
[engine DEPS](https://github.com/flutter-tizen/flutter/blob/a0e550d2b728d26d86bdbd981b33c9e9de7a656b/DEPS),
[Dart 3.13.4](https://github.com/dart-lang/sdk/blob/b530c21f7de367b94fb04787bfed9d8e989d75e8/tools/VERSION).

The [Windows launcher](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/bin/internal/shared.bat)
downloads its pinned Flutter framework and uses that installation's Dart to run
the CLI and pub. That default Dart 3.13.4 cannot satisfy the unchanged app's
`^3.13.5`. Separately, [TizenArtifacts](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/lib/tizen_artifacts.dart)
selects the Tizen-specific `gen_snapshot`; the
[kernel build target](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/lib/build_targets/application.dart)
inherits the framework's patched SDK and targets Linux. CLI host, target
compiler and runtime are separate compatibility gates.

## Actual experiment

Only two small official archives were downloaded into ignored
`tv/output/sdk-probe/`:

| Archive | Bytes | Integrity |
| --- | ---: | --- |
| [Windows-host ARM release compiler](https://github.com/flutter-tizen/flutter/releases/download/a0e550d2/tizen-arm-release_windows-x64.zip) | 1,649,446 | Published SHA-256 `48b4a0975bd3ef277c312a961e3d59aaad5d5b582ac0854627fcdc7a69b8dfa4`, verified locally |
| [Original framework-pinned product SDK](https://storage.googleapis.com/flutter_infra_release/flutter/af7e796e161ae0bb1ff0758c71a7105418bd9ded/flutter_patched_sdk_product.zip) | 4,108,252 | Published GCS MD5 `2HR5bwAxrIO0zfbm+uL+3g==`, verified; local SHA-256 `327401d6abaf81700d3a0c582c4dc16933d31560bc79910e4a06962e4b378671` |

The compiler archive contains `gen_snapshot.exe`, a Windows PE x86 executable
(`014C`), not an ARM executable. It runs on this Windows host and reports Dart
3.13.4 on `windows_simarm`. Its extracted SHA-256 is
`0cc1cd6ce1850a0e57e048b81b0221dabb310ba41b44f472345b13e1f85232c2`.
The [official asset metadata](https://api.github.com/repos/flutter-tizen/flutter/releases/tags/a0e550d2)
and GCS response metadata are retained beside the cached archives.

Both the existing host platform dill and the separately downloaded original
framework-pinned platform dill have SHA-256
`1ae5541b4d93fb1de5a6af4a6bcfde4430f5fe5d03ad42f35a2da2acfa02fd0e`.
Their kernel format is 138 and SDK hash is `0000000000` in the untouched files.
The zero hash is part of the published artifacts, not a local modification.

| Gate | Observed result |
| --- | --- |
| Existing Dart 3.13.5 runtime / original package graph | Selected SDK matches the graph's Flutter root; `iptvs` resolves to the original app directory. No pub command or constraint override runs. |
| Frontend 3.13.5, Flutter target, Linux OS, AOT/TFA | Exit 0, compiles the original factory, source implementations and identity owner into kernel format 138, SDK hash `04bcd1036c`. |
| Official Tizen compiler 3.13.4 on that kernel | Exit **254**, literal stderr **`ApiError`**. No Tizen ELF is produced. |
| Original Tizen-framework-pinned platform dill | Same failure, with byte-identical target libraries. Changing the platform dill cannot change the SDK hash embedded by the compiled frontend. |
| Positive control: already cached 3.13.5 Windows-host ARM compiler, same kernel | Exit 0, produces an ARM ELF. This is a compiler control only; it is not a Tizen native build. |
| Protected input hashes | No changes to the inspected original sources, root manifest, lockfile or package config. |

The final repeatable run is
`tv/output/sdk-probe/20261024T103452136Z-tizen-pinned-platform/evidence.json`;
command arguments, stdout/stderr, headers and hashes are retained there.
The first exploratory run is retained separately. No SDK hash, kernel bytes,
manifest requirement or original implementation was patched.

The [Dart patch diff](https://github.com/dart-lang/sdk/compare/3.13.4...3.13.5)
contains no VM ABI or kernel binary-format change. That alone does not establish
interoperability: [kernel loading](https://github.com/dart-lang/sdk/blob/b530c21f7de367b94fb04787bfed9d8e989d75e8/runtime/vm/kernel_binary.cc)
also checks the SDK hash, and the Tizen compiler's pinned Dart revision begins
`b530c21f7d`, unlike the actual kernel's `04bcd1036c`. The SDK-hash explanation
is supported by that source check and the positive control; the product compiler
itself printed only `ApiError`, so the report does not invent a more specific
runtime diagnostic.

## Full application compiler qualification — 24 October 2026

```powershell
./tv/sdk_probe/run.ps1 -EntryPoint Application -Variant application-main
```

This mode uses only the existing Flutter 3.47.7 / Dart 3.13.5 installation and
its cached Windows-host ARM compiler. It neither requires nor invokes the
incompatible Tizen 3.13.4 compiler; `CompilerArchive` is unused in this mode.
The original package graph must resolve `iptvs` to the app's `lib/` and Flutter
to the selected SDK. The runner checks the unchanged root `sdk: ^3.13.5` and
passes the existing `-DTVBRO_CLOUD_ENABLED=false` switch to the frontend. No pub
command, replacement manifest, SDK override or generated native-asset manifest
is used.

| Gate | Observed result |
| --- | --- |
| Shared TV entrypoint → original `lib/main.dart` | Frontend exit 0; emitted depfile confirms **145 original Dart files** under `lib/`, including canonical `main.dart`. |
| Frontend SDK hash | `04bcd1036c`, unchanged and matching the Dart 3.13.5 control compiler. |
| Matching ARM control compiler | Exit 0; produces an ARM ELF. No Tizen compiler or runtime was used. |
| Input integrity | Root manifest, lockfile, package config, existing package graph/native-assets metadata, TV entrypoint and the original imported Dart graph retained their pre-run hashes. |

The stable successful run is
`tv/output/sdk-probe/20261024T134658985Z-application-main-stable/evidence.json`.
The runner snapshots original `lib/` hashes before compilation, then selects
the actual owner graph from the frontend depfile. On frontend failure without
a usable depfile it records the inventory without claiming a compiled import
graph. A changed protected input makes Application mode fail with
`blocked_inputs_changed`. The earlier exploratory run
`20261024T134516001Z-application-main` compiled successfully but exited 1 after
detecting a concurrent change to `lib/data/expiry_cache.dart`; it is not a
stable-input qualification result.

These artifacts were not executed. Native assets and plugins were not linked;
SQLite ABI, storage durability, device classification, MediaKit initialization
and rendering, application startup and TPK packaging remain unqualified. A
successful frontend does not establish those runtime properties.

## Repeat the original source-fixture experiment offline

With the verified archives cached and their two dill files already extracted:

```powershell
./tv/sdk_probe/run.ps1 -PatchedSdk ./tv/output/sdk-probe/flutter-3.47.5-platform -Variant tizen-pinned-platform
```

`SourceFixture` remains the default. It expects the compiler archive at
`tv/output/sdk-probe/tizen-arm-release_windows-x64.zip`. Optional `FlutterSdk`,
`CompilerArchive` and `PatchedSdk` parameters select existing paths; this exact
experiment remains pinned to the versions above. It does not download, install,
run pub, edit an SDK, or build Android/Windows. Every run creates a fresh output
directory, waits for child-process completion with a bounded deadline, and emits
`evidence.json`. Exit 1 is the expected blocked result for these pins.
Application mode returns 0 only for the stable full-app ARM control compilation
described above; that status does not mean a Tizen build succeeded.

## SDK choices and current resource gates — 24 October 2026

| Choice | Scope and decision |
| --- | --- |
| A: matching 3.13.4 frontend/runtime with official Tizen engine | ZIP metadata shows selective HTTP Range extraction could transfer about **8.62 MB** for the frontend and `dartaotruntime.exe`. Only ZIP metadata was read; frontend/runtime entries were not downloaded. It cannot qualify unchanged `iptvs` requiring `^3.13.5`. |
| B: isolated custom Tizen engine/compiler with Dart ≥3.13.5 | Preserves the owner's requirement and is the viable native SDK route pending a newer official release. Requires a real Linux build environment, native toolchain/sysroot and source dependency checkout. Not built here. |
| C: current matching host frontend/compiler, full canonical entrypoint | Implemented above. Advances the original-app compilation graph without waiting for B, while keeping native Tizen qualification separate. |

An independent TV manifest can add platform dependencies while retaining the
owner's SDK requirement. A path dependency on `iptvs` still carries its
`^3.13.5` constraint under [pub's SDK rules](https://dart.dev/tools/pub/pubspec#sdk-constraints).
Restaging the same sources under a manifest with a lower requirement would
bypass that owner contract unless a separate TV baseline were explicitly
approved. No such lowering, source restaging or SDK-hash patch is used here.

The official [engine build flow](https://github.com/flutter-tizen/flutter-tizen/wiki/Building-the-engine-from-source)
supports a local engine. The pinned [CI workflow](https://github.com/flutter-tizen/flutter/blob/a0e550d2b728d26d86bdbd981b33c9e9de7a656b/.github/workflows/build.yml)
builds Tizen runtime/ICU and the host ARM compiler on Linux; its Windows job
builds only `gen_snapshot.exe`. Its Linux container supplies the native
toolchain, and `generate_sysroot.py` supplies the Tizen sysroot. ARM/release can
be selected alone and Android/Fuchsia SDK downloads disabled as upstream CI
does. The [Dart patch diff](https://github.com/dart-lang/sdk/compare/3.13.4...3.13.5)
has no VM or DEPS changes, so an isolated Dart revision roll is a small source
change; it still needs a rebuilt, qualified engine/compiler pair.

Read-only local checks found about **2.5 GiB free on D:**, an unavailable Docker
Linux daemon and a registered Ubuntu WSL distribution whose `ext4.vhdx` is
missing (`Wsl/Service/CreateInstance/MountDisk/HCS/ERROR_PATH_NOT_FOUND`). The
official `ghcr.io/flutter-tizen/build-engine` Linux image alone has
**1,017,585,910 compressed bytes** of layers (manifest
`sha256:cc6e431ffd60bdbe6bb20b2178c1dc4897a408f6c51728d3b59b5a9394bbe797`).
The complete checkout/build needs additional multi-gigabyte capacity; that is
a planning estimate, not a measured full-build size. B was therefore not
started. No image, dependency checkout, WSL repair, global installation or
large download was performed for this investigation.

### Subsequent authorized WSL repair and custom engine build

After the user requested WSL repair, a separate Ubuntu 24.04 distribution
`TVBro-Builder` was installed on G: and made the default. The old Ubuntu
registration was retained; its missing VHDX/data was not recovered. Docker
Engine was installed only inside the new distro and passed `hello-world`.
This supersedes the earlier local-environment blocker above.

The [isolated builder](../engine_builder/README.md) then built the pinned Tizen
engine with Dart `04bcd1036cdc799ac6564988f159ee454d42c822` (3.13.5), including
the ARM engine library and Linux-host ARM `gen_snapshot`. The built compiler
accepted the unchanged stable full-application `app.dill` and produced an ARM
AOT ELF with exit 0. The kernel's SDK hash/bytes and application requirements
were not patched or lowered. Full [evidence](../output/engine-builder/20261024/completed/evidence/runs/20261024T172727589059Z/evidence.json)
and limits are in [validation](../VALIDATION.md).
An additional [target-flag qualification](../output/engine-builder/20261024/tizen-aot-qualified/evidence.json)
passed with both official Tizen ARM flags and soft-float ELF flags matching
the runtime; the initial generic ARM AOT was retained separately.

This is a CUSTOM engine/compiler pair built from source, not an official SDK
release. It removes the measured compiler/kernel version mismatch for that
pair. It does not establish application plugin linking, runtime execution,
TPK packaging, or TV compatibility. The app's Android/Windows/shared source
and manifests remain untouched by this work.

## Further TV-only gates

A matching Tizen toolchain must provide a Dart 3.13.5-or-newer CLI/frontend **and**
matching target `gen_snapshot` and runtime artifacts. Prefer an upstream release
that ships them together. An alternative is a separately built Tizen engine and
cross-compiler from the official fork with a matching Dart roll, qualified as a
custom SDK; that requires the native toolchain/rootstrap and is larger work than
this probe. Neither was installed or built here.

The original entrypoint's host frontend/control gate has now passed. With a
matching Tizen SDK, compile that same shared entrypoint and qualify
plugin/native-asset linking and TPK packaging. Keep the app's shared code and
dependencies unchanged. Database,
device-class and player seams identified in
[`native_probe/QUALIFICATION.md`](../native_probe/QUALIFICATION.md) still require
their own decisions; this SDK experiment does not remove them. Physical-TV
execution remains deferred.
