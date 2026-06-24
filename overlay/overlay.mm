// CP2077 macOS overlay - Phase 2 complete: Dear ImGui in-game console with input.
//   * Renders an ImGui console onto the live game frame via a -[<cmdbuf> presentDrawable:] swizzle.
//   * Captures input via a -[NSApplication sendEvent:] swizzle (main thread) into a locked queue,
//     drained on the render thread so ALL ImGui calls stay single-threaded.
//   * Toggle with the backtick/tilde (`) key or F1. When open, input is swallowed from the game.
//   * Submitting a line writes it to /tmp/cp2077_cmd.txt (the existing Frida command channel);
//     the console tails /tmp/cp2077_out.txt for results. Fully decoupled from the Frida executor.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <string>
#include <vector>
#include <deque>
#include <mutex>
#include <atomic>
#include <thread>
#include <unistd.h>
#include <set>
#include <vector>
#include <unordered_map>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <cctype>
#include "imgui.h"
#include "backends/imgui_impl_metal.h"

// ---- logging ----
static void olog(const char* fmt, ...) {
    char buf[600]; va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
    FILE* f = fopen("/tmp/cp2077_overlay.log", "a"); if (f) { fprintf(f, "%s\n", buf); fclose(f); }
    fprintf(stderr, "[OVERLAY] %s\n", buf);
}

// ---- state ----
// presentDrawable: is implemented per-GPU-family command-buffer class (AGXG13X/G14/G15/G16F/...). The class
// the game uses varies by chip, so we swizzle EVERY command-buffer class that has the method and keep each
// one's original IMP keyed by its Method, looked up by the live buffer's class at call time.
static std::unordered_map<void*, IMP> g_origPresents;   // Method* -> original presentDrawable IMP
static SEL g_presentSel = NULL;
static IMP g_origSendEvent = NULL;
static bool g_imguiInit = false;
static unsigned long g_frame = 0;
static std::atomic<bool> g_show{false};
static std::atomic<bool> g_focusInput{false};
static std::atomic<int>  g_activeTab{0};        // 0 Console, 1 Items, 2 Quick
static std::atomic<bool> g_tabReq{false};       // a keyboard tab-switch was requested
static std::atomic<bool> g_itemsTabEntered{false};
static std::atomic<bool> g_pinTopReq{false};    // Cmd+P pins the current top search result
static std::vector<std::string> g_lines;
static char g_input[512] = {0};
static std::vector<std::string> g_history;   // submitted commands (oldest first)
static int g_historyPos = -1;                // -1 = current edit line; else index into g_history
static const char* OUT_PATH = "/tmp/cp2077_out.txt";
static const char* CMD_PATH = "/tmp/cp2077_cmd.txt";

// ---- bisection kill-switch (NCC_MODE env): full = hook + render (default),
// passthru = hook present but never render, off = don't swizzle present at all.
// Lets a tester localize stutter in-game without rebuilding. ----
enum NccMode { NCC_FULL = 0, NCC_PASSTHRU = 1, NCC_OFF = 2 };
static NccMode g_mode = NCC_FULL;
static const char* modeName() { return g_mode == NCC_OFF ? "off" : g_mode == NCC_PASSTHRU ? "passthru" : "full"; }
static void readMode() {
    char buf[32] = {0};
    const char* m = getenv("NCC_MODE");                 // 1) env var (terminal/dev launch)
    if (!m) {                                            // 2) else ~/nightcity_mode.txt (for the .app)
        const char* home = getenv("HOME");
        if (home) {
            char path[1024]; snprintf(path, sizeof(path), "%s/nightcity_mode.txt", home);
            FILE* f = fopen(path, "r");
            if (f) { if (fgets(buf, sizeof(buf), f)) m = buf; fclose(f); }
        }
    }
    if (!m) return;
    if (!strncmp(m, "off", 3)) g_mode = NCC_OFF;
    else if (!strncmp(m, "passthru", 8)) g_mode = NCC_PASSTHRU;
    else g_mode = NCC_FULL;
}

// ---- frame-time instrumentation: measure the game's real per-frame cadence at nextDrawable
// (called once per frame regardless of how it presents, so it works in every mode). Logs avg +
// worst-case present interval every 120 frames so we get milliseconds instead of "feels stuttery". ----
static double g_lastFrameT = 0.0, g_ftSum = 0.0, g_ftMax = 0.0; static int g_ftCount = 0;
static void frameTick() {
    double now = CACurrentMediaTime();
    if (g_lastFrameT > 0.0) {
        double dt = (now - g_lastFrameT) * 1000.0;   // ms
        g_ftSum += dt; if (dt > g_ftMax) g_ftMax = dt; g_ftCount++;
        if (g_ftCount >= 120) {
            olog("frametime: avg=%.2fms max=%.2fms over %d frames (mode=%s console=%s)",
                 g_ftSum / g_ftCount, g_ftMax, g_ftCount, modeName(), g_show.load() ? "open" : "closed");
            g_ftSum = 0.0; g_ftMax = 0.0; g_ftCount = 0;
        }
    }
    g_lastFrameT = now;
}

// ---- input event queue (main thread -> render thread) ----
struct InEvent { int type; int code; bool down; unsigned ch; float x; float y; };
static std::deque<InEvent> g_queue;
static std::mutex g_qmtx;

// ---- virtual mouse cursor (delta-accumulated; render-thread owned) ----
// The game associates the OS cursor off and hides it during gameplay, so absolute window coords are
// frozen. We accumulate raw mouse deltas into our own cursor position (framebuffer px) and let ImGui
// draw a software cursor, so the mouse works regardless of the game's pointer-capture state.
static float g_mx = 0.0f, g_my = 0.0f;
static bool  g_mouseInit = false;
static std::atomic<bool> g_recenterMouse{false};   // center the cursor when the console opens

// ---- command channel ----
static void refreshOut() {
    FILE* f = fopen(OUT_PATH, "r"); if (!f) return;
    g_lines.clear();
    char line[2048];
    while (fgets(line, sizeof(line), f)) { size_t n = strlen(line); if (n && line[n-1] == '\n') line[n-1] = 0; g_lines.push_back(line); }
    fclose(f);
    if (g_lines.size() > 400) g_lines.erase(g_lines.begin(), g_lines.end() - 400);
}
static unsigned g_cmdSeq = 0;
static void submitCommand(const char* c) {
    // Prefix a monotonic sequence so repeated identical commands are never de-duped
    // by the Frida poller (it compares raw file contents). The JS strips the "<seq>\t".
    FILE* f = fopen(CMD_PATH, "w"); if (f) { fprintf(f, "%u\t%s\n", ++g_cmdSeq, c); fclose(f); }
    olog("submitted: %s", c);
}
static void appendOut(const char* s) { FILE* f = fopen(OUT_PATH, "a"); if (f) { fprintf(f, "%s\n", s); fclose(f); } }

