#!/usr/bin/env bash
# Test builds only: keep the repository's debug ID and automatic debug signing.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
output_dir=${1:-"$repo_root/test-artifacts/android"}
flutter_command=${FLUTTER_COMMAND:-fvm}
if [[ "$flutter_command" == fvm ]]; then
  flutter=(fvm flutter)
else
  flutter=("$flutter_command")
fi
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
apk_output="$output_dir/LocalSend-Test-Android.apk"
if [[ -e "$apk_output" ]]; then
  echo "Refusing to replace an existing APK: $apk_output" >&2
  exit 1
fi

version_file=$(mktemp)
trap 'rm -f "$version_file"' EXIT
"${flutter[@]}" --version --machine > "$version_file"
python3 - "$repo_root/.fvmrc" "$version_file" <<'PY'
import json, sys
expected = json.load(open(sys.argv[1]))['flutter']
actual = json.load(open(sys.argv[2]))['frameworkVersion']
if actual != expected:
    raise SystemExit(f'Flutter version mismatch: expected {expected}, got {actual}')
PY

cd "$repo_root/app"
"${flutter[@]}" pub get --enforce-lockfile
cd "$repo_root/packages/localsend_isolates/rust_builder/cargokit/build_tool"
"${flutter[@]}" pub get --enforce-lockfile
cd "$repo_root/app"
"${flutter[@]}" build apk --debug --no-pub --target-platform android-arm,android-arm64,android-x64

apk="$repo_root/app/build/app/outputs/flutter-apk/app-debug.apk"
sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
if [[ -z "$sdk_root" ]]; then
  echo 'ANDROID_SDK_ROOT or ANDROID_HOME is required for APK validation.' >&2
  exit 1
fi
build_tools="$sdk_root/build-tools/36.0.0"
"$build_tools/apksigner" verify --verbose "$apk" > "$output_dir/apk-signature.txt"
"$build_tools/aapt" dump badging "$apk" > "$output_dir/apk-metadata.txt"
python3 - "$apk" "$output_dir/apk-metadata.txt" <<'PY'
import pathlib, sys, zipfile
metadata = pathlib.Path(sys.argv[2]).read_text()
if "package: name='org.localsend.localsend_app.debug'" not in metadata:
    raise SystemExit('Expected the separate LocalSend debug application ID')
with zipfile.ZipFile(sys.argv[1]) as apk:
    names = set(apk.namelist())
    for abi in ('armeabi-v7a', 'arm64-v8a', 'x86_64'):
        if f'lib/{abi}/librust_lib_localsend_app.so' not in names:
            raise SystemExit(f'Missing Rust library for {abi}')
print('APK identity, signing and Rust ABI libraries verified.')
PY
cp "$apk" "$apk_output"
cp "$repo_root/LICENSE" "$output_dir/LICENSE"
git -C "$repo_root" rev-parse HEAD > "$output_dir/SOURCE_COMMIT.txt"
cat > "$output_dir/TESTING.txt" <<'TXT'
LocalSend Android test build (debug), not a store release.
Application ID: org.localsend.localsend_app.debug. Display name: LocalSend Debug.
Uses Android's development signing key. It can coexist with the official app.
Avoid running both instances simultaneously on their default network port.
To test: put Android and Windows on the same LAN, send a small file in both
directions and compare its contents. Device interoperability is not established
merely by a successful build or APK signature verification.
Source and third-party license notices are also available through the app.
TXT
(cd "$output_dir" && sha256sum LocalSend-Test-Android.apk > SHA256SUMS.txt)
git -C "$repo_root" diff --exit-code
echo "Android test APK: $apk_output"
