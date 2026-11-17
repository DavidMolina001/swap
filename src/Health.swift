// The nightly check: `Swap --health <json path>`. For each app a provider reads: is it running, its version, and
// each interface structure the provider depends on. Read-only: Accessibility attributes and, where already allowed,
// a scripting read. Nothing is pressed, opened, focused or typed. The file holds booleans, versions and bundle ids,
// never chat names, message text, tab addresses or conversation ids. See Behind the scenes/qa/nightly.
// Knows no app by name. A provider's `health` may add "info.skipWeb": true when its windows hold other people's
// pages that a structure sketch must stay out of.
import AppKit
import ApplicationServices

enum Health {
    static func run(to path: String, sketch: Bool) -> Never {
        _ = NSApplication.shared
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { exit(4) }   // a hung app never holds the run
        let trusted = AXIsProcessTrusted()
        var apps: [String: Any] = [:]
        for provider in Children.sources {
            for id in provider.bundleIDs.sorted() {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
                guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
                var entry: [String: Any] = ["name": url.deletingPathExtension().lastPathComponent,
                                            "provider": "src/\(provider).swift",   // the file a repair may change; providers live in a file of their name
                                            "version": Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"]
                if let running {
                    if trusted {
                        var checks = provider.health(app: running)
                        if checks.isEmpty { continue }   // this provider reads nothing that can break
                        let skipWeb = checks.removeValue(forKey: "info.skipWeb") ?? false
                        entry["status"] = "checked"
                        entry["checks"] = checks
                        if sketch { entry["structure"] = structure(of: running, skipWeb: skipWeb) }
                    } else {
                        entry["status"] = "noAccess"
                    }
                } else {
                    entry["status"] = "skipped"
                }
                apps[id] = entry
            }
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let report: [String: Any] = [
            "swapVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? appVersion,
            "time": ISO8601DateFormatter().string(from: Date()),
            "accessibility": trusted,
            "screenLocked": session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
            "displayAsleep": CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            // Desktops as Swap sees them: counts only, so a tester's report can show why pages are missing.
            "desktops": [
                "spacesReadable": Spaces.available,
                "displays": NSScreen.screens.count,
                "separateSpaces": NSScreen.screensHaveSeparateSpaces,
                "onMainDisplay": Spaces.desktops()?.list.count ?? 0,
                "fullScreen": Spaces.desktops()?.list.filter { $0.fullScreen }.count ?? 0,
            ] as [String: Any],
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "apps": apps,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { exit(1) }
        exit(0)
    }

    // The app's windows: what Accessibility lists, or, when it lists none, the ones on other desktops, found the way
    // the list finds them (Spaces.swift). A Slack kept on another desktop still gets checked.
    static func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &ref) == .success, let listed = ref as? [AXUIElement], !listed.isEmpty { return listed }
        return Spaces.findAllWindows(pid: app.processIdentifier).map { $0.1 }
    }

    // Structure names for a repair run: how many elements of each role, and the identifiers and class names of the
    // app's own interface. Titles, values and descriptions are only compared against, in memory, so that a name
    // holding on-screen text is dropped. DOM ids (conversation ids) are never read. Browser pages are not entered.
    private static func structure(of app: NSRunningApplication, skipWeb: Bool) -> [String: Any] {
        func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
            var r: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, a as CFString, &r) == .success ? r : nil
        }
        var roles: [String: Int] = [:], names = Set<String>(), shown = Set<String>()
        var visited = 0
        let deadline = Date().addingTimeInterval(10)
        let skipped: Set<String> = skipWeb ? ["AXList", "AXTextArea", "AXTextField", "AXWebArea"] : ["AXList", "AXTextArea", "AXTextField"]
        func walk(_ el: AXUIElement, _ depth: Int) {
            if depth > 30 || visited > 4000 || Date() > deadline { return }
            visited += 1
            let role = attr(el, kAXRoleAttribute) as? String ?? "none"
            roles[role, default: 0] += 1
            for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let s = attr(el, a) as? String, s.count >= 3 { shown.insert(s.lowercased()) }
            }
            let own = attr(el, "AXIdentifier") as? String ?? ""
            if own == "ChatMessagesTableView" || skipped.contains(role) { return }
            if !own.isEmpty { names.insert(own) }
            names.formUnion(attr(el, "AXDOMClassList") as? [String] ?? [])
            for k in attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(k, depth + 1) }
        }
        for w in windows(of: app).prefix(3) { walk(w, 0) }
        func safe(_ n: String) -> Bool {
            n.range(of: #"^[A-Za-z][A-Za-z0-9_-]{2,63}$"#, options: .regularExpression) != nil
                && n.range(of: #"\d{3}"#, options: .regularExpression) == nil
                && n.range(of: #"^[A-Z0-9]+$"#, options: .regularExpression) == nil
                && !shown.contains { n.lowercased().contains($0) }
        }
        return ["roles": roles, "names": Array(names.filter(safe).sorted().prefix(400)), "nodes": visited]
    }
}