// Handle a submitted line. `clear`/`help` are local to the overlay; everything else goes to Frida.
static void handleSubmit(const char* cmd) {
    if (strcmp(cmd, "clear") == 0) { FILE* f = fopen(OUT_PATH, "w"); if (f) fclose(f); g_lines.clear(); return; }
    appendOut((std::string("> ") + cmd).c_str());
    if (strcmp(cmd, "help") == 0) {
        appendOut("items:  give <Items.X> <qty> | removeitem <Items.X> <qty> | money <n>");
        appendOut("        CET style: Game.AddToInventory(\"Items.X\", n)");
        appendOut("char:   perks <n> | attrs <n> | relic <n> | level <n> | streetcred <n> | heal | godmode [off] | invis [off] | infammo [off]");
        appendOut("world:  time <h> [m] | slowmo [factor|off] | nopolice [off]");
        appendOut("        teleport save <name> | teleport <name> | teleport <x> <y> <z> | setfact <name> <n>");
        appendOut("misc:   call <Class> <method> [args] | sig <Class> <method> | convdump | clear | help");
        appendOut("tip: Up/Down = command history. Bookmark spots: 'teleport save home' then 'teleport home'");
    } else {
        submitCommand(cmd);
    }
    refreshOut();
}

// ---- macOS virtual keycode -> ImGuiKey (control/nav keys + letters for Ctrl shortcuts) ----
static ImGuiKey macKeyToImGui(unsigned short k) {
    switch (k) {
        case 36: return ImGuiKey_Enter;      case 76: return ImGuiKey_KeypadEnter;
        case 48: return ImGuiKey_Tab;        case 49: return ImGuiKey_Space;
        case 51: return ImGuiKey_Backspace;  case 117: return ImGuiKey_Delete;
        case 53: return ImGuiKey_Escape;
        case 123: return ImGuiKey_LeftArrow; case 124: return ImGuiKey_RightArrow;
        case 125: return ImGuiKey_DownArrow; case 126: return ImGuiKey_UpArrow;
        case 115: return ImGuiKey_Home;      case 119: return ImGuiKey_End;
        case 116: return ImGuiKey_PageUp;    case 121: return ImGuiKey_PageDown;
        case 0: return ImGuiKey_A;  case 11: return ImGuiKey_B; case 8: return ImGuiKey_C;  case 2: return ImGuiKey_D;
        case 14: return ImGuiKey_E; case 3: return ImGuiKey_F;  case 5: return ImGuiKey_G;  case 4: return ImGuiKey_H;
        case 34: return ImGuiKey_I; case 38: return ImGuiKey_J; case 40: return ImGuiKey_K; case 37: return ImGuiKey_L;
        case 46: return ImGuiKey_M; case 45: return ImGuiKey_N; case 31: return ImGuiKey_O; case 35: return ImGuiKey_P;
        case 12: return ImGuiKey_Q; case 15: return ImGuiKey_R; case 1: return ImGuiKey_S;  case 17: return ImGuiKey_T;
        case 32: return ImGuiKey_U; case 9: return ImGuiKey_V;  case 13: return ImGuiKey_W; case 7: return ImGuiKey_X;
        case 16: return ImGuiKey_Y; case 6: return ImGuiKey_Z;
        default: return ImGuiKey_None;
    }
}

// Called on the MAIN thread from the sendEvent swizzle. Only queues data; no ImGui calls.
static void pushEventFromNS(NSEvent* ev) {
    NSEventType t = ev.type;
    std::lock_guard<std::mutex> lk(g_qmtx);
    NSEventModifierFlags mf = ev.modifierFlags;
    int mods = 0;
    if (mf & NSEventModifierFlagControl) mods |= 1;
    if (mf & NSEventModifierFlagShift)   mods |= 2;
    if (mf & NSEventModifierFlagOption)  mods |= 4;
    if (mf & NSEventModifierFlagCommand) mods |= 8;
    g_queue.push_back({5, mods, false, 0, 0, 0});
    if (t == NSEventTypeKeyDown || t == NSEventTypeKeyUp) {
        bool down = (t == NSEventTypeKeyDown);
        ImGuiKey k = macKeyToImGui(ev.keyCode);
        if (k != ImGuiKey_None) g_queue.push_back({0, (int)k, down, 0, 0, 0});
        if (down && !(mf & NSEventModifierFlagCommand)) { NSString* s = ev.characters; if (s) { for (NSUInteger i = 0; i < s.length; i++) { unichar c = [s characterAtIndex:i]; if (c >= 32 && c != 127) g_queue.push_back({1, 0, false, (unsigned)c, 0, 0}); } } }
    } else if (t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseDown ||
               t == NSEventTypeRightMouseUp || t == NSEventTypeMouseMoved || t == NSEventTypeLeftMouseDragged ||
               t == NSEventTypeRightMouseDragged) {
        // Movement: queue raw deltas (type 6). deltaX/deltaY keep reporting even when the game has the
        // cursor associated-off, unlike absolute locationInWindow. Scaled to framebuffer px by the
        // window's backing scale; the render thread integrates + clamps these into an absolute pos.
        CGFloat sc = ev.window ? ev.window.backingScaleFactor : 1.0;
        if (ev.deltaX != 0.0 || ev.deltaY != 0.0)
            g_queue.push_back({6, 0, false, 0, (float)(ev.deltaX * sc), (float)(ev.deltaY * sc)});
        if (t == NSEventTypeLeftMouseDown)       g_queue.push_back({3, 0, true,  0, 0, 0});
        else if (t == NSEventTypeLeftMouseUp)    g_queue.push_back({3, 0, false, 0, 0, 0});
        else if (t == NSEventTypeRightMouseDown) g_queue.push_back({3, 1, true,  0, 0, 0});
        else if (t == NSEventTypeRightMouseUp)   g_queue.push_back({3, 1, false, 0, 0, 0});
    } else if (t == NSEventTypeScrollWheel) {
        g_queue.push_back({4, 0, false, 0, (float)ev.scrollingDeltaX * 0.1f, (float)ev.scrollingDeltaY * 0.1f});
    }
}

static void drainEvents() {
    std::lock_guard<std::mutex> lk(g_qmtx);
    ImGuiIO& io = ImGui::GetIO();
    // Center the virtual cursor on first use and each time the console opens, so it's findable.
    // DisplaySize is valid here (renderOverlay sets it just before calling drainEvents).
    if (!g_mouseInit || g_recenterMouse.exchange(false)) {
        g_mx = io.DisplaySize.x * 0.5f; g_my = io.DisplaySize.y * 0.5f; g_mouseInit = true;
        io.AddMousePosEvent(g_mx, g_my);
    }
    for (auto& e : g_queue) {
        switch (e.type) {
            case 0: io.AddKeyEvent((ImGuiKey)e.code, e.down); break;
            case 1: io.AddInputCharacter(e.ch); break;
            case 2: io.AddMousePosEvent(e.x, e.y); break;
            case 3: io.AddMouseButtonEvent(e.code, e.down); break;
            case 4: io.AddMouseWheelEvent(e.x, e.y); break;
            case 5: io.AddKeyEvent(ImGuiMod_Ctrl, e.code & 1); io.AddKeyEvent(ImGuiMod_Shift, e.code & 2);
                    io.AddKeyEvent(ImGuiMod_Alt, e.code & 4); io.AddKeyEvent(ImGuiMod_Super, e.code & 8); break;
            case 6: g_mx += e.x; g_my += e.y;   // integrate raw mouse delta -> absolute pos, clamp to screen
                    if (g_mx < 0) g_mx = 0; else if (g_mx > io.DisplaySize.x) g_mx = io.DisplaySize.x;
                    if (g_my < 0) g_my = 0; else if (g_my > io.DisplaySize.y) g_my = io.DisplaySize.y;
                    io.AddMousePosEvent(g_mx, g_my); break;
        }
    }
    g_queue.clear();
}

