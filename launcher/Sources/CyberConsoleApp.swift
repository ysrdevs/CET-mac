import SwiftUI
import AppKit

enum Const {
    static let appVersion = "1.3.0"
    static let supportedGameVersion = "2.3.1"
    static let defaultGame = "\(NSHomeDirectory())/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
    // Files copied from the app's Resources into <game>/red4ext/ on install.
    static let payload = ["red4ext_hooks.js", "FridaGadget.config", "RED4ext.dylib",
                          "FridaGadget.dylib", "libcyberconsole_overlay.dylib", "cet_catalog.tsv"]
    static let repo = "ysrdevs/nightcity-console-mac"
    static let commandsURL = "https://github.com/ysrdevs/nightcity-console-mac/blob/main/docs/COMMANDS.md"
    static let supportURL = "https://ko-fi.com/ysrdevs"
}

final class Model: ObservableObject {
    @Published var gamePath: String
    @Published var status: String = ""
    @Published var installed: Bool = false
    @Published var gameVersion: String? = nil
    @Published var updateText: String? = nil      // set when a newer release is found on GitHub
    @Published var updateURL: String? = nil

    private let defaults = UserDefaults.standard

    init() {
        gamePath = defaults.string(forKey: "gamePath") ?? Const.defaultGame
        refresh()
        checkForUpdates()
    }

    var binaryPath: String { "\(gamePath)/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077" }
    var red4Dir: String { "\(gamePath)/red4ext" }
    var gameFound: Bool { FileManager.default.fileExists(atPath: binaryPath) }

    // the three dylibs DYLD_INSERT_LIBRARIES will load (must all exist before launch)
    var injectDylibs: [String] { ["RED4ext.dylib", "FridaGadget.dylib", "libcyberconsole_overlay.dylib"] }
    func fullyInstalled() -> Bool {
        let fm = FileManager.default
        return Const.payload.allSatisfy { fm.fileExists(atPath: "\(red4Dir)/\($0)") }
    }

    func setGamePath(_ p: String) {
        gamePath = p
        defaults.set(p, forKey: "gamePath")
        refresh()
    }

    func refresh() {
        gameVersion = readGameVersion()
        installed = fullyInstalled()
        if !gameFound {
            status = "Cyberpunk 2077 not found here - click Browse to locate it."
        } else {
            let v = gameVersion.map { " (v\($0))" } ?? ""
            status = "Game found\(v)" + (installed ? " · NightCity Console installed" : " · not installed yet")
        }
    }

