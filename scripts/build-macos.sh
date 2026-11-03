#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo 'Usage: scripts/build-macos.sh [debug|release]' >&2; exit 2;; esac
swift build -c "$configuration"
bin="$(swift build -c "$configuration" --show-bin-path)"
app="$PWD/.build-app/Cozy Notes.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/CozyNotes" "$app/Contents/MacOS/CozyNotes"
cp packaging/Info.plist "$app/Contents/Info.plist"
install -m 644 .build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/SwiftTerm-LICENSE.txt"
# SwiftPM may emit resource bundles beside its executable.
for bundle in "$bin"/*.bundle; do
    [ -d "$bundle" ] || continue
    cp -R "$bundle" "$app/Contents/Resources/"
done
codesign --force --deep --sign - "$app"
printf '\nApp: %s\n' "$app"
