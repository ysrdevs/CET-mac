# CET Mac

![macOS arm64](https://img.shields.io/badge/macOS-arm64-black)
![Cyberpunk 2077](https://img.shields.io/badge/Cyberpunk%202077-2.3.1-yellow)
![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-Steam%20supported-green)

A native Apple Silicon in-game console for Cyberpunk 2077 on macOS.

Think Cyber Engine Tweaks, but rebuilt for native macOS/Apple Silicon. CET Mac brings CET-style commands
to the native macOS version of Cyberpunk 2077, with an in-game Metal overlay you drive from the keyboard:
search and spawn from a built-in browser of 7,552 items, pin your favorites, fire one-click cheats
(money, heal, godmode, perks/attributes/relic, level), teleport with bookmarks, run CET-style commands,
and debug REDengine calls.

Single-player, personal use, on your own legally-owned copy. Not affiliated with Cyber Engine Tweaks or
CD PROJEKT RED. Back up your saves before using it.

Platform: macOS arm64. Built against Cyberpunk 2077 v2.3.1 (Steam). GOG support is in progress.

![CET Mac launcher](assets/screenshot.png)

## Demo

[Watch the demo](https://raw.githubusercontent.com/ysrdevs/CET-mac/main/assets/demo.mp4) (adding relic and perk points, weapons, and money, live in-game on macOS).

## For players

Prefer a walkthrough? Watch the install video:

[![Watch the install video](https://img.youtube.com/vi/V5KFp34nzPg/hqdefault.jpg)](https://www.youtube.com/watch?v=V5KFp34nzPg)

1. Download `CET-Mac.dmg` from [Releases](../../releases).
2. Open it and drag CET Mac into your Applications folder.
3. Open CET Mac, click Install, then Play.
4. In-game, press the backtick/tilde key (`` ` ``) or F1 to open the console.

No Terminal, no file editing. The app finds your game, installs the files (re-signing it so the console can
load), and launches it. Steam Cloud saves keep working.

Updating from an older version? After replacing the app, click Install once (it reads "Reinstall CET Mac"),
then Play. No need to uninstall first.

### Using the console in-game

The game captures the mouse during play, so the overlay is keyboard-driven. Switch tabs with **Cmd+1 /
Cmd+2 / Cmd+3**:

- **Console** (Cmd+1) - type commands directly. Up/Down for history, Cmd+V to paste, `help` for the list.
- **Items** (Cmd+2) - type to search 7,552 items, press **Enter** to spawn the top match, **Cmd+P** to pin
  it to your favorites. Set the quantity first if you want a stack.
- **Quick** (Cmd+3) - one-click cheats (money, heal, godmode, perks/attributes/relic, level), your pinned
  favorites, and teleport bookmarks.

Every action shows a confirmation at the bottom so you can see exactly what was added.

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

- **In-game ImGui console** drawn on the live frame (Metal), keyboard-driven with tabs (Cmd+1/2/3),
  command history, and clipboard (Cmd+V).
- **Searchable item browser** - a bundled catalog of 7,552 items. Type to filter, Enter to spawn the top
  match, no hunting for ids. Add/remove any item by `Items.*` id, any quantity, including CET
  `Game.AddToInventory` syntax.
- **Pinned favorites** - pin items (Cmd+P) and they persist across restarts in a Quick tab, so your go-to
  gear is one keypress away.
- **One-click cheats** - money, full heal, godmode, perks, attributes, relic points, set character level.
- **Teleport** with saved position bookmarks (save a spot, return to it later).
- **Action confirmations** - every command reports what it just did.
- Quest facts, and a generic `call <Class> <Method>` bridge that can invoke any observed RTTI method.

See [docs/COMMANDS.md](docs/COMMANDS.md) for the full list and known limits.

## How it works (short version)

CET Mac injects into the arm64 game process with `DYLD_INSERT_LIBRARIES` (no SIP changes), resolves
REDengine's RTTI, and drives the script VM to call game functions with typed arguments. The console UI is
Dear ImGui drawn from a `presentDrawable:` hook; input comes from an `NSApplication.sendEvent:` hook.
Commands travel over a small file channel to the injected script engine.

On Install, the launcher re-signs the game binary ad-hoc with the `allow-jit` /
`allow-unsigned-executable-memory` entitlements. The stock Steam signature omits these, and without them
macOS kills the game the moment the injected JIT engine generates code. This changes nothing permanent:
Steam's "Verify Integrity of Game Files" restores the original signature at any time.

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
- Install re-signs the game binary (ad-hoc) so the console can load. It is reversible at any time via
  Steam's "Verify Integrity of Game Files".
- macOS arm64 only.

## Support

This is free and open source. If it saved you some hassle and you want to support development, you
can buy me a coffee. Completely optional, and very appreciated.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/ysrdevs)

## Credits and license

MIT (see [LICENSE](LICENSE)). Built on [Dear ImGui](https://github.com/ocornut/imgui), Frida, and the
RED4ext macOS port. See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
