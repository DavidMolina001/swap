#if SELFTEST
// QA driver, compiled only into QA builds (-D SELFTEST). `--hook <dir>` makes Swap QA watch <dir>/cmd:
// testers over SSH write one command there (the `ctl` script does this), Swap QA runs it, writes the
// result to <dir>/out and touches <dir>/done. Real keystrokes go through the event tap like a person's.
// `Scene` swaps the real window list for fixtures (many windows, long titles, several desktops...).
import AppKit
import ScreenCaptureKit

enum Scene {
    static var current: (pages: [Windows.Page], current: Int)?

    static let names = ["one", "few", "twelve", "sixty", "longtitles", "unicode", "minimised", "desktops3",
                        "fullscreen", "emptydesk", "nodesktops", "desktops8"]

    static func icon(_ app: String) -> NSImage {
        for dir in ["/System/Applications", "/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices"] {
            let p = "\(dir)/\(app).app"
            if FileManager.default.fileExists(atPath: p) { return NSWorkspace.shared.icon(forFile: p) }
        }
        return NSWorkspace.shared.icon(forFile: "/System/Applications/TextEdit.app")
    }

    static var nextId: CGWindowID = 900_000
    static func item(_ app: String, _ title: String, minimized: Bool = false) -> WindowItem {
        nextId += 1
        return WindowItem(app: nil, window: nil, id: nextId, title: title, appName: app, icon: icon(app), minimized: minimized)
    }

    // Drill-in look: a Chrome window open on its tabs, Slack folded, the rest plain.
    static func childrenRows() -> [WindowItem] {
        var chrome = item("Google Chrome", "Acme - Calendar - Week of 1 November 2026")
        chrome.expandable = true; chrome.expanded = true; chrome.profile = "Work"
        let tabs: [(String, String, Bool)] = [("Acme - Calendar", "calendar.google.com", true), ("Inbox (17) - jo@example.com", "mail.google.com", false),
                                              ("Northwind budget tracker", "docs.google.com", false)]
        let kids = tabs.enumerated().map { i, t -> WindowItem in
            let kid = ChildItem(id: t.0, title: t.0, detail: t.1, icon: nil, active: t.2, unread: 0)
            return WindowItem(app: nil, window: nil, id: chrome.id, title: t.0, appName: "Google Chrome", icon: icon("Google Chrome"), minimized: false,
                              depth: 1, child: kid, parentKey: chrome.key, pinned: i == 0)
        }
        var slack = item("Slack", "Acme")
        slack.expandable = true; slack.workspace = "Acme"
        var slack2 = item("Slack", "Northwind")
        slack2.expandable = true; slack2.workspace = "Northwind"
        return [item("Notes", "Launch plan"), chrome] + kids + [slack, item("Terminal", "swap: zsh, 120×32"), slack2, item("Finder", "Projects")]
    }

