#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-macos.sh release --build-only

app="$PWD/.build-app/Cozy Notes.app"
plist="$app/Contents/Info.plist"
exe="$app/Contents/MacOS/CozyNotes"

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")"
min_os="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist")"
archs="$(lipo -archs "$exe" | tr ' ' '-')"

out_dir="$PWD/.build-app/release"
mkdir -p "$out_dir"

zip_name="Cozy-Notes-v${version}-macOS-${min_os}-${archs}.zip"
zip_path="$out_dir/$zip_name"
sha_path="${zip_path}.sha256"

rm -f -- "$zip_path" "$sha_path"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"
(cd "$out_dir" && shasum -a 256 "$zip_name" > "${zip_name}.sha256")

printf '\nRelease Archive: %s\n' "$zip_path"
printf 'SHA-256 File:    %s\n' "$sha_path"
cat "$sha_path"
