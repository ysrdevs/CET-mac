# NightCity Console: how it works and how it was built

This document is the deep technical record of porting Cyber Engine Tweaks-style functionality to the native macOS (Apple Silicon) build of Cyberpunk 2077, and of the reverse engineering that made it possible. It covers injection, RTTI resolution, the engine calling convention, the Metal overlay, the launcher, and the concrete findings (addresses, struct layouts, bugs found and fixed) that this component depends on.

Everything here targets the macOS (Apple Silicon) Steam build of Cyberpunk 2077 v2.3.1. Offsets and hashes are specific to that build.

## 1. The problem

Cyber Engine Tweaks (CET) is the standard cheat/scripting console for Cyberpunk 2077 on Windows. It relies on D3D12 and Windows-specific hooking, so it does not exist on macOS, and neither does any equivalent. NightCity Console rebuilds the core of that capability from scratch on Apple Silicon:

- Inject code into the running game process without disabling System Integrity Protection.
- Resolve the engine's runtime type system (RTTI) and call game functions with real, typed arguments.
- Draw a console on the live frame and capture keyboard/mouse input safely.

Three properties of the macOS port make this materially different from the Windows original: Apple Silicon enforces W^X (a page cannot be writable and executable at once), the Mach-O/dyld image model differs from the PE/Windows loader, and the engine's macOS build was compiled with a different ABI in several places (CName passed by value, some constructors inlined, GS-segment TLS unavailable). Each of these forced a specific solution documented below.

## 2. Injection

The shipped game binary has the hardened runtime enabled but ships the entitlements `com.apple.security.cs.allow-dyld-environment-variables` and `disable-library-validation`. That combination means `DYLD_INSERT_LIBRARIES` works with SIP left on, and any validly-signed dylib (ad-hoc is fine) loads into the process. No SIP changes, no patching the executable's load commands at install time.

Three dylibs are injected:

- `RED4ext.dylib` (macOS port): a REDengine hooking framework. It also loads the Frida gadget.
- `FridaGadget.dylib`: an in-process Frida runtime. Its config (`FridaGadget.config`) auto-loads `red4ext_hooks.js` on startup.
- `libcyberconsole_overlay.dylib`: the native Metal/ImGui overlay (section 7).

Plus `DYLD_FORCE_FLAT_NAMESPACE=1` and `SteamAppId=1091500` so the Steam API initializes.

W^X is the reason for the Frida gadget rather than classic inline hooking. On Apple Silicon, direct binary patching in the style of Detours fails because code pages are not writable. Frida uses `MAP_JIT` memory and JIT trampolines (toggling write permission with `pthread_jit_write_protect_np`), which is the only W^X-safe way to install inline hooks on this platform. This is also why the game must be re-signed with `allow-jit` and `allow-unsigned-executable-memory` (section 8): without those entitlements, AMFI kills the process the instant the JIT engine produces code.

The command engine lives entirely in `red4ext_hooks.js`. The overlay is a separate native dylib. They are decoupled and talk through two files in `/tmp` (section 6).

## 3. Finding offsets (the reverse engineering)

The macOS build ships a rich symbol table: `nm` yields roughly 68,000 symbols with addresses. Runtime address resolution is:

```text
runtime_addr = symbol_vaddr - 0x100000000 + module_base
```

where `module_base` is the load address of the `Cyberpunk2077` executable image. The vendored `cyberpunk2077_addresses.json` from earlier port attempts is stale/wrong for 2.3.1, so every offset was re-derived from the binary's own symbols plus disassembly in Ghidra (headless analysis with custom DecompFunc/Disasm/XrefData scripts) and radare2.

### The dyld image-index bug

The single most damaging early bug, which cascaded across every other port in this ecosystem, was image-base resolution. Earlier attempts computed `module_base` with `_dyld_get_image_header(0)`. Under `DYLD_INSERT_LIBRARIES` injection, image index 0 is not the game executable; it is the host/injected image. The game executable sits at a higher dyld image index (around 3 under injection). Using index 0 produced a base that was off by the slide between images (on the order of gigabytes), so every derived address was wrong and the process crashed immediately.