    // Best-effort GitHub Releases check. Silent on any failure (offline, rate limit, parse error).
    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/\(Const.repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("nightcity-console-update-check", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  Model.isNewer(tag, than: Const.appVersion) else { return }
            var dl = (obj["html_url"] as? String) ?? "https://github.com/\(Const.repo)/releases/latest"
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets where (a["name"] as? String)?.lowercased().hasSuffix(".dmg") == true {
                    if let u = a["browser_download_url"] as? String { dl = u; break }
                }
            }
            DispatchQueue.main.async {
                self.updateText = "Update available: \(tag). Download the new version and replace the app."
                self.updateURL = dl
            }
        }.resume()
    }

    // Compare dotted version tags (leading v/V tolerated). Returns true if `tag` > `current`.
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func readGameVersion() -> String? {
        let plist = "\(gamePath)/Cyberpunk2077.app/Contents/Info.plist"
        guard let d = NSDictionary(contentsOfFile: plist) else { return nil }
        return d["CFBundleShortVersionString"] as? String
    }

    func install() {
        guard gameFound else { status = "Game not found."; return }
        guard let res = Bundle.main.resourceURL else { status = "Bundle resources missing."; return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: red4Dir, withIntermediateDirectories: true)
            for f in Const.payload {
                let src = res.appendingPathComponent(f)
                guard fm.fileExists(atPath: src.path) else { status = "Missing bundled file: \(f)"; return }
                let dst = URL(fileURLWithPath: "\(red4Dir)/\(f)")
                if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                try fm.copyItem(at: src, to: dst)
            }
            stripQuarantine(red4Dir)   // files we just wrote -> make dyld load them
            guard ensureGameEntitlements() else { return }   // status set on failure
            status = "Installed - click Play."
            refresh()
        } catch {
            status = "Install failed: \(error.localizedDescription)"
        }
    }

    // Stock Cyberpunk ships signed with only allow-dyld-environment-variables + disable-library-validation.
    // Frida is a JIT: it writes machine code at runtime. Without allow-jit / allow-unsigned-executable-memory
    // the OS code-signing monitor SIGKILLs the game (CODESIGNING, Invalid Page) the instant Frida generates
    // code. We re-sign the game binary ad-hoc with those entitlements. No SIP changes. Fully reversible:
    // Steam "Verify integrity of game files" restores the original signature (and a later Play re-applies this).
    @discardableResult
    func ensureGameEntitlements() -> Bool {
        if gameHasJITEntitlement() { return true }   // already done; skip the (re)sign
        let ents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
        <key>com.apple.security.cs.allow-jit</key><true/>
        <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
        <key>com.apple.security.cs.disable-executable-page-protection</key><true/>
        <key>com.apple.security.cs.disable-library-validation</key><true/>
        </dict></plist>
        """
        let plistPath = NSTemporaryDirectory() + "nightcity-entitlements.plist"
        do { try ents.write(toFile: plistPath, atomically: true, encoding: .utf8) }
        catch { status = "Could not prepare entitlements: \(error.localizedDescription)"; return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-f", "-s", "-", "--entitlements", plistPath, binaryPath]
        let err = Pipe(); p.standardError = err
        do { try p.run(); p.waitUntilExit() }
        catch { status = "Could not run codesign: \(error.localizedDescription)"; return false }
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            status = "Re-signing the game failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
            return false
        }
        return true
    }

    // True if the game binary already carries the JIT entitlement (so we can skip re-signing).
    func gameHasJITEntitlement() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-d", "--entitlements", ":-", binaryPath]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return s.contains("allow-jit")
    }

    func uninstall() {
        let fm = FileManager.default
        for f in Const.payload {
            let p = "\(red4Dir)/\(f)"
            if fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
        }
        // also clear any wrapper left over from earlier builds
        let wrap = "\(red4Dir)/cyberconsole-launch.sh"
        if fm.fileExists(atPath: wrap) { try? fm.removeItem(atPath: wrap) }
        status = "Uninstalled."
        refresh()
    }

    func stripQuarantine(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", path]
        try? p.run()
        p.waitUntilExit()
    }

    func ensureSteam() {
        let ws = NSWorkspace.shared
        let running = ws.runningApplications.contains { $0.bundleIdentifier == "com.valvesoftware.steam" }
        if !running, let steam = ws.urlForApplication(withBundleIdentifier: "com.valvesoftware.steam") {
            ws.openApplication(at: steam, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    func play() {
        guard gameFound else { status = "Game not found."; return }
        if !fullyInstalled() { install() }   // self-heal stale/partial installs
        // pre-flight: every injected dylib must exist, or the game aborts on launch
        let fm = FileManager.default
        let missing = injectDylibs.filter { !fm.fileExists(atPath: "\(red4Dir)/\($0)") }
        guard missing.isEmpty else { status = "Can't launch - missing: \(missing.joined(separator: ", ")). Try Install again."; return }
        guard ensureGameEntitlements() else { return }   // re-sign if a Steam verify/update reset it
        ensureSteam()
        let inject = "\(red4Dir)/RED4ext.dylib:\(red4Dir)/FridaGadget.dylib:\(red4Dir)/libcyberconsole_overlay.dylib"
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = inject
        env["DYLD_FORCE_FLAT_NAMESPACE"] = "1"
        env["SteamAppId"] = "1091500"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.currentDirectoryURL = URL(fileURLWithPath: gamePath)
        p.environment = env
        do {
            try p.run()
            status = "Launched - press  `  or  F1  in-game to open the console."
        } catch {
            status = "Launch failed: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject private var m = Model()

    var versionMismatch: Bool {
        guard let v = m.gameVersion else { return false }
        return m.gameFound && v != Const.supportedGameVersion
    }

    // Steam installs always live under a "steamapps" path; anything else (e.g. GOG) is not supported yet.
    var nonSteam: Bool { m.gameFound && !m.gamePath.contains("steamapps") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NightCity Console").font(.largeTitle.bold())
            Text("In-game cheat console for Cyberpunk 2077 · macOS").foregroundColor(.secondary)
            Divider()

            if let ut = m.updateText {
                HStack {
                    Label(ut, systemImage: "arrow.down.circle.fill").font(.callout).foregroundColor(.green)
                    Spacer()
                    if let u = m.updateURL, let url = URL(string: u) { Link("Download", destination: url) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("GAME FOLDER").font(.caption2).foregroundColor(.secondary)
                HStack {
                    Text(m.gamePath)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Browse…") { browse() }
                }
            }

            if versionMismatch, let v = m.gameVersion {
                Label("Detected game v\(v); NightCity Console targets v\(Const.supportedGameVersion). It may not work.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundColor(.orange)
            }
            if nonSteam {
                Label("Only the Steam version is supported right now. GOG support is in progress.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundColor(.orange)
            }

            HStack(spacing: 12) {
                Button(m.installed ? "Reinstall NightCity Console" : "Install") { m.install() }
                    .disabled(!m.gameFound)
                Button("Play  ▶") { m.play() }
                    .disabled(!m.installed)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Uninstall NightCity Console") { m.uninstall() }
                    .disabled(!m.installed)
            }

            Spacer()
            HStack {
                Text(m.status).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Link("Commands", destination: URL(string: Const.commandsURL)!)
                Link("♥ Support", destination: URL(string: Const.supportURL)!)
            }
            Text("Steam version only for now · GOG support in progress").font(.caption2).foregroundColor(.secondary)
            Text("Single-player only · back up your saves").font(.caption2).foregroundColor(.secondary)
        }
        .padding(22)
        .frame(width: 600, height: 380)
    }

    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Select your 'Cyberpunk 2077' folder"
        if panel.runModal() == .OK, let url = panel.url { m.setGamePath(url.path) }
    }
}

@main
struct CyberConsoleApp: App {
    var body: some Scene {
        WindowGroup("NightCity Console") {
            ContentView()
        }
    }
}
