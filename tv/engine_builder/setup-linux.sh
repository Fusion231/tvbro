#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root with: wsl -d TVBro-Builder -u root --exec bash <this-script> [evidence-directory]
# Official repository procedure: https://docs.docker.com/engine/install/ubuntu/
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${WSL_DISTRO_NAME:-} == TVBro-Builder ]] || fail 'This script only supports WSL TVBro-Builder.'
[[ $EUID == 0 ]] || fail 'Run this script as root inside TVBro-Builder.'
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 && ${VERSION_CODENAME:-} == noble ]] || fail 'Ubuntu 24.04 (noble) is required.'
[[ $(dpkg --print-architecture) == amd64 ]] || fail 'The builder requires amd64.'
[[ $(< /proc/1/comm) == systemd ]] || fail 'The builder requires systemd as PID 1.'
[[ $# -le 1 ]] || fail 'Usage: setup-linux.sh [evidence-directory]'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
evidence_dir=${1:-"$script_dir/../output/engine-builder-setup"}
mkdir -p -- "$evidence_dir"
evidence_dir=$(cd -- "$evidence_dir" && pwd)
exec > >(tee "$evidence_dir/setup.log") 2>&1

started_at=$(date -u +%FT%TZ)
stage=preflight
work_dir=
finish() {
  result=$?
  trap - EXIT
  outcome=failed
  [[ $result == 0 ]] && outcome=succeeded
  printf '{"status":"%s","exit_code":%s,"stage":"%s","started_at":"%s","finished_at":"%s"}\n' \
    "$outcome" "$result" "$stage" "$started_at" "$(date -u +%FT%TZ)" > "$evidence_dir/status.json"
  if [[ -n $work_dir ]]; then
    rm -f -- "$work_dir/docker.asc" "$work_dir/docker.sources"
    rmdir -- "$work_dir"
  fi
  exit "$result"
}
trap finish EXIT
printf '{"status":"running","stage":"preflight","started_at":"%s"}\n' "$started_at" > "$evidence_dir/status.json"
printf 'Starting Docker setup in %s at %s\n' "$WSL_DISTRO_NAME" "$started_at"
cat /etc/os-release > "$evidence_dir/os-release.txt"
uname -a > "$evidence_dir/uname.txt"

for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
  if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
    fail "Conflicting package $package is installed; refusing to remove existing packages."
  fi
done

export DEBIAN_FRONTEND=noninteractive
apt_options=(-o Acquire::Retries=2 -o Acquire::http::Timeout=60 -o Acquire::https::Timeout=60 -o DPkg::Lock::Timeout=180)
stage=prerequisites
apt-get "${apt_options[@]}" update
apt-get "${apt_options[@]}" install -y --no-install-recommends ca-certificates curl gnupg

stage=repository
work_dir=$(mktemp -d /tmp/tvbro-docker-setup.XXXXXX)
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --connect-timeout 20 --max-time 120 --retry 2 --retry-delay 3 \
  https://download.docker.com/linux/ubuntu/gpg -o "$work_dir/docker.asc"
# Docker Release (CE deb), published by Docker at:
# https://github.com/docker/for-linux/issues/1471
expected_fingerprint=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
fingerprint=$(gpg --batch --show-keys --with-colons "$work_dir/docker.asc" | awk -F: '$1 == "fpr" && !seen++ {print $10}')
[[ $fingerprint == "$expected_fingerprint" ]] || fail "Unexpected Docker signing key fingerprint: $fingerprint"
gpg --batch --show-keys --fingerprint "$work_dir/docker.asc" > "$evidence_dir/docker-key.txt"
install -m 0755 -d /etc/apt/keyrings
install -m 0644 "$work_dir/docker.asc" /etc/apt/keyrings/docker.asc
cat > "$work_dir/docker.sources" <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
if [[ -e /etc/apt/sources.list.d/docker.sources ]] && ! cmp -s "$work_dir/docker.sources" /etc/apt/sources.list.d/docker.sources; then
  fail 'An unexpected Docker repository configuration already exists.'
fi
install -m 0644 "$work_dir/docker.sources" /etc/apt/sources.list.d/docker.sources
cp /etc/apt/sources.list.d/docker.sources "$evidence_dir/docker.sources"
apt-get "${apt_options[@]}" update

stage=packages
apt-cache policy docker-ce docker-ce-cli containerd.io > "$evidence_dir/apt-policy.txt"
apt-cache madison docker-ce docker-ce-cli containerd.io > "$evidence_dir/apt-versions.txt"
candidate() {
  apt-cache policy "$1" | awk '/Candidate:/ {print $2}'
}
docker_version=$(candidate docker-ce)
cli_version=$(candidate docker-ce-cli)
containerd_version=$(candidate containerd.io)
for version in "$docker_version" "$cli_version" "$containerd_version"; do
  [[ -n $version && $version != '(none)' ]] || fail 'Docker repository has no installable package candidate.'
done
[[ $docker_version == "$cli_version" ]] || fail 'Docker Engine and CLI package versions do not match.'
printf 'docker-ce=%s\ndocker-ce-cli=%s\ncontainerd.io=%s\n' \
  "$docker_version" "$cli_version" "$containerd_version" > "$evidence_dir/selected-versions.txt"
apt-get "${apt_options[@]}" install -y --no-install-recommends \
  "docker-ce=$docker_version" "docker-ce-cli=$cli_version" "containerd.io=$containerd_version"
dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' \
  docker-ce docker-ce-cli containerd.io > "$evidence_dir/installed-packages.tsv"

stage=service
systemctl enable --now docker.service
systemctl is-active docker.service > "$evidence_dir/docker-service-active.txt"
systemctl is-enabled docker.service > "$evidence_dir/docker-service-enabled.txt"
systemctl status docker.service --no-pager > "$evidence_dir/docker-service.txt"

stage=runtime
# Select the Linux socket explicitly; never change a Windows Docker context.
docker=(docker --host unix:///var/run/docker.sock)
"${docker[@]}" version --format '{{json .}}' > "$evidence_dir/docker-version.json"
"${docker[@]}" info --format '{{json .}}' > "$evidence_dir/docker-info.json"
"${docker[@]}" run --rm --pull=always --network none hello-world:latest 2>&1 | tee "$evidence_dir/hello-world.log"
"${docker[@]}" image inspect hello-world:latest --format '{{json .RepoDigests}}' > "$evidence_dir/hello-world-digests.json"
df -h /var/lib/docker /var/lib/containerd > "$evidence_dir/docker-disk.txt"
printf '{"distro":"TVBro-Builder","os":"Ubuntu 24.04","architecture":"amd64","repository":"https://download.docker.com/linux/ubuntu","suite":"noble","docker_ce":"%s","docker_ce_cli":"%s","containerd_io":"%s","key_fingerprint":"%s","daemon_socket":"unix:///var/run/docker.sock","documentation":"https://docs.docker.com/engine/install/ubuntu/"}\n' \
  "$docker_version" "$cli_version" "$containerd_version" "$fingerprint" > "$evidence_dir/manifest.json"
stage=complete
printf 'Docker Engine setup and hello-world completed successfully. Evidence: %s\n' "$evidence_dir"
