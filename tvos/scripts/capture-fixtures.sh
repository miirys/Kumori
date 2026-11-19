#!/bin/bash
# Screenshots of every fixture screen on the tvOS Simulator, without running the UI tests.
# macOS with Xcode and XcodeGen. Usage, from tvos/:
#
#   scripts/capture-fixtures.sh [output-dir] [extra launch arguments...]
#   scripts/capture-fixtures.sh captures -typeSize ax3
#
# For the full set with focus states and remote-driven checks, run the UI tests instead:
#   xcodebuild test -project Kumori.xcodeproj -scheme Kumori -destination "id=$UDID"
set -euo pipefail
cd "$(dirname "$0")/.."

out=${1:-captures}
shift || true
fixtures=(gallery home home-loading home-error shelves art-load library library-empty restore
          detail detail-long detail-running confirm-end materials)

xcodegen generate >/dev/null
udid=$(scripts/find-simulator.sh)
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null

xcodebuild -project Kumori.xcodeproj -scheme Kumori -configuration Debug \
  -destination "id=$udid" -derivedDataPath build-sim build -quiet
xcrun simctl install "$udid" build-sim/Build/Products/Debug-appletvsimulator/Kumori.app

mkdir -p "$out"
for f in "${fixtures[@]}"; do
  xcrun simctl terminate "$udid" app.kumori.tv 2>/dev/null || true
  xcrun simctl launch "$udid" app.kumori.tv -fixture "$f" "$@" >/dev/null
  # Fixtures settle in about a second (the slow-artwork one in under three).
  sleep 4
  xcrun simctl io "$udid" screenshot "$out/$f.png" >/dev/null
  echo "$out/$f.png"
done
xcrun simctl terminate "$udid" app.kumori.tv 2>/dev/null || true
