# The macOS Cyberpunk 2077 Modding Platform

This document is the definitive technical record of how Cyberpunk 2077 modding was brought to macOS on Apple Silicon, end to end. It covers every component that was ported or built, the reverse engineering that made each one possible, the specific addresses and struct offsets that were re-derived for the v2.3.1 ARM64 Steam binary, and the methodology that tied the work together.

The Windows modding ecosystem for Cyberpunk 2077 is mature: RED4ext loads native plugins, RED4ext.SDK gives those plugins typed access to the engine, TweakXL edits the game database at runtime, ArchiveXL loads custom resources, and Cyber Engine Tweaks exposes a scripting console. None of it ran on the Mac. The macOS build is a different binary (Mach-O, ARM64, no Windows GS-segment TLS, no `VirtualAlloc`, no Detours-style inline patching under W^X), and the entire address library is different. This platform reconstructs that ecosystem natively for the macOS build.

## Overview and mission

The mission was to take a Windows-only modding stack and make it run natively on the macOS Apple Silicon build of Cyberpunk 2077 (v2.3.1, Steam), with SIP and Gatekeeper left enabled, no kernel extensions, and no permanent modification of the game. The deliverable is a working platform a one or two person team can maintain:

- C++ plugin development against the engine (RED4ext loader plus RED4ext.SDK).
- Runtime TweakDB editing for custom items, stats, and economy (TweakXL).
- Custom resource and loose-archive loading (ArchiveXL, with Codeware as a companion).
- An in-game scripting console and item browser with a Metal overlay (NightCity Console), whose runtime mirrors CET's API surface.

Everything is built on three pillars: a Frida-based injection and hooking substrate that is W^X safe on ARM64, a re-derived address library for the v2.3.1 Mach-O binary, and a platform abstraction layer that maps Windows engine assumptions onto macOS primitives without changing the public APIs that mods compile against.

## Component map

The platform is a layered stack. Each layer depends on the ones below it.

| Layer | Component | Role |
| --- | --- | --- |
| Injection / hooking | RED4ext (macOS port) + Frida Gadget | Loads into the game, installs hooks, loads `.dylib` plugins |
| Plugin SDK | RED4ext.SDK (macOS port) | RTTI, scripting, memory, resource, TweakDB bindings for plugins |
| Game database | TweakXL (macOS port) | Runtime TweakDB record cloning and flat overrides |
| Resources | ArchiveXL (macOS port) + Codeware | Loose `.archive` loading, localization, custom resources |
| Console / overlay | NightCity Console runtime + Metal/ImGui overlay | CET-style commands, RTTI bridge from JavaScript, in-game UI |

Runtime wiring: `DYLD_INSERT_LIBRARIES` loads `RED4ext.dylib`, `FridaGadget.dylib`, and the overlay dylib into the game. Frida Gadget auto-loads `red4ext_hooks.js`, which installs the engine hooks via JIT trampolines. RED4ext loads the `.dylib` plugins (TweakXL, ArchiveXL, Codeware). All addresses resolve relative to the game executable's Mach-O image base.

## RED4ext (macOS loader)

### What it is

RED4ext is the script extender for REDengine 4. The original Windows project is by WopsS (Octavian Dima), MIT licensed, copyright 2020 to present. The macOS port is the Apple Silicon implementation of that framework: it provides the `.dylib` plugin system, address resolution, and the function hooks that the rest of the stack relies on.

### Porting and reverse engineering

The central problem on ARM64 macOS is that you cannot patch code the way Detours does on Windows. Apple Silicon enforces W^X (write-xor-execute) on executable pages, so the loader uses Frida Gadget rather than direct binary patching. Frida allocates `MAP_JIT` memory, toggles write permission with `pthread_jit_write_protect_np`, and builds JIT trampolines for each hook. This approach is architecture agnostic, which is why it replaced the Windows Detours path entirely on macOS.

Hooks are defined in `red4ext_hooks.js` and installed through the Frida `Interceptor` API as `Interceptor.attach(moduleBase.add(offset), { onEnter, onLeave })`, with the offsets fixed per v2.3.1. Nine engine hooks are active:

