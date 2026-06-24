#!/bin/bash
# Build "NightCity Console.app" (ad-hoc signed, for dev/testing).
# Bundles the runtime payload into Contents/Resources so the app can install it into the game.
# Release signing + notarization + .dmg is a separate step: tools/sign-notarize.sh
set -e
cd "$(dirname "$0")/.."   # repo root
APP="build/NightCity Console.app"

echo "==> overlay + deps"
./overlay/build.sh
./tools/fetch-deps.sh

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp launcher/Info.plist "$APP/Contents/Info.plist"

echo "==> compiling launcher"
swiftc -O -parse-as-library -target arm64-apple-macos12 \
  -o "$APP/Contents/MacOS/NightCityConsole" \
  launcher/Sources/*.swift

echo "==> bundling payload into Resources"
cp runtime/red4ext_hooks.js runtime/FridaGadget.config runtime/cet_catalog.tsv "$APP/Contents/Resources/"
cp deps/RED4ext.dylib deps/FridaGadget.dylib            "$APP/Contents/Resources/"
cp build/libcyberconsole_overlay.dylib                  "$APP/Contents/Resources/"
# CyberModMan creator payload (TweakXL plugin from deps/ + seed names file; launcher deploys these on install)
cp deps/TweakXL.dylib runtime/cybermodman/cybermodman_names.json "$APP/Contents/Resources/"

if [ -f assets/icon.png ]; then
  echo "==> generating app icon (AppIcon.icns from assets/icon.png)"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s"             assets/icon.png --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -z "$((s*2))" "$((s*2))" assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "==> ad-hoc signing"
codesign -s - --deep --force "$APP" >/dev/null
echo "built $APP"
echo "Run it:  open \"$APP\"   (first launch may need right-click -> Open until notarized)"
