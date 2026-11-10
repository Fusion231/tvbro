#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <app-bundle.aab> <merged-manifest.xml>" >&2
  exit 2
fi

bundle=$1
manifest=$2
expected_fingerprint=${EXPECTED_CERT_SHA256:-}

for file in "$bundle" "$manifest"; do
  if [ ! -f "$file" ]; then
    echo "Required build output was not found: $file" >&2
    exit 1
  fi
done
if [ -z "$expected_fingerprint" ]; then
  echo "EXPECTED_CERT_SHA256 is not configured." >&2
  exit 1
fi

unzip -tq "$bundle" >/dev/null
jarsigner -verify "$bundle" >/dev/null

python3 - "$manifest" <<'PY'
import sys
import xml.etree.ElementTree as ET

android = "{http://schemas.android.com/apk/res/android}"
root = ET.parse(sys.argv[1]).getroot()

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

package_name = root.get("package", "")
if package_name != "app.tvbro.player":
    fail(f"Google Play package mismatch: expected app.tvbro.player, received {package_name or 'none'}.")

uses_sdk = root.find("uses-sdk")
target_sdk = uses_sdk.get(android + "targetSdkVersion", "") if uses_sdk is not None else ""
try:
    target_sdk_number = int(target_sdk)
except ValueError:
    fail(f"Google Play target SDK is missing or invalid: {target_sdk or 'none'}.")
if target_sdk_number < 36:
    fail(f"Google Play requires target SDK 36 or higher for this app; received {target_sdk_number}.")

features = {
    feature.get(android + "name"): feature.get(android + "required", "true")
    for feature in root.findall("uses-feature")
}
for feature_name in ("android.software.leanback", "android.hardware.touchscreen"):
    if features.get(feature_name) != "false":
        fail(f"Google Play TV manifest must mark {feature_name} as not required.")

application = root.find("application")
if application is None or "tv_banner" not in application.get(android + "banner", ""):
    fail("Google Play TV manifest is missing the TVBro home-screen banner.")

leanback_launcher = False
for activity in root.findall("./application/activity"):
    for intent_filter in activity.findall("intent-filter"):
        actions = {node.get(android + "name") for node in intent_filter.findall("action")}
        categories = {node.get(android + "name") for node in intent_filter.findall("category")}
        if "android.intent.action.MAIN" in actions and "android.intent.category.LEANBACK_LAUNCHER" in categories:
            leanback_launcher = True
if not leanback_launcher:
    fail("Google Play TV manifest is missing a MAIN/LEANBACK_LAUNCHER activity.")
PY
if grep -q 'android.permission.REQUEST_INSTALL_PACKAGES' "$manifest"; then
  echo "Google Play manifest contains REQUEST_INSTALL_PACKAGES." >&2
  exit 1
fi
if grep -q 'androidx.core.content.FileProvider' "$manifest"; then
  echo "Google Play manifest contains the GitHub updater FileProvider." >&2
  exit 1
fi

actual_fingerprint=$(
  keytool -printcert -jarfile "$bundle" |
    sed -n 's/^[[:space:]]*SHA256: //p' |
    head -n 1
)
normalize_fingerprint() {
  printf '%s' "$1" | tr -d '[:space:]:' | tr '[:upper:]' '[:lower:]'
}
actual_normalized=$(normalize_fingerprint "$actual_fingerprint")
expected_normalized=$(normalize_fingerprint "$expected_fingerprint")
if [ -z "$actual_normalized" ] || [ "$actual_normalized" != "$expected_normalized" ]; then
  echo "Google Play upload certificate mismatch. Expected $expected_normalized, received ${actual_normalized:-none}." >&2
  exit 1
fi

echo "Verified Google Play AAB identity, target SDK, TV manifest, updater policy, archive signature, and upload certificate."