// macOS clipboard (NSPasteboard) so Cmd+V / Cmd+C work in the console input
static const char* clip_get(ImGuiContext*) {
    static std::string s;
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    NSString* str = [pb stringForType:NSPasteboardTypeString];
    s = (str != nil) ? std::string([str UTF8String]) : std::string();
    return s.c_str();
}
static void clip_set(ImGuiContext*, const char* text) {
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    if (text) [pb setString:[NSString stringWithUTF8String:text] forType:NSPasteboardTypeString];
}

static void initImGui(id<MTLDevice> dev) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigMacOSXBehaviors = true;   // Cmd-based shortcuts (Cmd+V paste, Cmd+C copy, Cmd+A select-all)
    io.MouseDrawCursor = true;         // draw our own cursor (the game hides the OS one during gameplay)
    ImGuiPlatformIO& pio = ImGui::GetPlatformIO();
    pio.Platform_GetClipboardTextFn = clip_get;
    pio.Platform_SetClipboardTextFn = clip_set;
    ImGui::StyleColorsDark();
    ImGui_ImplMetal_Init(dev);
    refreshOut();
    g_imguiInit = true;
    olog("ImGui %s initialized", IMGUI_VERSION);
}

// Up/Down arrow command history for the input box.
static int inputCallback(ImGuiInputTextCallbackData* data) {
    if (data->EventFlag == ImGuiInputTextFlags_CallbackHistory) {
        int prev = g_historyPos;
        if (data->EventKey == ImGuiKey_UpArrow) {
            if (g_historyPos == -1) g_historyPos = (int)g_history.size() - 1;
            else if (g_historyPos > 0) g_historyPos--;
        } else if (data->EventKey == ImGuiKey_DownArrow) {
            if (g_historyPos != -1 && ++g_historyPos >= (int)g_history.size()) g_historyPos = -1;
        }
        if (prev != g_historyPos) {
            const char* s = (g_historyPos >= 0 && g_historyPos < (int)g_history.size()) ? g_history[g_historyPos].c_str() : "";
            data->DeleteChars(0, data->BufTextLen);
            data->InsertChars(0, s);
        }
    }
    return 0;
}

// ---- item catalog (searchable browser) ----
struct CatItem { std::string id, name, type, sheet; };
static std::vector<CatItem> g_catalog;
static bool g_catalogLoaded = false;
static char g_itemFilter[128] = {0};
static std::string g_lastFilter = "\x01";   // force first build
static std::vector<int> g_filtered;
static int g_giveQty = 1;

// item-browser category filter (by the catalog "sheet" column). index 0 = All.
struct Cat { const char* label; const char* sheet; };
static const Cat g_categories[] = {
    {"All", ""}, {"Weapons", "WEAPONS"}, {"Cyberware", "CYBERWARE"},
    {"Clothes", "CLOTHES"}, {"Crafting", "CRAFTING"}, {"Mods", "MODS"}, {"Misc", "MISC"}
};
static const int g_numCategories = 7;
static std::atomic<int>  g_catFilter{0};
static std::atomic<bool> g_catReq{false};

// the catalog ships next to the overlay dylib (red4ext/ when installed, build/ in dev)
static std::string overlayDir() {
    Dl_info info;
    if (dladdr((void*)&overlayDir, &info) && info.dli_fname) {
        std::string p = info.dli_fname;
        size_t s = p.find_last_of('/');
        if (s != std::string::npos) return p.substr(0, s);
    }
    return ".";
}

static void loadCatalog() {
    g_catalogLoaded = true;
    std::string path = overlayDir() + "/cet_catalog.tsv";
    FILE* f = fopen(path.c_str(), "r");
    if (!f) { olog("catalog not found: %s", path.c_str()); return; }
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        size_t n = strlen(line);
        while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = 0;
        std::string fields[4]; int fi = 0; std::string cur;
        for (char* p = line; ; ++p) {
            if (*p == '\t' || *p == 0) { if (fi < 4) fields[fi] = cur; fi++; cur.clear(); if (*p == 0) break; }
            else cur += *p;
        }
        if (fields[0].empty()) continue;
        g_catalog.push_back({fields[0], fields[1], fields[2], fields[3]});
    }
    fclose(f);
    olog("catalog loaded: %zu items", g_catalog.size());
}

static std::string lower(const std::string& s) { std::string r = s; for (auto& c : r) c = (char)tolower((unsigned char)c); return r; }

static void rebuildFilter() {
    g_filtered.clear();
    std::string q = lower(g_itemFilter);
    int cat = g_catFilter.load();
    const char* sheet = (cat > 0 && cat < g_numCategories) ? g_categories[cat].sheet : nullptr;
    for (int i = 0; i < (int)g_catalog.size(); ++i) {
        const CatItem& it = g_catalog[i];
        if (sheet && it.sheet != sheet) continue;   // category filter
        if (q.empty() || lower(it.name).find(q) != std::string::npos
                       || lower(it.id).find(q) != std::string::npos
                       || lower(it.type).find(q) != std::string::npos)
            g_filtered.push_back(i);
    }
    g_lastFilter = g_itemFilter;
}

// send a command to the game, echoing it into the console scrollback
static void runCommand(const std::string& cmd) {
    appendOut((std::string("> ") + cmd).c_str());
    submitCommand(cmd.c_str());
    refreshOut();
}

// last-action confirmation shown in the overlay footer
static std::string g_lastAction;
static void runLabeled(const std::string& cmd, const std::string& label) { g_lastAction = label; runCommand(cmd); }

// persistent pinned-favorite items (~/Library/Application Support/NightCityConsole/favorites.txt)
struct Fav { std::string id, name; };
static std::vector<Fav> g_favorites;
static bool g_favLoaded = false;

