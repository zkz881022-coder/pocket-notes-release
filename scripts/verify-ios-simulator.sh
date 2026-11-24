#!/usr/bin/env bash
set -euo pipefail

snapshot="${1:?Missing snapshot directory}"
evidence="${2:?Missing evidence directory}"
mkdir -p "$evidence"
cp "$snapshot/main-sha" "$evidence/main-sha.txt"
python3 scripts/verify-feed.py preflight "$snapshot/expected.json" web/index.html

product_dir="$PWD/ios/build/iphonesimulator"
app_id="$(node -p 'require("./mobile.json").id')"
bash scripts/build-ios.sh iphonesimulator
app="$product_dir/Pocket.app"
codesign --force --sign - "$app"
codesign --verify "$app"

simulator="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    return tuple(int(part) for part in runtime.rsplit(".iOS-", 1)[1].split("-"))
for runtime in sorted((name for name in devices if ".iOS-" in name), key=version, reverse=True):
    for device in devices[runtime]:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit("No available iPhone simulator")
')"
xcrun simctl bootstatus "$simulator" -b
xcrun simctl status_bar "$simulator" override --time 9:41
xcrun simctl uninstall "$simulator" "$app_id" >/dev/null 2>&1 || true
xcrun simctl install "$simulator" "$app"
container="$(xcrun simctl get_app_container "$simulator" "$app_id" data)"
plist="$container/Library/Preferences/$app_id.plist"
python3 -c '
import plistlib, sys
from pathlib import Path
plist = Path(sys.argv[1])
if plist.exists() and "latestPocketFeed" in plistlib.loads(plist.read_bytes()):
    sys.exit("The simulator app already had a cached feed before launch")
' "$plist"
xcrun simctl launch "$simulator" "$app_id"
capture() {
    xcrun simctl io "$simulator" screenshot "$evidence/ios-simulator.png"
}

for attempt in {1..30}; do
    if match="$(python3 scripts/verify-feed.py ios "$snapshot/expected.json" web/index.html "$plist")"; then
        printf '%s\n' "$match" > "$evidence/ios-feed-match.json"
        sleep 2
        capture
        printf '%s\n' "iOS Simulator installed, launched and persisted current HTTPS feed data. Screenshot recorded; physical iPhone installation was outside this check."
        exit 0
    fi
    sleep 2
done
printf '%s\n' "iOS Simulator did not persist the expected title and a current item absent from the seed." >&2
exit 1
