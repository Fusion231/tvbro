#!/usr/bin/env bash
# Dedicated Ubuntu 22.04 container only; see README.md for the mount contract.
set -euo pipefail
ROOT=/opt/tvbro-tizen-toolchain
EVIDENCE=/evidence
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PHASE=all
RETRY=
while (($#)); do
  case "$1" in
    --phase) PHASE=$2; shift 2 ;;
    --retry) RETRY=$2; shift 2 ;;
    --help) echo 'setup.sh [--phase prerequisites|cli|dotnet|sdk|cache|verify|all] [--retry PHASE]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$PHASE" in prerequisites|cli|dotnet|sdk|cache|verify|all) ;; *) exit 2 ;; esac
test -f /.dockerenv
test "$(. /etc/os-release; echo "$VERSION_ID")" = 22.04
test "${TVBRO_BUILDER_IMAGE:-}" = 'ghcr.io/flutter-tizen/build-engine@sha256:cc6e431ffd60bdbe6bb20b2178c1dc4897a408f6c51728d3b59b5a9394bbe797'
test -d "$ROOT" && test -d "$EVIDENCE"
test "$(stat -f -c %T "$ROOT")" = ext2/ext3
test "$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')" -ge 20971520

if [ "$(id -u)" = 0 ]; then
  # Container packages only. No host distro package installation or desktop SDK.
  if ! command -v unzip >/dev/null || ! command -v zip >/dev/null || ! command -v make >/dev/null || ! test -f /usr/lib/x86_64-linux-gnu/libicuuc.so.70 || ! test -f /lib/x86_64-linux-gnu/libtinfo.so.5; then
    apt-get update >"$EVIDENCE/prerequisites.log" 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y unzip zip make file patch pciutils \
      libicu70 libgssapi-krb5-2 libssl3 libtinfo5 tzdata zlib1g >>"$EVIDENCE/prerequisites.log" 2>&1
  fi
  if { [ "$PHASE" = sdk ] || [ "$PHASE" = all ]; } && [ "$(dpkg-query -W -f='${Status}\n' python3.8 libpython3.8 2>/dev/null | grep -c '^install ok installed$' || true)" != 2 ]; then
    # SDK 10's GCC package preflight requires these real 3.8 packages.
    # Pin the compatibility repository below Jammy, preserving Python 3.10.
    printf 'deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://archive.ubuntu.com/ubuntu focal main\ndeb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://archive.ubuntu.com/ubuntu focal-updates main\n' >/etc/apt/sources.list.d/tvbro-sdk-python38.list
    printf 'Package: *\nPin: release n=focal\nPin-Priority: 100\n' >/etc/apt/preferences.d/tvbro-sdk-python38
    apt-get update >"$EVIDENCE/python38-apt-update.log" 2>&1
    apt-get --simulate install --no-install-recommends python3.8 libpython3.8 >"$EVIDENCE/python38-apt-plan.txt"
    ! grep -q '^Remv ' "$EVIDENCE/python38-apt-plan.txt"
    ! grep -q '^Inst python3 \[' "$EVIDENCE/python38-apt-plan.txt"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3.8 libpython3.8 >"$EVIDENCE/python38-apt-install.log" 2>&1
    python3.8 --version >"$EVIDENCE/python38-version.txt"
    python3 --version >>"$EVIDENCE/python38-version.txt"
  fi
  getent passwd tvbro-sdk >/dev/null || useradd --uid 10000 --user-group --home-dir "$ROOT/home" --no-create-home --shell /bin/bash tvbro-sdk
  install -d -o tvbro-sdk -g tvbro-sdk "$ROOT" "$ROOT/home" "$ROOT/state" "$ROOT/downloads"
  chmod a+rwx "$EVIDENCE"
  dpkg-query -W >"$EVIDENCE/container-packages.txt"
  if [ "$PHASE" = prerequisites ]; then echo 'prerequisites: succeeded'; exit 0; fi
  exec runuser -u tvbro-sdk -- bash "$SCRIPT_DIR/setup.sh" --phase "$PHASE" --retry "$RETRY"
