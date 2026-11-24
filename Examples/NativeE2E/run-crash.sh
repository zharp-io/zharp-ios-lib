#!/bin/bash
# ./run-crash.sh <action> <expected type> <expected message part> <function> <file>
# Launches the app in the booted simulator ($UDID) to crash, relaunches it to send the report,
# then checks and symbolicates what arrived (check.py).
set -euo pipefail
action=$1 type=$2 message=$3 function=$4 file=$5
bodies="$RUNNER_TEMP/bodies"
rm -rf "$bodies"/*
export SIMCTL_CHILD_ZHARP_ENDPOINT=http://127.0.0.1:4318/otlp

SIMCTL_CHILD_E2E_ACTION=$action xcrun simctl launch "$UDID" io.zharp.e2e.native
sleep 6
if xcrun simctl spawn "$UDID" launchctl list | grep -q "io.zharp.e2e.native"; then
  echo "::error::the app is still running: it did not crash"
  exit 1
fi
echo "crashed"
SIMCTL_CHILD_E2E_ACTION=relaunch xcrun simctl launch "$UDID" io.zharp.e2e.native
sleep 10
xcrun simctl terminate "$UDID" io.zharp.e2e.native || true
python3 check.py "$bodies" build/Build/Products/Release-iphonesimulator/NativeE2E.app.dSYM/Contents/Resources/DWARF/NativeE2E "$type" "$message" "$function" "$file"
mkdir -p "$RUNNER_TEMP/bodies-$action" && cp "$bodies"/* "$RUNNER_TEMP/bodies-$action"/
