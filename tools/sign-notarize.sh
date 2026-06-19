#!/bin/bash
# Sign (Developer ID + hardened runtime), notarize, and package "CET Mac.app" into a .dmg and a .zip.
# YOU run this with YOUR Apple Developer ID - it never asks the assistant for credentials.
#
# One-time setup (stores your notary credentials in the keychain):
#   xcrun notarytool store-credentials cyberconsole-notary \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# Then run:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="cyberconsole-notary" \
#   ./tools/sign-notarize.sh
set -e
cd "$(dirname "$0")/.."
APP="build/CET Mac.app"
DMG="dist/CET-Mac.dmg"
ZIP="dist/CET-Mac.zip"          # distributable zip (made from the stapled app)
SUBZIP="dist/_notarize.zip"     # temporary zip used only for the notarization upload

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to 'Developer ID Application: NAME (TEAMID)'}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile name}"

echo "==> building app (ad-hoc), then re-signing with Developer ID"
./launcher/build-app.sh

# Sign every Mach-O inside-out with hardened runtime + secure timestamp (required for notarization).
find "$APP/Contents/Resources" -name "*.dylib" -print0 | while IFS= read -r -d '' f; do
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
done
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> notarizing the app"
mkdir -p dist
rm -f "$SUBZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBZIP"
xcrun notarytool submit "$SUBZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"          # staple the ticket onto the app on disk
rm -f "$SUBZIP"

echo "==> packaging the stapled app (.zip + .dmg)"
# 1) distributable .zip: the app inside is stapled, so it passes Gatekeeper offline
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
# 2) .dmg with an /Applications shortcut + drag-here layout, then notarize + staple
#    the dmg itself so the downloaded image also passes Gatekeeper offline.
rm -f "$DMG"
VOL="CET Mac"; STAGE="build/dmg"; RWDMG="dist/_rw.dmg"; APPNAME="$(basename "$APP")"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APPNAME"
ln -s /Applications "$STAGE/Applications"            # the shortcut users drag into
rm -f "$RWDMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RWDMG"
MNT="/Volumes/$VOL"
hdiutil attach "$RWDMG" -nobrowse -noverify -noautoopen >/dev/null
# Lay the window out as icon view: app on the left, Applications on the right, so it's
# obvious you copy the app over. Non-fatal if Finder automation is unavailable - the
# Applications shortcut alone still conveys it.
osascript <<EOF || echo "  (note: could not style dmg window; Applications shortcut is still present)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 760, 470}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 96
    set text size of vopts to 12
    set position of item "$APPNAME" of container window to {150, 200}
    set position of item "Applications" of container window to {410, 200}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
sync; hdiutil detach "$MNT" >/dev/null || hdiutil detach "$MNT" -force >/dev/null
hdiutil convert "$RWDMG" -format UDZO -o "$DMG" >/dev/null
rm -f "$RWDMG"; rm -rf "$STAGE"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "done (signed, notarized, stapled - no Gatekeeper warnings):"
echo "  $DMG"
echo "  $ZIP"
