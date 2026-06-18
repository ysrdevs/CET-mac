# CET Mac

An in-game cheat/mod console for Cyberpunk 2077 on macOS (Apple Silicon). It does the kind of thing
Cyber Engine Tweaks does on Windows, on a platform where CET doesn't exist. You press a key in-game,
a console appears, and you type commands: spawn items, add money, set perks/attributes/level, teleport,
and more. CET item codes from the internet paste in and work as-is.

Single-player, personal use, on your own legally-owned copy. Not affiliated with CD PROJEKT RED.
Back up your saves before using it.

Platform: macOS arm64. Built against Cyberpunk 2077 v2.3.1 (Steam). GOG support is in progress.

![CET Mac launcher](assets/screenshot.png)

## Demo

[Watch the demo](https://raw.githubusercontent.com/ysrdevs/CET-mac/main/assets/demo.mp4) (adding relic and perk points, weapons, and money, live in-game on macOS).

## For players

1. Download `CET-Mac.dmg` from [Releases](../../releases).
2. Open it and run CET Mac (drag it to Applications if you like).
3. Click Install, then Play.
4. In-game, press the backtick/tilde key (`` ` ``) or F1 to open the console. Type `help`.

No Terminal, no file editing. The app finds your game, installs the files, and launches it. Steam Cloud
saves keep working.

Common commands (full list in [docs/COMMANDS.md](docs/COMMANDS.md), or `help` in-game):

```
give Items.Preset_Silverhand_3516 1       # Johnny's Malorian
money 50000
perks 10
level 50
heal
teleport save home    then    teleport home
Game.AddToInventory("Items.MaxDOSE", 5)    # CET-style line, also works
```

## What works

- In-game ImGui console drawn on the live frame (Metal), with command history and clipboard (Cmd+V).
- Add/remove any item by `Items.*` id, any quantity. Includes CET `Game.AddToInventory` syntax.
- Money, perks, attributes, relic points, character level, full heal.
- Teleport with position bookmarks, quest facts, and a generic `call <Class> <Method>` bridge that can
  invoke any observed RTTI method.

See [docs/COMMANDS.md](docs/COMMANDS.md) for the full list and known limits.

## How it works (short version)

CET Mac injects into the arm64 game process with `DYLD_INSERT_LIBRARIES` (no SIP changes; the game
ships entitlements that allow it), resolves REDengine's RTTI, and drives the script VM to call game
functions with typed arguments. The console UI is Dear ImGui drawn from a `presentDrawable:` hook; input
comes from an `NSApplication.sendEvent:` hook. Commands travel over a small file channel to the injected
script engine.

For the full write-up of the reverse engineering and architecture, see [TECHNICAL.md](TECHNICAL.md).

- `runtime/red4ext_hooks.js` - the command engine (RTTI calls, all commands).
- `overlay/overlay.mm` - the Metal/ImGui overlay and input.
- `launcher/` - the macOS app that installs and launches the game.

## For developers (from source)

```bash
git clone <this repo> && cd cet-mac
./tools/fetch-deps.sh        # pulls FridaGadget + RED4ext into deps/ (copies from a local install if present)
./dev/launch.sh              # builds the overlay, stages the payload into your game, and launches it
```

`dev/launch.sh` honors `CP2077_DIR` if your game isn't at the default Steam path. The third-party runtime
binaries are not committed (see `.gitignore`); they're fetched into `deps/` and bundled into the release
`.dmg`. Building the signed, notarized app: see `tools/sign-notarize.sh` (needs an Apple Developer ID);
it produces both a `.dmg` and a `.zip` in `dist/`.

## Compatibility and caveats

- **Steam version only** right now. The offsets are derived from the Steam macOS build; the GOG build
  differs, so it is not supported yet. **GOG support is in progress.**
- Built against Cyberpunk 2077 v2.3.1 (macOS, Apple Silicon, Steam). Game updates can move offsets and
  break it. Releases are tagged per supported game version.
- Single-player only. Modding can corrupt saves, so keep backups.
- macOS arm64 only.

## Support

This is free and open source. If it saved you some hassle and you want to support development, you
can buy me a coffee. Completely optional, and very appreciated.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/ysrdevs)

## Credits and license

MIT (see [LICENSE](LICENSE)). Built on [Dear ImGui](https://github.com/ocornut/imgui), Frida, and the
RED4ext macOS port. See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