The fix is to enumerate `_dyld_image_count()` and `_dyld_get_image_header()`, find the `mach_header_64` whose `filetype == MH_EXECUTE` (the game executable), and cache that base once. All address math derives from that value.

### Key resolved addresses (v2.3.1)

File vaddrs are shown; runtime address = `module_base + (vaddr - 0x100000000)`. Stated as a formula:

```text
address = symbol_vaddr - 0x100000000 + module_base
```

| Symbol / purpose | Address |
|---|---|
| Universal script executor `FUN_102173120` `(func, context, frame, result, resultType)` | `0x102173120` (runtime `0x2173120`) |
| RTTI registry getter `CRTTISystem::Get` | `0x102188e8c` (runtime `0x2188e8c`) |
| Opcode handler table (script VM dispatch), `module_base +` | `0x908b798` |
| `Main` entry (used for clean-shutdown hook) | `module_base + 0x31e18` |
| Per-scope loose-archive loader `FUN_103edafcc` | `0x103edafcc` |
| ArchiveSet `Append` `FUN_103edd568` | `0x103edd568` |
| Resource depot `LoadArchives` `FUN_103edaae8` | `0x103edaae8` |
| Archive glob (`*.archive`) `FUN_103eda360` | `0x103eda360` |

Every scripted call goes through the universal script executor `FUN_102173120`.

The RTTI registry vtable exposes `GetClass` at vtbl+0x10, `GetFunction` at vtbl+0x30, and `GetEnum` at vtbl+0x18.

### Hashing

- CName is the FNV-1a 64-bit hash (FNV1a64) of the type/function name. CName is passed by value (in `x0`) on this build, which differs from the Windows SDK where it is passed by pointer; wrapper functions account for this.
- TweakDBID is `CRC32(name) | (len << 32)`.

A subtle but important distinction: RTTI method/class lookups use FNV-1a 64-bit, while TweakDB flat-key hashing uses CRC32. Conflating the two silently resolves the wrong entries.

## 4. Calling a game function

REDengine's native script handlers read their arguments from bytecode in a `CScriptStackFrame`. To call a function from outside the script VM, that frame is constructed by hand:

1. Resolve the function. `clsByName(name)` calls the registry's `GetClass`. The class's instance-function array (CClass+0x48) and static-function array (CClass+0x58) are scanned, walking up parent classes, matching the short-name CName at function+0x10. This yields a `CClassFunction*`, its return type, and whether it is static.
2. Marshal each argument by the function's declared parameter type. For each argument, a synthetic `CProperty` is allocated (type at +0x00, valueOffset at +0x20), the encoded value is written into a locals buffer at that offset, and a `LocalVar` opcode (0x18) referencing the property is emitted, ending with `ParamEnd` (0x26). Supported types: Int32/Uint32/Int64/Float/Bool, CName (FNV-1a 64), TweakDBID, gameItemID, enums (resolved by member name against the enum value list, or by literal integer), object handles (`@player`/`@self`/`@<ptr>` written as `{instance, refCount}`), and raw struct passthrough.
3. Invoke `FUN_102173120(func, context, frame, &result, returnType)` (the universal script executor) and read the result.

Two failure modes were learned the hard way:

- You must supply exactly the number of parameters the function declares (or stop only at a genuinely optional trailing param). Under-supplying makes the handler read `ParamEnd` as a value opcode and crash. NightCity Console logs each function's live signature so commands are built against the real shape.
- Items must be built with `ItemID.FromTDBID(TweakDBID)` to produce a proper `gameItemID` (correct rngSeed and structure). Hand-built IDs validate but never commit, so `FromTDBID` is mandatory.

The opcode handler table is a DATA-section table (`module_base + 0x908b798`), indexed at runtime by the frame's current code byte. It is a table of function pointers, not code, so it must be dereferenced rather than called directly. This matters when decoding typed arguments out of raw stack frames in observe-style hooks.

