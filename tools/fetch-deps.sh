#!/bin/bash
# Populate deps/ with the third-party runtime binaries CyberConsole injects.
# These are NOT committed to git (FridaGadget is ~57 MB). They are bundled into the
# release .dmg at package time.
#
# Primary path: copy from a known-good local Cyberpunk 2077 install (if present).
# Otherwise, download from upstream (see URLs below) and place the files in deps/.
set -e
cd "$(dirname "$0")/.."
mkdir -p deps
GAME="$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/red4ext"

copy_if() { [ -f "$1" ] && cp "$1" "deps/$(basename "$1")" && echo "  got $(basename "$1")"; }

echo "Fetching runtime deps into deps/ ..."
if [ -d "$GAME" ]; then
  echo "Found local install - copying from: $GAME"
  copy_if "$GAME/RED4ext.dylib"
  copy_if "$GAME/FridaGadget.dylib"
  copy_if "$GAME/plugins/TweakXL/TweakXL.dylib"   # CyberModMan creator weapon engine (RED4ext plugin)
fi

MISSING=0
for f in RED4ext.dylib FridaGadget.dylib TweakXL.dylib; do
  [ -f "deps/$f" ] || { echo "  MISSING: deps/$f"; MISSING=1; }
done

if [ "$MISSING" = "1" ]; then
  cat <<'EOF'

Some deps are missing. Obtain them from upstream and drop into deps/:
  - FridaGadget.dylib : frida-gadget (macOS arm64) from https://github.com/frida/frida/releases
                        (download frida-gadget-<ver>-macos-arm64.dylib.gz, gunzip, rename to FridaGadget.dylib)
  - RED4ext.dylib     : RED4ext macOS port release
Then re-run this script (or just place the files and continue).
EOF
  exit 1
fi
echo "deps ready."