fi
test "$(id -un)" = tvbro-sdk
export PUB_CACHE="$ROOT/pub-cache" DOTNET_ROOT="$ROOT/dotnet" DOTNET_CLI_HOME="$ROOT/home"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export XDG_CONFIG_HOME="$ROOT/home/.config" XDG_CACHE_HOME="$ROOT/home/.cache"
export PATH="$ROOT/dotnet:$ROOT/flutter-tizen/bin:$PATH"
export TIZEN_SDK="$ROOT/home/tizen-sdk"
mkdir -p "$ROOT/state" "$ROOT/downloads"

phase() {
  local name=$1 result run_log
  shift
  if [ -f "$ROOT/state/$name.done" ]; then echo "$name: reused"; return; fi
  if [ -f "$ROOT/state/$name.started" ] && [ "$RETRY" != "$name" ]; then
    echo "Explicit --retry $name is required after an interrupted or failed phase" >&2; exit 1
  fi
  run_log="$EVIDENCE/$(date -u +%Y%m%dT%H%M%S)-$name.log"
  printf '%s\n' "$run_log" >"$ROOT/state/$name.started"
  echo "$name: started ($run_log)"
  set +e
  (set -e; set -x; "$@") >"$run_log" 2>&1
  result=$?
  set -e
  python3 - "$EVIDENCE/terminal.json" "$name" "$result" "$run_log" <<'PY'
import datetime,json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({'timeUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'phase':sys.argv[2],'exitCode':int(sys.argv[3]),'status':'succeeded' if sys.argv[3]=='0' else 'failed','log':sys.argv[4]},indent=2)+'\n')
PY
  if [ "$result" != 0 ]; then echo "$name: failed ($run_log)" >&2; exit "$result"; fi
  cp "$ROOT/state/$name.started" "$ROOT/state/$name.done"
  echo "$name: succeeded"
}

download() {
  local url=$1 target=$2 algorithm=$3 expected=$4
  if [ ! -f "$target" ]; then
    curl --fail --location --retry 0 --continue-at - --output "$target.part" "$url"
    mv -- "$target.part" "$target"
  fi
  if [ "$algorithm" != record ]; then
    printf '%s  %s\n' "$expected" "$target" | "${algorithm}sum" --check -
  fi
  sha256sum "$target" >>"$EVIDENCE/download-sha256.txt"
}

cli() {
  local tool="$ROOT/flutter-tizen"
  if [ ! -d "$tool/.git" ]; then
    git init "$tool"
    git -C "$tool" remote add origin https://github.com/flutter-tizen/flutter-tizen.git
    git -C "$tool" fetch --depth=1 origin 22bcec9058fbe1e0943e6c6fda21792f24868e91
    git -C "$tool" checkout --detach FETCH_HEAD
  fi
  test "$(git -C "$tool" rev-parse HEAD)" = 22bcec9058fbe1e0943e6c6fda21792f24868e91
  if [ ! -d "$tool/flutter/.git" ]; then
    # Reuse original Git objects read-only, without copying the Windows cache.
    # Local clone's upload-pack checks protected config separately. Keep its
    # two explicit trust entries in this SDK user's isolated home only.
    printf '[safe]\n\tdirectory = /host-flutter\n\tdirectory = /host-flutter/.git\n' >"$ROOT/home/source-gitconfig"
    GIT_CONFIG_GLOBAL="$ROOT/home/source-gitconfig" git clone --shared --no-checkout /host-flutter "$tool/flutter"
    git -C "$tool/flutter" checkout --detach abaf9c523780a608bd46686fd5e53740a07077f8
  fi
  test "$(git -C "$tool/flutter" rev-parse HEAD)" = abaf9c523780a608bd46686fd5e53740a07077f8
  printf '%s\n' abaf9c523780a608bd46686fd5e53740a07077f8 >"$tool/bin/internal/flutter.version"
  "$tool/flutter/bin/flutter" --version
  "$tool/flutter/bin/flutter" --version --machine >"$EVIDENCE/flutter-version.json"
  "$tool/flutter/bin/cache/dart-sdk/bin/dart" --version
  python3 - "$EVIDENCE/flutter-version.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['dartSdkVersion']=='3.13.5' and d['frameworkRevision']=='abaf9c523780a608bd46686fd5e53740a07077f8',d
PY
  "$tool/flutter/bin/flutter" precache --universal --no-android
}

dotnet() {
  local archive="$ROOT/downloads/dotnet-sdk-8.0.426-linux-x64.tar.gz"
  download https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.426/dotnet-sdk-8.0.426-linux-x64.tar.gz \
    "$archive" sha512 8141d01bdc53f604aed3bb661b604707a64209f8a947cd81bf95b4f518951593d77864069191f54ea5e84362a409da6b0f69074bf893b283d7e0cf93e2bf20a8
  mkdir -p "$ROOT/dotnet"
  tar -xzf "$archive" --no-same-owner -C "$ROOT/dotnet"
  test "$("$ROOT/dotnet/dotnet" --version)" = 8.0.426
  "$ROOT/dotnet/dotnet" --info >"$EVIDENCE/dotnet-info.txt"
}

sdk() {
  local installer="$ROOT/downloads/web-cli_Tizen_SDK_10.0_ubuntu-64.bin"
  download https://download.tizen.org/sdk/Installer/tizen-sdk_10.0/web-cli_Tizen_SDK_10.0_ubuntu-64.bin "$installer" record ''
  test "$(stat -c %s "$installer")" = 401290863
  if [ ! -f "$TIZEN_SDK/sdk.info" ]; then
    mkdir -p "$TIZEN_SDK"
    touch "$ROOT/home/.bashrc"
    bash "$installer" --accept-license --no-java-check "$TIZEN_SDK"
    test -f "$TIZEN_SDK/sdk.info"
  fi
  local manager="$TIZEN_SDK/package-manager/package-manager-cli.bin"
  "$manager" show-pkgs >"$EVIDENCE/tizen-available-packages.txt"
  local package package_log
  for package in NativeCLI NativeToolchain-Gcc-9.2 IOT-Headed-6.0-NativeAppDevelopment-CLI certificate-generator certificate-encryptor; do
    package_log="$EVIDENCE/sdk-package-$package.log"
    "$manager" install --accept-license --no-java-check "$package" >"$package_log" 2>&1
    cat "$package_log"
  done
  "$manager" show-pkgs >"$EVIDENCE/tizen-packages-after.txt"
  "$TIZEN_SDK/tools/ide/bin/tizen" version
  cp "$TIZEN_SDK/sdk.info" "$EVIDENCE/sdk.info"
}

cache() {
  python3 "$SCRIPT_DIR/configure-cache.py" --root "$ROOT" --engine /engine --evidence "$EVIDENCE"
  "$ROOT/flutter-tizen/bin/flutter-tizen" --version >"$EVIDENCE/flutter-tizen-version.txt"
  git -C "$ROOT/flutter-tizen" diff -- bin/internal/flutter.version lib/tizen_cache.dart >"$EVIDENCE/isolated-cli.diff"
}

verify() {
  python3 "$SCRIPT_DIR/configure-cache.py" --root "$ROOT" --engine /engine --evidence "$EVIDENCE" --verify-only
  "$ROOT/flutter-tizen/bin/flutter-tizen" build tpk --help >"$EVIDENCE/tpk-help.txt"
  "$TIZEN_SDK/tools/ide/bin/tizen" certificate --help >"$EVIDENCE/certificate-help.txt"
  "$TIZEN_SDK/tools/ide/bin/tizen" security-profiles --help >"$EVIDENCE/security-profiles-help.txt"
  "$TIZEN_SDK/tools/llvm-10/bin/clang" --version >"$EVIDENCE/compiler-version.txt"
  "$ROOT/dotnet/dotnet" --version
  test -f "$TIZEN_SDK/platforms/tizen-6.0/iot-headed/rootstraps/iot-headed-6.0-device.core/usr/lib/libc.so"
}

if [ "$PHASE" = all ]; then
  phase cli cli
  phase dotnet dotnet
  phase sdk sdk
  phase cache cache
  phase verify verify
else
  phase "$PHASE" "$PHASE"
fi
