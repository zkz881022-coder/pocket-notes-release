#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
: "${ANDROID_SIGNING_P12:?Missing Android signing key}"
: "${ANDROID_SIGNING_PASSWORD:?Missing Android signing password}"
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
platform="$sdk_root/platforms/android-35/android.jar"
tools="$sdk_root/build-tools/35.0.0"
for binary in aapt2 d8 zipalign apksigner; do
    if [[ ! -x "$tools/$binary" ]]; then
        printf 'Missing Android build tool: %s\n' "$tools/$binary" >&2
        exit 1
    fi
done
test -s "$platform"

umask 077
stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pocket-android.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/res/values" "$stage/assets" "$stage/classes" "$stage/dex"
printf '%s' "$ANDROID_SIGNING_P12" | base64 --decode > "$stage/signing.p12"
unset ANDROID_SIGNING_P12

sources_dir=android/app/src/main
cp -a "$sources_dir"/res/. "$stage/res/"
cp -a web "$stage/assets/web"
cp mobile.json "$stage/assets/mobile.json"

python3 - "$stage" "$sources_dir/AndroidManifest.xml" <<'PY'
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

stage, source_manifest = map(Path, sys.argv[1:])
metadata = json.loads(Path("mobile.json").read_text(encoding="utf-8"))
app_id = metadata["id"]
version = metadata["version"]
build = metadata["build"]
name = metadata["name"]
if not isinstance(app_id, str) or not re.fullmatch(r"[a-z][a-z0-9]*(\.[a-z][a-z0-9]*){2,}", app_id):
    sys.exit("Invalid mobile.json id")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    sys.exit("Invalid mobile.json version")
if type(build) is not int or not 1 <= build <= 2100000000:
    sys.exit("Invalid mobile.json build")
if not isinstance(name, str) or not name.strip() or len(name) > 40:
    sys.exit("Invalid mobile.json name")
if re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff\ufffe\uffff]", name):
    sys.exit("Mobile app name contains a character XML cannot represent")

ET.register_namespace("android", "http://schemas.android.com/apk/res/android")
manifest = ET.parse(source_manifest)
manifest.getroot().set("package", app_id)
manifest.write(stage / "AndroidManifest.xml", encoding="utf-8", xml_declaration=True)
resource = ET.Element("resources")
label = ET.SubElement(resource, "string", name="app_name", formatted="false")
# Android resource quoting preserves whitespace and disables leading @/? references.
label.text = '"' + name.translate({
    ord("\\"): r"\\", ord('"'): r'\"', ord("'"): r"\'",
    ord("\r"): r"\r", ord("\n"): r"\n", ord("\t"): r"\t",
}) + '"'
ET.ElementTree(resource).write(stage / "res/values/strings.xml", encoding="utf-8", xml_declaration=True)
(stage / "version.txt").write_text(f"{app_id}\n{version}\n{build}\n", encoding="utf-8")
PY

mapfile -t metadata < "$stage/version.txt"
app_id="${metadata[0]}"
version="${metadata[1]}"
build="${metadata[2]}"
test -s "$stage/assets/web/index.html"

"$tools/aapt2" compile --dir "$stage/res" -o "$stage/resources.zip"
"$tools/aapt2" link -o "$stage/unsigned.apk" -I "$platform" \
    --manifest "$stage/AndroidManifest.xml" \
    --min-sdk-version 24 --target-sdk-version 34 --version-code "$build" --version-name "$version" \
    -A "$stage/assets" "$stage/resources.zip"
mapfile -d '' -t sources < <(find "$sources_dir/java" -type f -name '*.java' -print0)
test "${#sources[@]}" -gt 0
javac -encoding UTF-8 --release 8 -classpath "$platform" -d "$stage/classes" "${sources[@]}"
jar cf "$stage/classes.jar" -C "$stage/classes" .
"$tools/d8" --release --lib "$platform" --min-api 24 --output "$stage/dex" "$stage/classes.jar"
test -s "$stage/dex/classes.dex"
zip -q -j "$stage/unsigned.apk" "$stage"/dex/classes*.dex
"$tools/zipalign" -f 4 "$stage/unsigned.apk" "$stage/aligned.apk"
"$tools/apksigner" sign --ks "$stage/signing.p12" --ks-type PKCS12 --ks-key-alias pocket \
    --ks-pass env:ANDROID_SIGNING_PASSWORD --key-pass env:ANDROID_SIGNING_PASSWORD \
    --out "$stage/pocket-android.apk" "$stage/aligned.apk"
unset ANDROID_SIGNING_PASSWORD

apk="$stage/pocket-android.apk"
"$tools/apksigner" verify --verbose "$apk"
"$tools/zipalign" -c 4 "$apk"
badging="$("$tools/aapt2" dump badging "$apk")"
printf '%s\n' "$badging"
analyzer=
for candidate in "$sdk_root/cmdline-tools/latest/bin/apkanalyzer" "$sdk_root"/cmdline-tools/*/bin/apkanalyzer; do
    if [[ -x "$candidate" ]]; then
        analyzer="$candidate"
        break
    fi
done
if [[ -z "$analyzer" ]]; then
    printf 'Missing APK manifest analyzer under %s/cmdline-tools\n' "$sdk_root" >&2
    exit 1
fi
JAVA_HOME="${JAVA_HOME_21_X64:-${JAVA_HOME:-}}" "$analyzer" manifest print "$apk" > "$stage/packaged-manifest.xml"
python3 - "$apk" "$stage/packaged-manifest.xml" "$app_id" "$version" "$build" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from zipfile import ZipFile

apk, manifest_path, app_id, version, build = sys.argv[1:]
manifest = ET.parse(manifest_path).getroot()
android = "{http://schemas.android.com/apk/res/android}"
if (manifest.get("package"), manifest.get(android + "versionName"),
        manifest.get(android + "versionCode")) != (app_id, version, build):
    sys.exit("APK manifest application ID or version differs from mobile.json")
sdk = manifest.find("uses-sdk")
if sdk is None or (sdk.get(android + "minSdkVersion"), sdk.get(android + "targetSdkVersion")) != ("24", "34"):
    sys.exit("APK manifest does not declare minimum API 24 and target API 34")
launcher = next((activity for activity in manifest.findall("application/activity")
                 if activity.get(android + "name") == "com.pocketpublish.shell.MainActivity"), None)
if launcher is None or launcher.get(android + "exported") != "true" or not any(
    "android.intent.action.MAIN" in {action.get(android + "name") for action in intent.findall("action")}
    and "android.intent.category.LAUNCHER" in {category.get(android + "name") for category in intent.findall("category")}
    for intent in launcher.findall("intent-filter")
):
    sys.exit("APK manifest does not declare the exported launcher activity")
print("Verified packaged application identity, version, SDK levels and launcher activity")

with ZipFile(apk) as package:
    expected = {"AndroidManifest.xml", "classes.dex", "resources.arsc", "res/drawable/app_icon.xml"}
    if package.testzip() is not None or not expected.issubset(package.namelist()):
        sys.exit("The APK is missing a required compiled entry or has a corrupt ZIP entry")
    assets = [Path("mobile.json"), *(page for page in Path("web").rglob("*") if page.is_file())]
    for source in assets:
        if package.read("assets/" + source.as_posix()) != source.read_bytes():
            sys.exit(f"Packaged content differs: {source}")
    print(f"Verified {len(assets)} packaged web/metadata files")
PY
mkdir -p out
mv -f "$apk" out/pocket-android.apk
