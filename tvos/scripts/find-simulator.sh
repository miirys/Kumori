#!/bin/bash
# Prints the UDID of an Apple TV 4K simulator on the newest installed tvOS runtime,
# creating one (and downloading the runtime) if there isn't one. macOS with Xcode only.
set -euo pipefail

pick_runtime() {
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "tvOS" and r.get("isAvailable")]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")'
}

runtime=$(pick_runtime)
if [ -z "$runtime" ]; then
  echo "No tvOS simulator runtime installed; downloading one." >&2
  xcodebuild -downloadPlatform tvOS >&2
  runtime=$(pick_runtime)
fi
[ -n "$runtime" ] || { echo "No tvOS runtime available" >&2; exit 1; }

udid=$(xcrun simctl list devices available -j | RUNTIME="$runtime" python3 -c '
import json, os, sys
devs = json.load(sys.stdin)["devices"].get(os.environ["RUNTIME"], [])
devs = [d for d in devs if d["name"].startswith("Apple TV 4K")]
devs.sort(key=lambda d: d["name"])
print(devs[-1]["udid"] if devs else "")')

if [ -z "$udid" ]; then
  devtype=$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
ts = [t for t in json.load(sys.stdin)["devicetypes"] if t["name"].startswith("Apple TV 4K")]
ts.sort(key=lambda t: t["name"])
print(ts[-1]["identifier"] if ts else "")')
  [ -n "$devtype" ] || { echo "No Apple TV 4K device type" >&2; exit 1; }
  udid=$(xcrun simctl create "Kumori Apple TV" "$devtype" "$runtime")
fi

echo "Using $udid on $runtime" >&2
echo "$udid"
