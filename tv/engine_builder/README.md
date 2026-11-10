# Custom Tizen ARM engine builder

This runner builds a **CUSTOM** engine/compiler pair from the official Tizen
fork, rolling only its isolated Dart source pin to 3.13.5. It then compiles the
unchanged kernel from the existing full-application qualification. It does not
run the application, link application plugins, package a TPK, or test a TV.
The original application, Android, Windows, manifests and services are not
mounted writable or edited.

## Inputs and environment

- Engine: `a0e550d2b728d26d86bdbd981b33c9e9de7a656b`.
- Dart: `04bcd1036cdc799ac6564988f159ee454d42c822` (3.13.5).
- Image: `ghcr.io/flutter-tizen/build-engine@sha256:cc6e431ffd60bdbe6bb20b2178c1dc4897a408f6c51728d3b59b5a9394bbe797`.
- Linux x86_64 Docker, with a persistent, initially empty **ext4** directory
  bound at `/work`. Keep this directory inside the builder WSL distribution;
  the distribution's VHDX may live on G:, but the checkout must not use
  `/mnt/g` or another Windows filesystem.
- Bind this directory at `/builder:ro`; bind the existing stable probe run at
  `/control:ro`. Its `app.dill` must have SHA-256
  `04c80cfa32a25830bf653c80af186ae82bae56371dcc95e3770c44febe42164f`.
  The accompanying `evidence.json` must retain its successful Application-mode
  status, 145 original Dart files, and empty changed-input list.

The image contains the Tizen LLVM 18.1.8 toolchain, built with clang 11, on
Ubuntu 22.04. The runner installs only container prerequisites `ninja-build`,
`unzip` and `patch`. The first depot_tools phase records its remote HEAD before
fetching that exact commit; `DEPOT_TOOLS_UPDATE=0` keeps subsequent invocations
on the recorded code. Version capture and builds use `/usr/bin/ninja` explicitly
to select the installed binary instead of the depot_tools shim. Container reference and image ID are supplied by the host
and recorded as host-supplied provenance; the runner cannot inspect its own
Docker image through the daemon.

## Invocation

For the dedicated repaired Ubuntu 24.04 distro, `setup-linux.sh` installs
Docker from its signed official APT repository and verifies `hello-world`.
It refuses any distro other than `TVBro-Builder`; it does not configure
Windows Docker Desktop. Its optional argument selects the evidence directory.

Run these commands **inside the repaired builder distro**, after Docker is
ready and the pinned image has been pulled. Adjust only the first directory
to an empty directory in that distro's Linux filesystem. Do not recreate or
clear an existing workspace to retry a failed phase.

```bash
builder_work="$HOME/tvbro-tizen-engine"
mkdir -p "$builder_work"
image='ghcr.io/flutter-tizen/build-engine@sha256:cc6e431ffd60bdbe6bb20b2178c1dc4897a408f6c51728d3b59b5a9394bbe797'
image_id="$(docker image inspect --format '{{.Id}}' "$image")"
docker run --rm --name tvbro-tizen-engine \
  --mount "type=bind,src=$builder_work,dst=/work" \
  --mount 'type=bind,src=/mnt/d/tvbro/app/tv/engine_builder,dst=/builder,readonly' \
  --mount 'type=bind,src=/mnt/d/tvbro/app/tv/output/sdk-probe/20261024T134658985Z-application-main-stable,dst=/control,readonly' \
  --env "TVBRO_BUILDER_IMAGE=$image" \
  --env "TVBRO_CONTAINER_IMAGE_ID=$image_id" \
  "$image" bash /builder/build.sh --jobs 8
```

The default is one ARM release configuration, eight Ninja jobs and no LTO.
A preflight requires 80 GiB free on `/work`. This is an operational guard for
the currently available 237 GiB builder filesystem, not a measured full-build
requirement or a guarantee that 80 GiB will suffice. `--min-free-gib` explicitly
selects a different floor when reviewing an existing partial build.
Android/Fuchsia downloads and the prebuilt Flutter Dart SDK are disabled as in
upstream CI. The official sysroot generator runs unchanged with API 6.0 and
generates all three sysroots; it has no architecture-selection option. The two
upstream compiler workarounds are checked against the pinned source before
application: one linker-flag removal and the two occurrences of the warning
spelling replacement.

`gclient setdep` retains expression-valued DEPS flags as the literal string
`'False'`, while other flags become the boolean `False`. Its condition evaluator
parses the string recursively to the same false boolean. The validator accepts
exactly these two disabled forms and retains the exact Dart-revision check.

Every child process is awaited directly. The runner performs no repeated
status polling, automatic Git retries, automatic sync retries or background
jobs. A host invoking Docker asynchronously should immediately attach its
completion observer and inspect the terminal result once it finishes.

## Resume and evidence

