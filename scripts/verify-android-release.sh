#!/usr/bin/env bash
set -euo pipefail

snapshot="${1:?Missing snapshot directory}"
evidence="${2:?Missing evidence directory}"
repo="${GITHUB_REPOSITORY:?Missing GitHub repository}"
tag="${POCKET_RELEASE_TAG:?Missing release tag}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ || "$tag" == *..* || "$tag" == *. ]]; then
    printf '%s\n' 'Invalid literal release tag' >&2
    exit 2
fi

mkdir -p "$evidence"
cp "$snapshot/main-sha" "$evidence/main-sha.txt"
apk="$snapshot/pocket-android.apk"
curl --proto '=https' --proto-redir '=https' --fail --silent --show-error \
    --location --max-time 60 --max-filesize 104857600 \
    "https://github.com/$repo/releases/download/$tag/pocket-android.apk" -o "$apk"
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
signer="$sdk_root/build-tools/35.0.0/apksigner"
signature="$("$signer" verify --verbose --print-certs "$apk")"
{
    printf 'Release tag: %s\n' "$tag"
    printf 'APK SHA-256: %s\n' "$(sha256sum "$apk" | cut -d ' ' -f1)"
    printf '%s\n' "$signature" | grep -E '^Signer #[0-9]+ certificate SHA-256 digest:'
} > "$evidence/android-signature.txt"
unzip -p "$apk" assets/web/index.html > "$snapshot/android-seed.html"
python3 scripts/verify-feed.py preflight "$snapshot/expected.json" "$snapshot/android-seed.html"
printf '%s\n' 'Release APK signature verified and bundled seed inspected.'
