#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
sdk="${1:-iphoneos}"
if [[ "$sdk" != iphoneos && "$sdk" != iphonesimulator ]]; then
    printf '%s\n' "Usage: bash scripts/build-ios.sh [iphoneos|iphonesimulator]" >&2
    exit 2
fi
config=Release
destination="generic/platform=iOS"
if [[ "$sdk" = iphonesimulator ]]; then
    config=Debug
    destination="generic/platform=iOS Simulator"
    extra=("ARCHS=$(uname -m)")
else
    extra=(ARCHS=arm64)
fi
product_dir="$PWD/ios/build/$sdk"
xcodebuild -project ios/Pocket.xcodeproj -scheme Pocket -configuration "$config" \
    -sdk "$sdk" -destination "$destination" "CONFIGURATION_BUILD_DIR=$product_dir" \
    CODE_SIGNING_ALLOWED=NO \
    "PRODUCT_BUNDLE_IDENTIFIER=$(node -p 'require("./mobile.json").id')" \
    "POCKET_DISPLAY_NAME=$(node -p 'require("./mobile.json").name')" \
    "MARKETING_VERSION=$(node -p 'require("./mobile.json").version')" \
    "CURRENT_PROJECT_VERSION=$(node -p 'require("./mobile.json").build')" "${extra[@]}"

if [[ "$sdk" = iphonesimulator ]]; then
    printf '%s\n' "$product_dir/Pocket.app"
    exit 0
fi

app="$product_dir/Pocket.app"
executable="$app/Pocket"
if codesign -d "$executable" >/dev/null 2>&1; then
    codesign --remove-signature "$executable"
fi
if codesign -d "$executable" >/dev/null 2>&1 || [[ -e "$app/_CodeSignature" || -e "$app/embedded.mobileprovision" ]]; then
    printf '%s\n' "Unexpected signature or provisioning profile" >&2
    exit 1
fi
[[ "$(xcrun lipo -archs "$executable")" == arm64 ]]
build_info="$(xcrun vtool -show-build "$executable")"
grep -Eq 'platform[[:space:]]+IOS$' <<< "$build_info"
grep -Eq 'minos[[:space:]]+16\.0$' <<< "$build_info"
test -s "$app/Assets.car"
find "$app" -maxdepth 1 -name 'AppIcon*.png' -print -quit | grep -q .
test -s "$app/web/index.html"
cmp "$app/mobile.json" mobile.json
/usr/libexec/PlistBuddy -c "Print :CFBundleIcons:CFBundlePrimaryIcon" "$app/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" == "$(node -p 'require("./mobile.json").id')" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Info.plist")" == "$(node -p 'require("./mobile.json").name')" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")" == "$(node -p 'require("./mobile.json").version')" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")" == "$(node -p 'require("./mobile.json").build')" ]]

stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/Payload" out
ditto "$app" "$stage/Payload/Pocket.app"
ipa="$stage/pocket-ios.ipa"
ditto -c -k --keepParent "$stage/Payload" "$ipa"
unzip -tq "$ipa"
unzip -Z1 "$ipa" | grep -Fx 'Payload/Pocket.app/Info.plist'
mv -f "$ipa" out/pocket-ios.ipa