static std::string favPath() {
    NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/NightCityConsole"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return std::string([[dir stringByAppendingPathComponent:@"favorites.txt"] UTF8String]);
}
static void loadFavorites() {
    g_favLoaded = true;
    FILE* f = fopen(favPath().c_str(), "r"); if (!f) return;
    char line[1024];
    while (fgets(line, sizeof(line), f)) {
        size_t n = strlen(line); while (n && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = 0;
        if (!line[0]) continue;
        char* tab = strchr(line, '\t');
        if (tab) { *tab = 0; g_favorites.push_back({line, tab + 1}); }
        else g_favorites.push_back({line, line});
    }
    fclose(f);
}
static void saveFavorites() {
    FILE* f = fopen(favPath().c_str(), "w"); if (!f) return;
    for (auto& fv : g_favorites) fprintf(f, "%s\t%s\n", fv.id.c_str(), fv.name.c_str());
    fclose(f);
}
static void addFavorite(const std::string& id, const std::string& name) {
    for (auto& fv : g_favorites) if (fv.id == id) { g_lastAction = "Already pinned: " + name; return; }
    g_favorites.push_back({id, name}); saveFavorites(); g_lastAction = "Pinned: " + name;
}
static void removeFavorite(int i) {
    if (i >= 0 && i < (int)g_favorites.size()) { g_favorites.erase(g_favorites.begin() + i); saveFavorites(); }
}

static void drawItemsTab() {
    if (!g_catalogLoaded) loadCatalog();
    if (g_catalog.empty()) { ImGui::TextDisabled("Item catalog not found (cet_catalog.tsv)."); return; }
    // category row: click a category to browse it (or Cmd+G to cycle by keyboard)
    int cat = g_catFilter.load();
    for (int c = 0; c < g_numCategories; ++c) {
        if (c) ImGui::SameLine();
        bool active = (c == cat);
        if (active) ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.20f, 0.45f, 0.75f, 1.0f));
        if (ImGui::SmallButton(g_categories[c].label)) { g_catFilter = c; g_catReq = true; }
        if (active) ImGui::PopStyleColor();
    }
    ImGui::SetNextItemWidth(110);
    if (ImGui::InputInt("qty", &g_giveQty)) { if (g_giveQty < 1) g_giveQty = 1; }
    ImGui::SameLine();
    if (g_itemsTabEntered.exchange(false)) ImGui::SetKeyboardFocusHere();   // focus the search box on tab enter
    ImGui::SetNextItemWidth(-1);
    bool entered = ImGui::InputTextWithHint("##itemsearch", "type to search, Enter spawns the top result (Cmd+G cycles category)",
                                            g_itemFilter, sizeof(g_itemFilter), ImGuiInputTextFlags_EnterReturnsTrue);
    if (g_catReq.exchange(false) || g_lastFilter != g_itemFilter) rebuildFilter();
    if (entered && !g_filtered.empty()) {
        const CatItem& top = g_catalog[g_filtered[0]];
        runLabeled("give " + top.id + " " + std::to_string(g_giveQty), "Added " + top.name);
        ImGui::SetKeyboardFocusHere(-1);   // keep typing in the search box
    }
    if (g_pinTopReq.exchange(false) && !g_filtered.empty()) {   // Cmd+P pins the top result
        const CatItem& top = g_catalog[g_filtered[0]];
        addFavorite(top.id, top.name);
    }
    if (!g_filtered.empty())
        ImGui::TextDisabled("Enter spawns / Cmd+P pins: %s   (%d matches)", g_catalog[g_filtered[0]].name.c_str(), (int)g_filtered.size());
    else
        ImGui::TextDisabled("no matches");
    ImGui::Separator();
    ImGui::BeginChild("itemlist", ImVec2(0, 0));
    ImGuiListClipper clipper; clipper.Begin((int)g_filtered.size());
    while (clipper.Step()) {
        for (int row = clipper.DisplayStart; row < clipper.DisplayEnd; ++row) {
            const CatItem& it = g_catalog[g_filtered[row]];
            ImGui::PushID(row);
            if (ImGui::SmallButton("Give")) runLabeled("give " + it.id + " " + std::to_string(g_giveQty), "Added " + it.name);
            ImGui::SameLine();
            if (ImGui::SmallButton("Pin")) addFavorite(it.id, it.name);
            ImGui::SameLine();
            if (row == 0) ImGui::TextColored(ImVec4(1.0f, 0.95f, 0.4f, 1.0f), "%s", it.name.c_str());  // top result (Enter target)
            else ImGui::TextUnformatted(it.name.c_str());
            ImGui::SameLine(); ImGui::TextDisabled("  %s", it.id.c_str());
            ImGui::PopID();
        }
    }
    ImGui::EndChild();
}

static void drawQuickTab() {
    if (!g_favLoaded) loadFavorites();
    ImGui::TextDisabled("Pinned items:");
    if (g_favorites.empty())
        ImGui::TextDisabled("  (none yet - go to the Items tab, find an item, click Pin)");
    for (int i = 0; i < (int)g_favorites.size(); ++i) {
        ImGui::PushID(2000 + i);
        if (ImGui::SmallButton("Give")) runLabeled("give " + g_favorites[i].id + " 1", "Added " + g_favorites[i].name);
        ImGui::SameLine();
        if (ImGui::SmallButton("x")) { removeFavorite(i); ImGui::PopID(); break; }
        ImGui::SameLine(); ImGui::TextUnformatted(g_favorites[i].name.c_str());
        ImGui::PopID();
    }
    ImGui::Separator();
    ImGui::TextDisabled("One-click cheats:");
    if (ImGui::Button("Money +50k")) runLabeled("money 50000", "Money +50k"); ImGui::SameLine();
    if (ImGui::Button("Heal")) runLabeled("heal", "Healed"); ImGui::SameLine();
    if (ImGui::Button("Godmode")) runLabeled("godmode", "Godmode on"); ImGui::SameLine();
    if (ImGui::Button("Godmode off")) runLabeled("godmode off", "Godmode off");
    if (ImGui::Button("Invisible")) runLabeled("invis", "Invisible on"); ImGui::SameLine();
    if (ImGui::Button("Invisible off")) runLabeled("invis off", "Invisible off"); ImGui::SameLine();
    if (ImGui::Button("Infinite ammo")) runLabeled("infammo", "Infinite ammo on"); ImGui::SameLine();
    if (ImGui::Button("Ammo off")) runLabeled("infammo off", "Infinite ammo off");
    if (ImGui::Button("Perks +10")) runLabeled("perks 10", "Perks +10"); ImGui::SameLine();
    if (ImGui::Button("Attrs +10")) runLabeled("attrs 10", "Attrs +10"); ImGui::SameLine();
    if (ImGui::Button("Relic +10")) runLabeled("relic 10", "Relic +10"); ImGui::SameLine();
    if (ImGui::Button("Level 50")) runLabeled("level 50", "Level 50"); ImGui::SameLine();
    if (ImGui::Button("Street Cred 50")) runLabeled("streetcred 50", "Street Cred 50");
    ImGui::Separator();
    ImGui::TextDisabled("World:");
    if (ImGui::Button("Day")) runLabeled("time 12", "Time: noon"); ImGui::SameLine();
    if (ImGui::Button("Night")) runLabeled("time 0", "Time: midnight");
    if (ImGui::Button("Slow-mo")) runLabeled("slowmo", "Slow-mo on"); ImGui::SameLine();
    if (ImGui::Button("Slow-mo off")) runLabeled("slowmo off", "Slow-mo off"); ImGui::SameLine();
    if (ImGui::Button("No police")) runLabeled("nopolice", "Police disabled"); ImGui::SameLine();
    if (ImGui::Button("Police on")) runLabeled("nopolice off", "Police enabled");
    ImGui::Separator();
    ImGui::TextDisabled("Teleport bookmark (save a spot, return later):");
    static char tpname[64] = "home";
    ImGui::SetNextItemWidth(160); ImGui::InputText("##tpname", tpname, sizeof(tpname));
    ImGui::SameLine(); if (ImGui::Button("Save spot")) runLabeled(std::string("teleport save ") + tpname, std::string("Saved spot: ") + tpname);
    ImGui::SameLine(); if (ImGui::Button("Go to spot")) runLabeled(std::string("teleport ") + tpname, std::string("Teleported: ") + tpname);
}

