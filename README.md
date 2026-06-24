# NightCity Console for Mac

![macOS arm64](https://img.shields.io/badge/macOS-arm64-black)
![Cyberpunk 2077](https://img.shields.io/badge/Cyberpunk%202077-2.3.1-yellow)
![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-Steam%20supported-green)

A native Apple Silicon in-game console, cheat menu, and item browser for Cyberpunk 2077 on macOS. Think Cyber Engine Tweaks, rebuilt from scratch for the native macOS/Apple Silicon build of the game: inject into the running process, resolve REDengine's runtime type system, call game functions with real typed arguments, and draw a console on the live frame with a Metal overlay you drive from the keyboard.

> Renamed from "CET Mac" to "NightCity Console for Mac" to avoid confusion with Cyber Engine Tweaks. This is an independent, macOS-native project and is not affiliated with CET, WolvenKit, REDmod, CD PROJEKT RED, or Cyberpunk 2077. Single-player, personal use, on your own legally-owned copy. Back up your saves before using it.

![NightCity Console launcher](assets/screenshot.png)

## Demo

[Watch the demo](https://raw.githubusercontent.com/ysrdevs/nightcity-console-mac/main/assets/demo.mp4) (adding relic and perk points, weapons, and money, live in-game on macOS).

## Screenshots

<table>
  <tr>
    <td width="50%"><img src="assets/search-item.jpg" width="100%" alt="Search any item and add it"><br><b>Search any item and spawn it</b></td>
    <td width="50%"><img src="assets/item-stats.jpg" width="100%" alt="Find any item and its stats"><br><b>Find any item and its stats</b></td>
  </tr>
  <tr>
    <td width="50%"><img src="assets/add-points.jpg" width="100%" alt="Add perks, attributes, and relic points"><br><b>Add perks, attributes, and relic points</b></td>
    <td width="50%"><img src="assets/teleport-quick-actions.jpg" width="100%" alt="Teleport utility and quick actions"><br><b>Teleport utility and quick actions</b></td>
  </tr>
</table>

## Status

macOS arm64 (Apple Silicon, M1/M2/M3/M4). Built and verified against Cyberpunk 2077 v2.3.1 (Steam). GOG support is in progress. The offsets and hashes are derived from the Steam macOS build, so other distributions are not supported yet.

## What it does

- In-game ImGui console drawn on the live frame (Metal), keyboard-driven, with tabbed views (Cmd+1/2/3), command history, and clipboard support (Cmd+V/C/X/A).
- Searchable item browser backed by a bundled catalog of 7,552 items. Browse by category (Weapons, Cyberware, Clothes, Crafting, Mods, Misc) or type to filter, press Enter to spawn the top match, no hunting for ids.
- Pinned favorites that persist across restarts, surfaced in a Quick tab so your go-to gear is one keypress away.
- One-click cheats: money, full heal, perks, attributes, relic points, set character level.
- Godmode that registers with the engine godmode system and auto-reapplies across scene and vehicle transitions.
- Invisibility (line-of-sight and detection break), infinite ammo, and world toggles (time of day, slow motion, disable police response).
- Teleport with saved position bookmarks (save a spot, return to it later).
- A generic `call <Class> <Method>` bridge that can invoke any observed RTTI method, plus quest-fact editing.
- Action confirmations: every command reports exactly what it did at the bottom of the overlay.
- Native Mods tab that lists, enables, and disables loose `.archive` mods by renaming `.archive` to `.archive.off`.

See [docs/COMMANDS.md](docs/COMMANDS.md) for the full command list and known limits.

## Requirements

- Apple Silicon Mac (arm64). Intel is not supported.
- macOS 12 (Monterey) or newer.
- Cyberpunk 2077 v2.3.1, macOS, Steam build.
- A legally-owned copy of the game. No CD PROJEKT RED files are distributed by this project.

## Install and usage (players)

Prefer a walkthrough? Watch the install and usage video:

[![Watch the install and usage video](https://img.youtube.com/vi/VOUMaNLSAV0/hqdefault.jpg)](https://youtu.be/VOUMaNLSAV0)

1. Download `NightCity-Console-for-Mac.dmg` from [Releases](../../releases).
2. Open it and drag NightCity Console into your Applications folder.
3. Open NightCity Console, click Install, then Play.
4. In-game, press the backtick/tilde key (`` ` ``) or F1 to open the console.

No Terminal, no file editing. The app finds your game, installs the runtime files (re-signing the game binary so the console can load), and launches it. Steam Cloud saves keep working.

Updating from an older version: after replacing the app, click Install once (it reads "Reinstall NightCity Console"), then Play. No need to uninstall first.

### Using the console in-game

The game captures the mouse during play, so the overlay is keyboard-driven. Switch tabs with Cmd+1 / Cmd+2 / Cmd+3:

- Console (Cmd+1): type commands directly. Up/Down for history, Cmd+V to paste, `help` for the list.
- Items (Cmd+2): browse by category (Cmd+G cycles categories) or type to search the 7,552-item catalog. Enter spawns the top match, Cmd+P pins it to favorites. Set the quantity first if you want a stack.
- Quick (Cmd+3): one-click cheats, your pinned favorites, and teleport bookmarks.

Common commands (full list in [docs/COMMANDS.md](docs/COMMANDS.md), or `help` in-game):

```text
give Items.Preset_Silverhand_3516 1       # Johnny's Malorian
money 50000
perks 10
level 50
heal
teleport save home    then    teleport home
Game.AddToInventory("Items.MaxDOSE", 5)    # CET-style line, also works
```

## Build (from source)

```bash
git clone <this repo> && cd nightcity-console-mac
./tools/fetch-deps.sh        # pulls FridaGadget + RED4ext into deps/ (copies from a local install if present)
./dev/launch.sh              # builds the overlay, stages the payload into your game, and launches it
```

`dev/launch.sh` honors `CP2077_DIR` if your game is not at the default Steam path. The third-party runtime binaries (`RED4ext.dylib`, `FridaGadget.dylib`) are not committed (see `.gitignore`); they are fetched into `deps/` and bundled into the release `.dmg`.

To build the signed, notarized app for distribution, run `tools/sign-notarize.sh` (needs an Apple Developer ID). It re-signs everything inside-out with a hardened runtime, notarizes the `.app` and the `.dmg` with `notarytool`, staples the tickets, and produces both a `.dmg` and a `.zip` in `dist/`.

Key source files:

- `runtime/red4ext_hooks.js`: the command engine (RTTI resolution, function calls, all commands).
- `overlay/overlay.mm`: the Metal/ImGui overlay and input handling.
- `launcher/`: the SwiftUI macOS app that installs and launches the game.

## How it works (short version)

NightCity Console injects three dylibs into the arm64 game process with `DYLD_INSERT_LIBRARIES` (no SIP changes): the macOS RED4ext hooking framework, the Frida gadget (an in-process script host), and a native Metal/ImGui overlay. It resolves REDengine's RTTI registry, then drives the script VM (the universal script executor) to call game functions with typed arguments built into a synthetic script stack frame. The console UI is Dear ImGui drawn from a `presentDrawable:` swizzle; input comes from an `NSApplication.sendEvent:` swizzle. The command engine and the overlay are decoupled and communicate over a small file channel in `/tmp`.

On Install, the launcher re-signs the game binary ad-hoc with the `allow-jit` and `allow-unsigned-executable-memory` entitlements. The stock Steam signature omits these, and without them macOS kills the game the moment the injected JIT engine generates code. Nothing is permanent: Steam's "Verify Integrity of Game Files" restores the original signature at any time.

For the full reverse-engineering and architecture write-up (offsets, struct layouts, calling convention, the bugs found and how they were fixed), see [TECHNICAL.md](TECHNICAL.md). For the complete macOS modding platform (RED4ext, RED4ext.SDK, TweakXL, ArchiveXL, and the console runtime), see [docs/MACOS-MODDING-PLATFORM.md](docs/MACOS-MODDING-PLATFORM.md).

## Compatibility and caveats

- Steam version only right now. The offsets come from the Steam macOS build; the GOG build differs, so it is not supported yet. GOG support is in progress.
- Built against v2.3.1. Game updates can move offsets and break it. Releases are tagged per supported game version.
- Single-player only. Modding can corrupt saves, so keep backups.
- Install re-signs the game binary (ad-hoc) so the console can load. This is reversible at any time via Steam's "Verify Integrity of Game Files".
- macOS arm64 only.

## Support

This is free and open source. If it saved you some hassle and you want to support development, you can buy me a coffee. Completely optional, and very appreciated.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/ysrdevs)

## Credits and acknowledgements

macOS port and reverse engineering by ysrdevs (Yuvraj Singh).

This project rebuilds capability pioneered by the Windows Cyberpunk 2077 modding ecosystem. The NightCity Console runtime intentionally matches the Cyber Engine Tweaks Lua/console command surface so that CET knowledge and copy-paste item codes transfer directly.

Upstream originals, used under their respective MIT licenses (see each project's LICENSE for the exact name and year):

- RED4ext and RED4ext.SDK by WopsS (Octavian Dima). The macOS hooking framework is a port of this work.
- TweakXL, ArchiveXL, and Codeware by psiberx. The macOS modding integrations are ports of these projects.
- Cyber Engine Tweaks (CET) by the CET team. The console matches CET's Lua API surface.

Tools and libraries:

- Frida (runtime instrumentation and in-process script host).
- Dear ImGui by Omar Cornut (overlay UI).
- Ghidra (reverse engineering and decompilation).
- redscript by jac3km4.
- Vendored libraries: nameof and semver by Neargye, PEGTL by taocpp, WIL by Microsoft, spdlog by gabime, fmt by fmtlib, simdjson, toml11, and fishhook.

See [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for component roles and license details.

Cyberpunk 2077 is a trademark of CD PROJEKT S.A. This is an unofficial, non-commercial, single-player tool and is not affiliated with or endorsed by CD PROJEKT RED.

## License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 ysrdevs.
