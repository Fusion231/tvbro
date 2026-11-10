#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/build-ios.sh <dev|appStore|altStore> [--build-number N]

  dev       Build the iPhone/iPad Simulator app with the development identity.
  appStore  Build and package an unsigned App Store-shaped IPA.
  altStore  Build and package an unsigned sideload IPA with a side-by-side ID.

App Store Connect archives must be signed separately using the owner's Apple
Developer account in Xcode. Unsigned IPAs must be re-signed before installation.
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

mode="$1"
shift
case "$mode" in
  dev)
    channel="development"
    expected_bundle_id="app.tvbro.player.dev"
    ;;
  appStore)
    channel="appStore"
    expected_bundle_id="app.tvbro.player"
    ;;
  altStore)
    channel="altStore"
    expected_bundle_id="app.tvbro.player"
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    echo "Unknown iOS build mode: $mode" >&2
    usage >&2
    exit 2
    ;;
esac

build_number=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-number)
      if [[ $# -lt 2 ]]; then
        echo "--build-number requires a value." >&2
        exit 2
      fi
      build_number="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$build_number" && ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo "Build number must contain only digits." >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS packaging requires macOS with Xcode command-line tools." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_project_root="$repo_root/clients/player"
cd "$flutter_project_root"

flutter_bin="${FLUTTER_BIN:-flutter}"
version_line="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n 1)"
if [[ -z "$version_line" ]]; then
  echo "Could not read version from pubspec.yaml." >&2
  exit 1
fi
build_name="${version_line%%+*}"
if [[ -z "$build_number" ]]; then
  if [[ "$version_line" == *+* ]]; then
    build_number="${version_line#*+}"
  else
    build_number="1"
  fi
fi

"$flutter_bin" pub get

dart_defines=("--dart-define=DISTRIBUTION_CHANNEL=$channel")
if [[ -n "${SUPABASE_URL:-}" ]]; then
  dart_defines+=("--dart-define=SUPABASE_URL=$SUPABASE_URL")
fi
if [[ -n "${SUPABASE_ANON_KEY:-}" ]]; then
  dart_defines+=("--dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY")
fi
if [[ -n "${PANEL_URL:-}" ]]; then
  dart_defines+=("--dart-define=PANEL_URL=$PANEL_URL")
fi

if [[ "$mode" == "dev" ]]; then
  "$flutter_bin" build ios --debug --simulator \
    --build-name "$build_name" \
    --build-number "$build_number" \
    "${dart_defines[@]}"
  app_path="build/ios/iphonesimulator/Runner.app"
  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
  if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
    echo "Expected development bundle ID $expected_bundle_id, got $actual_bundle_id." >&2
    exit 1
  fi
  echo "Simulator app: $flutter_project_root/$app_path ($actual_bundle_id)"
  exit 0
fi

"$flutter_bin" build ios --release --no-codesign \
  --build-name "$build_name" \
  --build-number "$build_number" \
  "${dart_defines[@]}"

app_path="build/ios/iphoneos/Runner.app"
info_plist="$app_path/Info.plist"
actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
  echo "Expected release bundle ID $expected_bundle_id, got $actual_bundle_id." >&2
  exit 1
fi

if [[ "$mode" == "altStore" ]]; then
  if [[ -d "$app_path/_CodeSignature" ]]; then
    echo "Refusing to change the bundle ID of a signed app." >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.tvbro.player.sideload' "$info_plist"
  expected_bundle_id="app.tvbro.player.sideload"
fi

/usr/bin/plutil -lint "$info_plist"
actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
  echo "Final bundle ID mismatch: expected $expected_bundle_id, got $actual_bundle_id." >&2
  exit 1
fi

case "$mode" in
  appStore) channel_name="appstore" ;;
  altStore) channel_name="altstore" ;;
esac
ipa_name="tvbro-ios-${channel_name}-unsigned-v${build_name}-${build_number}.ipa"
ipa_dir="build/ios/ipa"
mkdir -p "$ipa_dir"
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir/Payload"
ditto "$app_path" "$staging_dir/Payload/Runner.app"
ditto -c -k --sequesterRsrc --keepParent "$staging_dir/Payload" "$ipa_dir/$ipa_name"
unzip -tq "$ipa_dir/$ipa_name"
unzip -p "$ipa_dir/$ipa_name" Payload/Runner.app/Info.plist >/dev/null

echo "Unsigned IPA: $flutter_project_root/$ipa_dir/$ipa_name ($actual_bundle_id)"