// ---- Creator: build a custom iconic weapon IN-PROCESS (ported from makeweapon.py). No Python, no
//      external scripts, no hardcoded paths: generates the TweakXL YAML + appends the name/flavor/gold
//      LocKey strings, then applies live via cmnreload/tweakload/give. Game dir discovered at runtime. ----
#define CR_SLOT_RANGED "AttachmentSlots.IconicWeaponModLegendary"
#define CR_SLOT_MELEE  "AttachmentSlots.IconicMeleeWeaponMod1"
#define CR_BP_R   "Items.Iconic_Ranged_Weapon_Blueprint"
#define CR_BP_RN  "Items.Iconic_Ranged_Weapon_NoMuzzle_Blueprint"
#define CR_BP_RA  "Items.Iconic_Ranged_Weapon_NoAttachments_Blueprint"
#define CR_BP_M   "Items.Iconic_Melee_Blueprint"
static const long CR_LOCKEY_START = 7777798;

struct CrBase { const char* label; const char* preset; const char* bp; const char* slot; bool melee; };
static const CrBase kCrBases[] = {
    {"Pistol  -  Lexington", "Items.Preset_Lexington_Default",    CR_BP_R,  CR_SLOT_RANGED, false},
    {"SMG  -  Saratoga",     "Items.Preset_Saratoga_Default",     CR_BP_R,  CR_SLOT_RANGED, false},
    {"Shotgun  -  Carnage",  "Items.Preset_Carnage_Default",      CR_BP_RA, CR_SLOT_RANGED, false},
    {"Sniper  -  Nekomata",  "Items.Preset_Nekomata_Default",     CR_BP_RN, CR_SLOT_RANGED, false},
    {"Katana",               "Items.Preset_Katana_Default",       CR_BP_M,  CR_SLOT_MELEE,  true},
    {"Knife",                "Items.Preset_Knife_Default",        CR_BP_M,  CR_SLOT_MELEE,  true},
    {"Baseball Bat",         "Items.Preset_Baseball_Bat_Default", CR_BP_M,  CR_SLOT_MELEE,  true},
};
static const int kCrNumBases = (int)(sizeof(kCrBases) / sizeof(kCrBases[0]));

struct CrStat { const char* stat; const char* mod; const char* val; };
struct CrEff  { const char* name; CrStat stats[2]; int nstats; bool meleeOnly; };
static const CrEff kCrEffects[] = {
    {"fire",        {{"BurningApplicationRate","Additive","100"}}, 1, false},
    {"bleed",       {{"BleedingApplicationRate","Additive","75"}}, 1, false},
    {"shock",       {{"ElectrocutedApplicationRate","Additive","75"}}, 1, false},
    {"poison",      {{"PoisonedApplicationRate","Additive","75"}}, 1, false},
    {"stun",        {{"StunApplicationRate","Additive","75"}}, 1, false},
    {"crit",        {{"CritChance","Additive","40"},{"CritDamage","Additive","150"}}, 2, false},
    {"headshot",    {{"HeadshotDamageMultiplier","Additive","3.0"}}, 1, false},
    {"ignorearmor", {{"CanWeaponIgnoreArmor","Additive","1"}}, 1, false},
    {"armorpen",    {{"ArmorPenetrationBonus","Additive","100"}}, 1, false},
    {"lifesteal",   {{"HealthRegainOnKill","Additive","30"}}, 1, false},
    {"execute",     {{"BonusPercentDamageToEnemiesBelowHalfHealth","Additive","50"}}, 1, false},
    {"damage",      {{"DamagePerHit","Multiplier","1.5"}}, 1, false},
    {"bigmag",      {{"MagazineCapacityBonus","Additive","40"}}, 1, false},
    {"fastreload",  {{"ReloadSpeedPercentBonus","Additive","50"}}, 1, false},
    {"stealth",     {{"StealthHitDamageBonus","Additive","100"}}, 1, false},
    {"melee",       {{"MeleeDamagePercentBonus","Additive","60"}}, 1, false},
    {"antiboss",    {{"BonusDamageAgainstBosses","Additive","100"}}, 1, false},
    {"leap",        {{"CanMeleeLeap","Additive","1"}}, 1, true},
};
static const int kCrNumEffects = (int)(sizeof(kCrEffects) / sizeof(kCrEffects[0]));

static int   g_crBase = 0;
static char  g_crName[64]   = "Crit Machine";
static char  g_crWhite[256] = "Built in a back-alley ripperdoc's. One of a kind.";
static char  g_crGold[256]  = "Custom iconic ability.";
static bool  g_crEff[32] = { false };
static std::mutex g_crMtx;
static std::string g_crStatus;
static std::atomic<bool> g_crBusy{false};

