# Isolated Tizen packaging toolchain

Run `setup.sh` in the already pinned Ubuntu 22.04 engine container image. It
prepares only tools for a C# TV ARM release build, reusing the qualified engine.
It does not build the engine again, modify the original app, run pub in the
original app, contact a TV, or publish anything.

Required container mounts:

- `/opt/tvbro-tizen-toolchain`: a new persistent Linux ext4 directory, writable.
- `/owner`: original `D:/tvbro/app`, **read-only**, including these scripts.
- `/host-flutter`: existing `D:/tvbro/evaluation/tooling/flutter`, **read-only**.
- `/engine`: existing `/opt/tvbro-tizen-engine-a0e550d2-dart3135`, **read-only**.
- `/evidence`: `app/tv/output/tizen-builder/20261024`, writable.

The official SDK installer refuses root. The setup creates UID 10000
`tvbro-sdk` only inside the container, with its home under the isolated tool
directory. Container prerequisites do not install Android, GTK desktop, an
emulator, or an IDE. The installer bundles its own Java runtime.
SDK 10.0 also requires its destination to be inside that user's home, so
`TIZEN_SDK` is `/opt/tvbro-tizen-toolchain/home/tizen-sdk`.

The SDK's GCC package preflight requires real `python3.8`/`libpython3.8` packages.
Setup installs them side by side only in the disposable Ubuntu 22.04 container,
using the signed official Ubuntu Focal base/updates repositories pinned below Jammy.
An APT plan is retained and rejected if it removes packages or replaces the
default Python. Python 3.10 remains the default. No fake Python binaries or
package-manager success overrides are used; earlier failed attempts remain in
the evidence directory.

Root should review before invoking the large phases. The first small command is:

```bash
bash /owner/tv/tizen_builder/setup.sh --phase prerequisites
```

`container.sh cli` runs the reviewed mount contract from `TVBro-Builder`, using
the explicit local Docker socket and the persistent `tvbro-tizen-toolchain`
container. Its `/output` mount is the original prepared stage; newer wrappers
can be prepared under `/opt/tvbro-tizen-toolchain/work` in the same container.
Retain this container: its Python 3.8 and system compatibility libraries are
installed in its filesystem, not in the persistent tools mount.

Then run `--phase all`. Each phase writes a complete log and terminal JSON to
`/evidence`; child commands are awaited directly without polling. Completed
phases are reused. A failed/interrupted phase needs explicit `--retry PHASE`.
Git fetches, SDK installation and downloads are never automatically retried.
Partial downloads remain available for a user-authorized retry. There is a
20 GiB operational free-space floor, not a measured storage requirement.

Pinned inputs:

- Flutter-Tizen `22bcec9058fbe1e0943e6c6fda21792f24868e91`.
- Its **isolated** framework pin changes to owner Flutter
  `abaf9c523780a608bd46686fd5e53740a07077f8`, Dart 3.13.5. The Git objects are
  reused read-only from `/host-flutter`; Windows binaries/cache are not copied.
- Custom engine/compiler/ICU from the existing successful native build.
- Embedder `cccce063cdb6783ed2a72ebc772adecc25808697`, only `tizen-common.zip`
  and `tizen-6.0-arm.zip`, checked against published SHA-256 digests.
- .NET SDK **8.0.426**, checked against Microsoft's published SHA-512.
- Tizen SDK **10.0 CLI**, 401,290,863 bytes. The official installer checks its
  embedded archive; local SHA-256 is retained. No independent published full
  installer SHA-256 is claimed.
- Native CLI, GCC 9.2 (whose official metadata also depends on LLVM 10.0),
  IOT-Headed 6.0 CLI/rootstraps, and certificate-generator/encryptor CLI tools.
  The graphical Certificate Manager is unnecessary for a local qualification key.

