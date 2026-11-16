// One row per Slack workspace (Settings.slackWorkspaces). Slack has one window; its other workspaces become
// rows of their own, placed by when you last used each (read from Slack's window title while it is in front).
// The workspace list comes from SlackSource and is cached here. Slack is only read while a feature that needs it is
// on, on a title-change notification rather than a timer. Last use is written to disk only while Return expands
// apps is on; with that off it lasts for this run, and turning it off deletes what was saved (SlackRecents.clearSaved).
import AppKit
import ApplicationServices

enum SlackRows {
    static let bundleID = "com.tinyspeck.slackmacgap"
    private(set) static var workspaces: [SlackWorkspace] = []
    private static var lastUse: [String: Date] = {
        (UserDefaults.standard.dictionary(forKey: "slackWorkspaceUse") as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }()
    private static var started = false
    private static var lastTitle = ""
    private static var drillWas: Bool?
    private static var observer: AXObserver?
    private static var observedPID: pid_t = 0
    private static var observedWindow: AXUIElement?

    static var app: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }
    private static var wanted: Bool { Settings.drillIn || Settings.slackWorkspaces }

    static func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard wanted, let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.bundleIdentifier == bundleID else { return }
            attach(a)
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { noteCurrent() }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard wanted, let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, a.bundleIdentifier == bundleID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { attach(a); refresh() }
        }
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { _ in settingsChanged() }
        settingsChanged()
    }

    // Follows the settings: reads only while wanted, deletes what was saved when Return expands apps goes off.
    private static func settingsChanged() {
        let drill = Settings.drillIn, first = drillWas == nil, changed = drillWas != drill
        drillWas = drill
        if !drill, changed { SlackRecents.clearSaved(pins: false) }   // also clears what an older build wrote with it off
        if let app, changed || first {
            SlackSource.queue.async { SlackSource.setTree(on: drill, app: app) }
        }
        if wanted {
            if let app { attach(app) }
            if first || workspaces.isEmpty { refresh() }
        } else {
            detach()
            workspaces = []
        }
    }

    // Slack changing its window title is the only signal needed, so nothing polls.
    private static let titleChanged: AXObserverCallback = { _, _, _, _ in
        DispatchQueue.main.async {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { noteCurrent() }
        }
    }

    private static func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if Settings.drillIn { SlackSource.queue.async { SlackSource.setTree(on: true, app: app) } }
        if observedPID != pid || observer == nil {
            detach()
            var made: AXObserver?
            guard AXObserverCreate(pid, titleChanged, &made) == .success, let made else { return }
            observer = made
            observedPID = pid
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .commonModes)
        }
        guard let observer else { return }
        SlackSource.queue.async {
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 0.5)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &ref) == .success, let w = ref else { return }
            let window = w as! AXUIElement
            if let old = observedWindow {
                if CFEqual(old, window) { return }
                AXObserverRemoveNotification(observer, old, kAXTitleChangedNotification as CFString)
            }
            observedWindow = AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, nil) == .success ? window : nil
        }
    }

    private static func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; observedPID = 0
        SlackSource.queue.async { observedWindow = nil }
    }

    static func refresh() {
        guard let app, wanted else { workspaces = []; return }
        SlackSource.queue.async {
            let ws = SlackSource.workspaces(of: app)
            DispatchQueue.main.async {
                // A name Slack's menu shortens: the full one from the window title, once known, so rows keep one name.
                workspaces = ws.map { w in
                    guard w.name.hasSuffix("…"), let full = SlackRecents.team(named: w.name)?.name else { return w }
                    return SlackWorkspace(id: full, name: full, icon: w.icon, unread: w.unread, shortcutIndex: w.shortcutIndex)
                }
            }
        }
    }

    // Marks the workspace of Slack's front window as used now (read off the main thread).
    static func noteCurrent() {
        guard let app, wanted else { return }
        let drill = Settings.drillIn, known = Set(SlackRecents.teams.map { $0.id })
        SlackSource.queue.async {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.5)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &ref) == .success, let w = ref else { return }
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success,
                  let title = t as? String, let name = SlackSource.currentWorkspace(windowTitle: title) else { return }
            let changed = title != lastTitle
            lastTitle = title
            // A new title means a new chat is open: the sidebar marks it, at no API cost.
            let snap = changed && drill ? SlackSource.snapshot(of: ParentRef(app: app, window: w as! AXUIElement, id: windowID(w as! AXUIElement) ?? 0, title: title), known: known) : nil
            DispatchQueue.main.async {
                used(name)
                if let snap { SlackRecents.absorb(snap) }
            }
        }
    }

    static func used(_ name: String) {
        let full = workspace(named: name)?.name ?? name
        lastUse[full] = Date()
        if Settings.drillIn { UserDefaults.standard.set(lastUse.mapValues { $0.timeIntervalSince1970 }, forKey: "slackWorkspaceUse") }
    }
    static func forgetUse() {
        lastUse = [:]
        UserDefaults.standard.removeObject(forKey: "slackWorkspaceUse")
    }
    static func lastUsed(_ name: String) -> Date? { lastUse[name] ?? lastUse.first { matches($0.key, name) }?.value }

    // Slack shortens long names in its menu ("Northwind Trading Li…"); the window title has the full one.
    static func matches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = a.hasSuffix("…") ? String(a.dropLast()) : a, y = b.hasSuffix("…") ? String(b.dropLast()) : b
        return (x.count < a.count && y.hasPrefix(x)) || (y.count < b.count && x.hasPrefix(y))
    }
    static func workspace(named name: String) -> SlackWorkspace? { workspaces.first { matches($0.name, name) } }
    static func current(ofTitle title: String) -> String? {
        SlackSource.currentWorkspace(windowTitle: title).map { workspace(named: $0)?.name ?? $0 }
    }

    // Starts the switch and says what to wait for. If it can't be started nothing else is tried, and the letter
    // or read waiting on it is dropped.
    static func switchTo(_ name: String) {
        SlackSource.expect(.init(workspace: name, team: SlackRecents.team(named: name)?.id))
        guard let app, let ws = workspace(named: name) else { SlackSource.switchFailed(); return }
        used(ws.name)
        if let team = SlackRecents.team(named: ws.name) { SlackRecents.openWorkspace(team); return }
        SlackSource.queue.async { if !SlackSource.switchTo(ws, app: app) { SlackSource.switchFailed() } }
    }

    // Replaces the Slack window row by one row per workspace. The one in use keeps the window's place; the
    // others go where their last use falls among the windows below it; never used ones go to the end.
    static var sessionCurrent: String?   // the workspace Slack showed when the list opened, so rows keep their places

    static func expand(_ base: inout [WindowItem]) {
        guard Settings.slackWorkspaces, workspaces.count > 1,
              let si = base.firstIndex(where: { $0.app?.bundleIdentifier == bundleID && $0.child == nil && $0.workspace == nil }) else { return }
        let slack = base[si]
        let cur = sessionCurrent ?? current(ofTitle: slack.title) ?? workspaces[0].name
        sessionCurrent = cur
        func row(_ name: String) -> WindowItem {
            WindowItem(app: slack.app, window: slack.window, id: slack.id, title: name, appName: slack.appName, icon: slack.icon,
                       minimized: slack.minimized, desktop: slack.desktop, workspace: name)
        }
        base[si] = row(cur)
        base[si].dot = slackTitleHasUnread(slack.title)   // Slack's title says so for this workspace
        let hidden = Settings.slackHidden
        let others = workspaces.map { $0.name }.filter { !matches($0, cur) && !hidden.contains($0) }
            .sorted { (lastUsed($0) ?? .distantPast) > (lastUsed($1) ?? .distantPast) }
        for name in others {
            var at = base.count
            if let when = lastUsed(name) {
                for i in (si + 1)..<base.count {
                    let t = base[i].workspace.flatMap { lastUsed($0) } ?? Recency.times[base[i].id]
                    if t == nil || t! < when { at = i; break }
                }
            }
            base.insert(row(name), at: at)
        }
    }
}
