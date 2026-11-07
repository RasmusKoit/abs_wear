#!/usr/bin/env bash
# Runs the integration tests on a connected device or emulator against the
# ABS test server (tool/abs_test_server). Usage:
#   tool/e2e.sh [device-id]        # default: first connected device
# The server URL as seen from the device comes from E2E_ABS_URL, falling back
# to ABS_E2E_URL in tool/abs_test_server/.env.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . tool/abs_test_server/.env; set +a
URL=${E2E_ABS_URL:-${ABS_E2E_URL:-}}
[ -n "$URL" ] || { echo "Set ABS_E2E_URL in tool/abs_test_server/.env"; exit 1; }
DEVICE=${1:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
[ -n "$DEVICE" ] || { echo "No device connected (start an emulator or adb connect the watch)"; exit 1; }
echo "Device: $DEVICE   Server: $URL"
flutter test integration_test \
  -d "$DEVICE" \
  --flavor development \
  --dart-define=ABS_URL="$URL" \
  --dart-define=ABS_TEST_USER="$ABS_TEST_USER" \
  --dart-define=ABS_TEST_PASSWORD="$ABS_TEST_PASSWORD"
