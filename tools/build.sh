#!/bin/bash
# Builds Doddy without opening Xcode and installs it in /Applications.
# Usage: ./tools/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
python3 tools/genproj.py >/dev/null
xcodebuild -project Doddy.xcodeproj -target Doddy -configuration Release \
  SYMROOT="$PWD/build" CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build | tail -n 25
APP="$PWD/build/Release/Doddy.app"
[ -d "$APP" ] || { echo "Build failed: Doddy.app was not produced"; exit 1; }
osascript -e 'tell application "Doddy" to quit' 2>/dev/null || true
sleep 1
rm -rf /Applications/Doddy.app
cp -R "$APP" /Applications/Doddy.app
rm -rf "$PWD/build"      # keep only the installed copy, so macOS never opens a second one
xattr -dr com.apple.quarantine /Applications/Doddy.app 2>/dev/null || true
open /Applications/Doddy.app
echo "Doddy is installed in /Applications and running."
