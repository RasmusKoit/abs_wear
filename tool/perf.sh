#!/usr/bin/env bash
# Times library loading on a device in profile mode, as the test account on
# ABS_PROD_URL. Usage: tool/perf.sh [device-id] [label]
# Uses the staging app (removed afterwards), so other installs are untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
. tool/abs_test_server/env.sh
load_env tool/abs_test_server/.env
DEVICE=${1:-$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')}
LABEL=${2:-run}
APP=dev.koit.abs_wear.stg
CONN=$(adb -s "$DEVICE" shell dumpsys connectivity)
ID=$(echo "$CONN" | sed -n 's/.*Active default network: \([0-9]*\).*/\1/p' | head -1)
NET=$(echo "$CONN" | grep "NetworkAgentInfo{network{$ID}" | grep -o 'Transports: [A-Z]*' | head -1 || true)
echo "Device: $DEVICE   Network: ${NET:-unknown}   Label: $LABEL"
(while true; do
  adb -s "$DEVICE" shell pm grant $APP android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  sleep 1
done) &
GRANT=$!
trap 'kill $GRANT 2>/dev/null || true; adb -s "$DEVICE" uninstall $APP >/dev/null 2>&1 || true' EXIT
"${FLUTTER:-flutter}" drive --profile \
  -d "$DEVICE" \
  --flavor staging \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/perf/library_perf_test.dart \
  --dart-define=ABS_URL="$ABS_PROD_URL" \
  --dart-define=ABS_TEST_USER="$ABS_PROD_USER" \
  --dart-define=ABS_TEST_PASSWORD="$ABS_PROD_PASSWORD" \
  ${PERF_ROUNDS:+--dart-define=PERF_ROUNDS=$PERF_ROUNDS}
mkdir -p build/perf
cp build/perf.json "build/perf/$LABEL.json"
python -c "import json,sys; d=json.load(open(sys.argv[1])); [print(f'{k}: {v}') for k,v in sorted(d.items()) if k.endswith('_median')]" "build/perf/$LABEL.json"
