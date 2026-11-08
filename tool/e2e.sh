#!/usr/bin/env bash
# Runs the integration tests on a connected device or emulator against the
# ABS test server (tool/abs_test_server). Usage:
#   tool/e2e.sh [device-id]        # default: first connected device
# The server URL as seen from the device comes from E2E_ABS_URL, falling back
# to ABS_E2E_URL in tool/abs_test_server/.env.
set -euo pipefail
cd "$(dirname "$0")/.."
. tool/abs_test_server/env.sh
load_env tool/abs_test_server/.env
URL=${E2E_ABS_URL:-${ABS_E2E_URL:-}}
[ -n "$URL" ] || { echo "Set ABS_E2E_URL in tool/abs_test_server/.env"; exit 1; }
DEVICE=${1:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$DEVICE" ] || { echo "No device connected (start an emulator or adb connect the watch)"; exit 1; }
echo "Device: $DEVICE   Server: $URL"
# The app asks for the notification permission on start; a dialog on top
# would send it to the background and stall the tests. Grant it up front
# (kept across reinstalls), and right after a first install.
PKG=dev.koit.abs_wear.dev
grant() { adb -s "$DEVICE" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1; }
grant || true
( for _ in $(seq 180); do grant && break; sleep 1; done ) &
"${FLUTTER:-flutter}" test integration_test \
  -d "$DEVICE" \
  --flavor development \
  --dart-define=ABS_URL="$URL" \
  --dart-define=ABS_TEST_USER="$ABS_TEST_USER" \
  --dart-define=ABS_TEST_PASSWORD="$ABS_TEST_PASSWORD"
