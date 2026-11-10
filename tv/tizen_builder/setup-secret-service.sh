#!/usr/bin/env bash
# Real headless Secret Service for SDK signing, confined to this container.
set -euo pipefail
test -f /.dockerenv
test "$(id -u)" = 0
test "${TVBRO_BUILDER_IMAGE:-}" = 'ghcr.io/flutter-tizen/build-engine@sha256:cc6e431ffd60bdbe6bb20b2178c1dc4897a408f6c51728d3b59b5a9394bbe797'
root=/opt/tvbro-tizen-toolchain
mkdir -p "$root/downloads/keyring" "$root/compat-keyring"
cd "$root/downloads/keyring"
package=gnome-keyring_40.0-3ubuntu3_amd64.deb
if [ ! -f "$package" ]; then apt-get download gnome-keyring=40.0-3ubuntu3; fi
sha256sum "$package" >/evidence/keyring-package-sha256.txt
dpkg-deb --field "$package" Package Version Architecture >/evidence/keyring-package.txt
dpkg-deb --extract "$package" "$root/compat-keyring"
apt-get --simulate install --no-install-recommends libgck-1-0 libgcr-base-3-1 libsecret-1-0 >/evidence/keyring-apt-plan.txt
! grep -q '^Remv ' /evidence/keyring-apt-plan.txt
! grep -Eq '^Inst (libgtk|systemd|gnome-shell|gnome-session)' /evidence/keyring-apt-plan.txt
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libgck-1-0 libgcr-base-3-1 libsecret-1-0 >/evidence/keyring-apt-install.log 2>&1
ldd "$root/compat-keyring/usr/bin/gnome-keyring-daemon" >/evidence/keyring-daemon-ldd.txt
! grep -q 'not found' /evidence/keyring-daemon-ldd.txt
"$root/compat-keyring/usr/bin/gnome-keyring-daemon" --version >/evidence/keyring-daemon-version.txt
dpkg-query -W >/evidence/container-packages.txt
echo 'Headless Secret Service prerequisites: succeeded'