// Game dir = the folder two levels up from this dylib (<GAME>/red4ext/libcyberconsole_overlay.dylib).
static std::string crGameRoot() {
    Dl_info info;
    if (dladdr((void*)&crGameRoot, &info) && info.dli_fname) {
        std::string p = info.dli_fname;
        size_t a = p.find_last_of('/'); if (a != std::string::npos) p.resize(a);   // -> <GAME>/red4ext
        size_t b = p.find_last_of('/'); if (b != std::string::npos) p.resize(b);   // -> <GAME>
        return p;
    }
    return "";
}
static std::string crJsonEsc(const std::string& s) {
    std::string o; for (unsigned char c : s) { switch (c) {
        case '"': o += "\\\""; break; case '\\': o += "\\\\"; break;
        case '\n': o += "\\n"; break; case '\r': o += "\\r"; break; case '\t': o += "\\t"; break;
        default: if (c < 0x20) { char b[8]; snprintf(b, sizeof(b), "\\u%04x", c); o += b; } else o += (char)c; }
    } return o;
}
// Mirror Python str.title() + strip non-alnum, then prefix CyberModMan.
static std::string crRecordStem(const std::string& name) {
    std::string out; bool wordStart = true;
    for (char c : name) {
        if (isalnum((unsigned char)c)) {
            if (isalpha((unsigned char)c)) { out += (char)(wordStart ? toupper(c) : tolower(c)); wordStart = false; }
            else { out += c; wordStart = true; }
        } else wordStart = true;
    }
    return "CyberModMan" + (out.empty() ? std::string("Weapon") : out);
}
static std::string crStatYaml(const char* st, const char* mt, const char* v) {
    return std::string("    - $type: ConstantStatModifier\n      statType: BaseStats.") + st +
           "\n      modifierType: " + mt + "\n      value: " + v + "\n";
}
static std::string crReadFile(const std::string& path) {
    std::string c; FILE* f = fopen(path.c_str(), "r"); if (!f) return c;
    char b[4096]; size_t n; while ((n = fread(b,1,sizeof(b),f)) > 0) c.append(b,n); fclose(f); return c;
}
static std::set<long> crUsedLockeys(const std::string& path) {
    std::set<long> used; std::string c = crReadFile(path);
    for (size_t i = 0; i < c.size(); ) {
        if (c[i] == '"') { size_t j = i+1; std::string num; bool digits = true;
            while (j < c.size() && c[j] != '"') { if (!isdigit((unsigned char)c[j])) digits = false; num += c[j]; j++; }
            if (digits && !num.empty() && j < c.size()) { size_t k = j+1;
                while (k < c.size() && isspace((unsigned char)c[k])) k++;
                if (k < c.size() && c[k] == ':') used.insert(strtol(num.c_str(), nullptr, 10)); }
            i = j + 1;
        } else i++;
    }
    return used;
}
static bool crAppendNames(const std::string& path, long k1, const std::string& v1,
                          long k2, const std::string& v2, long k3, const std::string& v3) {
    std::string c = crReadFile(path);
    while (!c.empty() && isspace((unsigned char)c.back())) c.pop_back();
    std::string entries =
        "  \"" + std::to_string(k1) + "\": \"" + crJsonEsc(v1) + "\",\n"
        "  \"" + std::to_string(k2) + "\": \"" + crJsonEsc(v2) + "\",\n"
        "  \"" + std::to_string(k3) + "\": \"" + crJsonEsc(v3) + "\"\n";
    std::string out;
    if (c.empty() || c == "{}" || c == "{") out = "{\n" + entries + "}\n";
    else if (c.back() == '}') {
        c.pop_back(); while (!c.empty() && isspace((unsigned char)c.back())) c.pop_back();
        std::string sep = (!c.empty() && c.back() == '{') ? "\n" : ",\n";
        out = c + sep + entries + "}\n";
    } else out = "{\n" + entries + "}\n";
    FILE* w = fopen(path.c_str(), "w"); if (!w) return false;
    fwrite(out.data(), 1, out.size(), w); fclose(w); return true;
}
// Generate + deploy. Returns the record id, or "" with err set.
static std::string crGenWeapon(int baseIdx, const std::string& name, const std::string& white,
                               const std::string& gold, const bool* effSel, std::string& err) {
    std::string game = crGameRoot();
    if (game.empty()) { err = "could not locate game dir"; return ""; }
    std::string tweaks = game + "/r6/tweaks";
    std::string namesPath = game + "/red4ext/cybermodman_names.json";
    const CrBase& bse = kCrBases[baseIdx];
    std::string stem = crRecordStem(name);
    std::string recordId = "Items." + stem;

    std::string body; bool hasDamage = false;
    for (int i = 0; i < kCrNumEffects; ++i) {
        if (!effSel[i]) continue;
        const CrEff& e = kCrEffects[i];
        if (e.meleeOnly && !bse.melee) continue;
        for (int s = 0; s < e.nstats; ++s) {
            body += crStatYaml(e.stats[s].stat, e.stats[s].mod, e.stats[s].val);
            if (std::string(e.stats[s].stat) == "DamagePerHit") hasDamage = true;
        }
    }
    std::string stats = (hasDamage ? std::string() : crStatYaml("DamagePerHit","Multiplier","1.5")) + body;

    std::set<long> used = crUsedLockeys(namesPath);
    long keys[3]; int got = 0; for (long k = CR_LOCKEY_START; got < 3; ++k) if (!used.count(k)) keys[got++] = k;
    std::string kn = std::to_string(keys[0]), kw = std::to_string(keys[1]), kg = std::to_string(keys[2]);

    std::string yaml =
        "# cybermodman generated iconic: " + name + "\n" +
        "Items." + stem + "_AbilityUI:\n  $type: GameplayLogicPackageUIData\n  localizedDescription: LocKey#" + kg + "\n\n" +
        "Items." + stem + "_Ability:\n  $base: Items.IconicWeaponModAbilityBase\n  UIData: Items." + stem + "_AbilityUI\n\n" +
        "Items." + stem + "_Mod:\n  $base: Items.IconicWeaponModBase\n  OnAttach:\n    - Items." + stem + "_Ability\n  statModifiers:\n" +
        stats +
        "Items." + stem + ":\n  $base: " + bse.preset + "\n  blueprint: " + bse.bp + "\n  quality: Quality.Legendary\n" +
        "  displayName: LocKey#" + kn + "\n  gameplayDescription: LocKey#" + kw + "\n" +
        "  tags:\n    - !append IconicWeapon\n  statModifiers:\n    - !append Quality.IconicItem\n" +
        "  statModifierGroups:\n    - !remove Items.QualityRandomization\n    - !append Items.IconicQualityRandomization\n" +
        "  slotPartListPreset:\n    - !append-once\n      $type: SlotItemPartPreset\n      itemPartPreset: Items." + stem + "_Mod\n      slot: " + bse.slot + "\n";

    std::string yamlPath = tweaks + "/cybermodman_" + stem + ".yaml";
    FILE* yf = fopen(yamlPath.c_str(), "w");
    if (!yf) { err = "cannot write " + yamlPath; return ""; }
    fwrite(yaml.data(), 1, yaml.size(), yf); fclose(yf);
    if (!crAppendNames(namesPath, keys[0], name, keys[1], white, keys[2], gold)) { err = "cannot write names json"; return ""; }
    return recordId;
}

static void crSetStatus(const std::string& s) { std::lock_guard<std::mutex> lk(g_crMtx); g_crStatus = s; }

static void crCreateThread(int baseIdx, std::string name, std::string white, std::string gold, std::vector<char> sel) {
    g_crBusy = true;
    crSetStatus("Generating \"" + name + "\" ...");
    bool eff[64] = { false }; for (size_t i = 0; i < sel.size() && i < 64; ++i) eff[i] = sel[i] != 0;
    std::string err;
    std::string recordId = crGenWeapon(baseIdx, name, white, gold, eff, err);
    if (recordId.empty()) { crSetStatus("FAILED: " + err); g_crBusy = false; return; }
    crSetStatus("Created " + recordId + " - applying in-game ...");
    runCommand("cmnreload");               usleep(350000);   // load the new name/flavor/gold LocKeys
    runCommand("tweakload");               usleep(750000);   // apply the new weapon record to TweakDB
    runCommand("give " + recordId + " 1"); usleep(150000);   // hand it to the player
    crSetStatus("DONE: \"" + name + "\" (" + recordId + ") created + applied + added to inventory.\n"
                "Note: the GOLD ability text fully links after one game restart (name, white text + the weapon work now).");
    g_crBusy = false;
}