- `Main` (entry point at offset `0x31E18` from image base)
- `CGameApplication::AddState`
- `Global::ExecuteProcess`
- `CBaseEngine::InitScripts`
- `CBaseEngine::LoadScripts`
- `ScriptValidator::Validate`
- `AssertionFailed`
- `GameInstance::CollectSaveableSystems`
- `GsmState_SessionActive::ReportErrorCode`

Address resolution is dual mode. `Addresses::Resolve(hash)` first tries `dlsym(RTLD_DEFAULT, symbolName)` for exported symbols, then falls back to an offset database for everything that is not exported. The symbol mapping holds 21,332 symbols (`cyberpunk2077_symbols.json`); the offset database (`cyberpunk2077_addresses.json`) carries the function offsets, and all 126 SDK addresses resolve through this combined scheme. `LoadSections()` records the code, data, and rdata section offsets so the resolver can place addresses correctly.

The macOS platform layer (`src/dll/Platform/MacOS.cpp`) implements memory protection via `vm_protect`/`mach_vm_protect`, module handling via `dlopen`/`dlsym`, and Mach-O symbol rebinding via Facebook's fishhook for the `Platform::GetProcAddress` fallback. The Frida integration lives in `src/dll/Platform/Hooking.cpp` (with a native ARM64 trampoline fallback path kept for completeness).

Code signing and injection: the game binary is ad-hoc resigned, the injection happens via `LC_LOAD_DYLIB` so the executable's logic is never patched, and SIP stays on. The hooks attach early, with Frida Gadget coming up before RED4ext init so the `Main` hook can fire.

### Key discoveries

- Frida Gadget is mandatory for W^X compliance on ARM64; direct code patching fails. `MAP_JIT` plus `pthread_jit_write_protect_np` is the only reliable inline-hook path.
- The game executable is at dyld image index 3 under `DYLD_INSERT_LIBRARIES` injection, not index 0. Index 0 is the host process. This single fact, computed wrong, poisons every derived address (see the cross-cutting methodology section).
- Loose `.archive` mods load from `archive/Mac/mod/` with first-wins ASCII-alphabetical order by filename. The Windows `pc` path token becomes `Mac`. There is no `modlist.txt` ordering on macOS.
- For non-exported functions such as the TweakDB loaders, offsets are sourced from pattern matching plus Ghidra RE and stored in the addresses database, because no exported symbol exists to `dlsym`.

### Native Mods tab

The loader also surfaces a Mods tab inside the NightCity Console overlay that enables and disables loose mods by renaming `.archive` to `.archive.off` and back, giving the Mac the equivalent of Windows loose-mod folders without deleting files.

## RED4ext.SDK (macOS port)

### What it is

RED4ext.SDK is the C++ plugin SDK: RTTI bindings, scripting system access, memory and job-queue primitives, resource loading, and TweakDB interaction. The Windows original is again by WopsS, MIT licensed. The macOS port (v0.5.0) keeps the public API identical so a plugin compiles the same on Windows and macOS, while a platform abstraction layer maps the Windows assumptions onto macOS underneath. It spans 48 C++ implementation files and 102 headers (about 10,261 lines including inline implementations).

### Porting and reverse engineering

The compatibility layer is `include/RED4ext/Detail/WinCompat.hpp`, 145 lines of Windows API equivalents:

- Interlocked operations map to `__atomic_*` builtins.
- `GetModuleHandle` uses `dlopen`/dyld via `dlfcn.h`; `HMODULE` becomes `void*`.
- `VirtualAlloc` uses `mmap`.
- `CRITICAL_SECTION` becomes a `pthread_mutex_t` (64 bytes).
- Aligned allocation uses `posix_memalign`.
- Spinlocks and mutexes use atomic intrinsics and pthread primitives instead of `CRITICAL_SECTION`.

Headers guard Windows code with `#if defined(_WIN32) || defined(_WIN64)` and select the macOS path under `#else`, defining `RED4EXT_PLATFORM_MACOS`.

Thread-local storage is the subtle part. Windows reads the game TLS through the GS segment with `__readgsqword(0x58)`, which does not exist on macOS. The port replaces this with a pthread-based thread-local `g_gameTLS` pointer (the relevant field sits `0x30` into the TLS structure), and a runtime hook `Detail::SetGameTLS` initializes it during game bootstrap. This is in `include/RED4ext/TLS-inl.hpp`.

