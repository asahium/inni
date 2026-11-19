#!/bin/bash
# Builds build/Inni-<version>.dmg (app + /Applications link). VERSION/BUILD override Info.plist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PLIST="$ROOT/Resources/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")}"

"$ROOT/scripts/bundle.sh" release
APP="$ROOT/build/Inni.app"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
if [ -n "${BUILD:-}" ]; then /usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" "$APP/Contents/Info.plist"; fi
codesign --force --sign - --timestamp=none "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/build/Inni-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Inni $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
echo "$DMG"
