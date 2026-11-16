#if SELFTEST
// Live end-to-end test, compiled only into QA builds (-D SELFTEST). It types real Option+Tab
// keystrokes, then checks which window ended up in front. Run on a test Mac only: it takes over
// the keyboard and mouse for about a minute. Results go to the log file given after --selftest.
import AppKit
import ApplicationServices

// A child source for the test: every TextEdit window has three parts, of which Gamma can be closed (a tab) and the
// others can't (chats). `opened` and `closed` record what the keys did. `empty` names a window with nothing inside.
// `calls` counts everything the list path asks of a provider: a quick flip must leave it at zero.
enum TestChildren: AppProvider {
    static var bundleIDs: Set<String> = ["com.apple.TextEdit"]
    static var opened: String?, closed: String?, empty: String?
    static var calls = 0
    static func children(of parent: ParentRef) -> [ChildItem] {
        if parent.title == empty { return [] }
        return ["Alpha", "Beta", "Gamma"].enumerated().map {
            ChildItem(id: $0.element, title: "\(parent.title) › \($0.element)", detail: "part", icon: nil, active: $0.offset == 0, unread: 0)
        }
    }
    static func open(_ child: ChildItem, in parent: ParentRef) { opened = child.id }
    static func canClose(_ child: ChildItem) -> Bool { child.id == "Gamma" }
    static func closeChild(_ child: ChildItem, in parent: ParentRef) -> Bool { closed = child.id; return true }
    static func addRows(to pages: [Windows.Page], current: Int) -> [Windows.Page] { calls += 1; return pages }
    static func arrange(_ rows: inout [WindowItem]) { calls += 1 }
    static func decorate(_ row: inout WindowItem, window: AXUIElement) { row.profile = "Test label" }
    static func prepare(_ item: WindowItem, expanding: Bool) -> TimeInterval { calls += 1; return 0 }
    static func sessionEnded() { calls += 1 }
}

enum SelfTest {
    static var logPath = ""
    static var queue: [(Double, () -> Void)] = []
    static var failures = 0