Address resolution uses templates in `Relocation-inl.hpp`. `RelocFunc` and `RelocPtr` add `GetImageBase()` (obtained from `_dyld_get_image_header`) to the hardcoded file offsets in `cyberpunk2077_addresses.json` (126 offsets). `UniversalRelocPtr` delegates to `UniversalRelocBase::Resolve`, which queries RED4ext.dylib's exported `RED4ext_ResolveAddress`. The image base for offsets is `0x100000000` plus the file vaddr; `_dyld_get_image_header` returns an ARM64 `mach_header_64` pointer.

A native macOS `CString` implementation matters because the engine's own `CString` constructors are unmapped on this binary. Short strings (under `0x14` bytes) live inline (SSO); longer strings are `malloc`'d with the `0x40000000` heap flag set in the length bits. `CName` is passed by value in `x0` (an ABI difference from Windows where it is passed by pointer).

### Key discoveries (struct layouts)

The SDK documents the ResourceDepot and archive structures that the loose-mod work depends on:

```text
ResourceDepot           total 0x58
  +0x10  groups         DynArray<ArchiveGroup>
  +0x30  rootPath       CString
  +0x50  hasModArchives bool

ArchiveGroup            total/stride 0x38
  +0x00  archives       DynArray<Archive>
  +0x10  basePath       CString
  +0x30  scope          uint32 (ArchiveScope)

Archive                 total 0x50
  +0x00  instance       void*
  +0x08  asyncHandle    int32
  +0x10  path           CString
  +0x30  reserved

ArchiveScope enum: Content = 1, DLC = 2, Patch = 3, Mod = 4
```

`ResourceDepot::Get()` returns a static singleton via `UniversalRelocPtr`, and the `Mod` scope (4) is what enables loose-mod support. The TweakDB boot path, by contrast, is not marked by string xrefs (a documented dead end): identifying its load/init targets required dynamic function tracing, not static analysis.

### Building

CMake 3.21+, C++20 mandatory. Header-only or static-library modes, optional precompiled headers, platform-conditional CoreFoundation linking.

```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.ncpu)
# optional: -DRED4EXT_BUILD_EXAMPLES=ON
# optional: -DRED4EXT_HEADER_ONLY=ON
```

Five example plugins ship to demonstrate integration: `accessing_properties`, `execute_functions`, `function_registration`, `native_class_redscript`, and `native_globals_redscript`.

## TweakXL (macOS port)

### What it is

