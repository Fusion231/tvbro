# Samsung WGT SDK and signing

The Samsung web client packages WGT files with the existing `TVBro-Builder`
WSL distribution and its `tvbro-tizen-toolchain` container. The active
`../samsung_web/tools/package-wgt.sh` uses `env.sh` and `local-signing.py` here.
Keep the prepared container and `/opt/tvbro-tizen-toolchain`: the SDK,
compatibility libraries, installed signing dependencies and private profiles
are stored there. Packaging does not install an SDK, contact a TV or publish.

## SDK bootstrap

`container.sh` runs from `TVBro-Builder` with its configured local Docker
socket, pinned Ubuntu 22.04 image and mounts. It mounts this checkout as
`/owner` read-only; the existing `/host-flutter`, `/engine` and `/output` mounts
must also remain available. Review that mount contract before recreating the
container. The scripts require at least 20 GiB free in the tools filesystem.

For SDK preparation, run these phases from the WSL checkout:

```bash
bash clients/tv/tizen_builder/container.sh prerequisites
bash clients/tv/tizen_builder/container.sh dotnet
bash clients/tv/tizen_builder/container.sh sdk
docker --host unix:///var/run/docker.sock exec tvbro-tizen-toolchain \
  bash /owner/clients/tv/tizen_builder/setup-secret-service.sh
```

`setup.sh` records phase logs under `/evidence`, reuses completed phases and
requires `--retry PHASE` after an interrupted or failed phase. Its optional
cache phases call the retained `configure-cache.py`; WGT packaging uses the
installed Tizen CLI directly. The bootstrap commands do not provision a
Samsung certificate or replace the prepared container's signing dependencies.

## Package the current web payload

Build the payload as described in [Samsung Web](../samsung_web/README.md).
From `TVBro-Builder`, package its locked manifest with the installed Samsung
profile and the final manifest's SHA-256:

```bash
bash clients/tv/samsung_web/tools/package-wgt.sh \
  --profile '<installed-Samsung-profile>' \
  --expected-manifest-sha '<latest-build.json-SHA256>'
```

The wrapper enters the prepared container as `tvbro-sdk` (UID 10000) and
sources `/owner/clients/tv/tizen_builder/env.sh`. `--manifest` selects another build
manifest. `--unsigned` creates an unsigned archive for inspection.

The default `TVBroLocalQualification` profile is only for local qualification.
For that profile, the wrapper runs `local-signing.py` immediately before
packaging to restore its private D-Bus/keyring session and reuse the saved
author key. To initialize it manually inside the container as `tvbro-sdk`:

```bash
source /owner/clients/tv/tizen_builder/env.sh
python3 -B /owner/clients/tv/tizen_builder/local-signing.py
```

Private keys and passwords stay under `$HOME/private`, with directory mode
0700 and key/password mode 0600. Keep them and the profile private; retain the
original author identity for updates. The helper also needs the prepared
container's installed `Tizen.NET.Sdk` 1.1.7 signing metadata.

## TV installation

A Samsung test install needs an existing Samsung Developer account, the
Samsung Certificate Extension and an installed Samsung TV profile whose
distributor certificate includes the target TV's DUID. Neither an unsigned
archive nor the generic local qualification profile grants installation
permission. Enable Developer Mode using the PC's IP and connect using the
TV's supplied IP; do not uninstall the existing app to work around a missing
author key. Packaging verification does not establish playback, remote or
storage behavior on the device. See [Samsung installation](../samsung_web/INSTALL.md)
for device setup and distribution requirements.