## 5. Getting live engine systems

Two mechanisms, both reached from the live `GameInstance` (obtained via `PlayerPuppet.GetGame()`):

- Scriptable systems (e.g. `PlayerDevelopmentSystem`): `GameInstance.GetScriptableSystemsContainer(gi)` (a static method on `ScriptGameInstance`) returns a container, then `container.Get(CName)` returns the instance.
- Other engine facilities (godmode, teleportation, player system) are not in that container. They come from static getters on `GameInstance`, e.g. `GetGodModeSystem(gi)`, `GetTeleportationFacility(gi)`, `GetPlayerSystem(gi)`. The helper `getViaGetter(gi, "GetXxx")` resolves the static getter and calls it with the 8-byte GameInstance pointer.

The player handle is subtle. The Frida hook captures any object whose vtable matches `PlayerPuppet`, but some of those are transient/preview puppets. Resolving the player deterministically via `PlayerSystem.GetLocalPlayerControlledGameObject()` (class `cpPlayerSystem`) fixed intermittent failures in commands that depend on the correct owner (item give, heal, and so on).

## 6. The command engine and channel

`red4ext_hooks.js` polls `/tmp/cp2077_cmd.txt` about twice a second. A command is queued and executed on the game thread at a clean point: when the script executor's call depth returns to zero, so the call is not nested inside another scripted call. Output is appended to `/tmp/cp2077_out.txt`. This file channel is the only coupling between the command engine and the overlay, which keeps the two completely independent.

Commands are simple verbs (`give`, `money`, `perks`, `level`, `heal`, `teleport`, `setfact`, `call`, and so on). A small translator also recognizes the most common CET copy-paste line, `Game.AddToInventory("Items.X", n)`, and routes it through the same path, so item codes from the internet work unchanged.

## 7. The in-game overlay (Metal + ImGui)

The Frida gadget here has no Objective-C bridge and no `Module.findExportByName`, so the overlay is a separate native dylib that uses the Objective-C runtime directly via method swizzling.

Render path:

- At load (deferred a few seconds so Metal is ready) the concrete command-buffer class is found at runtime (`object_getClass` on a command buffer from a throwaway queue; on Apple GPUs this is an `AGXG<n>FamilyCommandBuffer`, where `<n>` varies by chip family) and `presentDrawable:` is swizzled. Because the present selector exists in several variants on different hardware (`presentDrawable:`, `presentDrawable:atTime:`, `presentDrawable:afterMinimumDuration:`), all variants are hooked, with nesting depth tracked so ImGui renders exactly once per frame on the outermost call.
- In the hook, before calling the original, a render pass is built on the drawable's texture with `loadAction = Load` (preserving the game's frame), and Dear ImGui is drawn into the same command buffer so it composites on top, then the present proceeds. The layer reports `framebufferOnly = 0`, so the drawable texture is freely usable and no layer recreation is needed. Pixel format is RGBA8Unorm.

Input path (the tricky part, and the reason ImGui correctness held up):

- Events arrive on the main thread; ImGui runs on the render thread; ImGui is not thread safe. So `-[NSApplication sendEvent:]` is swizzled, keyboard/mouse data is extracted into a mutex-guarded queue, and that queue is drained on the render thread just before `ImGui::NewFrame`. All ImGui calls stay on one thread.
- The backtick/tilde key (and F1) toggles the console. While open, input is swallowed so the game does not also react. Clipboard is wired to `NSPasteboard` with `ConfigMacOSXBehaviors`, so Cmd+V/C/X/A work.

The overlay also hosts a declarative JSON tab engine (`overlay/tabs/`) with mtime-based hot-reload, so new tabs and content can ship without rebuilding the dylib.

## 8. The launcher app, Steam Cloud, and clean shutdown