The stock Tizen cache requests every architecture/mode. `configure-cache.py`
narrows only the isolated CLI's two artifact lists to real ARM release files
and the API 6.0 embedder. It does not create empty placeholder cache directories.
The normal base/embedding stamps remain upstream pins; `custom-cache.json`
explicitly identifies the runtime/compiler as **CUSTOM**, with exact hashes.
`isolated-cli.diff` retains the framework-pin and cache-list changes. This SDK
is deliberately limited to ARM release TV API 6.0; other modes are unqualified.

Before TV project commands, source `/owner/tv/tizen_builder/env.sh` and run as
`tvbro-sdk` in the generated project on ext4. The wrapper stage owns its own
manifest/package graph and imports `/owner` read-only. Signing must use a local
qualification profile; no Samsung account, device certificate, store upload or
TV connection is part of setup. A later device-install package needs a Samsung
profile scoped to that TV's DUID; see `../tizen_app/SAMSUNG_TESTING.md`.

The actual setup and verification passed on 2026-10-24. Evidence includes
`20261024T183710-sdk.log`, `20261024T190922-verify.log`, `compiler-version.txt`,
`tpk-help.txt`, `custom-cache.json`, and `container-packages.txt`. The real
compiler is `$TIZEN_SDK/tools/llvm-10/bin/clang` (Tizen clang 10.0.0); its
Ubuntu `libtinfo5` dependency is installed. The API 6.0 ARM rootstrap is
`$TIZEN_SDK/platforms/tizen-6.0/iot-headed/rootstraps/iot-headed-6.0-device.core`.
These checks establish tool readiness; an application TPK build is separate.

`local-signing.py`, run as `tvbro-sdk` after sourcing `env.sh`, creates the real
SDK author certificate and `TVBroLocalQualification` security profile for local
qualification. Its P12 and CSPRNG password remain in `$HOME/private` with mode
0600, inside a mode 0700 directory. Commands and captured output redact the
password. Existing keys are reused. Build with
`--security-profile TVBroLocalQualification`; do not export the private directory.
`local-signing-profile.json` records the public certificate and sanitized log.

SDK 10's `secret-tool` requires Secret Service. Run `setup-secret-service.sh`
once as container root: it extracts the official Ubuntu `gnome-keyring`
40.0-3ubuntu3 daemon into the tools directory and installs only its headless
library dependencies, avoiding the GTK/systemd package stack. The signing
helper starts a private D-Bus and unlocks an encrypted keyring using a separate
CSPRNG password, all under `$HOME/private`. SDK `.pwd` attributes are logical
keyring references; no placeholder `.pwd` files are created.

Run `local-signing.py` immediately before packaging/build in the same active
WSL invocation. Idle WSL/container restarts terminate the daemons; the helper
restores them and validates both author and distributor lookups. Then keep
the environment from `env.sh` for the build. `signing-interop.py` separately
checks both decoded passwords against the exact SDK 1.1.7 BouncyCastle DLL
(assembly version 1.8.1.0), emitting only lengths, hashes, and load results.
The successful cross-process proof is
`signing-interop-20261024T194358.json`; earlier failure evidence is retained.

The CLI's legacy .NET packaging path still passes SDK 10 `.pwd` references as
literal passwords to SDK 1.1.7. `package-existing.py` resolves those private
keyring references and invokes the installed SDK `Sign` task through
`PackageExisting.proj`. It takes a generated `work/*/tpkroot`, a new child of
`qualification/`, and an installed `--profile`. No Dart/native code is rebuilt;
the original, copied and signed payload must have identical hashes. Secrets
remain in the child process environment and are redacted from the saved log.
This helper does not turn a generic Tizen profile into a Samsung certificate.

Primary sources: [Tizen Linux requirements](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/doc/linux-install.md),
[SDK/compiler selection](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/lib/tizen_sdk.dart),
[cache lists](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/lib/tizen_cache.dart),
[supported CLI installer](https://github.com/Samsung/tizen-docs/blob/master/docs/sdk-tools/baseline-sdk/setup/install-sdk.md),
[Microsoft binary installation](https://learn.microsoft.com/dotnet/core/install/linux-scripted-manual).
