#!/bin/bash
# Builds Doddy (Release), installs it in /Applications and makes a disk image you can share.
# Run from the project folder:  ./tools/package.sh
set -e
cd "$(dirname "$0")/.."

echo "1/5  Preparing the project…"
python3 tools/genproj.py >/dev/null

echo "2/5  Building (this takes a minute)…"
rm -rf build
xcodebuild -project Doddy.xcodeproj -target Doddy -configuration Release \
  SYMROOT="$PWD/build" CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES -quiet build

APP="$PWD/build/Release/Doddy.app"
if [ ! -d "$APP" ]; then echo "Build failed: Doddy.app not found."; exit 1; fi

echo "3/5  Installing in /Applications…"
osascript -e 'tell application "Doddy" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Doddy.app
cp -R "$APP" /Applications/Doddy.app
xattr -cr /Applications/Doddy.app

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0")

echo "4/5  Making the disk image and the extension zip…"
rm -rf dist
mkdir -p dist/dmg
cp -R "$APP" dist/dmg/Doddy.app
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "Doddy" -srcfolder dist/dmg -ov -format UDZO "dist/Doddy-$VERSION.dmg" >/dev/null
rm -rf dist/dmg
# The browser extension, ready for "Load unpacked" after unzipping.
mkdir -p "dist/ext/Doddy extension"
cp -R extension/. "dist/ext/Doddy extension/"
find dist/ext -name ".DS_Store" -delete
(cd dist/ext && zip -qr "../Doddy-extension-$VERSION.zip" "Doddy extension")
rm -rf dist/ext

echo "5/5  Opening Doddy…"
open /Applications/Doddy.app
echo
echo "Done. Doddy is in Applications. Files to share are in $PWD/dist:"
ls -1 dist | sed "s/^/  /"
echo "Next: reload the extension in chrome://extensions (Load unpacked → the 'extension' folder, or use the button in Doddy's Setup)."