The launcher (`launcher/`) is a small SwiftUI app. Install copies the payload into `<game>/red4ext/` and strips the `com.apple.quarantine` attribute from the files it writes. This is the key macOS trick: files written by a locally-running app are not quarantined, so dyld will load them. Play sets the injection environment and launches the game binary directly. It also re-signs the game binary ad-hoc with the `allow-jit` and `allow-unsigned-executable-memory` entitlements (required for the Frida JIT engine under W^X, section 2), dropping CDPR's identity while preserving the `cs.*` relaxations needed to satisfy AMFI. SIP and Gatekeeper remain enabled.

Two macOS-specific findings shaped the launcher:

- Steam launch options do not work for injection on macOS. Steam launches Mac games through LaunchServices (`open`), not by `exec`, so the Linux-style `"wrapper.sh" %command%` trick fails. Direct launch is the working path.
- The game crashes on exit when hooks are attached: a SIGSEGV in the engine's own teardown calling a stale hook/trampoline, after the save is flushed but before libc `exit()`. Replacing `exit()` with `_exit()` is too late. The fix is to hook `Main`'s return (the game is quitting, the save is done) and call `_exit(0)` immediately, so the crashing teardown never runs. This also fixed Steam Cloud: launching directly still registers the session with the Steam client, but the crash-on-exit was aborting Steam's post-session cloud upload; a clean exit lets it complete.

## 9. Loose-archive mods and the resource depot

Loose `.archive` mods load natively on macOS by integrating with the engine's resource depot. The path token differs from Windows: the engine scans `archive/Mac/mod/` (macOS) rather than `archive/pc/mod/` (Windows). A new Mod-scope archive group is registered and the engine's loader pulls `*.archive` files from it. The Mods tab in the overlay enumerates this directory and toggles mods by renaming `.archive` to `.archive.off`.

The load path is driven by a small set of engine functions, re-derived for this build:

| Purpose | Symbol | Address |
|---|---|---|
| Per-scope loose-archive loader | `FUN_103edafcc` | `0x103edafcc` |
| Append an archive to an `ArchiveSet` | `FUN_103edd568` | `0x103edd568` |
| Load archives into the depot | `FUN_103edaae8` | `0x103edaae8` |
| Glob the directory for `*.archive` | `FUN_103eda360` | `0x103eda360` |

The per-scope loader (`FUN_103edafcc`) walks an `ArchiveSet` (entry stride `0x38`, `basePath` at `+0x10`, `scope` at `+0x30`), globs each scope's directory with `FUN_103eda360` using the scope prefix plus `*.archive`, calls `Append` (`FUN_103edd568`) for each file found, and `LoadArchives` (`FUN_103edaae8`) brings them into the depot.

These struct layouts were re-derived for the ARM64 build (verified by raw memory reads against the live engine, not assumed from the Windows SDK):

`ResourceDepot` (total 0x58, larger layouts observed up to 0x80 depending on build view):

| Field | Offset |
|---|---|
| `groups` (DynArray of ArchiveGroup) | `+0x10` |
| `rootPath` (CString) | `+0x30` |
| `hasModArchives` (bool) | `+0x50` |

`ArchiveGroup` (stride 0x38):

| Field | Offset |
|---|---|
| `archives` (DynArray) | `+0x00` |
| `basePath` (CString) | `+0x10` |
| `scope` (u32) | `+0x30` |

`ArchiveScope` enum values: Content=1, DLC=2, Patch=3, Mod=4. A new Mod-scope group is inserted before the first non-Mod group so the base archives stay in place but mod content overlays them.

Load order on macOS is ASCII-alphabetical by filename with first-loaded-wins per-file conflict resolution. There is no `modlist.txt` priority file; ordering is controlled by filename prefix. This is the opposite resolution direction from Windows.

## 10. Findings reused from the wider macOS modding port

NightCity Console shares an address library and SDK with the macOS TweakXL and ArchiveXL ports. Several findings from that work are load-bearing here and are recorded for contributors.

### CString memory layout (macOS ARM64)