static void drawCreatorTab() {
    ImGui::TextColored(ImVec4(1.0f, 0.84f, 0.0f, 1.0f), "CYBERMODMAN  -  Custom Iconic Weapon Creator");
    ImGui::TextDisabled("Pick a base, name it, choose effects, hit Create. (Load a save first so it can be given.)");
    ImGui::Separator();
    ImGui::SetNextItemWidth(300);
    if (ImGui::BeginCombo("Base", kCrBases[g_crBase].label)) {
        for (int i = 0; i < kCrNumBases; ++i) { bool sel = (i == g_crBase);
            if (ImGui::Selectable(kCrBases[i].label, sel)) g_crBase = i;
            if (sel) ImGui::SetItemDefaultFocus(); }
        ImGui::EndCombo();
    }
    ImGui::SetNextItemWidth(300); ImGui::InputText("Name", g_crName, sizeof(g_crName));
    ImGui::SetNextItemWidth(520); ImGui::InputText("White flavor", g_crWhite, sizeof(g_crWhite));
    ImGui::SetNextItemWidth(520); ImGui::InputText("Gold ability text", g_crGold, sizeof(g_crGold));
    ImGui::Separator();
    ImGui::TextDisabled("Effects (leap = melee only):");
    for (int i = 0; i < kCrNumEffects; ++i) {
        ImGui::Checkbox(kCrEffects[i].name, &g_crEff[i]);
        if ((i % 6) != 5 && i != kCrNumEffects - 1) ImGui::SameLine();
    }
    ImGui::Separator();
    bool busy = g_crBusy.load();
    if (busy) ImGui::BeginDisabled();
    if (ImGui::Button("Create & Apply", ImVec2(190, 34))) {
        std::vector<char> sel(kCrNumEffects); for (int i = 0; i < kCrNumEffects; ++i) sel[i] = g_crEff[i] ? 1 : 0;
        std::thread(crCreateThread, g_crBase, std::string(g_crName),
                    std::string(g_crWhite), std::string(g_crGold), sel).detach();
    }
    if (busy) { ImGui::EndDisabled(); ImGui::SameLine(); ImGui::TextDisabled("working..."); }
    { std::lock_guard<std::mutex> lk(g_crMtx);
      if (!g_crStatus.empty()) { ImGui::Separator(); ImGui::TextWrapped("%s", g_crStatus.c_str()); } }
}

static void drawConsole() {
    ImGui::SetNextWindowSize(ImVec2(860, 480), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(48, 48), ImGuiCond_FirstUseEver);
    ImGui::Begin("NightCity Console  ( ` or F1 to toggle )");
    ImGui::TextDisabled("Cmd+1 Console    Cmd+2 Items    Cmd+3 Quick");
    int req = -1;
    if (g_tabReq.exchange(false)) req = g_activeTab.load();   // a keyboard tab-switch this frame
    if (ImGui::BeginTabBar("cetmac_tabs")) {
        if (ImGui::BeginTabItem("Console", nullptr, req == 0 ? ImGuiTabItemFlags_SetSelected : 0)) {
            ImGui::BeginChild("scroll", ImVec2(0, -ImGui::GetFrameHeightWithSpacing()), false, ImGuiWindowFlags_HorizontalScrollbar);
            for (auto& l : g_lines) ImGui::TextUnformatted(l.c_str());
            if (ImGui::GetScrollY() >= ImGui::GetScrollMaxY() - 4.0f) ImGui::SetScrollHereY(1.0f);
            ImGui::EndChild();
            ImGui::Separator();
            ImGui::SetNextItemWidth(-1.0f);
            if (g_focusInput.exchange(false)) ImGui::SetKeyboardFocusHere();
            ImGuiInputTextFlags flags = ImGuiInputTextFlags_EnterReturnsTrue | ImGuiInputTextFlags_CallbackHistory;
            if (ImGui::InputText("##cmd", g_input, sizeof(g_input), flags, inputCallback)) {
                if (g_input[0]) {
                    if (g_history.empty() || g_history.back() != g_input) g_history.push_back(g_input);
                    g_historyPos = -1;
                    handleSubmit(g_input);
                    g_input[0] = 0;
                }
                ImGui::SetKeyboardFocusHere(-1);
            }
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("Items", nullptr, req == 1 ? ImGuiTabItemFlags_SetSelected : 0)) { drawItemsTab(); ImGui::EndTabItem(); }
        if (ImGui::BeginTabItem("Quick", nullptr, req == 2 ? ImGuiTabItemFlags_SetSelected : 0)) { drawQuickTab(); ImGui::EndTabItem(); }
        if (ImGui::BeginTabItem("Creator", nullptr, req == 3 ? ImGuiTabItemFlags_SetSelected : 0)) { drawCreatorTab(); ImGui::EndTabItem(); }
        ImGui::EndTabBar();
    }
    if (!g_lastAction.empty()) {
        ImGui::Separator();
        ImGui::TextColored(ImVec4(0.45f, 1.0f, 0.55f, 1.0f), "%s", g_lastAction.c_str());
    }
    ImGui::End();
}

static void renderOverlay(id<MTLCommandBuffer> cb, id<CAMetalDrawable> drawable) {
    static std::atomic<bool> firstLogged{false};
    if (!firstLogged.exchange(true))
        olog("present FIRED: cb=%s drawable=%p tex=%p", cb ? class_getName(object_getClass(cb)) : "null",
             (__bridge void*)drawable, (__bridge void*)(drawable ? drawable.texture : nil));   // one-time diagnostic
    if (!cb || !drawable) return;
    // When the console is hidden there is nothing to draw. Skip the entire render pass:
    // encoding an empty ImGui frame plus a Load-action render command encoder every frame
    // costs real GPU time (a full-framebuffer memory round-trip) and stutters in dense,
    // GPU-bound interiors. Bail before we touch the GPU so a closed console is free.
    if (!g_show.load()) return;
    id<MTLTexture> tex = drawable.texture; if (!tex) return;
    id<MTLDevice> dev = cb.device;
    if (!g_imguiInit) initImGui(dev);
    g_frame++;
    if ((g_frame % 60) == 0) refreshOut();

    MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = tex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)tex.width, (float)tex.height);
    io.DisplayFramebufferScale = ImVec2(1.0f, 1.0f);
    io.DeltaTime = 1.0f / 60.0f;
    drainEvents();

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();
    if (g_show.load()) drawConsole();
    ImGui::Render();

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    if (!enc) return;
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
}

