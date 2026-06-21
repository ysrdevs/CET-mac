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

// ---- input event queue (main thread -> render thread) ----
struct InEvent { int type; int code; bool down; unsigned ch; float x; float y; };
static std::deque<InEvent> g_queue;
static std::mutex g_qmtx;

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
        appendOut("char:   perks <n> | attrs <n> | relic <n> | level <n> | heal | godmode [off] | invis [off] | infammo [off]");
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

static void pushMousePos(NSEvent* ev) {
    NSWindow* w = ev.window; if (!w) return;
    NSView* cv = [w contentView]; if (!cv) return;
    NSPoint p = ev.locationInWindow;
    NSPoint vp = [cv convertPoint:p fromView:nil];
    CGFloat h = cv.bounds.size.height;
    CGFloat sc = w.backingScaleFactor;
    g_queue.push_back({2, 0, false, 0, (float)(vp.x * sc), (float)((h - vp.y) * sc)});
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
        pushMousePos(ev);
        if (t == NSEventTypeLeftMouseDown)       g_queue.push_back({3, 0, true,  0, 0, 0});
        else if (t == NSEventTypeLeftMouseUp)    g_queue.push_back({3, 0, false, 0, 0, 0});
        else if (t == NSEventTypeRightMouseDown) g_queue.push_back({3, 1, true,  0, 0, 0});
        else if (t == NSEventTypeRightMouseUp)   g_queue.push_back({3, 1, false, 0, 0, 0});
    } else if (t == NSEventTypeScrollWheel) {
        pushMousePos(ev);
        g_queue.push_back({4, 0, false, 0, (float)ev.scrollingDeltaX * 0.1f, (float)ev.scrollingDeltaY * 0.1f});
    }
}

static void drainEvents() {
    std::lock_guard<std::mutex> lk(g_qmtx);
    ImGuiIO& io = ImGui::GetIO();
    for (auto& e : g_queue) {
        switch (e.type) {
            case 0: io.AddKeyEvent((ImGuiKey)e.code, e.down); break;
            case 1: io.AddInputCharacter(e.ch); break;
            case 2: io.AddMousePosEvent(e.x, e.y); break;
            case 3: io.AddMouseButtonEvent(e.code, e.down); break;
            case 4: io.AddMouseWheelEvent(e.x, e.y); break;
            case 5: io.AddKeyEvent(ImGuiMod_Ctrl, e.code & 1); io.AddKeyEvent(ImGuiMod_Shift, e.code & 2);
                    io.AddKeyEvent(ImGuiMod_Alt, e.code & 4); io.AddKeyEvent(ImGuiMod_Super, e.code & 8); break;
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
    if (ImGui::Button("Level 50")) runLabeled("level 50", "Level 50");
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
static void my_presentDrawable(id self, SEL _cmd, id drawable) {
    runRender(self, drawable);
    IMP o = origPresentFor(self, _cmd); if (o) ((void(*)(id, SEL, id))o)(self, _cmd, drawable);
}
static void my_presentAtTime(id self, SEL _cmd, id drawable, CFTimeInterval t) {
    runRender(self, drawable);
    IMP o = origPresentFor(self, _cmd); if (o) ((void(*)(id, SEL, id, CFTimeInterval))o)(self, _cmd, drawable, t);
}
static void my_presentAfter(id self, SEL _cmd, id drawable, CFTimeInterval d) {
    runRender(self, drawable);
    IMP o = origPresentFor(self, _cmd); if (o) ((void(*)(id, SEL, id, CFTimeInterval))o)(self, _cmd, drawable, d);
}

static void my_sendEvent(id self, SEL _cmd, NSEvent* ev) {
    @try {
        NSEventType t = ev.type;
        if (t == NSEventTypeKeyDown) {
            unsigned short kc = ev.keyCode;
            if (kc == 50 || kc == 122) {  // ` (grave/tilde) or F1
                bool now = !g_show.load();
                g_show = now;
                if (now) { g_focusInput = true; NSWindow* w = ev.window; if (w) [w setAcceptsMouseMovedEvents:YES]; }
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
    olog("==== CP2077 overlay dylib loaded ====");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installPresentHook();
        installInputHook();
        installLayerDiag();
    });
}
