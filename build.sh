#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="build/Magicker Mouse.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"
cp Resources/*.icns Resources/*.png "$app/Contents/Resources/"
xcrun clang -fobjc-arc -mmacosx-version-min=15.0 -framework Cocoa \
    -framework ApplicationServices Mapper.m -o "$app/Contents/MacOS/MagicMouseMapper"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
ditto -c -k --norsrc --keepParent "$app" build/Magicker-Mouse-19.zip
