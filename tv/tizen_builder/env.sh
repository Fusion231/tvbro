#!/usr/bin/env bash
# Source inside the prepared container before staging/pub/build in a TV project.
export PUB_CACHE=/opt/tvbro-tizen-toolchain/pub-cache
export DOTNET_ROOT=/opt/tvbro-tizen-toolchain/dotnet
export DOTNET_CLI_HOME=/opt/tvbro-tizen-toolchain/home
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export TIZEN_SDK=/opt/tvbro-tizen-toolchain/home/tizen-sdk
export XDG_CONFIG_HOME=/opt/tvbro-tizen-toolchain/home/.config
export XDG_CACHE_HOME=/opt/tvbro-tizen-toolchain/home/.cache
export XDG_RUNTIME_DIR=/opt/tvbro-tizen-toolchain/home/private/runtime
export XDG_DATA_HOME=/opt/tvbro-tizen-toolchain/home/private/keyring-data
export DBUS_SESSION_BUS_ADDRESS=unix:path=/opt/tvbro-tizen-toolchain/home/private/dbus-session.sock
export GNOME_KEYRING_CONTROL=/opt/tvbro-tizen-toolchain/home/private/keyring-control
export PATH="$DOTNET_ROOT:/opt/tvbro-tizen-toolchain/flutter-tizen/bin:$PATH"
