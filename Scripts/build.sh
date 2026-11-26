#!/bin/bash
# Runs on GitHub's macOS runner (see .github/workflows/build.yml). You do not run this yourself.
set -euo pipefail

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf build
APP="build/AudioController.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AudioController" "$APP/Contents/MacOS/AudioController"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature (no Apple Developer account). First launch: right-click the app > Open.
codesign --force --deep --sign - "$APP"

mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Audio Controller" -srcfolder build/dmg -ov -format UDZO build/AudioController.dmg
lipo -info "$APP/Contents/MacOS/AudioController" || true
ls -la build
