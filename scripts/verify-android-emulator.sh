#!/usr/bin/env bash
set -euo pipefail

snapshot="${1:?Missing snapshot directory}"
evidence="${2:?Missing evidence directory}"
app_id="$(node -p 'require("./mobile.json").id')"
[[ "$app_id" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]

adb install "$snapshot/pocket-android.apk"
adb shell pm clear "$app_id" | tr -d '\r' | grep -Fx Success
launch="$(timeout 20s adb shell am start -W -n "$app_id/com.pocketpublish.shell.MainActivity" | tr -d '\r')"
printf '%s\n' "$launch" | grep -Fx 'Status: ok'
size="$(adb shell wm size | tr -d '\r' | awk '/size:/ { size = $NF } END { print size }')"
[[ "$size" =~ ^([0-9]+)x([0-9]+)$ ]]
x=$(( BASH_REMATCH[1] / 2 ))
upper=$(( BASH_REMATCH[2] * 2 / 9 ))
lower=$(( BASH_REMATCH[2] * 7 / 9 ))
mkdir -p "$evidence"
feed="$snapshot/expected.json"
seed="$snapshot/android-seed.html"
diagnostic="$evidence/android-ui-status.json"

capture_app() {
    local position="$1"
    local raw="$snapshot/raw-android-ui.xml"
    local clean="$snapshot/android-$position.xml"
    timeout 7s adb shell uiautomator dump /sdcard/pocket-verification.xml >/dev/null 2>&1 \
        && timeout 4s adb exec-out cat /sdcard/pocket-verification.xml > "$raw" \
        && python3 scripts/verify-feed.py android-filter "$feed" "$seed" "$raw" \
            --package "$app_id" --output "$clean" \
        && cp "$clean" "$evidence/android-ui-$position.xml" || return 1
    if timeout 4s adb exec-out screencap -p > "$snapshot/android-$position.png" \
        && test -s "$snapshot/android-$position.png"; then
        cp "$snapshot/android-$position.png" "$evidence/android-emulator-$position.png"
    fi
}

for attempt in {1..12}; do
    if (( attempt % 2 == 0 )); then
        adb shell input keyevent KEYCODE_HOME
        sleep 2
        timeout 20s adb shell am start -W -n "$app_id/com.pocketpublish.shell.MainActivity" >/dev/null
        sleep 3
    fi
    observations=()
    adb shell input swipe "$x" "$upper" "$x" "$lower" 450
    sleep 1
    if capture_app top; then
        observations+=(--extra "$snapshot/android-top.xml")
    fi
    adb shell input swipe "$x" "$lower" "$x" "$upper" 500
    sleep 1
    if capture_app scrolled; then
        observations+=(--extra "$snapshot/android-scrolled.xml")
    fi
    if match="$(python3 scripts/verify-feed.py android "$feed" "$seed" \
        --package "$app_id" --diagnostic "$diagnostic" "${observations[@]}")"; then
        printf '%s\n' "$match" > "$evidence/android-feed-match.json"
        test -s "$evidence/android-emulator-top.png" || test -s "$evidence/android-emulator-scrolled.png"
        printf '%s\n' 'Installed the signed release APK and observed the current feed title and matching item text.'
        exit 0
    fi
    sleep 8
done
cat "$diagnostic"
printf '%s\n' 'Android Emulator did not show the expected current feed title and item text. Only foreground app observations were retained.' >&2
exit 1