    static func log(_ s: String) {
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(toFile: logPath, atomically: true, encoding: .utf8) }
    }
    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        log("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    }

    // MARK: keyboard and mouse

    static let optionKey: CGKeyCode = 58, shiftKey: CGKeyCode = 56

    static func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(25_000) }
    static func flags(option: Bool, shift: Bool = false) {
        var f: CGEventFlags = []
        if option { f.insert(.maskAlternate) }
        if shift { f.insert(.maskShift) }
        let e = CGEvent(keyboardEventSource: nil, virtualKey: option ? optionKey : optionKey, keyDown: option)
        e?.type = .flagsChanged
        e?.flags = f
        post(e)
    }
    static func key(_ code: CGKeyCode, shift: Bool = false) {
        var f: CGEventFlags = [.maskAlternate]
        if shift { f.insert(.maskShift) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = f
            post(e)
        }
    }
    static func tab(shift: Bool = false) { key(48, shift: shift) }
    // A key held long enough to repeat: down, a repeat, then up, with Option held.
    static func heldKey(_ code: CGKeyCode) {
        for (down, again) in [(true, false), (true, true), (true, true), (false, false)] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = [.maskAlternate]
            if again { e?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            post(e)
            usleep(40_000)
        }
    }
    // A plain key to whatever has the keyboard. Only for closing a Find bar in the test's own TextEdit window.
    static func plainToApp(_ code: CGKeyCode) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else { return }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = []
            post(e)
        }
    }
    // Keys with no modifier, for the search field. Both refuse unless Swap's own panel has the keyboard, so a
    // test can never type into another app.
    static func plain(_ code: CGKeyCode, flags f: CGEventFlags = []) {
        guard Hook.onMain({ Controller.shared.panel.isKeyWindow }) else { log("plain key refused: the panel is not key"); return }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = f
            post(e)
        }
    }
    @discardableResult static func typeText(_ text: String) -> Bool {
        guard Hook.onMain({ Controller.shared.panel.isKeyWindow }) else { log("typing refused: the panel is not key"); return false }
        let keys: [Character: CGKeyCode] = ["a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46,
                                            "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6, " ": 49]
        for c in text {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: keys[c] ?? 49, keyDown: down)
                e?.flags = []
                var u = Array(String(c).utf16)
                e?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
                post(e)
            }
        }
        return true
    }
    // The app that has the keyboard, as the system sees it.
    static func focusedApp() -> String {
        guard let el = ax(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return "none" }
        var pid: pid_t = 0
        AXUIElementGetPid(el as! AXUIElement, &pid)
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }
    static func deskIndex() -> Int { Spaces.desktops().map { d in d.list.firstIndex { $0.id == d.current } ?? -1 } ?? -1 }
    // Control+Left/Right: the system shortcut that moves one desktop.
    static func controlArrow(_ code: CGKeyCode) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = [.maskControl, .maskSecondaryFn]
            post(e)
        }
    }
    static func click(at p: CGPoint) {
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
    }
    private static func scroll(_ dx: Int32, _ phase: Int64) -> CGEvent? {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)
        e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)   // 1 began, 2 changed, 4 ended
        e?.flags = .maskAlternate
        return e
    }

    // The same fingers one step at a time, so a test can look at the list half way. `fingers` left is negative.
    static func dragBegin() { post(scroll(0, 1)) }
    static func dragEnd() { post(scroll(0, 4)) }
    static func drag(fingers: Int32) {
        let inverted = scroll(10, 2).flatMap { NSEvent(cgEvent: $0)?.isDirectionInvertedFromDevice } ?? false
        post(scroll(fingers * (inverted ? 1 : -1), 2))
    }

    // A two-finger horizontal trackpad swipe while Option is held.
    static func swipe(fingersLeft: Bool) {
        let inverted = scroll(10, 2).flatMap { NSEvent(cgEvent: $0)?.isDirectionInvertedFromDevice } ?? false
        let dx: Int32 = (fingersLeft ? -15 : 15) * (inverted ? 1 : -1)
        post(scroll(0, 1))
        for _ in 0..<6 { post(scroll(dx, 2)) }
        post(scroll(0, 4))
    }
    // Bring a window forward the way a click would (raise it, make its app frontmost) without telling
    // Swap's recency tracker, so the tracker has to notice on its own.
    static func userFocus(_ item: WindowItem) {
        guard let app = item.app, let w = item.window else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
    static func order() -> String { Windows.list().map { $0.title.replacingOccurrences(of: "Swap test ", with: "") }.joined(separator: ", ") }


    // MARK: what is in front

    static func ax(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var r: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &r) == .success ? r : nil
    }
    // "App | window title" of the focused window of the frontmost app.
    static func front() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "none" }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var title = "?"
        if let w = ax(el, kAXFocusedWindowAttribute) { title = (ax(w as! AXUIElement, kAXTitleAttribute) as? String) ?? "" }
        return "\(app.localizedName ?? "?") | \(title)"
    }
    static func name(_ i: WindowItem) -> String { "\(i.appName) | \(i.title)" }

    // Any text area under this element containing a tab character, or the letter typed while the list was
    // open (Option+Z gives Ω), means a key leaked through.
    static func hasTab(_ el: AXUIElement, depth: Int = 0) -> Bool {
        if (ax(el, kAXRoleAttribute) as? String) == kAXTextAreaRole, let v = ax(el, kAXValueAttribute) as? String,
           v.contains("\t") || v.contains("Ω") || v.contains("z") { return true }
        guard depth < 6, let kids = ax(el, kAXChildrenAttribute) as? [AXUIElement] else { return false }
        return kids.contains { hasTab($0, depth: depth + 1) }
    }

    // The value of the first search field under this element: TextEdit's Find bar.
    static func searchField(_ el: AXUIElement, depth: Int = 0) -> String? {
        if (ax(el, kAXRoleAttribute) as? String) == kAXTextFieldRole, (ax(el, kAXSubroleAttribute) as? String) == "AXSearchField" { return (ax(el, kAXValueAttribute) as? String) ?? "" }
        guard depth < 8, let kids = ax(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for k in kids { if let v = searchField(k, depth: depth + 1) { return v } }
        return nil
    }
    static func documentText(_ el: AXUIElement, depth: Int = 0) -> String? {
        if (ax(el, kAXRoleAttribute) as? String) == kAXTextAreaRole { return (ax(el, kAXValueAttribute) as? String) ?? "" }
        guard depth < 6, let kids = ax(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for k in kids { if let v = documentText(k, depth: depth + 1) { return v } }
        return nil
    }
    static func textEditWindow(_ title: String) -> WindowItem? { Windows.list().first { $0.title == title } }

    // MARK: runner

    static func then(_ delay: Double, _ f: @escaping () -> Void) { queue.append((delay, f)) }
    static func run() {
        guard !queue.isEmpty else { return }
        let (d, f) = queue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { f(); run() }
    }

    // Shows the panel for 3 seconds without typing anything, and logs where the window server has it.
    static func showOnly(log path: String) {
        logPath = path
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
        let items = Windows.list()
        let p = Controller.shared.panel
        p.show(items: items, selected: 1, screen: NSScreen.main) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            log("items \(items.count) frame \(p.frame) visible \(p.isVisible) onActiveSpace \(p.isOnActiveSpace) level \(p.level.rawValue) alpha \(p.alphaValue)")
            log("occlusion visible: \(p.occlusionState.contains(.visible)) screen: \(p.screen?.frame ?? .zero) content: \(p.contentView?.frame ?? .zero) subviews \(p.contentView?.subviews.count ?? -1)")
            let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(p.windowNumber)) as? [[String: Any]]) ?? []
            log("window server: \(info.first.map { "onscreen=\($0[kCGWindowIsOnscreen as String] ?? "nil") layer=\($0[kCGWindowLayer as String] ?? "") bounds=\($0[kCGWindowBounds as String] ?? "") alpha=\($0[kCGWindowAlpha as String] ?? "")" } ?? "not found")")
            try? "open".write(toFile: logPath + ".panel", atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { log("DONE"); NSApp.terminate(nil) }
    }

    static func start(log path: String) {
        logPath = path
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
        waitForTap()
    }
    static func waitForTap() {
        if Controller.shared.tap == nil {
            log("waiting for Accessibility (trusted=\(AXIsProcessTrusted()))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { waitForTap() }
            return
        }
        plan()
        run()
    }

    static func plan() {
        var list: [WindowItem] = []
        var before = ""
        var shows = 0

        if ProcessInfo.processInfo.environment["SWAP_TEST_ONLY"] != "desktops" {
        then(0.5) {
            // Start from one of the test's own windows in front.
            if let t = Windows.list().first(where: { $0.title == "Swap test Three.txt" }) { userFocus(t) }
        }
        then(1.0) {
            list = Windows.list()
            log("windows: \(list.count)")
            for (i, w) in list.prefix(8).enumerated() { log("  \(i): \(name(w))\(w.minimized ? " (minimised)" : "")") }
            log("front: \(front())")
            check("at least 3 windows to test with", list.count >= 3, "\(list.count)")
            before = front()
            shows = Controller.shared.showCount
        }
        // 1. Quick Option+Tab: jumps to the second window, no panel.
        then(0.2) { flags(option: true); tab(); flags(option: false) }
        then(1.0) {
            check("quick Option+Tab goes to the next window", front() == name(list[1]), "front=\(front()) expected=\(name(list[1]))")
            check("quick Option+Tab does not flash the panel", Controller.shared.showCount == shows)
            check("switcher closed after release", !Controller.shared.isActive && !Controller.shared.panel.isVisible)
        }
        // 2. Again: flips back to where we started.
        then(0.2) { flags(option: true); tab(); flags(option: false) }
        then(1.0) { check("second quick Option+Tab flips back", front() == before, "front=\(front()) expected=\(before)") }

        // 3. Hold Option, Tab twice: panel shows, release picks the third window.
        then(0.2) { list = Windows.list(); before = front(); flags(option: true); tab(); tab() }
        then(0.8) {
            let p = Controller.shared.panel
            check("panel appears while Option is held", p.isVisible)
            let selfRow = Settings.showSelfInList ? 1 : 0   // Swap's own row, last
            check("panel shows every window", p.switcher?.count == min(list.count, Controller.maxItems) + selfRow, "\(p.switcher?.count ?? -1) rows")
            check("two Tabs select the third window", Controller.shared.selection == 2, "sel=\(Controller.shared.selection)")
            try? "open".write(toFile: logPath + ".panel", atomically: true, encoding: .utf8)
        }
        then(4.0) { try? FileManager.default.removeItem(atPath: logPath + ".panel"); flags(option: false) }
        then(1.0) {
            check("releasing Option switches to the selected window", front() == name(list[2]), "front=\(front()) expected=\(name(list[2]))")
            check("panel hides after release", !Controller.shared.panel.isVisible)
            let now = Windows.list()
            check("list is in last-used order: new window first, previous second",
                  now.count > 1 && front() == name(now[0]) && name(now[1]) == before,
                  "first=\(now.first.map(name) ?? "-") second=\(now.count > 1 ? name(now[1]) : "-") expected second=\(before)")
        }

        // 4. Esc cancels: nothing changes.
        then(0.2) { before = front(); flags(option: true); tab() }
        then(0.5) { key(53) }
        then(0.3) {
            check("Esc closes the switcher", !Controller.shared.isActive && !Controller.shared.panel.isVisible)
            flags(option: false)
        }
        then(0.8) { check("Esc keeps the same window in front", front() == before, "front=\(front())") }

        // 5. Option+Shift+Tab steps backwards to the last window.
        then(0.2) { list = Windows.list(); flags(option: true, shift: true); tab(shift: true) }
        then(0.5) {
            check("Option+Shift+Tab selects the last window", Controller.shared.selection == list.count - 1,
                  "sel=\(Controller.shared.selection) of \(list.count)")
            key(53); flags(option: false)
        }

        // 6. Arrow keys move the selection. A stray key typed meanwhile must not reach the app behind.
        then(0.5) { flags(option: true); tab() }
        then(0.5) { key(125) }
        then(0.2) { check("Down arrow moves to the next row", Controller.shared.selection == 2, "sel=\(Controller.shared.selection)"); key(126) }
        then(0.2) { check("Up arrow moves back", Controller.shared.selection == 1, "sel=\(Controller.shared.selection)"); key(43) }   // comma: not a letter, so it stays with the list
        then(0.2) { check("a non-letter key keeps the switcher open", Controller.shared.isActive); key(6) }   // Z: not on the allowlist
        then(0.3) {
            check("a letter off the allowlist does nothing: the list stays, the row stays", Controller.shared.isActive && Controller.shared.selection == 1, "sel=\(Controller.shared.selection)")
            check("and says so", Controller.shared.lastRefusal == Verbs.notAKey, Controller.shared.lastRefusal)
            key(53); flags(option: false)
        }

        // 6b. Number keys pick a row straight away.
        then(0.5) { list = Windows.list(); flags(option: true); tab() }
        then(0.5) { key(20) }   // "3"
        then(0.3) { flags(option: false) }
        then(0.8) { check("pressing 3 switches to the third window", front() == name(list[2]), "front=\(front()) expected=\(name(list[2]))") }

        // 7. Clicking a row switches to it.
        then(0.5) { list = Windows.list(); flags(option: true); tab() }
        then(0.6) {
            guard let rows = Controller.shared.panel.switcher?.rows, let row = rows.rowRect(2), let win = rows.window else {
                check("click a row", false, "panel not shown"); return
            }
            let r = win.convertToScreen(rows.convert(row, to: nil))
            let mainH = NSScreen.screens[0].frame.height
            click(at: CGPoint(x: r.midX, y: mainH - r.midY))   // Quartz points start at the top left
        }
        then(1.0) {
            check("clicking a row switches to that window", front() == name(list[2]), "front=\(front()) expected=\(name(list[2]))")
            flags(option: false)
        }

        // 8. A minimised window comes back when picked.
        var target: WindowItem?
        then(0.5) {
            list = Windows.list()
            target = list.dropFirst().first { $0.appName == "TextEdit" }
            if let w = target?.window { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        }
        then(1.5) {
            list = Windows.list()
            guard let t = target, let i = list.firstIndex(where: { $0.title == t.title && $0.appName == t.appName }) else {
                check("minimised window still listed", false); return
            }
            check("minimised window still listed, marked minimised", list[i].minimized, "index \(i)")
            flags(option: true)
            for _ in 0..<i { tab() }
            flags(option: false)
        }
        then(1.5) {
            guard let w = target?.window else { return }
            let stillMin = (ax(w, kAXMinimizedAttribute) as? Bool)
            check("picking a minimised window restores it", stillMin == false)
            check("restored window is in front", front() == name(target!), "front=\(front())")
            if stillMin != false {   // why: can this Mac un-minimise through Accessibility at all?
                let err = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                log("minimised debug: AXMinimized=\(String(describing: stillMin)) direct unminimise err=\(err.rawValue) sel=\(Controller.shared.selection) list=\(Windows.list().map { name($0) + ($0.minimized ? "*" : "") })")
            }
        }

        // 9. Order follows real use across apps: click Preview, then a TextEdit window, and a quick
        //    Option+Tab goes back to Preview (app grouping would have picked another TextEdit window).
        var preview: WindowItem?
        then(0.5) {
            preview = Windows.list().first { $0.appName == "Preview" && $0.title.hasPrefix("Swap test") }
            if let p = preview { userFocus(p) } else { check("Preview window to test with", false) }
        }
        then(1.2) {
            log("order after Preview: \(order())")
            if let t = Windows.list().first(where: { $0.appName == "TextEdit" && $0.title.hasPrefix("Swap test") }) { userFocus(t) }
        }
        then(1.2) { log("order after TextEdit: \(order())") }
        then(1.2) { flags(option: true); tab(); flags(option: false) }
        then(1.2) {
            guard let p = preview else { return }
            check("across apps: quick Option+Tab returns to the last-used window", front() == name(p), "front=\(front())")
        }

        // 9b. A hung app (stopped helper window) must not hold the keyboard: releasing Option while the list
        //     is still loading ends the session, the switch happens, and the next quick flip works too.
        if let helperPath = ProcessInfo.processInfo.environment["SWAP_TEST_HELPER"] {
            var hung: Process?
            var two: WindowItem?, three: WindowItem?
            then(0.5) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: helperPath)
                p.arguments = ["window", "Swap test hung"]
                try? p.run()
                hung = p
            }
            then(1.5) {
                // The helper is in front; freeze it there. A quick flip must still get you out of it.
                if let pid = hung?.processIdentifier { kill(pid, SIGSTOP) }
                flags(option: true); tab(); flags(option: false)
            }
            then(1.5) {
                check("hung app in front: quick Option+Tab gets you out of it", preview != nil && front() == name(preview!), "front=\(front())")
                three = Windows.list().first { $0.title == "Swap test Three.txt" }
                if let t = three { userFocus(t) }
            }
            then(1.0) {
                two = Windows.list().first { $0.title == "Swap test Two.txt" }
                if let t = two { userFocus(t) }
            }
            then(1.0) {
                let started = Date()
                flags(option: true); tab(); usleep(50_000); flags(option: false)
                log("hung app: quick flip posted in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
            then(1.5) {
                check("hung app: releasing Option while the list loads ends the session",
                      !Controller.shared.isActive && !Controller.shared.panel.isVisible)
                check("hung app: the quick flip still switched", three != nil && front() == name(three!), "front=\(front())")
                flags(option: true); tab(); flags(option: false)
            }
            then(1.2) {
                check("hung app: the next quick flip works too", two != nil && front() == name(two!), "front=\(front())")
                if let pid = hung?.processIdentifier { kill(pid, SIGCONT) }
                hung?.terminate()
            }
        }

        }

        if (Spaces.desktops()?.list.count ?? 0) < 2 {
            then(0.1) { log("SKIP  desktop checks: this Mac has only one desktop") }
        } else {
        // 10. Desktops. Open a window on Desktop 2 while Swap runs, as happens in real use: move right with
        //     Control+Right, start the helper (SWAP_TEST_HELPER), come back with Control+Left.
        let deskTitle = "Swap test desktop 2"
        var desks: (list: [Spaces.Desktop], current: UInt64)?
        var home: WindowItem?
        var helper: Process?
        then(0.5) { controlArrow(124) }
        then(1.5) {
            guard let path = ProcessInfo.processInfo.environment["SWAP_TEST_HELPER"] else { log("no SWAP_TEST_HELPER"); return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["window", deskTitle, "ghost"]   // plus a borderless helper window that must stay hidden
            try? p.run()
            helper = p
            log("after Control+Right: desktop \(deskIndex())")
        }
        then(2.0) {
            if let pid = helper?.processIdentifier {
                let el = AXUIElementCreateApplication(pid)
                let ax = (SelfTest.ax(el, kAXWindowsAttribute) as? [AXUIElement])?.compactMap(windowID) ?? []
                let cg = ((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [])
                    .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
                    .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
                log("helper pid \(pid): ax=\(ax) cg=\(cg) spaces=\(cg.map { Spaces.space(of: $0).map(String.init) ?? "-" }) cached=\(WindowCache.ids(of: pid)) front=\(front())")
            }
            controlArrow(123)
        }
        then(1.5) {
            log("after Control+Left: desktop \(deskIndex()), cached=\(helper.map { WindowCache.ids(of: $0.processIdentifier) } ?? [])")
            desks = Spaces.desktops()
            let p = Windows.pages()
            log("pages: " + p.pages.map { "\($0.title)=\($0.items.count)" }.joined(separator: ", ") + "  current=\(p.current)")
            check("one page per desktop", desks != nil && p.pages.count == desks!.list.count && p.pages.count >= 2, "\(p.pages.count) pages")
            check("the test window is listed on the Desktop 2 page",
                  p.pages.count > p.current + 1 && p.pages[p.current + 1].items.contains { $0.title == deskTitle })
            let helperRows = p.pages.flatMap { $0.items }.filter { $0.appName == "SwapTestWindow" }.map { $0.title }
            check("a helper window on another desktop is not listed (only the real window)", helperRows == [deskTitle], "\(helperRows)")
            flags(option: true); tab()
        }
        then(0.6) { swipe(fingersLeft: true) }
        then(0.5) {
            let c = Controller.shared
            check("two-finger swipe left shows the next desktop", c.page == 1 && c.pageTitle == "Desktop 2", "page=\(c.page) \(c.pageTitle)")
            check("its last-used window is selected", c.selectedItem?.title == deskTitle, c.selectedItem?.title ?? "none")
            swipe(fingersLeft: false)
        }
        then(0.8) {
            check("two-finger swipe right goes back", Controller.shared.page == 0, "page=\(Controller.shared.page)")
            dragBegin(); drag(fingers: -30)
        }
        var heldAt = 0.0
        then(0.3) {
            let c = Controller.shared, s = c.slideState
            heldAt = s["offset"] as? Double ?? 0
            check("a swipe in progress: the list is under the fingers", heldAt < -20 && heldAt > -60, "offset=\(heldAt)")
            check("a swipe in progress: still on the same desktop", c.page == 0, "page=\(c.page)")
            drag(fingers: -60)
        }
        then(0.3) {
            let moved = Controller.shared.slideState["offset"] as? Double ?? 0
            check("a swipe in progress: more travel moves it further", moved < heldAt - 60, "offset=\(moved)")
            drag(fingers: 80)
        }
        then(0.3) {
            let back = Controller.shared.slideState["offset"] as? Double ?? 0
            check("a swipe in progress: reversing brings it back", back > -60, "offset=\(back)")
            dragEnd()
        }
        then(0.9) {
            let c = Controller.shared
            check("let go short of half way: springs back to the same desktop", c.page == 0 && c.slideState["on"] as? Bool == false, "\(c.page) \(c.slideState)")
            dragBegin(); drag(fingers: -260)
        }
        then(0.3) { dragEnd() }
        var ticks = 0
        then(0.12) {
            let s = Controller.shared.slideState
            ticks = s["ticks"] as? Int ?? 0
            check("let go past half way: it carries on by itself", s["settling"] as? Bool == true && ticks > 2, "\(s)")
        }
        then(0.9) {
            let c = Controller.shared
            check("let go past half way: lands on the next desktop", c.page == 1 && c.slideState["on"] as? Bool == false, "page=\(c.page) \(c.slideState)")
            check("after landing the header shows the new desktop", c.panel.switcher?.header?.title == "Desktop 2", c.panel.switcher?.header?.title ?? "none")
            dragBegin(); drag(fingers: -200)
        }
        then(0.3) {
            let o = Controller.shared.slideState["offset"] as? Double ?? 0
            check("nothing beyond the last desktop: the list stretches and resists", o < -20 && o > -Double(Tokens.Motion.pageEdgeStretch), "offset=\(o)")
            dragEnd()
        }
        then(0.9) {
            let c = Controller.shared
            check("nothing beyond the last desktop: it springs back", c.page == 1 && c.slideState["on"] as? Bool == false, "page=\(c.page) \(c.slideState)")
            dragBegin(); drag(fingers: 260)
        }
        then(0.2) { dragEnd() }
        then(0.05) { dragBegin() }   // fingers back down while it is still moving
        then(0.1) {
            let c = Controller.shared, s = c.slideState
            check("fingers down catch a moving list", s["on"] as? Bool == true && s["settling"] as? Bool == false && c.page == 1, "page=\(c.page) \(s)")
            drag(fingers: 200)
            dragEnd()
        }
        then(0.9) {
            let c = Controller.shared
            check("a caught list still lands", c.page == 0 && c.slideState["on"] as? Bool == false, "page=\(c.page) \(c.slideState)")
            dragBegin(); drag(fingers: -260)
        }
        then(0.2) { key(125) }   // a key while the fingers are down
        then(0.3) {
            let c = Controller.shared
            check("a key mid-swipe finishes it and acts on the page arriving", c.page == 1 && c.slideState["on"] as? Bool == false, "page=\(c.page) \(c.slideState)")
            dragEnd()
            key(123)
        }
        then(0.9) {
            check("Left arrow slides back", Controller.shared.page == 0 && Controller.shared.slideState["on"] as? Bool == false, "page=\(Controller.shared.page)")
            key(124)
        }
        then(0.8) {
            check("Right arrow shows the next desktop", Controller.shared.page == 1, "page=\(Controller.shared.page)")
            key(123)
        }
        then(0.8) {
            check("Left arrow goes back", Controller.shared.page == 0, "page=\(Controller.shared.page)")
            home = Controller.shared.selectedItem.flatMap { _ in Windows.list().first }
            key(124)
        }
        then(0.4) { flags(option: false) }
        then(2.0) {
            let now = Spaces.desktops()?.current
            check("picking a window on Desktop 2 moves to Desktop 2", desks != nil && desks!.list.count > 1 && now == desks!.list[1].id,
                  "space=\(now.map(String.init) ?? "nil")")
            check("and brings that window to the front", front() == "SwapTestWindow | \(deskTitle)", "front=\(front())")
            flags(option: true); tab()
        }
        then(0.6) { key(123) }
        then(0.4) {
            check("from Desktop 2, Left arrow shows Desktop 1 with its last window selected",
                  Controller.shared.page == 0 && Controller.shared.selectedItem?.id == home?.id,
                  "page=\(Controller.shared.page) sel=\(Controller.shared.selectedItem?.title ?? "none") expected=\(home?.title ?? "none")")
            flags(option: false)
        }
        then(2.0) {
            check("picking it moves back to Desktop 1", Spaces.desktops()?.current == desks?.list.first?.id)
            check("and brings that window to the front", home != nil && front() == name(home!), "front=\(front())")
        }
        // A quick Option+Tab now goes back to the window you came from, on Desktop 2, and again back home.
        then(0.5) { flags(option: true); tab(); flags(option: false) }
        then(2.0) {
            check("quick Option+Tab after a desktop switch returns to the window you came from",
                  desks != nil && Spaces.desktops()?.current == desks!.list[1].id && front() == "SwapTestWindow | \(deskTitle)",
                  "front=\(front())")
            flags(option: true); tab(); flags(option: false)
        }
        then(2.0) {
            check("and once more goes back home", Spaces.desktops()?.current == desks?.list.first?.id && home != nil && front() == name(home!),
                  "front=\(front())")
            helper?.terminate()
        }

        }

        // 10. W closes the selected window and Q quits its app; the list stays open either way.
        //     A fourth TextEdit document and Calculator are opened just for this, so nothing else is lost.
        let closeDoc = NSTemporaryDirectory() + "Swap test Close.txt", closeDoc2 = NSTemporaryDirectory() + "Swap test Close2.txt"
        then(0.3) {
            try? "Swap test window Close".write(toFile: closeDoc, atomically: true, encoding: .utf8)
            try? "Swap test window Close2".write(toFile: closeDoc2, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(URL(fileURLWithPath: closeDoc))
            NSWorkspace.shared.open(URL(fileURLWithPath: closeDoc2))
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        // Opens the list, walks the selection (arrows) to the first row matching `want`, checks it is the one
        // selected and only then presses `code`. Three timed steps: key events are handled on the main
        // thread between them, so no block may wait for them itself.
        func pressOn(_ what: String, _ want: @escaping (WindowItem) -> Bool, _ code: CGKeyCode, held: Bool = false) {
            var found = false
            then(0.3) { flags(option: true); tab() }
            then(0.7) {
                let rows = Controller.shared.panel.switcher?.rows.items ?? []
                guard let i = rows.firstIndex(where: want) else {
                    check("\(what) is listed", false, rows.map { "\($0.appName) | \($0.title)" }.joined(separator: ", "))
                    key(53); flags(option: false); return
                }
                let d = i - Controller.shared.selection
                for _ in 0..<abs(d) { key(d > 0 ? 125 : 126) }
                found = true
            }
            then(0.6) {
                guard found else { return }
                let ok = Controller.shared.selectedItem.map(want) ?? false
                check("\(what) selected before the key", ok, "sel=\(Controller.shared.selection)")
                if !ok { key(53); flags(option: false) } else if held { heldKey(code) } else { key(code) }
            }
        }
        then(2.5) {}
        pressOn("W: the extra TextEdit window", { $0.title == "Swap test Close.txt" }, 13, held: true)   // W, held down
        then(0.8) {
            check("W keeps the list open", Controller.shared.isActive && Controller.shared.panel.isVisible)
            let rows = Controller.shared.panel.switcher?.rows.items ?? []
            check("W drops the row from the list", !rows.contains { $0.title == "Swap test Close.txt" })
            check("a held W closes one window, not the next one too", rows.contains { $0.title == "Swap test Close2.txt" })
            check("after W the selection stays on the same app", Controller.shared.selectedItem?.appName == "TextEdit", Controller.shared.selectedItem?.appName ?? "none")
            key(53); flags(option: false)
        }
        then(1.0) {
            check("W closed the window", !Windows.list().contains { $0.title == "Swap test Close.txt" }, order())
            check("the repeats of a held key reached no app", textEditWindow("Swap test Close2.txt") != nil)
        }
        pressOn("W: the second extra window", { $0.title == "Swap test Close2.txt" }, 13)
        then(0.6) { key(53); flags(option: false); try? FileManager.default.removeItem(atPath: closeDoc2) }
        // A window that won't close (what a Save prompt does): the row stays, selected, and the window comes forward.
        if let helperPath = ProcessInfo.processInfo.environment["SWAP_TEST_HELPER"] {
            var stays: Process?
            then(0.3) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: helperPath)
                p.arguments = ["window", "Swap test stays", "noclose"]
                try? p.run()
                stays = p
            }
            then(2.0) {}
            pressOn("W: a window that refuses to close", { $0.title == "Swap test stays" }, 13)
            then(1.0) {
                let c = Controller.shared
                check("a window that stays open keeps its row", (c.panel.switcher?.rows.items ?? []).contains { $0.title == "Swap test stays" })
                check("W keeps the row selected, so a release goes to the prompt", c.selectedItem?.title == "Swap test stays", c.selectedItem?.title ?? "none")
                flags(option: false)
            }
            then(1.0) {
                check("and that window is in front", front().hasSuffix("| Swap test stays"), "front=\(front())")
                stays?.terminate()
            }
            then(0.8) {}
        }
        pressOn("Q: Calculator", { $0.appName == "Calculator" }, 12)   // Q
        then(0.8) {
            check("Q keeps the list open", Controller.shared.isActive && Controller.shared.panel.isVisible)
            check("Q drops the app's rows from the list", !(Controller.shared.panel.switcher?.rows.items ?? []).contains { $0.appName == "Calculator" })
            key(53); flags(option: false)
        }
        then(2.0) {
            check("Q quit the app", !NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.calculator" })
            try? FileManager.default.removeItem(atPath: closeDoc)
        }

        // 11. Drill-in: Return expands a TextEdit window into its parts (TestChildren), Shift+Return folds it,
        //     Return on a part closes the list and opens that part. The setting is switched on just for this.
        var drillWas = false
        var parentIdx = -1
        then(0.3) { drillWas = Settings.drillIn; Settings.drillIn = true; flags(option: true); tab() }
        then(0.8) {
            let c = Controller.shared
            let rows = c.panel.switcher?.rows.items ?? []
            parentIdx = rows.firstIndex { $0.appName == "TextEdit" && $0.child == nil } ?? -1
            check("a TextEdit row to expand", parentIdx >= 0, "\(rows.map { $0.appName })")
            guard parentIdx >= 0 else { flags(option: false); return }
            let d = parentIdx - c.selection
            for _ in 0..<abs(d) { key(d > 0 ? 125 : 126) }
        }
        then(0.5) {
            guard parentIdx >= 0 else { return }
            check("the TextEdit row is marked expandable", Controller.shared.selectedItem?.expandable == true)
            key(36)
        }
        then(1.0) {
            guard parentIdx >= 0 else { return }
            let c = Controller.shared
            let rows = c.panel.switcher?.rows.items ?? []
            check("Return keeps the list open and expands the row", c.isActive && c.panel.isVisible && rows.indices.contains(parentIdx) && rows[parentIdx].expanded)
            check("its three parts appear under it", rows.count >= parentIdx + 4 && rows[(parentIdx + 1)...(parentIdx + 3)].allSatisfy { $0.child != nil }, "\(rows.count) rows")
            check("the first part is selected", c.selection == parentIdx + 1 && c.selectedItem?.child?.id == "Alpha", "sel=\(c.selection)")
            key(36, shift: true)
        }
        then(0.6) {
            guard parentIdx >= 0 else { return }
            let c = Controller.shared
            let rows = c.panel.switcher?.rows.items ?? []
            check("Shift+Return folds it back and selects the window", rows.allSatisfy { $0.child == nil } && c.selection == parentIdx, "sel=\(c.selection) rows=\(rows.count)")
            key(36)
        }
        then(0.8) { guard parentIdx >= 0 else { return }; key(125) }
        var pinsWere: [String: [String]] = [:]
        then(0.4) {
            guard parentIdx >= 0 else { return }
            check("Down moves to the second part", Controller.shared.selectedItem?.child?.id == "Beta", Controller.shared.selectedItem?.child?.id ?? "none")
            pinsWere = Settings.pins
            key(35)   // P pins Beta
        }
        then(0.5) {
            guard parentIdx >= 0 else { return }
            let c = Controller.shared
            let rows = c.panel.switcher?.rows.items ?? []
            check("P pins the part: it moves to the top of its row, marked pinned",
                  rows.indices.contains(parentIdx + 1) && rows[parentIdx + 1].child?.id == "Beta" && rows[parentIdx + 1].pinned && c.selectedItem?.child?.id == "Beta",
                  "first=\(rows.indices.contains(parentIdx + 1) ? rows[parentIdx + 1].child?.id ?? "-" : "-") sel=\(c.selectedItem?.child?.id ?? "none")")
            key(35)   // P again unpins
        }
        then(0.5) {
            guard parentIdx >= 0 else { return }
            let c = Controller.shared
            let rows = c.panel.switcher?.rows.items ?? []
            check("P again unpins: Alpha is first again, Beta still selected",
                  rows.indices.contains(parentIdx + 2) && rows[parentIdx + 1].child?.id == "Alpha" && !rows[parentIdx + 1].pinned && c.selectedItem?.child?.id == "Beta",
                  "sel=\(c.selectedItem?.child?.id ?? "none")")
            Settings.pins = pinsWere
            key(13)   // W on a part that can't close: a chat
        }
        then(0.5) {
            guard parentIdx >= 0 else { return }
            let c = Controller.shared
            check("W on a chat keeps the list and every row, and says why", c.isActive && c.selectedItem?.child?.id == "Beta" && c.lastRefusal == Verbs.refusal(.close), c.lastRefusal)
            key(125)
        }
        then(0.4) { guard parentIdx >= 0 else { return }; key(13) }   // W on Gamma, which closes as a tab does
        then(0.6) {
            guard parentIdx >= 0 else { return }
            let c = Controller.shared
            let rows = c.panel.switcher?.rows.items ?? []
            check("W on a tab closes it and keeps the list open", c.isActive && TestChildren.closed == "Gamma" && !rows.contains { $0.child?.id == "Gamma" }, TestChildren.closed ?? "none")
            check("the selection stays among its neighbours", c.selectedItem?.child?.id == "Beta", c.selectedItem?.child?.id ?? "none")
        }
        then(0.3) {
            guard parentIdx >= 0 else { return }
            TestChildren.opened = nil
            key(36)
        }
        then(1.2) {
            Settings.drillIn = drillWas
            guard parentIdx >= 0 else { flags(option: false); return }
            check("Return on a part closes the list", !Controller.shared.isActive)
            check("and opens that part in its window", TestChildren.opened == "Beta", TestChildren.opened ?? "none")
            flags(option: false)
        }

        // 11b. A key a row has no use for says so; a row with nothing inside is a plain row; a quick flip calls no provider.
        then(0.3) { drillWas = Settings.drillIn; Settings.drillIn = true; flags(option: true); tab() }
        then(0.6) { key(35) }   // P on a window
        then(0.4) {
            let c = Controller.shared
            check("P on a window row does nothing and says why", c.isActive && c.lastRefusal == Verbs.refusal(.pin), c.lastRefusal)
            check("provider labels arrive after the list shows", (c.panel.switcher?.rows.items ?? []).contains { $0.profile == "Test label" })
            let d = (c.panel.switcher?.rows.items ?? []).firstIndex { $0.appName == "TextEdit" && $0.child == nil } ?? 0
            let move = d - c.selection
            for _ in 0..<abs(move) { key(move > 0 ? 125 : 126) }
        }
        var plainRow = ""
        then(0.4) {
            plainRow = Controller.shared.selectedItem?.title ?? ""
            TestChildren.empty = plainRow
            key(36)
        }
        then(1.2) {
            let c = Controller.shared
            check("a row with nothing inside shows no chevron and Return switches to it", !c.isActive && front().hasSuffix("| \(plainRow)"), "front=\(front()) active=\(c.isActive)")
            TestChildren.empty = nil
            flags(option: false)
            TestChildren.calls = 0
        }
        then(0.4) { flags(option: true); tab(); flags(option: false) }
        then(0.8) {
            check("a quick flip asks no provider for anything, Return expands on", TestChildren.calls == 0, "\(TestChildren.calls) calls")
            Settings.drillIn = drillWas
        }

        // 11c. A pinned list goes when you leave it: another app coming forward, or a click anywhere else.
        then(4.5) { Controller.shared.showFromMenu() }   // past the grace period after an earlier W, Q or letter
        then(0.6) {
            check("list from the menu stays open", Controller.shared.isActive && Controller.shared.isPinned)
            if let p = Windows.list().first(where: { $0.appName == "Preview" }) { userFocus(p) }
        }
        then(0.8) {
            check("a pinned list closes when another app comes forward", !Controller.shared.isActive, "active=\(Controller.shared.isActive)")
            if let t = textEditWindow("Swap test Two.txt") { userFocus(t) }
        }
        then(1.0) { Controller.shared.showFromMenu() }
        then(0.6) {
            let panel = Controller.shared.panel.frame
            let h = NSScreen.screens[0].frame.height
            guard let w = textEditWindow("Swap test Two.txt")?.window, let pos = ax(w, kAXPositionAttribute) else { key(53); return }
            var p = CGPoint.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            let target = CGPoint(x: p.x + 90, y: p.y + 10)   // its title bar
            if panel.contains(NSPoint(x: target.x, y: h - target.y)) { log("SKIP  click outside: the window sits under the list"); Controller.shared.showFromMenu(); return }
            click(at: target)
        }
        then(0.8) {
            check("a pinned list closes on a click outside it", !Controller.shared.isActive, "active=\(Controller.shared.isActive)")
            if Controller.shared.isActive { flags(option: true); key(53); flags(option: false) }
        }

        // 11d. A letter on a row: Command+letter reaches that window, and what is typed next lands after it, in the Find
        //      field, without the Option that is still held. Never in the document, never in the wrong app.
        func letterOn(_ title: String) {
            then(0.4) { if let t = textEditWindow("Swap test Three.txt") { userFocus(t) } }
            pressOn("F: \(title)", { $0.title == title }, 3)
        }
        func findBar(_ title: String) -> String? { textEditWindow(title)?.window.flatMap { searchField($0) } }
        func closeFind(_ title: String) {
            then(0.2) { if findBar(title) != nil, let t = textEditWindow(title) { userFocus(t) } }
            then(0.5) { if findBar(title) != nil, front().hasSuffix("| \(title)") { plainToApp(53) } }
            then(0.4) {}
        }
        letterOn("Swap test Two.txt")
        then(0.03) { key(40); key(38) }   // k, j with Option still held, straight after F
        then(1.0) {
            check("a letter closes the list and goes to that window", !Controller.shared.isActive && front().hasSuffix("| Swap test Two.txt"), "front=\(front())")
            check("keys typed after the letter land after it, as plain keys", findBar("Swap test Two.txt") == "kj", findBar("Swap test Two.txt") ?? "no Find bar")
            let doc = textEditWindow("Swap test Two.txt")?.window.flatMap { documentText($0) }
            check("and not in the document", doc == "Swap test window Two\n", doc ?? "none")
            check("the keyboard comes back", !AppCommand.holding)
            flags(option: false)
        }
        closeFind("Swap test Two.txt")
        // Option+Tab straight after a letter: the new list opens and stays, and the command still reaches its window.
        // Keep open is on for this step: the test's Option exists only in event flags, and the command's own flags replace
        // them in the system's reading of what is held, which the real key is not subject to.
        var keepWas = false
        then(0.1) { keepWas = Settings.keepOpen; Settings.keepOpen = true }
        letterOn("Swap test One.txt")
        then(0.03) { tab() }
        then(0.9) {
            let c = Controller.shared
            Settings.keepOpen = keepWas
            check("Option+Tab right after a letter opens the list, Swap's own command does not close it", c.isActive && c.panel.isVisible, "active=\(c.isActive)")
            check("and the command still reaches its window", findBar("Swap test One.txt") != nil, findBar("Swap test One.txt") ?? "no Find bar")
            key(53); flags(option: false)
        }
        closeFind("Swap test One.txt")
        // A quick flip away inside the wait: the command must not land in the app you moved to.
        letterOn("Swap test Two.txt")
        then(0.01) { tab(); flags(option: false) }
        then(1.2) {
            let doc = front()
            let bars = ["Swap test One.txt", "Swap test Three.txt"].filter { findBar($0) != nil && doc.hasSuffix("| \($0)") }
            check("flipping away right after a letter: the command does not follow", bars.isEmpty, "front=\(doc)")
            check("and nothing stays held", !AppCommand.holding)
        }
        for w in ["Swap test One.txt", "Swap test Two.txt", "Swap test Three.txt"] { closeFind(w) }

        // 12. The search row: never in the way, stays open on release, gives the keyboard back, finds and opens.
        let searchDir = NSHomeDirectory() + "/swap-search-qa"
        let searchDoc = searchDir + "/Searchqa Report Seven.txt"
        let swapRowsUp = { key(126); key(126) }   // from the second row: first row, then the search row
        func rowsNow() -> [WindowItem] { Controller.shared.panel.switcher?.rows.items ?? [] }
        var searchRowWas = true
        then(0.3) {
            searchRowWas = Settings.searchRow
            Settings.searchRow = true
            try? FileManager.default.createDirectory(atPath: searchDir, withIntermediateDirectories: true)
            try? "search test".write(toFile: searchDoc, atomically: true, encoding: .utf8)
            if let t = Windows.list().first(where: { $0.title == "Swap test Three.txt" }) { userFocus(t) }
        }
        then(5.0) { before = front(); shows = Controller.shared.showCount; flags(option: true); tab(); flags(option: false) }   // Spotlight indexes the file meanwhile
        then(1.0) {
            let c = Controller.shared
            check("search row: quick flip still shows no panel", c.showCount == shows)
            check("search row: quick flip still switches window", front() != before, "front=\(front())")
            check("search row: quick flip never takes the keyboard", !c.panel.isKeyWindow && !c.search.inUse)
        }
        then(0.2) { flags(option: true); tab(); flags(option: false) }
        then(1.0) { before = front(); flags(option: true); tab() }
        then(0.7) {
            let row = Controller.shared.panel.switcher?.searchRow
            check("the search row is on show", row != nil)
            check("idle it has no field and asks for no typing", row?.state == .idle && row?.field == nil && !Controller.shared.panel.isKeyWindow)
            swapRowsUp()
        }
        then(0.4) {
            let c = Controller.shared
            check("Up from the first row selects the search row", c.search.onRow, "sel=\(c.selection)")
            check("selecting it does not take the keyboard yet", !c.panel.isKeyWindow)
            key(126)
        }
        then(0.3) {
            let c = Controller.shared
            check("Up on the search row goes round to the last row", !c.search.onRow && c.selection == rowsNow().count - 1, "sel=\(c.selection)")
            key(125); key(126)   // Down to the first row, Up to the search row
        }
        then(0.3) {
            check("Down from the last row and Up reach the search row again", Controller.shared.search.onRow, "sel=\(Controller.shared.selection)")
            flags(option: false)
        }
        then(0.5) {
            let c = Controller.shared
            check("release on search keeps the list open", c.isActive && c.panel.isVisible)
            check("release on search focuses the field", c.panel.isKeyWindow && c.search.typing)
            check("the app behind stays active", front() == before && !NSRunningApplication.current.isActive, "front=\(front())")
            plain(53)
        }
        then(0.7) {
            let c = Controller.shared
            check("Esc closes search", !c.isActive && !c.panel.isVisible)
            check("Esc restores focus to the app in front", front() == before && focusedApp() == NSWorkspace.shared.frontmostApplication?.localizedName,
                  "front=\(front()) keyboard=\(focusedApp())")
            flags(option: true); tab()
        }
        then(0.6) { swapRowsUp() }
        then(0.3) { flags(option: false) }
        then(0.4) { typeText("swap test tw") }
        then(0.8) {
            let rows = rowsNow()
            check("typing filters to the window that matches", rows.first?.title == "Swap test Two.txt", rows.prefix(3).map { $0.title }.joined(separator: ", "))
            check("the first result is selected", Controller.shared.selection == 0)
            for _ in 0..<2 { plain(51) }
        }
        then(0.8) {
            check("deleting widens the results", rowsNow().filter { $0.title.hasPrefix("Swap test") }.count >= 3, "\(rowsNow().count) rows")
            plain(125)
        }
        then(0.3) {
            check("Down moves through results", Controller.shared.selection == 1, "sel=\(Controller.shared.selection)")
            plain(126)
        }
        then(0.3) {
            check("Up moves back", Controller.shared.selection == 0, "sel=\(Controller.shared.selection)")
            for _ in 0..<10 { plain(51) }
        }
        then(0.6) {
            let c = Controller.shared
            check("an empty field shows the window list again", c.search.query.isEmpty && c.search.onRow && !rowsNow().isEmpty, "'\(c.search.query)' \(rowsNow().count) rows")
            typeText("f searchqa report")
        }
        then(1.5) {
            let rows = rowsNow()
            check("f then space finds the test file", rows.first?.opens?.path == searchDoc, rows.first?.opens?.path ?? "no rows")
            check("every row is a file", !rows.isEmpty && rows.allSatisfy { $0.opens != nil })
            check("the folder shows on the right", rows.first?.appName == "~/swap-search-qa", rows.first?.appName ?? "")
            plain(36)
        }
        then(2.0) {
            check("Return closes the list", !Controller.shared.isActive && !Controller.shared.panel.isVisible)
            check("Return opens the file", front().hasSuffix("| Searchqa Report Seven.txt"), "front=\(front())")
            if let w = Windows.list().first(where: { $0.title == "Searchqa Report Seven.txt" }) { Windows.close(w) }
            try? FileManager.default.removeItem(atPath: searchDoc)
            try? FileManager.default.removeItem(atPath: searchDir)
        }
        then(0.8) { flags(option: true); tab() }
        then(0.6) { swapRowsUp() }
        then(0.3) { flags(option: false) }
        then(0.4) { typeText("calculator") }
        then(0.8) {
            let hit = rowsNow().first
            check("apps are found by name", hit?.title == "Calculator" && hit?.opens != nil, hit?.title ?? "no rows")
            plain(53)
        }
        // / and Space jump straight into the field, from any row, with Option still held. Esc still closes.
        then(0.8) { before = front(); flags(option: true); tab() }
        then(0.6) { key(44) }   // /
        then(0.4) {
            let c = Controller.shared
            check("/ goes straight to the field with Option held", c.search.typing && c.panel.isKeyWindow && c.search.query.isEmpty, "q='\(c.search.query)'")
            key(53)   // Option+Esc, which macOS means as complete a word
        }
        then(0.5) {
            check("Esc closes search with Option still held", !Controller.shared.isActive && !Controller.shared.panel.isVisible)
            flags(option: false)
        }
        then(0.5) { flags(option: true); tab() }
        then(0.6) { key(49) }   // Space
        then(0.3) { for code: CGKeyCode in [1, 13, 0, 35] { key(code) } }   // s w a p, Option still held
        then(0.5) {
            let c = Controller.shared
            check("Space goes straight to the field", c.search.typing)
            check("letters reach the field plain while Option is held", c.search.query == "swap", "q='\(c.search.query)'")
            key(125)   // Down, Option still held
        }
        then(0.4) {
            check("Down moves through results with Option held", Controller.shared.selection == 1, "sel=\(Controller.shared.selection)")
            flags(option: false)
        }
        then(0.3) {
            check("releasing Option in the field keeps the list", Controller.shared.isActive)
            plain(53)
        }
        // A letter on the search row starts the search. The list keeps its height from then on.
        var heights: [CGFloat] = []
        then(0.6) { flags(option: true); tab() }
        then(0.6) { swapRowsUp() }
        then(0.4) { heights = [Controller.shared.panel.frame.height]; key(1) }
        then(0.3) { key(13) }
        then(0.4) {
            let c = Controller.shared
            check("letters on the search row start typing at once, none lost", c.search.typing && c.search.query == "sw", "q='\(c.search.query)'")
            heights.append(c.panel.frame.height)
            flags(option: false)
        }
        then(0.3) { typeText("a") }
        then(0.1) { heights.append(Controller.shared.panel.frame.height); typeText("p") }
        then(0.1) { heights.append(Controller.shared.panel.frame.height); typeText("q") }
        then(0.1) { heights.append(Controller.shared.panel.frame.height); typeText("z") }
        then(0.6) {
            heights.append(Controller.shared.panel.frame.height)
            check("the list keeps a stable height while typing", zip(heights, heights.dropFirst()).allSatisfy { $1 >= $0 }, "\(heights)")
            check("nothing matched: the query stands", Controller.shared.search.query == "swapqz" && rowsNow().isEmpty, "q='\(Controller.shared.search.query)'")
            for _ in 0..<2 { plain(51) }
        }
        // The list's keys on results: Command+a digit picks, Command+P says no on a window, Option+Tab then release picks.
        then(0.6) { plain(35, flags: .maskCommand) }
        then(0.4) {
            check("Command+P on a window result says why", Controller.shared.lastRefusal == Verbs.refusal(.pin), Controller.shared.lastRefusal)
            before = rowsNow().count > 1 ? rowsNow()[1].title : ""
            plain(19, flags: .maskCommand)   // Command+2
        }
        then(1.0) {
            check("Command+2 picks the second result", !Controller.shared.isActive && front().hasSuffix("| \(before)"), "front=\(front()) expected \(before)")
            flags(option: true); tab()
        }
        then(0.6) { key(44) }
        then(0.3) { flags(option: false) }
        then(0.3) { typeText("swap") }
        then(0.6) { before = rowsNow().count > 1 ? rowsNow()[1].title : ""; flags(option: true); tab() }
        then(0.3) { flags(option: false) }
        then(1.0) {
            check("Option+Tab in results then release picks, as in the list", !Controller.shared.isActive && front().hasSuffix("| \(before)"), "front=\(front()) expected \(before)")
        }
        // The setting off: Up from the first row wraps to the last row, as it always did.
        then(0.6) { Settings.searchRow = false; flags(option: true); tab() }
        then(0.6) { swapRowsUp() }
        then(0.4) {
            let c = Controller.shared
            check("searchRow off: no search row, Up wraps as before", c.panel.switcher?.searchRow == nil && !c.search.onRow && c.selection == rowsNow().count - 1, "sel=\(c.selection)")
            key(53); flags(option: false)
            Settings.searchRow = searchRowWas
        }

        // 12b. Swap's own row: last on the page of the desktop you are on, passed over by the first Tab both ways, opens
        //      Swap's menu when picked (Return, release, click, a number), refuses W, Q and P. Picking it only counts here
        //      (SwapMenu.dryRun): a real menu runs a tracking loop that would hold up every step after it.
        var selfWas = true, dockWas = true, menuOpens = 0
        func isLastSelf(_ rows: [WindowItem]) -> Bool { rows.last?.isSelf == true && rows.filter({ $0.isSelf }).count == 1 }
        func toSelfRow() {   // Tab from the current row until the selection is on Swap's row
            let rows = rowsNow()
            guard isLastSelf(rows) else { return }
            for _ in 0..<max(0, rows.count - 1 - Controller.shared.selection) { tab() }
        }
        then(0.6) {
            selfWas = Settings.showSelfInList; dockWas = Settings.showInDock
            Settings.showSelfInList = true
            SwapMenu.dryRun = true
            menuOpens = SwapMenu.opens
            if let t = Windows.list().first(where: { $0.title == "Swap test Three.txt" }) { userFocus(t) }
        }
        then(1.0) { flags(option: true); tab() }
        then(0.7) {
            let c = Controller.shared, rows = rowsNow()
            check("Swap row: listed once, as the last row", isLastSelf(rows), rows.map { $0.isSelf ? "[Swap]" : $0.title }.joined(separator: ", "))
            check("Swap row: Swap's name, no app or window behind it, Menu on the right",
                  rows.last.map { $0.title == "Swap" && $0.appName == "Menu" && $0.app == nil && $0.window == nil } ?? false)
            check("Swap row: the first Tab lands on a window, not on it", c.selectedItem?.isSelf == false, "sel=\(c.selection)")
            check("Swap row: not part of the window list itself (recency, quick flip, search)", !Windows.list().contains { $0.isSelf })
            check("Swap row: opening the list does not bring Swap to the front", !NSRunningApplication.current.isActive)
            toSelfRow()
        }
        then(0.4) {
            let c = Controller.shared
            check("Swap row: Tab reaches it after the last window", c.selectedItem?.isSelf == true && c.selection == rowsNow().count - 1,
                  "sel=\(c.selection) of \(rowsNow().count)")
            tab()
        }
        then(0.3) {
            check("Swap row: Tab on it wraps round to the first row", Controller.shared.selection == 0, "sel=\(Controller.shared.selection)")
            tab(shift: true)
        }
        then(0.3) {
            check("Swap row: Shift+Tab from the first row goes back to it", Controller.shared.selectedItem?.isSelf == true, "sel=\(Controller.shared.selection)")
            key(13)   // W
        }
        then(0.3) {
            let c = Controller.shared
            check("Swap row: W does nothing and says so", c.isActive && c.selectedItem?.isSelf == true && c.lastRefusal == Verbs.menuRow, c.lastRefusal)
            key(12)   // Q
        }
        then(0.3) {
            let c = Controller.shared
            check("Swap row: Q does nothing and says so", c.isActive && c.selectedItem?.isSelf == true && c.lastRefusal == Verbs.menuRow, c.lastRefusal)
            key(35)   // P
        }
        then(0.3) {
            let c = Controller.shared
            check("Swap row: P does not pin it and says so", c.isActive && c.lastRefusal == Verbs.menuRow && rowsNow().last?.pinned == false, c.lastRefusal)
            check("Swap row: none of those opened the menu", SwapMenu.opens == menuOpens, "\(SwapMenu.opens - menuOpens)")
            key(36)   // Return
        }
        then(0.5) {
            let c = Controller.shared
            check("Swap row: Return closes the list and opens Swap's menu", !c.isActive && !c.panel.isVisible && SwapMenu.opens == menuOpens + 1,
                  "opens=\(SwapMenu.opens - menuOpens)")
            flags(option: false)
        }
        // Release on it.
        then(0.6) { flags(option: true); tab() }
        then(0.7) { toSelfRow() }
        then(0.4) { check("Swap row: selected before the release", Controller.shared.selectedItem?.isSelf == true); flags(option: false) }
        then(0.5) {
            check("Swap row: releasing Option on it opens Swap's menu", !Controller.shared.isActive && SwapMenu.opens == menuOpens + 2,
                  "opens=\(SwapMenu.opens - menuOpens)")
        }
        // A click on it.
        then(0.5) { flags(option: true); tab() }
        then(0.7) {
            guard let rows = Controller.shared.panel.switcher?.rows, let row = rows.rowRect(rows.items.count - 1), let win = rows.window,
                  rows.items.last?.isSelf == true else { check("Swap row: on screen to click", false); key(53); flags(option: false); return }
            let r = win.convertToScreen(rows.convert(row, to: nil))
            click(at: CGPoint(x: r.midX, y: NSScreen.screens[0].frame.height - r.midY))   // Quartz points start at the top left
        }
        then(0.6) {
            check("Swap row: a click on it opens Swap's menu", !Controller.shared.isActive && SwapMenu.opens == menuOpens + 3,
                  "opens=\(SwapMenu.opens - menuOpens)")
            flags(option: false)
        }
        // Its number.
        let digit: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25]
        var numbered = false
        then(0.5) { flags(option: true); tab() }
        then(0.7) {
            let n = rowsNow().count
            if Settings.numberKeys, isLastSelf(rowsNow()), let code = digit[n] { numbered = true; key(code) }
            else { log("SKIP  Swap row by number: it is row \(n), past 9"); key(53) }
        }
        then(0.5) {
            if numbered {
                check("Swap row: its number key opens Swap's menu", !Controller.shared.isActive && SwapMenu.opens == menuOpens + 4,
                      "opens=\(SwapMenu.opens - menuOpens)")
            }
            flags(option: false)
            menuOpens = SwapMenu.opens
            before = front()
        }
        // A quick flip, either way round, never lands on it.
        then(0.6) { flags(option: true); tab(); flags(option: false) }
        then(1.0) {
            check("Swap row: a quick Option+Tab goes to a window, never to Swap's row",
                  front() != before && SwapMenu.opens == menuOpens && !Controller.shared.isActive, "front=\(front()) opens=\(SwapMenu.opens - menuOpens)")
            before = front()
            flags(option: true, shift: true); tab(shift: true); flags(option: false)
        }
        then(1.0) {
            check("Swap row: a quick Option+Shift+Tab goes to a window too",
                  front() != before && SwapMenu.opens == menuOpens && !Controller.shared.isActive, "front=\(front()) opens=\(SwapMenu.opens - menuOpens)")
            Scene.current = ([Windows.Page(title: "", items: [])], 0)   // nothing open at all
        }
        // Nothing else open: a quick flip does nothing; held, the list shows Swap's row alone and a release opens the menu.
        then(0.3) { flags(option: true); tab(); flags(option: false) }
        then(0.6) {
            check("Swap row alone: a quick Option+Tab does nothing", !Controller.shared.isActive && SwapMenu.opens == menuOpens,
                  "opens=\(SwapMenu.opens - menuOpens)")
            flags(option: true); tab()
        }
        then(0.7) {
            let rows = rowsNow()
            check("Swap row alone: holding Option shows the list with just Swap's row, selected",
                  Controller.shared.panel.isVisible && rows.count == 1 && rows[0].isSelf && Controller.shared.selection == 0, "\(rows.count) rows")
            flags(option: false)
        }
        then(0.5) {
            check("Swap row alone: releasing opens Swap's menu", !Controller.shared.isActive && SwapMenu.opens == menuOpens + 1,
                  "opens=\(SwapMenu.opens - menuOpens)")
            Scene.current = nil
            Settings.showSelfInList = false
        }
        // The setting off: no row.
        then(0.5) { flags(option: true); tab() }
        then(0.7) {
            check("showSelfInList off: no Swap row", Controller.shared.isActive && !rowsNow().isEmpty && !rowsNow().contains { $0.isSelf }, "\(rowsNow().count) rows")
            key(53); flags(option: false)
            Settings.showSelfInList = selfWas
            SwapMenu.dryRun = false
            Settings.showInDock = true
        }
        // The Dock icon follows its setting at once, both ways, without bringing Swap to the front.
        then(0.5) {
            check("showInDock on: Swap is a Dock app", NSApp.activationPolicy() == .regular)
            check("showInDock on: Swap did not come to the front", !NSRunningApplication.current.isActive)
            Settings.showInDock = false
        }
        then(0.5) {
            check("showInDock off: menu bar only again", NSApp.activationPolicy() == .accessory)
            Settings.showInDock = dockWas
        }
        then(0.5) { check("showInDock: back to how it was", NSApp.activationPolicy() == (dockWas ? .regular : .accessory)) }

        // The tap can come down and go back up (what happens when Accessibility is switched off and on).
        then(0.3) { (NSApp.delegate as? AppDelegate)?.rebuildTapForTest(); before = front() }
        then(0.6) { flags(option: true); tab(); flags(option: false) }
        then(1.0) { check("the shortcut works after the keyboard tap is rebuilt", Controller.shared.tap != nil && front() != before, "front=\(front())") }

        // 13. No Tab reached the apps (TextEdit documents would contain a tab character).
        then(0.3) {
            let leaked = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "TextEdit" }.contains { app in
                let el = AXUIElementCreateApplication(app.processIdentifier)
                return ((ax(el, kAXWindowsAttribute) as? [AXUIElement]) ?? []).contains { hasTab($0) }
            }
            check("Tab and letter keystrokes were swallowed, not typed into apps", !leaked)
            log(failures == 0 ? "DONE all passed" : "DONE \(failures) failed")
            NSApp.terminate(nil)
        }
    }
}
#endif