    static func set(_ name: String) -> Bool {
        if name == "off" { current = nil; return true }
        let basics: [(String, String)] = [
            ("Safari", "Swap: an open source window switcher for macOS"), ("Mail", "Inbox (3 new)"),
            ("Terminal", "swap — zsh — 120×32"), ("Finder", "Projects"), ("Notes", "Shopping list"),
            ("Calendar", "October 2026"), ("Photos", "Library"), ("Music", "Music"), ("Messages", "Messages"),
            ("TextEdit", "Untitled 2"), ("Preview", "Report.pdf"), ("System Settings", "Privacy & Security"),
        ]
        func page(_ title: String, _ items: [WindowItem]) -> Windows.Page { Windows.Page(title: title, items: items) }
        func many(_ n: Int) -> [WindowItem] { (0..<n).map { i in let b = basics[i % basics.count]; return item(b.0, n > basics.count ? "\(b.1) \(i / basics.count + 1)" : b.1) } }
        switch name {
        case "one": current = ([page("", [item("Safari", "Start Page")])], 0)
        case "children": current = ([page("Desktop 1", Scene.childrenRows())], 0)
        case "few": current = ([page("", many(4))], 0)
        case "twelve": current = ([page("", many(12))], 0)
        case "sixty": current = ([page("", many(60))], 0)
        case "longtitles": current = ([page("", [
            item("Safari", "A very long window title that is far too long to fit in one row of the list and gets cut off at the end, surely"),
            item("Google Chrome", "Meet – weekly planning – Camera and microphone recording – Google Chrome – Personal (Work)"),
            item("Terminal", "swap"), item("Xcode", "Swap — Panel.swift — Edited"),
            item("Finder", ""), item("Notes", "   "),
        ])], 0)
        case "unicode": current = ([page("", [
            item("Notes", "Résumé café naïve façade"), item("Safari", "日本語のウィンドウタイトル"), item("Mail", "Письмо от Марии"),
            item("TextEdit", "مرحبا بالعالم"), item("Messages", "Emoji 🎉🚀 title"), item("Finder", "שלום עולם"),
        ])], 0)
        case "minimised": current = ([page("", [
            item("Safari", "Start Page"), item("Mail", "Inbox", minimized: true), item("Notes", "Ideas", minimized: true),
            item("Terminal", "zsh"), item("Photos", "Library", minimized: true),
        ])], 0)
        case "desktops3": current = ([
            page("Desktop 1", many(5)), page("Desktop 2", [item("Xcode", "Swap — main.swift"), item("Terminal", "build")]),
            page("Desktop 3", [item("Music", "Music")])], 0)
        case "desktops8": current = ((1...8).map { n in page("Desktop \(n)", n == 4 ? [] : Array(many(12).prefix(n + 1))) }, 5)
        case "fullscreen": current = ([
            page("Desktop 1", many(3)), page("Safari", [item("Safari", "YouTube")]), page("Desktop 2", many(2))], 0)
        case "emptydesk": current = ([page("Desktop 1", many(3)), page("Desktop 2", [])], 0)
        case "nodesktops": current = ([page("", many(6))], 0)
        default: return false
        }
        return true
    }
}

enum Hook {
    static var dir = ""
    static let worker = DispatchQueue(label: "swap.hook")

