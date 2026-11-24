#!/usr/bin/env bash
set -euo pipefail

snapshot="${1:?Missing snapshot directory}"
evidence="${2:?Missing evidence directory}"
app_id="$(node -p 'require("./mobile.json").id')"
[[ "$app_id" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]

adb install "$snapshot/pocket-android.apk"
adb shell pm clear "$app_id" | tr -d '\r' | grep -Fx Success
launch="$(adb shell am start -W -n "$app_id/com.pocketpublish.shell.MainActivity" | tr -d '\r')"
printf '%s\n' "$launch" | grep -Fx 'Status: ok'
for attempt in {1..18}; do
    if timeout 8s adb shell uiautomator dump /sdcard/pocket-verification.xml >/dev/null 2>&1 \
        && adb exec-out cat /sdcard/pocket-verification.xml > "$snapshot/android-ui.xml" \
        && match="$(python3 scripts/verify-feed.py android "$snapshot/expected.json" "$snapshot/android-seed.html" "$snapshot/android-ui.xml")"; then
        adb exec-out screencap -p > "$evidence/android-emulator.png"
        test -s "$evidence/android-emulator.png"
        printf '%s\n' "$match" > "$evidence/android-feed-match.json"
        printf '%s\n' 'Installed the signed release APK and observed the current feed title and a current item absent from its bundled seed.'
        exit 0
    fi
    sleep 2
done
printf '%s\n' 'Android Emulator did not show the current feed title and a current item absent from the bundled seed.' >&2
exit 1