static void runRender(id self, id drawable) {
    @autoreleasepool {
        @try { renderOverlay((id<MTLCommandBuffer>)self, (id<CAMetalDrawable>)drawable); }
        @catch (NSException* e) { olog("render exception: %s", [[e reason] UTF8String]); }
    }
}
static IMP origPresentFor(id self, SEL _cmd) {
    Method m = class_getInstanceMethod(object_getClass(self), _cmd);
    auto it = g_origPresents.find((void*)m);
    return it != g_origPresents.end() ? it->second : NULL;
}
// The game may present via presentDrawable:, presentDrawable:atTime:, or presentDrawable:afterMinimumDuration:
// (newer hardware/displays use the frame-paced variants). Render in all three, then chain to the original.
// A present can be nested (e.g. the MTL3On4 compat wrapper forwards to the underlying AGX buffer's present,
// and we hook both); render ONLY at the outermost call so we don't draw the overlay twice per frame.
static thread_local int g_presentDepth = 0;
static void my_presentDrawable(id self, SEL _cmd, id drawable) {
    if (g_presentDepth == 0 && g_mode == NCC_FULL) runRender(self, drawable);
    g_presentDepth++;
    IMP o = origPresentFor(self, _cmd); if (o) ((void(*)(id, SEL, id))o)(self, _cmd, drawable);
    g_presentDepth--;
}
static void my_presentAtTime(id self, SEL _cmd, id drawable, CFTimeInterval t) {
    if (g_presentDepth == 0 && g_mode == NCC_FULL) runRender(self, drawable);
    g_presentDepth++;
    IMP o = origPresentFor(self, _cmd); if (o) ((void(*)(id, SEL, id, CFTimeInterval))o)(self, _cmd, drawable, t);
    g_presentDepth--;
}
static void my_presentAfter(id self, SEL _cmd, id drawable, CFTimeInterval d) {
    if (g_presentDepth == 0 && g_mode == NCC_FULL) runRender(self, drawable);
    g_presentDepth++;
    IMP o = origPresentFor(self, _cmd); if (o) ((void(*)(id, SEL, id, CFTimeInterval))o)(self, _cmd, drawable, d);
    g_presentDepth--;
}

static void my_sendEvent(id self, SEL _cmd, NSEvent* ev) {
    @try {
        NSEventType t = ev.type;
        if (t == NSEventTypeKeyDown) {
            unsigned short kc = ev.keyCode;
            if (kc == 50 || kc == 122) {  // ` (grave/tilde) or F1
                bool now = !g_show.load();
                g_show = now;
                if (now) { g_focusInput = true; g_recenterMouse = true; NSWindow* w = ev.window; if (w) [w setAcceptsMouseMovedEvents:YES]; }
                return;  // swallow the toggle key
            }
            // Cmd+1 / Cmd+2 / Cmd+3 switch tabs (the game captures the mouse, so tabs are keyboard-driven)
            if (g_show.load() && (ev.modifierFlags & NSEventModifierFlagCommand)) {
                int tab = (kc == 18) ? 0 : (kc == 19) ? 1 : (kc == 20) ? 2 : -1;
                if (tab >= 0) {
                    g_activeTab = tab; g_tabReq = true;
                    if (tab == 0) g_focusInput = true;
                    if (tab == 1) g_itemsTabEntered = true;
                    return;  // swallow
                }
                if (kc == 35) { g_pinTopReq = true; return; }   // Cmd+P pins the current top search result
                if (kc == 5)  { g_catFilter = (g_catFilter.load() + 1) % g_numCategories; g_catReq = true; return; }  // Cmd+G cycles item category
            }
        }
        if (g_show.load()) {
            pushEventFromNS(ev);
            if (t == NSEventTypeKeyDown || t == NSEventTypeKeyUp || t == NSEventTypeFlagsChanged ||
                t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseDown ||
                t == NSEventTypeRightMouseUp || t == NSEventTypeMouseMoved || t == NSEventTypeLeftMouseDragged ||
                t == NSEventTypeRightMouseDragged || t == NSEventTypeScrollWheel)
                return;  // swallow so the game doesn't react while the console is open
        }
    } @catch (NSException* e) { olog("sendEvent exception: %s", [[e reason] UTF8String]); }
    ((void(*)(id, SEL, id))g_origSendEvent)(self, _cmd, ev);
}

// Diagnostic: hook CAMetalLayer.nextDrawable (called every frame by any Metal app, regardless of how it
// presents) to capture the live drawable class - so if presentDrawable* never fires we still learn the path.
static IMP g_origNextDrawable = NULL;
static id my_nextDrawable(id self, SEL _cmd) {
    id d = ((id(*)(id, SEL))g_origNextDrawable)(self, _cmd);
    frameTick();   // once per frame, every mode: our frame-cadence probe
    static std::atomic<bool> logged{false};
    if (!logged.exchange(true))
        olog("nextDrawable FIRED: layer=%s drawable=%s", class_getName(object_getClass(self)),
             d ? class_getName(object_getClass(d)) : "null");
    return d;
}
static void installLayerDiag() {
    Class c = objc_getClass("CAMetalLayer");
    if (!c) { olog("diag: no CAMetalLayer"); return; }
    Method m = class_getInstanceMethod(c, sel_registerName("nextDrawable"));
    if (!m) { olog("diag: no nextDrawable on CAMetalLayer"); return; }
    g_origNextDrawable = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_nextDrawable);
    olog("hooked nextDrawable on CAMetalLayer (diag)");
}

static void installPresentHook() {
    if (g_mode == NCC_OFF) { olog("NCC_MODE=off: present hook NOT installed (bisection)"); return; }
    // Force the GPU-family command-buffer class (AGXG16F etc.) to load so the scan below sees it.
    @try {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (dev) { id<MTLCommandQueue> q = [dev newCommandQueue]; if (q) [q commandBuffer]; }
    } @catch (NSException*) {}
    struct Variant { const char* sel; IMP imp; };
    Variant variants[] = {
        { "presentDrawable:", (IMP)my_presentDrawable },
        { "presentDrawable:atTime:", (IMP)my_presentAtTime },
        { "presentDrawable:afterMinimumDuration:", (IMP)my_presentAfter },
    };
    int n = objc_getClassList(NULL, 0);
    Class* list = (Class*)malloc(sizeof(Class) * n);
    objc_getClassList(list, n);
    int hooked = 0;
    // Swizzle every command-buffer class's present methods (all three variants; dedupe inherited methods by
    // Method pointer). Catches whichever class AND present variant the game uses, on any chip/display.
    for (int i = 0; i < n; i++) {
        const char* nm = class_getName(list[i]);
        if (!nm || !strstr(nm, "CommandBuffer")) continue;
        for (auto& v : variants) {
            Method m = class_getInstanceMethod(list[i], sel_registerName(v.sel));
            if (!m) continue;
            if (g_origPresents.count((void*)m)) continue;   // already hooked (shared/inherited method)
            g_origPresents[(void*)m] = method_getImplementation(m);
            method_setImplementation(m, v.imp);
            hooked++;
            olog("hooked %s on %s", v.sel, nm);
        }
    }
    free(list);
    if (!hooked) olog("FATAL: no command-buffer present method found");
}

static void installInputHook() {
    id app = ((id(*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    if (!app) { olog("FATAL: no NSApplication"); return; }
    Class appClass = object_getClass(app);
    SEL sel = sel_registerName("sendEvent:");
    Method m = class_getInstanceMethod(appClass, sel);
    if (!m) { olog("FATAL: no sendEvent: on %s", class_getName(appClass)); return; }
    g_origSendEvent = method_getImplementation(m);
    method_setImplementation(m, (IMP)my_sendEvent);
    olog("hooked sendEvent: on %s", class_getName(appClass));
}

__attribute__((constructor))
static void overlay_init() {
    readMode();
    olog("==== CP2077 overlay dylib loaded (NCC_MODE=%s) ====", modeName());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installPresentHook();
        installInputHook();
        installLayerDiag();
    });
}