TweakXL edits TweakDB (the game's runtime database of records and flats) at load time, enabling YAML and RED tweak mods: game stats, items, vehicles, economy overrides. The Windows original is by psiberx (Pavel Siberx), MIT licensed, copyright 2021. The macOS fork targets Apple Silicon and requires the RED4ext loader and Frida Gadget. The result is verified: cloned records (for example, an item based on `Items.Preset_Lexington_Default`) spawn as real, functional, lootable, equippable in-game items with the correct name, rarity, category, and price.

### Porting and reverse engineering

The initialization pipeline had to be retargeted. The original fork hooked TweakDB load functions that turned out to be the wrong ones on the retail Mac build. The Mac port instead drives initialization from `StatsDataSystem::InitializeRecords`, the one engine hook confirmed to fire reliably after TweakDB loads on the 2.3.1 macOS build. `TweakService::OnBootstrap` installs that hook; when it fires, `EnsureInitialized()` constructs the `TweakDBManager`, `TweakImporter`, and `TweakExecutor` for the first time.

Tweak loading: `TweakImporter` reads `.yaml` from `<game>/r6/tweaks/`, parses through the YAML and RED parsers, and `TweakDBManager::CommitBatch` writes flats into TweakDB's live flat-data buffer (at offset `0x40`, stride indexed), then bumps the generation counter at offset `0x160` to invalidate cached record display descriptors. All flat types work without crashes: Float, Int, TweakDBID, `gamedataLocKeyWrapper`, String, and CString.

Several engine subsystems are unmapped on macOS and were worked around rather than mapped:

- FlatValue allocation uses `posix_memalign` plus `memcpy` because the engine memory allocators are unmapped.
- The job system is unmapped, so `TweakChangeset::StartAsyncCommitJob` runs `CommitBatch` inline (synchronously) instead of queueing to the engine dispatcher.
- `UpdateRecord`, `CreateTweakDBID`, and `CheckForIssues` are skipped: not address-mapped or ABI-incompatible, and core functionality does not need them (record clones inherit base flats, and `give` hashes names directly).

Hook attachment uses the SDK's platform-agnostic `HookAfter`/`HookBefore` (Frida on macOS), and `Core::RawFunc` resolves a function address from its hash via `TweakXLAddressResolver`. Both the SDK's `UniversalRelocFunc` and TweakXL's resolver maintain an identical 11-entry offset table relative to the `__TEXT` base `0x100000000`.

### Key discoveries

The two hardest bugs were both about cache invalidation and memory layout:

- Blank item names. The TweakDB record's flat-descriptor cache (at record `+0x60`) is rebuilt only when its cached generation differs from the global TweakDB generation byte at `0x160`. `EnsureRuntimeAccess` was setting `0x160` to 0 before cloning, so the cache generation `0 == 0` forever and never re-resolved, leaving blank names. The fix is to increment the `unk160` generation byte after `CommitBatch`.
- String-flat crashes. The engine's `CString` constructor, copy, and destructor are unmapped on macOS; the SDK's `UniversalRelocFunc` was null-dereferencing on them. Implementing the macOS `CString` layout natively (inline for short, `malloc`'d heap with the `0x40000000` flag in the length bits for long) fixed it.

Other re-derived addresses: `CreateRecord` via a 32-case type factory (`0x26B8DB8`), the CRC32 `Derive` for TweakDBID (`0x3453B14`), and generic array growth via a per-type move-callback (`DynArray_Realloc`). The earlier fork's TweakDB hook offsets (`0x2B79AC0`, `0x2B7BE94`, `0x2B7BAB0`) were valid functions found via string-xref to editor/config init, but never on the retail boot path; the corrected target is `StatsDataSystem::InitializeRecords` (`0x3A939B8`). `CNamePool::Get` takes the hash by value in `x0` and returns the interned pointer at `+0x14`.

### Building

```bash
brew install spdlog yaml-cpp
git clone --recursive <tweakxl-macos repo>
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.ncpu)
codesign -s - -f TweakXL.dylib
cp TweakXL.dylib "<game>/red4ext/plugins/TweakXL/"
# also copy Data/ and Scripts/
```

## ArchiveXL (macOS port) with Codeware

### What it is

ArchiveXL is psiberx's custom resource loader: loose archives, localization, appearances, and factory entries. Upstream is v1.26.1, MIT licensed, copyright 2021. Codeware is psiberx's companion library that extends Redscript and the RTTI surface; on macOS it rides the same RED4ext.SDK platform layer. The macOS port compiles to an ARM64 dylib via CMake (RTTI disabled, exceptions enabled, visibility hidden) and exports the RED4ext plugin interface (`Main`/`Query`/`Supports`).

### Porting and reverse engineering

ArchiveXL boots through a dependency-injection container (`Application.cpp`) that registers providers: `RuntimeProvider` (base image tracking), `SpdlogProvider`, `ArchiveXLAddressResolver`, `MacOSHookingProvider` (forwards `HookAttach`/`HookDetach` to the RED4ext SDK hooking interface), and `RED4extProvider`. On macOS the Windows-only MinHook and RedLib are skipped, and `ExtensionService` boots with the localization extension enabled.

The `.xl` loading lifecycle uses three engine hooks fired `HookOnceAfter`:

- `InitResourceDepot` (hash `2923109755`, offset `0x1704194`, confirmed) drives `Configure()`, which reads `.xl` YAML from the bundle directory. This function allocates the depot and initializes the singleton at app `+0x198`.
- `LoadGatheredResources` (hash `3729789488`, offset `0x3D9EFC8`, confirmed) drives `Load()`, which executes the extensions. Inner worker is `FUN_0x21B211C`.
- `LoadTweakDB` (hash `3602585178`, offset `0x2B7BE94`, reused from the TweakXL port on the same binary) drives `OnTweakDBReady()`.

The localization extension hooks `Localization::LoadTexts` (hash `3550098299`, offset `0x2F67DB4`, confirmed) with ABI `uint64(Handle<PersistenceOnScreenEntries>&, ResourcePath)`. `OnLoadTexts()` resolves the language from the `ResourcePath`, fetches custom entries from the `.xl` config, and patches the loaded text resource's map to include custom LocKey to string mappings before returning. It only adds or overrides, so base game text is untouched. `LoadSubtitles` (hash `772484645`, offset `0x2F67BE0`, confirmed) has the same shape. `LoadVoiceOvers` and `LoadLipsyncs` are unconfirmed and deliberately skipped to avoid crashes on unresolved addresses.

The custom-item-name workflow ties the whole stack together: define a `displayName` LocKey in TweakDB via TweakXL, register a `.xl` with an `onscreens` node mapping language to a custom JSON, populate that JSON with LocKey to text, and the localization extension patches the loaded text resource at hook-fire so the item display resolves live text.

Loose-archive mounting (`ArchiveService`) walks the depot groups (stride `0x38`: archives at `+0x00`, basePath at `+0x10`, scope at `+0x30`), inserts a new Mod-scope group before the first non-Mod group (a stable insertion that preserves base archives), and calls `LoadArchives` for each registered directory. `InitializeArchives` is hash `2885423437`, `LoadArchives` is hash `2517385486`. The Mac fix is to explicitly `RegisterDirectory(archive/Mac/mod)` because Windows hardcodes `archive/pc/mod` and the registry was otherwise compiled out to an empty `Bundle/` path (the boots-but-loads-nothing symptom).

Address resolution mirrors the other components: `ArchiveXLAddressResolver` keeps a hand-populated `m_addressTable` keyed by AddressLib hash, `GetImageBase()` finds the `MH_EXECUTE` dyld header (fixing the index-0 bug), and `ResolveAddress()` returns base plus offset or 0 for unknown. Setting `ARCHIVEXL_ADDR_TRACE` logs lookups to stderr.

### Key discoveries

- Extension hooks can no-fire under injection. If the dylib injects after the engine has already run `InitResourceDepot`/`LoadGatheredResources`, `HookOnceAfter` never triggers and `.xl` files never load. The workaround is a `ManualBringUp()` C export (driven from the console runtime) that calls `Configure`/`Load`/`OnDepotReady`/`OnTweakDBReady` manually post-injection, mirroring TweakXL's reload-trigger pattern.
- A loose-archive playbook (documented as `LOOSE-ARCHIVE-PLAYBOOK.md`) captures the decision tree empirically: Branch A if the engine scans `archive/Mac/mod` natively (mods sort ASCII-alphabetical, first-wins, no `modlist.txt`); Branch B otherwise, via a Frida `HookAfter InitializeArchives` that calls `LoadArchives` into a Mod-scope group, or by enabling `ArchiveService` in C++.

### Building

```bash
brew install spdlog yaml-cpp
cmake -S . -B build2 -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build build2 --target ArchiveXL -j8
codesign -s - -f --entitlements entitlements.xml build2/ArchiveXL.dylib
cp build2/ArchiveXL.dylib <game>/red4ext/plugins/ArchiveXL/ArchiveXL.dylib
cp -r bundle/*  <game>/red4ext/plugins/ArchiveXL/
cp -r scripts/* <game>/red4ext/plugins/ArchiveXL/scripts/
```

## NightCity Console (runtime and overlay)

### What it is

NightCity Console (formerly named CET Mac, renamed to avoid confusion with Cyber Engine Tweaks) is a macOS-native, ARM64 in-game console and item browser for Cyberpunk 2077 v2.3.1. It is an independent project, not affiliated with CET, WolvenKit, or CD PROJEKT RED. Its runtime deliberately matches CET's Lua API surface so that scripts and command idioms translate. MIT licensed.

It has two halves: a runtime (the command engine and RTTI bridge, `runtime/red4ext_hooks.js`, 1578 lines) and an overlay (the Metal/ImGui UI and input, `overlay/overlay.mm`, 1357 lines).

### The MINI-CET runtime

The runtime is a Frida JavaScript executor that resolves engine RTTI and calls engine functions from script, the same primitives CET exposes through Lua. The core entry points:

- `resolveFunc` walks the `CClass` vtable (instance functions at `+0x48`, static at `+0x58`) matching FNV-1a 64-bit `CName` hashes, querying the RTTI registry.
- `callFunc` marshals arguments into a synthetic `CScriptStackFrame` (opcodes `LocalVar 0x18`, `ParamEnd 0x26`) and invokes the universal script executor.
- `createInstance` allocates and constructs via the `CClass` vtable.
- `Observe` / `cmObserve` attaches to executor hooks with raw-frame and typed-argument callbacks.

RTTI bridge addresses (offsets from image base):

```text
script executor (ScriptVM)   base + 0x2173120   func(func, context, frame, result, resultType)
RTTI registry (CRTTISystem::Get)  base + 0x2188e8c   returns CRTTISystem*
opcode handler table          base + 0x6e40000   (DATA section, dereferenced not called)
Main entry                    base + 0x31e18
```

`CClass` field layout: vtable at `0x00`, parent at `0x10`, name (CName) at `0x18`, methods at `0x48`, size at `0x68`. Class lookup walks the hierarchy: `GetClass` at vtable `+0x10`, `GetEnum` at `+0x18`, `GetFunction` at `+0x30`.

Encoding rules that had to be pinned down: `CName` is FNV-1a 64-bit; `TweakDBID` is `CRC32(name) | (len << 32)`; `ItemID` derives from `TweakDBID` via `ItemID::FromTDBID` with correct rngSeed init; item quantities marshal as an 8-byte `gameItemID`.

The command engine runs decoupled from the overlay through a file channel: it polls `/tmp/cp2077_cmd.txt` at roughly 2 Hz for queued verbs, executes them on a clean game-thread point (executor call-depth zero), and writes output to `/tmp/cp2077_out.txt`. Commands include `give`, `money`, `perks`, `heal`, `teleport`, `godmode`, `invisibility`, and the rest, plus a generic `call <Class> <Method>` bridge.

A notable RE finding: `CClass::CreateInstance` is inlined on this binary. A full `__TEXT` scan (`0x6de0000` bytes) found zero matches for a discrete `CreateInstance(size, zero)` function. The substitute calls the vtable directly: `AllocMemory` at vtable `+0xF0`, `ConstructCls` at vtable `+0xE0`. The `+0x08` shift from the SDK layout is the Itanium ABI destructor-slot insertion.

### The overlay

The overlay is Dear ImGui (by Omar Cornut) composited on the live Metal frame. The present-hook swizzles `presentDrawable:` on all `MTLCommandBuffer` family variants (the per-chip `AGXG<n>FamilyCommandBuffer` classes), because the variant present on the system depends on the GPU. The render pass uses `loadAction = Load` to preserve the game frame, then composites ImGui. Input comes from an `NSApplication.sendEvent:` swizzle into a thread-locked queue drained on the render thread before `ImGui::NewFrame`, maintaining ImGui's single-threaded invariant.

Three present variants exist on different hardware (`presentDrawable:`, `presentDrawable:atTime:`, `presentDrawable:afterMinimumDuration:`); all three are hooked, with nesting depth tracked so ImGui renders only once per frame on the outermost call.

The overlay carries a declarative JSON tab engine: tabs are defined as `{ id, title, widgets[...] }` loaded from `~/Library/Application Support/NightCity Console/tabs/` with mtime polling and hot reload, so new tabs (Vehicles, World/Weather, Stat editor) ship without rebuilding. The built-in tabs are Console, Items (a 7,552-item catalog in `cet_catalog.tsv`), Quick, Creator, and Mods.

### Launcher and Steam integration

The SwiftUI launcher (`launcher/Sources/CyberConsoleApp.swift`, 408 lines) copies the payload into `<game>/red4ext/`, ad-hoc resigns the game binary with `allow-jit` and `allow-unsigned-executable-memory` entitlements (the stock Steam signature omits these, and macOS kills the game the moment the JIT engine generates code without them), and launches with `DYLD_INSERT_LIBRARIES` plus the `SteamAppId` env var. This is fully reversible via Steam's Verify Integrity of Game Files.

A Steam Cloud crash on exit had to be fixed: the game crashed with SIGSEGV in engine teardown on a stale hook trampoline after the save flush. The fix hooks the `Main` return to call `_exit(0)` immediately, bypassing teardown so the Steam post-session cloud upload completes.

### Key discoveries

- Loose `.archive` mods load natively on macOS by integrating with `ResourceDepot::InitializeArchives`, registering a Mod-scope ArchiveSet via `Append` (`FUN_103edd568`, base `+0x3edd568`, signature `(groups*, set*)`) and `LoadArchives` (`FUN_103edaae8`, base `+0x3edaae8`, signature `(depot, set, paths[], outLoaded[], prefix, prefix2)`). The glob pattern is built from `prefix + '*.archive'`. Confirmed live against engine memory: basePath at `0x10` (not `0x08`), scope at `0x30`, stride `0x38`. A texture replacer (HanakoNoMakeup) was verified loading live.
- `CStackFrame` layout for Observe callbacks: code at `0x00`, func at `0x08`, params at `0x18`, data at `0x30`, dataType at `0x38`, context (`IScriptable*`) at `0x40`, currentParam (u8) at `0x62`, useDirectData (bool) at `0x63`.
- The OpcodeHandlers table is in `__DATA` at `0x6e40000`, beyond `__TEXT`; it must be dereferenced, not called, and its sole xref is the opcode dispatcher at `0x2e36b14`.
- Method hashing is FNV-1a 64-bit; game IDs use CRC32. Distinguishing the two is essential: FNV for method hashing, CRC32 for TweakDB flat keys (`Derive` at `0x3453b14`, table at `0x106c0bc80`).

## Cross-cutting reverse-engineering methodology

The components share one toolchain and a small set of hard-won techniques. This section records the methodology that produced every address above.

### The Ghidra headless toolchain

The authoritative source of addresses, struct layouts, and xrefs is a Ghidra 12.1.2 headless analysis of the full v2.3.1 Mach-O binary (ARM64, with debug symbols). Custom Java/Python scripts drive it via a `run.sh` wrapper:

- `DecompFunc` decompiles a function at a given address.
- `Disasm` disassembles a range.
- `XrefData` resolves cross-references.

Output is emitted to a canonical `offsets.json` (the offset truth table: `script_executor`, `rtti_registry_get`, every function address, struct layouts, and macOS-specific notes). The RED4ext addresses.json shipped by the Windows project is unreliable for the Mac binary; everything is verified in Ghidra before it is trusted.

### Frida probes

Where static analysis stalls (most importantly the TweakDB boot path, which has no string markers because it runs on `redDispatcher` worker threads), the technique is dynamic. A Frida instrumentation harness installs per-function call counters, captures stack traces, and supports safe attach/detach on concurrent paths. Differential tracing (hook a set of candidates, observe which actually fire at boot, and in what order) is how the correct TweakDB init target was found after string-xref matching led to editor/config functions that never run at retail boot. A control-hook (`RegisterGameTweakDBRTTI` at `0x2b07bf4`) confirmed the boot ordering.

### The dyld image-base discovery

The single most consequential bug across the whole project: under `DYLD_INSERT_LIBRARIES` injection, `_dyld_get_image_header(0)` returns the injected dylib (or the host), not the game. The game executable is at dyld image index 3. Computing the image base from index 0 made every derived address wrong by the slide between images (on the order of gigabytes), causing immediate crashes. The fix, applied uniformly in every component's `GetImageBase()`, is to enumerate `_dyld_image_count()` and find the `mach_header` with `filetype == MH_EXECUTE`, then cache that base once. The canonical base for offset arithmetic is `0x100000000` plus the file vaddr.

### The address-library re-derivation

The entire Windows AddressLib had to be re-derived function by function for the ARM64 binary. Each component keeps a small hand-populated offset table keyed by AddressLib hash (TweakXL and ArchiveXL each maintain theirs; the SDK keeps the master 126-entry set). Reuse across components is deliberate where the same function is involved: `LoadTweakDB` at `0x2B7BE94` is shared between TweakXL and ArchiveXL because it is the same function in the same binary. The two ResourceDepot functions that the earlier fork lacked were recovered: `InitializeArchives` (`0x3ed9578`) and the `LoadArchives` candidate (`0x3edaae8`).

### ResourceDepot and loose-mod reverse engineering

The loose-mod system was reconstructed by combining static struct recovery (Ghidra) with live raw-memory dumps (via the MINI-CET `resolveFunc` and Frida cell reads) to confirm field offsets against the running engine. The ResourceDepot singleton lives at `GameApplication + 0x198`, written by `InitResourceDepot` at `0x1704194`. The depot's `groups` DynArray is at `0x10`, each ArchiveGroup is stride `0x38` with `basePath` (CString) at `0x10` and `scope` (u32) at `0x30`. Insertion is a stable operation: the Mod-scope group is placed before the first non-Mod group, so base archives stay untouched while mod archives overlay them. Load order is ASCII-alphabetical by filename, first-wins per-file conflict resolution, the opposite of the Windows last-wins convention.

### The MINI-CET reflection bridge

The reflection layer is itself a reverse-engineering instrument as well as a runtime. Because `resolveFunc`/`callFunc`/`createInstance` can call any engine function and read any struct from JavaScript at runtime, it doubles as a live probe: struct offsets were confirmed, inlined functions (like `CreateInstance`) were diagnosed, and the vtable substitute (`AllocMemory` at `+0xF0`, `ConstructCls` at `+0xE0`) was validated against the running game across more than ten game verbs before being committed. The CName-by-value ABI, the `+0x14` interned-pointer return, and the opcode table location were all confirmed this way.

## Journey: from "is this even possible" to a shipping platform

The starting question was whether macOS modding was possible at all. The Mac build is a different binary with no Windows TLS, no `VirtualAlloc`, and W^X enforcement that defeats Detours-style hooking. The Windows address library does not apply, and the one macOS fork that existed earlier was built on a wrong assumption (dyld image index 0) that made every address incorrect.

The path was, roughly:

1. Establish injection that survives SIP and Gatekeeper: `DYLD_INSERT_LIBRARIES` plus ad-hoc resigning with JIT entitlements, no kernel extension, no permanent binary patch.
2. Establish W^X-safe hooking: Frida Gadget with `MAP_JIT` and JIT trampolines instead of Detours.
3. Fix the foundational image-base bug so addresses resolve correctly (index 3, `MH_EXECUTE`).
4. Re-derive the address library in Ghidra, verifying each function rather than trusting the Windows data, and using Frida differential tracing for the functions that have no string markers.
5. Port the SDK with a platform abstraction layer (WinCompat, pthread TLS, native CString, CName by value) so plugins compile unchanged.
6. Bring up TweakXL: retarget initialization to a hook that actually fires (`StatsDataSystem::InitializeRecords`), fix the flat-generation cache invalidation and the string-flat CString crash, and verify real lootable custom items.
7. Bring up ArchiveXL and Codeware: confirm the localization and depot hooks, wire `RegisterDirectory(archive/Mac/mod)`, and reconstruct the loose-archive mount path.
8. Build NightCity Console: the MINI-CET RTTI bridge, the Metal/ImGui overlay with multi-variant present hooks, the declarative tab engine, the launcher, and the Steam Cloud exit fix.

The outcome is a working, shippable platform: native C++ plugins, runtime TweakDB custom items proven in-game, loose `.archive` loading proven in-game, and an in-game console and item browser, all on Apple Silicon with SIP enabled and nothing permanent done to the game.

## Credits and acknowledgements

Author, macOS port and reverse engineering: ysrdevs (Yuvraj Singh).

Upstream originals (MIT licensed; see each project's LICENSE for the exact name and year):

- RED4ext and RED4ext.SDK by WopsS (Octavian Dima), copyright 2020 to present.
- TweakXL, ArchiveXL, and Codeware by psiberx (Pavel Siberx), copyright 2021.
- Cyber Engine Tweaks (CET) by the CET team. The NightCity Console runtime matches CET's Lua API surface.
- Cyberpunk 2077 by CD PROJEKT RED (the target binary).

Tools and libraries:

- Frida, for runtime instrumentation and W^X-safe hooking.
- Dear ImGui by Omar Cornut, for the overlay UI.
- Ghidra, for reverse engineering and decompilation.
- redscript by jac3km4.
- Vendored libraries: nameof and semver by Neargye, PEGTL by taocpp, WIL by Microsoft, spdlog by gabime, fmt by fmtlib, simdjson, toml11, and fishhook.

This is an independent project for single-player, personal use on a legally owned copy of the game. It is not affiliated with Cyber Engine Tweaks, WolvenKit, REDmod, or CD PROJEKT RED.
