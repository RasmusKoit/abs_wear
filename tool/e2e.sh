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
# The first download asks for POST_NOTIFICATIONS (API 33+), and the dialog
# would stall the download tests. flutter test installs the app fresh, so
# grant it as soon as the package shows up.
PERM=android.permission.POST_NOTIFICATIONS
(until adb -s "$DEVICE" shell pm grant dev.koit.abs_wear.dev $PERM >/dev/null 2>&1; do
  sleep 1
done) &
GRANT=$!
trap 'kill $GRANT 2>/dev/null || true' EXIT
"${FLUTTER:-flutter}" test integration_test \
  -d "$DEVICE" \
  --flavor development \
  --dart-define=ABS_URL="$URL" \
  --dart-define=ABS_TEST_USER="$ABS_TEST_USER" \
  --dart-define=ABS_TEST_PASSWORD="$ABS_TEST_PASSWORD"