Completed source/build phases are reused. Container prerequisites are checked
again on every invocation: when `--rm` has discarded installed tools, the
packages phase provisions the new container and records a new attempt. This
does not repeat any source fetch or dependency sync.

`--stop-after sync` (or any phase listed by
`--help`) ends after the requested successful phase and can be followed by the
same command without that option. An interrupted or failed phase requires an
explicit flag, for example `--retry-phase sync`. This retries that phase using
the existing checkout/cache. A successful source/build phase cannot be forced
to run again in the same workspace. A changed pin requires a new empty workspace. No source
tree, cache or user data is deleted.

Persistent paths:

- `/work/state/*.json`: phase state, attempt number, exact commands and exits.
- `/work/state/depot_revision.txt`: the frozen depot_tools commit.
- `/work/evidence/runs/<UTC>/`: complete phase logs, event log and run evidence;
  the workaround/gn phases also retain the source diff and generated `args.gn`.
- `/work/evidence/tool-versions.json`: actual Git, Ninja, GN, Tizen Clang,
  Python, depot_tools and installed container package versions.
- `/work/evidence/terminal.json`: a small terminal status and link to the run.
- `/work/artifacts/custom-tizen-arm-release/`: `libflutter_engine.so`,
  `icudtl.dat`, Linux-host `gen_snapshot`, and `application-tizen-arm.so`.

Success requires a Dart 3.13.5 compiler, an ARM runtime and application ELF,
an x86_64 Linux compiler ELF, and unchanged control-kernel bytes. Artifact
hashes, commands and the original qualification evidence are retained. A
successful status describes this custom build and AOT compilation only.

New ARM controls pass `--no-sim-use-hardfp` and `--no-use-integer-division`,
matching the [pinned Tizen ARM alias](https://github.com/flutter-tizen/flutter-tizen/blob/22bcec9058fbe1e0943e6c6fda21792f24868e91/lib/tizen_build_info.dart)
and [Flutter AOT snapshotter](https://github.com/flutter/flutter/blob/6a19cca56475dbfba1478ee68d7bd0c2ef891da1/packages/flutter_tools/lib/src/base/build.dart). The first
flag selects the soft-float calling convention used by the Tizen runtime.
The phase and final evidence record the actual compiler options. Reusing an
older completed control reads its recorded command; it does not claim that
these flags were used or regenerate that completed artifact.

The compressed image was measured at 1,017,585,910 bytes. The first successful
run completed all 6,611 Ninja actions in about 7 min 45 s with eight jobs;
the complete persistent workspace occupied about 9.7 GiB afterwards. These are
observations of this build, not capacity guarantees. Expanded image size and
peak memory remain unmeasured.

## Measured result — 2026-10-24

The build and unchanged full-application kernel AOT qualification passed.
`gen_snapshot` reports Dart SDK 3.13.5 stable; `libflutter_engine.so` and the
application AOT are ARM ELF32, while the compiler executable is x86_64 ELF64.
The runtime library is 10,045,816 bytes and the AOT is 12,517,960 bytes.
The [complete evidence](../output/engine-builder/20261024/completed/evidence/runs/20261024T172727589059Z/evidence.json)
retains all phases, exact commands and artifact hashes. Two earlier attempts
stopped at a DEPS flag representation check and the depot_tools Ninja shim;
the final runner handles gclient's exact `'False'` expression value and uses
the real `/usr/bin/ninja` installed in the container. Existing sync/sysroot
outputs were reused when resuming.

The separate [Tizen ARM qualification](../output/engine-builder/20261024/tizen-aot-qualified/evidence.json)
then compiled the same unchanged kernel with both official ARM flags to
`application-tizen-arm-qualified.so` (12,534,344 bytes). It passed with ARM
ELF32 `ET_DYN`, soft-float flags `0x5000200` matching the runtime, and both
required snapshot exports. The original kernel, compiler, engine and first
AOT hashes remained unchanged; the first AOT is retained separately. An
[ELF audit](../output/engine-builder/20261024/audit/readelf-audit.log) also
checks runtime exports and reports dependency/version requirements.

This result qualifies source build and AOT compilation only. Runtime execution,
application plugin linking and TPK packaging remain unperformed.

Primary references: [pinned CI](https://github.com/flutter-tizen/flutter/blob/a0e550d2b728d26d86bdbd981b33c9e9de7a656b/.github/workflows/build.yml),
[image recipe](https://github.com/flutter-tizen/flutter/blob/a0e550d2b728d26d86bdbd981b33c9e9de7a656b/engine/src/flutter/ci/tizen/Dockerfile),
[sysroot generator](https://github.com/flutter-tizen/flutter/blob/a0e550d2b728d26d86bdbd981b33c9e9de7a656b/engine/src/flutter/ci/tizen/generate_sysroot.py),
[local-engine guide](https://github.com/flutter-tizen/flutter-tizen/wiki/Building-the-engine-from-source).
