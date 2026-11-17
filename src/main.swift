import AppKit
import ApplicationServices
import ServiceManagement
import UserNotifications

let appVersion = "0.9.2"

// The one-time "Allow" box before the Downloads widget is switched on (menu and Settings share it). The
// first folder read afterwards is what makes macOS ask for Downloads access, so the user hears about it first.
enum GlanceConsent {
    private static let key = "glanceDownloadsAllowed"
    static var downloadsAllowed: Bool { UserDefaults.standard.bool(forKey: key) }

    // Returns true when the widget may be added: already allowed earlier, or Allow was clicked now.
    @discardableResult
    static func askDownloads(from window: NSWindow? = nil) -> Bool {
        if downloadsAllowed { return true }
        let alert = NSAlert()
        alert.messageText = "Swap will read your Downloads folder to count files still downloading. macOS will ask you to allow it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        if window == nil { NSApp.activate(ignoringOtherApps: true) }   // from the menu bar there is no window to sit on
        let allowed = alert.runModal() == .alertFirstButtonReturn
        if allowed { UserDefaults.standard.set(true, forKey: key) }
        return allowed
    }
}

// A yes/no shared between the keyboard tap's thread and the main thread.
func writeSnapshot(to path: String, glance: [Glance.Reading]? = nil) {
    func icon(_ file: String) -> NSImage { NSWorkspace.shared.icon(forFile: file) }
    let bar: [Glance.Reading]? = glance ?? (Settings.glanceBar ? Glance.samples(Settings.glanceWidgetList) : nil)
    let sample: [(String, String, String, Bool)] = [
        ("Safari", "Swap: an open source window switcher for macOS", "/Applications/Safari.app", false),
        ("Mail", "Inbox (3 new)", "/System/Applications/Mail.app", false),
        ("Terminal", "swap — zsh — 120×32", "/System/Applications/Utilities/Terminal.app", false),
        ("Finder", "Projects", "/System/Library/CoreServices/Finder.app", false),
        ("Notes", "A very long note title that is far too long to fit in one row of the list and gets cut off", "/System/Applications/Notes.app", false),
        ("Safari", "Start Page", "/Applications/Safari.app", false),
        ("Calendar", "October 2026", "/System/Applications/Calendar.app", true),
        ("Photos", "Library", "/System/Applications/Photos.app", false),
    ]
    var items = sample.map { WindowItem(app: nil, window: nil, id: 0, title: $0.1, appName: $0.0, icon: icon($0.2), minimized: $0.3) }
    var selected = 1
    #if SELFTEST
    if ProcessInfo.processInfo.environment["SWAP_SNAPSHOT_SCENE"] == "children" { items = Scene.childrenRows(); selected = 2 }   // QA builds only
    #endif
    let view = SwitcherView(items: items, selected: selected, screen: nil, solidBackground: true,
                            header: SwitcherView.Header(title: "Desktop 1", index: 0, count: 3, emptyHint: nil),
                            glance: bar)
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

let args = CommandLine.arguments
// --prime-permissions: ask macOS now for every permission the tab features need (Automation for each
// installed browser), so the user answers all the prompts in one sitting. Browsers that are not running
// are started hidden for the question and quit again. Prints one line per browser and exits.
// --update-check: print what Check for Updates would find. --update-install: also install it in place (no relaunch).
// For tests and support; the app itself uses the menu item.
if args.contains("--update-check") || args.contains("--update-install") {
    _ = NSApplication.shared
    let install = args.contains("--update-install")
    Updater.shared.check { result in
        switch result {
        case .upToDate(let v): print("up to date: \(v)"); exit(0)
        case .failed(let why): print("failed: \(why)"); exit(1)
        case .available(let v, let dmg, _):
            print("available: \(v) \(dmg.absoluteString)")
            guard install else { exit(0) }
            Updater.shared.install(version: v, dmg: dmg, relaunch: false) { why in
                if let why { print("install failed: \(why)"); exit(2) }
                print("installed: \(v) at \(Bundle.main.bundlePath)"); exit(0)
            }
        }
    }
    RunLoop.main.run()
}
if args.contains("--prime-permissions") {
    _ = NSApplication.shared
    // Launched with `open` (so macOS credits the prompts to Swap, not to a terminal), it reports to a log.
    let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Swap-permissions.log")
    try? "".write(to: logURL, atomically: true, encoding: .utf8)
    func report(_ s: String) {
        print(s)
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); h.closeFile() }
    }
    report("Accessibility: \(AXIsProcessTrusted() ? "on" : "OFF")")
    let browsers = [("com.google.Chrome", "Google Chrome"), ("com.apple.Safari", "Safari"),
                    ("com.microsoft.edgemac", "Microsoft Edge"), ("com.brave.Browser", "Brave Browser")]
    for (id, name) in browsers {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { report("\(name): not installed"); continue }
        var startedHere = false
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false; cfg.hides = true
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 15)
            startedHere = true
            Thread.sleep(forTimeInterval: 3)
        }
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application id \"\(id)\" to count windows")
        let result = script?.executeAndReturnError(&error)
        if let error = error { report("\(name): \(error[NSAppleScript.errorMessage] ?? error)") }
        else { report("\(name): ok, \(result?.int32Value ?? 0) windows") }
        if startedHere { NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() } }
    }
    report("done")
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
    _ = NSApplication.shared
    writeSnapshot(to: args[i + 1])
    exit(0)
}

Children.sources = [BrowserTabs.self, SlackSource.self, WhatsAppSource.self, FinderProvider.self]
if let i = args.firstIndex(of: "--health"), args.count > i + 1 { Health.run(to: args[i + 1], sketch: args.contains("--sketch")) }   // nightly check, read-only
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