    static func start(_ d: String) {
        dir = d
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        for f in ["cmd", "out", "done"] { try? FileManager.default.removeItem(atPath: "\(d)/\(f)") }
        try? "ready".write(toFile: "\(d)/status", atomically: true, encoding: .utf8)
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in poll() }
        RunLoop.main.add(t, forMode: .common)   // keeps answering while a menu is open
    }

    static func poll() {
        let path = "\(dir)/cmd"
        guard let cmd = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: "\(dir)/done")
        worker.async {
            let out = run(cmd.trimmingCharacters(in: .whitespacesAndNewlines))
            try? out.write(toFile: "\(dir)/out", atomically: true, encoding: .utf8)
            try? "".write(toFile: "\(dir)/done", atomically: true, encoding: .utf8)
        }
    }

    static func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }

    static func json(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    static func state() -> [String: Any] {
        onMain {
            let c = Controller.shared
            let p = c.panel
            return [
                "active": c.isActive, "panelVisible": p.isVisible, "showCount": c.showCount,
                "slide": c.slideState, "headerTitle": p.switcher?.header?.title ?? "",
                "page": c.page, "pageTitle": c.pageTitle, "pageCount": c.pageCount, "selection": c.selection,
                "selected": c.selectedItem.map { ["app": $0.appName, "title": $0.title] } ?? NSNull(),
                "panelFrame": p.isVisible ? ["x": p.frame.minX, "y": p.frame.minY, "w": p.frame.width, "h": p.frame.height] : NSNull(),
                "rows": (p.switcher?.rows.items ?? []).map { ["app": $0.appName, "title": $0.title, "minimised": $0.minimized,
                                                               "depth": $0.depth, "expandable": $0.expandable, "expanded": $0.expanded,
                                                               "workspace": $0.workspace ?? NSNull(), "pinned": $0.pinned, "opens": $0.opens?.path ?? NSNull()] },
                "search": ["row": p.switcher?.searchRow != nil, "onRow": c.search.onRow, "typing": c.search.typing, "query": c.search.query,
                           "panelKey": p.isKeyWindow, "swapActive": NSRunningApplication.current.isActive,
                           "focusedApp": SelfTest.focusedApp(), "field": p.switcher?.searchRow?.field?.stringValue ?? NSNull(),
                           "rowState": p.switcher?.searchRow.map { "\($0.state)" } ?? NSNull()],
                "refused": c.lastRefusal, "holdingKeys": AppCommand.holding,
                "scene": Scene.current == nil ? NSNull() : "on",
                "trusted": AXIsProcessTrusted(), "tap": c.tap != nil, "pinned": c.isPinned,
                "appearance": Settings.appearance.rawValue, "dark": Settings.isDark, "dots": Settings.dots.rawValue, "panelWidth": Settings.panelWidth.rawValue,
                "glance": ["on": Settings.glanceBar, "density": Settings.glanceDensity.rawValue, "widgets": Settings.glanceWidgets,
                           "override": GlanceEngine.shared.override != nil, "timerRunning": GlanceTimer.shared.isRunning,
                           "barHeight": p.switcher?.glanceHeight ?? 0,
                           "shown": (p.switcher?.glanceReadings ?? []).map { ["widget": $0.widget.rawValue, "value": $0.value, "level": $0.level.rawValue] }],
                "settings": ["shortcut": Settings.shortcut.rawValue, "quickFlip": Settings.quickFlip, "numberKeys": Settings.numberKeys, "actionKeys": Settings.actionKeys,
                             "keepOpen": Settings.keepOpen, "desktops": Settings.desktops.rawValue, "hideEmptyDesktops": Settings.hideEmptyDesktops,
                             "showMinimised": Settings.showMinimised, "showHidden": Settings.showHidden, "showAppName": Settings.showAppName,
                             "hiddenApps": Settings.hiddenApps, "hideUntitled": Settings.hideUntitled,
                             "drillIn": Settings.drillIn, "childOrder": Settings.childOrder == .recent ? "recent" : "natural",
                             "slackWorkspaces": Settings.slackWorkspaces, "slackHidden": Settings.slackHidden, "pins": Settings.pins],
            ]
        }
    }

    // Comma-separated real-input tokens: optdown optup tab shifttab up down left right esc return shiftreturn
    // w q swipeleft swiperight click:<row> wait:<ms>. Search: plain:<keycode> (no Option held), type:<text> (only while
    // Swap's own search field has the keyboard, so nothing can land in another app)
    static func keys(_ seq: String) -> String {
        var done: [String] = []
        for raw in seq.split(separator: ",") {
            let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch t {
            case "optdown": SelfTest.flags(option: true)
            case "optup": SelfTest.flags(option: false)
            case "tab": SelfTest.tab()
            case "shifttab": SelfTest.flags(option: true, shift: true); SelfTest.tab(shift: true)
            case "up": SelfTest.key(126)
            case "down": SelfTest.key(125)
            case "left": SelfTest.key(123)
            case "right": SelfTest.key(124)
            case "esc": SelfTest.key(53)
            case "return": SelfTest.key(36)
            case "shiftreturn": SelfTest.key(36, shift: true)
            case "p": SelfTest.key(35)
            case "n": SelfTest.key(45)
            case let t where t.hasPrefix("key:"): SelfTest.key(CGKeyCode(t.dropFirst(4)) ?? 0)
            case "w": SelfTest.key(13)
            case "q": SelfTest.key(12)
            case let t where t.hasPrefix("plain:"):
                guard onMain({ Controller.shared.panel.isKeyWindow }) else { return "error: search field does not have the keyboard" }
                SelfTest.plain(CGKeyCode(t.dropFirst(6)) ?? 0)
            case let t where t.hasPrefix("cmd:"):
                guard onMain({ Controller.shared.panel.isKeyWindow }) else { return "error: search field does not have the keyboard" }
                SelfTest.plain(CGKeyCode(t.dropFirst(4)) ?? 0, flags: .maskCommand)
            case let t where t.hasPrefix("type:"):
                guard SelfTest.typeText(String(t.dropFirst(5))) else { return "error: search field does not have the keyboard" }
            case "dragbegin": SelfTest.dragBegin()
            case "dragend": SelfTest.dragEnd()
            case let t where t.hasPrefix("drag:"): SelfTest.drag(fingers: Int32(t.dropFirst(5)) ?? 0)
            case "swipeleft": SelfTest.swipe(fingersLeft: true)
            case "swiperight": SelfTest.swipe(fingersLeft: false)
            default:
                if t.hasPrefix("wait:"), let ms = Int(t.dropFirst(5)) { usleep(UInt32(max(0, ms)) * 1000) }
                else if t.hasPrefix("key:"), let code = UInt16(t.dropFirst(4)) { SelfTest.key(code) }   // any key, with Option held
                else if t.hasPrefix("click:"), let row = Int(t.dropFirst(6)) {
                    let pt: CGPoint? = onMain {
                        guard let rows = Controller.shared.panel.switcher?.rows, let r = rows.rowRect(row), let win = rows.window else { return nil }
                        let s = win.convertToScreen(rows.convert(r, to: nil))
                        return CGPoint(x: s.midX, y: NSScreen.screens[0].frame.height - s.midY)
                    }
                    if let pt { SelfTest.click(at: pt) } else { return "error: row \(row) not on screen" }
                } else { return "error: unknown token \(t)" }
            }
            done.append(t)
            usleep(120_000)
        }
        return "ok " + done.joined(separator: " ")
    }

    static func run(_ cmd: String) -> String {
        let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        switch name {
        case "ping": return "pong \(appVersion)"
        case "state": return json(state())
        case "front": return SelfTest.front()
        case "list":
            let p = onMain { Windows.pages() }
            return json(["current": p.current, "pages": p.pages.map { ["title": $0.title, "items": $0.items.map { ["app": $0.appName, "title": $0.title, "minimised": $0.minimized, "id": Int($0.id)] }] }])
        case "keys": return keys(arg)
        case "scene":
            let ok = onMain { Scene.set(arg) }
            return ok ? "ok scene \(arg)" : "error: scenes are \(Scene.names.joined(separator: " ")) off"
        case "scenes": return Scene.names.joined(separator: " ")
        case "snapshot": return snapshot(arg)
        case "screenshot":   // screenshot <png> [panel|settings]: whole display, or cropped to the panel / the Settings window
            let a = arg.split(separator: " ").map(String.init)
            return screenshot(path: a.first ?? "", crop: a.count > 1 ? a.dropFirst().joined(separator: " ") : "")
        case "settings":   // settings <tab 0-4|close>: open the Settings window on that tab (or close it)
            return onMain {
                if arg == "close" { SettingsWindowController.shared.window?.orderOut(nil); return "ok closed" }
                SettingsWindowController.shared.show(tab: Int(arg) ?? 0)
                let f = SettingsWindowController.shared.window?.frame ?? .zero
                return "ok settings tab \(Int(arg) ?? 0) frame \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
            }
        case "press":   // press <button title>: push that button in any sheet or dialog of any app (e.g. "Don't Save")
            guard !arg.isEmpty else { return "error: press <button title>" }
            var n = 0
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let el = AXUIElementCreateApplication(app.processIdentifier)
                var targets = (SelfTest.ax(el, kAXWindowsAttribute) as? [AXUIElement]) ?? []
                for w in targets { if let sheets = SelfTest.ax(w, "AXSheets") as? [AXUIElement] { targets += sheets } }
                for t in targets {
                    for b in (SelfTest.ax(t, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                        guard (SelfTest.ax(b, kAXRoleAttribute) as? String) == kAXButtonRole,
                              (SelfTest.ax(b, kAXTitleAttribute) as? String) == arg else { continue }
                        if AXUIElementPerformAction(b, kAXPressAction as CFString) == .success { n += 1 }
                    }
                }
            }
            return "ok pressed \(n)"
        case "glance":   // glance <normal|busy|idle|none|live|off>: fixtures for the bar (live = real readings), off = bar off
            return onMain {
                let e = GlanceEngine.shared
                switch arg {
                case "off": Settings.glanceBar = false; e.override = nil
                case "live": Settings.glanceBar = true; e.override = nil
                case "none": Settings.glanceBar = true; e.override = []
                case "normal", "busy", "idle":
                    Settings.glanceBar = true
                    var r = Glance.samples(Settings.glanceWidgetList, busy: arg == "busy")
                    if arg == "idle" { r = r.map { var x = $0; if x.widget == .timer || x.widget == .downloads { x.idle = true }; return x } }
                    e.override = r
                default: return "error: glance normal|busy|idle|none|live|off"
                }
                return "ok glance \(arg)"
            }
        case "timer":   // timer <minutes|stop>: the glance timer, as the menu would
            return onMain {
                if arg == "stop" { GlanceTimer.shared.stop(); return "ok timer stopped" }
                guard let m = Double(arg), m > 0 else { return "error: timer <minutes|stop>" }
                GlanceTimer.shared.start(minutes: m); return "ok timer \(m) min"
            }
        case "statusitem":   // frame of Swap's menu bar item in points, top-left origin: "x y w h"
            return onMain {
                guard let w = NSApp.windows.first(where: { NSStringFromClass(type(of: $0)).contains("NSStatusBarWindow") }),
                      let h = NSScreen.main?.frame.height else { return "error: no status item window" }
                let f = w.frame
                return "\(Int(f.minX)) \(Int(h - f.maxY)) \(Int(f.width)) \(Int(f.height))"
            }
        case "filesearch":   // filesearch <text>: the file search on its own, no panel or keyboard. Prints the hits.
            let sem = DispatchSemaphore(value: 0)
            var hits: [FileHit] = []
            var engine: FileSearch?
            onMain { engine = FileSearch(); engine?.search(arg) { hits = $0; sem.signal() } }
            let t0 = Date()
            let answered = sem.wait(timeout: .now() + 4) == .success
            onMain { engine?.cancel() }
            return json(["answered": answered, "seconds": Date().timeIntervalSince(t0), "hits": hits.map { ["path": $0.path, "folder": $0.folder, "type": $0.type ?? "?"] }])
        case "showlist":   // open the list from the "menu", pinned until Esc or a pick
            onMain { Controller.shared.showFromMenu() }
            return "ok showlist"
        case "set":   // set <key> <value>: write one setting (bool, int or string) as Settings… would
            let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard a.count == 2 else { return "error: set <key> <value>" }
            let v: Any = a[1] == "true" ? true : a[1] == "false" ? false : (Int(a[1]).map { $0 as Any } ?? a[1])
            if a[1].hasPrefix("[") { UserDefaults.standard.set(a[1].dropFirst().dropLast().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }, forKey: a[0]) }
            else if a[1] == "nil" { UserDefaults.standard.removeObject(forKey: a[0]) }
            else { UserDefaults.standard.set(v, forKey: a[0]) }
            onMain { NotificationCenter.default.post(name: Settings.changed, object: nil) }
            return "ok set \(a[0]) \(a[1])"
        case "desktops":
            let d = Spaces.desktops()
            return json(["count": d?.list.count ?? 0, "current": d.map { x in x.list.firstIndex { $0.id == x.current } ?? -1 } ?? -1,
                         "fullScreen": d?.list.filter { $0.fullScreen }.count ?? 0])
        case "adddesktop": return addDesktop()
        case "close":   // close <title prefix>: press the close button of every window whose title starts with it
            guard !arg.isEmpty else { return "error: close <title prefix>" }
            var n = 0
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let el = AXUIElementCreateApplication(app.processIdentifier)
                for w in (SelfTest.ax(el, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
                    guard let t = SelfTest.ax(w, kAXTitleAttribute) as? String, t.hasPrefix(arg),
                          let b = SelfTest.ax(w, kAXCloseButtonAttribute) else { continue }
                    if AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success { n += 1 }
                }
            }
            return "ok closed \(n)"
        case "mouse":   // mouse <x> <y> [click]: move the pointer (Quartz points, top left origin), optionally click
            let a = arg.split(separator: " ").map(String.init)
            guard a.count >= 2, let x = Double(a[0]), let y = Double(a[1]) else { return "error: mouse <x> <y> [click]" }
            let pt = CGPoint(x: x, y: y)
            if a.count > 2 && a[2] == "click" { SelfTest.click(at: pt) }
            else { SelfTest.post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)) }
            return "ok mouse \(Int(x)) \(Int(y))\(a.count > 2 ? " click" : "")"
        case "syskey":   // syskey <keycode> [control|option|command|shift ...]: one key press with these modifiers
            let a = arg.split(separator: " ").map(String.init)
            guard let first = a.first, let code = UInt16(first) else { return "error: syskey <keycode> [modifiers]" }
            var f: CGEventFlags = []
            for m in a.dropFirst() {
                switch m { case "control": f.insert(.maskControl); case "option": f.insert(.maskAlternate)
                case "command": f.insert(.maskCommand); case "shift": f.insert(.maskShift); default: break }
            }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                e?.flags = f
                SelfTest.post(e)
            }
            return "ok syskey \(code)"
        case "quit": DispatchQueue.main.async { NSApp.terminate(nil) }; return "bye"
        default: return "error: commands are ping state front list keys <seq> scene <name|off> scenes snapshot <png> screenshot <png> [panel] desktops quit"
        }
    }

    // Opens Mission Control and presses its "add desktop" button through Accessibility (the Dock owns it).
    static func addDesktop() -> String {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return "error: no Dock" }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 126, keyDown: down)
            e?.flags = .maskControl
            e?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
        usleep(1_800_000)
        func find(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            var r: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success, (r as? String) == kAXButtonRole {
                var d: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &d)
                var t: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &t)
                let text = ((d as? String) ?? "") + " " + ((t as? String) ?? "")
                if text.lowercased().contains("add") { return el }
            }
            guard depth < 10 else { return nil }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let list = kids as? [AXUIElement] else { return nil }
            for k in list { if let f = find(k, depth + 1) { return f } }
            return nil
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 2)
        var result = "error: add button not found"
        if let b = find(app, 0) {
            // The button only appears when the pointer is near the top right; press works anyway.
            result = AXUIElementPerformAction(b, kAXPressAction as CFString) == .success ? "ok added" : "error: press failed"
        }
        usleep(1_200_000)
        for down in [true, false] {   // leave Mission Control
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)
            e?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
        usleep(800_000)
        return result
    }

    // Offscreen render of the panel as it is now (or of the current scene with row 1 selected).
    static func snapshot(_ path: String) -> String {
        guard !path.isEmpty else { return "error: path" }
        return onMain {
            let view: SwitcherView
            if let live = Controller.shared.panel.switcher { view = live }
            else {
                let p = Scene.current ?? Windows.pages()
                let items = p.pages[p.current].items
                view = SwitcherView(items: items, selected: items.count > 1 ? 1 : 0, screen: NSScreen.main, solidBackground: true,
                                    header: p.pages.count > 1 ? SwitcherView.Header(title: p.pages[p.current].title, index: p.current,
                                                                                    count: p.pages.count, emptyHint: nil) : nil)
            }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "error: render" }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return "error: png" }
            do { try png.write(to: URL(fileURLWithPath: path)); return "ok \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))" }
            catch { return "error: \(error)" }
        }
    }

    // Real picture of the main display (needs Screen Recording), optionally cropped to the panel.
    static func screenshot(path: String, crop: String) -> String {
        guard !path.isEmpty else { return "error: path" }
        guard #available(macOS 14.0, *) else { return "error: needs macOS 14" }
        let sem = DispatchSemaphore(value: 0)
        var result = "error: timeout"
        let panelOnly = crop == "panel" || crop == "settings"
        // Extra crops for the README pictures: rect:x,y,w,h (points, top-left origin), around:WxH (that size
        // centred on the panel), window:<App Name> (that app's front window, 8 pt margin).
        var fixedRect: CGRect?   // points, top-left origin
        if crop.hasPrefix("rect:") {
            let v = crop.dropFirst(5).split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { fixedRect = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        } else if crop.hasPrefix("window:") {
            let app = String(crop.dropFirst(7))
            let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            if let w = list.first(where: { ($0[kCGWindowOwnerName as String] as? String) == app && ($0[kCGWindowLayer as String] as? Int) == 0 }),
               let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
                fixedRect = CGRect(x: b["X"]! - 8, y: b["Y"]! - 8, width: b["Width"]! + 16, height: b["Height"]! + 16)
            } else { return "error: no window of \(app)" }
        }
        let panelFrame: NSRect? = (fixedRect != nil && !crop.hasPrefix("around:")) ? nil : onMain {
            if crop == "settings" { let w = SettingsWindowController.shared.window; return w?.isVisible == true ? w?.frame : nil }
            return Controller.shared.panel.isVisible ? Controller.shared.panel.frame : nil
        }
        if crop.hasPrefix("around:") {
            let v = crop.dropFirst(7).split(separator: "x").compactMap { Double($0) }
            guard v.count == 2, let f = panelFrame, let h = NSScreen.main?.frame.height else { return "error: around needs WxH and a visible panel" }
            fixedRect = CGRect(x: f.midX - v[0] / 2, y: (h - f.midY) - v[1] / 2, width: v[0], height: v[1])
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, err in
            guard let display = content?.displays.first else { result = "error: \(err?.localizedDescription ?? "no display")"; sem.signal(); return }
            let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
            let cfg = SCStreamConfiguration()
            cfg.width = display.width * scale; cfg.height = display.height * scale
            cfg.showsCursor = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, err in
                defer { sem.signal() }
                guard var cg = img else { result = "error: \(err?.localizedDescription ?? "capture failed")"; return }
                if let r0 = fixedRect {
                    let s = CGFloat(scale)
                    let r = CGRect(x: max(0, r0.minX) * s, y: max(0, r0.minY) * s, width: r0.width * s, height: r0.height * s)
                    if let c = cg.cropping(to: r) { cg = c }
                } else if panelOnly {
                    guard let f = panelFrame else { result = "error: \(crop) not visible"; return }
                    let h = CGFloat(display.height)
                    let r = CGRect(x: (f.minX - 8) * CGFloat(scale), y: (h - f.maxY - 8) * CGFloat(scale),
                                   width: (f.width + 16) * CGFloat(scale), height: (f.height + 16) * CGFloat(scale))
                    if let c = cg.cropping(to: r) { cg = c }
                }
                let rep = NSBitmapImageRep(cgImage: cg)
                guard let png = rep.representation(using: .png, properties: [:]) else { result = "error: png"; return }
                do { try png.write(to: URL(fileURLWithPath: path)); result = "ok \(path) \(cg.width)x\(cg.height)" }
                catch { result = "error: \(error)" }
            }
        }
        _ = sem.wait(timeout: .now() + 10)
        return result
    }
}
#endif
