#!/bin/bash
# Builds YTA.app with Swift Package Manager and the Command Line Tools only. No Xcode needed.
#
#   Scripts/build-app.sh            release build into ./build/YTA.app
#   Scripts/build-app.sh debug      debug build
#   Scripts/build-app.sh --install  also copy the app to ~/Applications
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

CONFIG="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug) CONFIG="debug" ;;
    release) CONFIG="release" ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "Building YTA $VERSION ($BUILD_NUMBER), $CONFIG"
swift build -c "$CONFIG" --arch arm64 --product YTA
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="$ROOT/build/YTA.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/YTA" "$APP/Contents/MacOS/YTA"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Scripts/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# SwiftPM resource bundles, if any target has resources.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# App resources (fonts, skills, prompt templates) live in Resources/.
if [ -d Resources ]; then
  rsync -a --exclude '.gitkeep' Resources/ "$APP/Contents/Resources/"
fi

if [ -f Scripts/AppIcon.icns ]; then
  cp Scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

"$ROOT/Scripts/sign.sh" "$APP"

echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/YTA.app"
  cp -R "$APP" "$HOME/Applications/YTA.app"
  echo "Installed to ~/Applications/YTA.app"
fi
