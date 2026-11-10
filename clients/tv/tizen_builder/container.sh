#!/usr/bin/env bash
# Run from the dedicated WSL distro; retain the container for create/pub/build.
set -euo pipefail
test "${WSL_DISTRO_NAME:-}" = TVBro-Builder
image='ghcr.io/flutter-tizen/build-engine@sha256:cc6e431ffd60bdbe6bb20b2178c1dc4897a408f6c51728d3b59b5a9394bbe797'
name=tvbro-tizen-toolchain
root=/opt/tvbro-tizen-toolchain
evidence=/mnt/d/tvbro/app/clients/tv/output/tizen-builder/20261024
mkdir -p "$root" "$evidence"
if ! docker --host unix:///var/run/docker.sock container inspect "$name" >"$evidence/container.json" 2>/dev/null; then
  docker --host unix:///var/run/docker.sock run --detach --name "$name" --restart unless-stopped \
    --mount "type=bind,src=$root,dst=$root" \
    --mount 'type=bind,src=/mnt/d/tvbro/app,dst=/owner,readonly' \
    --mount 'type=bind,src=/mnt/d/tvbro/evaluation/tooling/flutter,dst=/host-flutter,readonly' \
    --mount 'type=bind,src=/opt/tvbro-tizen-engine-a0e550d2-dart3135,dst=/engine,readonly' \
    --mount 'type=bind,src=/opt/tvbro-tizen-app/stage-20261024T181105715Z,dst=/output' \
    --mount "type=bind,src=$evidence,dst=/evidence" \
    --env "TVBRO_BUILDER_IMAGE=$image" \
    "$image" sleep infinity
  docker --host unix:///var/run/docker.sock container inspect "$name" >"$evidence/container.json"
fi
python3 - "$evidence/container.json" "$image" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))[0]
assert c['Config']['Image']==sys.argv[2]
mounts={m['Destination']:m for m in c['Mounts']}
for name,source in {'/owner':'/mnt/d/tvbro/app','/host-flutter':'/mnt/d/tvbro/evaluation/tooling/flutter','/engine':'/opt/tvbro-tizen-engine-a0e550d2-dart3135'}.items():
    assert mounts[name]['Source']==source and mounts[name]['RW'] is False,name
assert mounts['/opt/tvbro-tizen-toolchain']['RW'] is True
PY
if [ "$(docker --host unix:///var/run/docker.sock inspect --format '{{.State.Running}}' "$name")" != true ]; then docker --host unix:///var/run/docker.sock start "$name"; fi
docker --host unix:///var/run/docker.sock exec "$name" bash /owner/clients/tv/tizen_builder/setup.sh --phase "${1:-cli}" "${@:2}"
