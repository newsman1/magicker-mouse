#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# Stage outside Finder-managed folders to avoid metadata invalidating signatures.
stage=$(mktemp -d "${TMPDIR:-/tmp}/magicker-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Magicker Mouse.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build
cp Info.plist "$app/Contents/"
cp Resources/*.icns Resources/*.png "$app/Contents/Resources/"
xcrun clang -fobjc-arc -mmacosx-version-min=15.0 -framework Cocoa \
    -framework UniformTypeIdentifiers -framework ApplicationServices -framework IOKit Mapper.m -o "$app/Contents/MacOS/MagicMouseMapper"
xattr -cr "$app"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto -c -k --norsrc --keepParent "$app" build/Magicker-Mouse-25.zip
ditto --norsrc "$app" "build/Magicker Mouse.app"
