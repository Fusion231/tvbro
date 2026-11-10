#!/usr/bin/env bash
# Run from TVBro-Builder WSL as root, or from its prepared container as UID10000.
# Uses only an existing SDK/profile; never installs SDKs or contacts a TV.
set -euo pipefail

if [[ ! -f /.dockerenv ]]; then
  [[ "${WSL_DISTRO_NAME:-}" == TVBro-Builder ]] || { echo "Use TVBro-Builder WSL." >&2; exit 2; }
  docker_socket=unix:///var/run/docker.sock
  running="$(docker --host "$docker_socket" inspect -f '{{.State.Running}}' tvbro-tizen-toolchain)"
  if [[ "$running" != true ]]; then
    docker --host "$docker_socket" start tvbro-tizen-toolchain >/dev/null
  fi
  exec docker --host "$docker_socket" exec tvbro-tizen-toolchain \
    /usr/sbin/runuser -u tvbro-sdk -- /bin/bash \
    /owner/clients/tv/samsung_web/tools/package-wgt.sh "$@"
fi

[[ "$(id -u)" == 10000 ]] || { echo "Require tvbro-sdk UID10000." >&2; exit 2; }
source /owner/clients/tv/tizen_builder/env.sh
[[ "$HOME" == /opt/tvbro-tizen-toolchain/home ]] || { echo "Unexpected SDK HOME." >&2; exit 2; }
manifest=/owner/clients/tv/output/samsung-web/latest-build.json
expected_sha=
unsigned=false
profile=TVBroLocalQualification
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) manifest="$2"; shift 2 ;;
    --expected-manifest-sha) expected_sha="$2"; shift 2 ;;
    --unsigned) unsigned=true; shift ;;
    --profile) profile="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "Pass the final latest-build.json SHA-256." >&2; exit 2; }
[[ "$profile" =~ ^[A-Za-z0-9_.\ -]{1,64}$ ]] || { echo "Invalid SDK certificate profile name." >&2; exit 2; }

stamp="$(date -u +%Y%m%dT%H%M%S%N)"
work="/opt/tvbro-tizen-toolchain/work/samsung-web-$stamp"
evidence="/evidence/samsung-web/$stamp"
helper=/owner/clients/tv/samsung_web/tools/package-wgt.py
python3 -B "$helper" stage "$manifest" "$work" "$evidence" "$expected_sha"

if [[ "$unsigned" == true ]]; then
  python3 -B "$helper" unsigned "$work" "$evidence"
  exit
fi

# A WSL idle restart may stop private DBus/keyring processes. Initialize and
# package within this same active WSL invocation; no private values are printed.
if [[ "$profile" == TVBroLocalQualification ]] && ! python3 -B /owner/clients/tv/tizen_builder/local-signing.py >"$evidence/local-signing.log" 2>&1; then
  echo "Existing local qualification profile could not be initialized: $evidence/local-signing.log" >&2
  exit 1
fi
source /owner/clients/tv/tizen_builder/env.sh
set +e
timeout 180 "$TIZEN_SDK/tools/ide/bin/tizen" package \
  -t wgt -s "$profile" -o "$work/out" -- "$work/payload" \
  >"$evidence/package.log" 2>&1
sdk_exit=$?
set -e
python3 -B "$helper" verify "$work" "$evidence" "$sdk_exit" "$profile"