The engine's own CString constructor/copy/destructor are not address-mapped on this build (they exist only as relocation targets in the Windows SDK, which resolve to 0 and null-deref on macOS). CString is therefore implemented natively: 24 bytes total, small-string inline buffer for lengths under 0x14 (20) bytes, otherwise a `malloc`'d heap buffer with the heap flag `0x40000000` set in the length field. This was the root cause of crashes on any String/CString flat override before the native implementation was added.

### TweakDB flat-generation cache invalidation

Custom/cloned TweakDB records initially spawned with blank display names. The item display reads a cached descriptor at `record+0x60`, which is rebuilt only when the record's cached generation differs from the global TweakDB generation byte at offset `0x160`. An earlier code path zeroed `0x160` before cloning, so cached-gen 0 equalled global 0 forever and the cache never rebuilt. The fix is to increment the `unk160` generation byte after committing the batch, forcing a re-resolve on the next lookup. Live flats are indexed at TweakDB offset `0x40`.

### CClass::CreateInstance is inlined

A discrete `CClass::CreateInstance(size, zero)` function does not exist in this binary; it was inlined into every caller (a full `__TEXT` scan found zero matches). Instance creation uses a vtable substitute: `AllocMemory` at vtable+0xF0 and `ConstructCls` at vtable+0xE0. The +0x08 shift relative to the Windows SDK is the Itanium ABI destructor-slot insertion.

### TLS without the GS segment

Windows reads thread-local game state via `__readgsqword(0x58)`. macOS has no GS segment for this, so the SDK uses a pthread-based static `g_gameTLS` pointer initialized by a runtime hook (`Detail::SetGameTLS`) called from the game bootstrap. The relevant pointer sits 0x30 bytes into the TLS structure.

### Earlier TweakDB hook mis-targeting

A prior fork hardcoded TweakDB offsets (`0x2b79ac0`, `0x2b7be94`, `0x2b7bab0`) that were valid functions but never called at boot. They had been matched via string-xref to editor/config init functions rather than the retail boot loader, which has no string markers (it runs on dispatcher worker threads). The correct initialization target was found by dynamic differential tracing: retargeting to `StatsDataSystem::InitializeRecords`, which reliably fires after the TweakDB is loaded.

## 11. Known limits and where to contribute

- Godmode registers with the engine godmode system (`HasGodMode` returns true), but on 2.3.1 the damage pipeline still applies hit damage. It prevents death, not damage. A true zero-damage mode would need a per-tick health stat-pool refill.
- Teleport is blocked by the game during active combat. Bookmarks are session-only.
- Not yet implemented: real vehicle summon (needs the garage vehicle id, not just `ToggleSummonMode`), equip-to-slot (needs `EquipmentSystemPlayerData`), and NPC/vehicle spawning.
- Offsets are tied to game v2.3.1. A game update will likely require re-deriving them.

The signatures needed for the unfinished features were already captured by the `convdump` diagnostic and are documented in the command engine, so they are a reasonable starting point for contributions.

## 12. Build and packaging

- `overlay/build.sh` clones Dear ImGui (pinned) and compiles `libcyberconsole_overlay.dylib`.
- `tools/fetch-deps.sh` puts `RED4ext.dylib` and `FridaGadget.dylib` into `deps/` (copied from a local game install if present). These large binaries are never committed.
- `launcher/build-app.sh` compiles the SwiftUI app with `swiftc`, assembles the `.app` bundle, copies the payload into `Contents/Resources`, and ad-hoc signs it for local testing.
- `dev/launch.sh` builds the overlay, stages the payload into a running game copy, and launches it with injection (honoring `CP2077_DIR` for non-default Steam paths).
- `tools/sign-notarize.sh` re-signs everything inside-out with a Developer ID and hardened runtime, notarizes the app and the dmg with `notarytool`, staples the tickets, and produces `dist/NightCity-Console-for-Mac.dmg` that passes Gatekeeper with no warnings. Run with your own Apple Developer ID.
