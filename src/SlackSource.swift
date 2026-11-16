// Slack through Accessibility only: one row per signed-in workspace, and under it the sidebar (channels and DMs)
// of the workspace the window is showing. Slack is Electron, so a few things are not what AppKit would give:
//  - the workspace rail only exposes the current workspace, so the list comes from File > Workspace in the menu
//    bar (names, order and the Cmd+N shortcut live there; AXPress on a menu item switches workspace);
//  - the window's AXWebArea has the address app.slack.com/client/<team>/<conversation>: the team id (T… or, on
//    Enterprise Grid, E…) and the open chat, with no sign-in. Chats open with slack:// links, on every workspace;
//  - the sidebar is a virtual list: only rows Slack has rendered (visible plus a small overscan) exist in the tree.
// AX structure relied on (see the QA harness in "Behind the scenes/qa/children-harness/slack"):
//   AXWindow > ... > AXWebArea > ... > AXOutline (found by its rows having conversation ids, so any language works)
//     AXRows: AXRow/AXOutlineRow, AXDOMIdentifier = conversation id (C…, D…, G…) or "sectionHeading-…" / "Pdrafts" etc.
//       AXGroup (AXDOMClassList p-channel_sidebar__channel [--selected] [--unread])
//         AXGroup (class p-channel_sidebar__user_avatar) for DMs, AXStaticText name parts, AXStaticText badge count
import AppKit
import ApplicationServices

struct SlackWorkspace {
    let id: String
    let name: String
    let icon: NSImage?       // not readable through Accessibility (the rail hides every workspace but the current one)
    let unread: Bool         // only known for the current workspace: Slack prefixes the window title with "* "
    let shortcutIndex: Int   // Cmd+N in Slack, 1-based, the order of File > Workspace
}

enum SlackSource: AppProvider {
    static func start() { SlackRows.start() }
    static func sessionEnded() { SlackRows.sessionCurrent = nil }
    static func arrange(_ rows: inout [WindowItem]) { SlackRows.expand(&rows) }

    static var queue: DispatchQueue { Children.queue(for: SlackSource.self) }

    // The saved list at once for a workspace Swap knows, then a fresh one from the window if it is the one on show.
    // A row that names a workspace only ever shows that workspace's chats: unknown means nothing, never what is on screen.
    static func fetch(_ item: WindowItem, _ done: @escaping ([ChildItem]?) -> Void) -> Bool {
        let ref = Children.parent(of: item), ws = item.workspace
        let known = Set(SlackRecents.teams.map { $0.id })
        func saved(showing: String) -> [ChildItem]? {
            let team = ws.flatMap { SlackRecents.team(named: $0) } ?? (ws == nil ? SlackRecents.teams.first { $0.id == showing } : nil)
            return team.map { SlackRecents.items($0, pins: SlackRecents.pins()) }
        }
        let first = ws.flatMap { _ in saved(showing: "") } ?? []
        if !first.isEmpty { done(first) }
        queue.async {
            if let ref {
                setTree(on: true, app: ref.app)
                if let wanted = pendingExpectation() { _ = waitUntilShowing(wanted, window: ref.window) }
            }
            let snap = ref.flatMap { snapshot(of: $0, known: known) }
            let showing = ref.map { address($0.window).team } ?? ""
            DispatchQueue.main.async {
                if let snap { SlackRecents.absorb(snap) }
                let fresh = saved(showing: showing)
                if fresh == nil, first.isEmpty { done([]) }
                else if let fresh, fresh.map({ "\($0.id)\($0.unread)" }) != first.map({ "\($0.id)\($0.unread)" }) || first.isEmpty { done(fresh) }
            }
        }
        return true
    }

    // A workspace Slack isn't showing: switch to it to open it, or to learn its chats the first time. Nothing
    // waits here: fetch and command wait for Slack's address to show the workspace.
    static func prepare(_ item: WindowItem, expanding: Bool) -> TimeInterval {
        guard let ws = item.workspace, item.child == nil else { return 0 }
        guard let cur = SlackRows.sessionCurrent, !SlackRows.matches(ws, cur) else { SlackRows.used(ws); return 0 }
        if expanding, SlackRecents.team(named: ws) != nil { return 0 }
        SlackRows.switchTo(ws)
        SlackRows.sessionCurrent = ws
        return 0
    }

    // A letter on a Slack row: runs on this provider's queue just before the keystroke. True drops the key: it
    // only goes out once the chat or workspace it is aimed at is on screen.
    static func command(_ key: Int64, app: NSRunningApplication) -> Bool {
        guard let wanted = pendingExpectation() else { return false }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, axTimeout)
        guard let window = slackElement(el, kAXFocusedWindowAttribute) ?? (slackAttr(el, kAXWindowsAttribute) as? [AXUIElement])?.first else { return true }
        AXUIElementSetMessagingTimeout(window, axTimeout)
        return !waitUntilShowing(wanted, window: window)
    }

    // What the next letter or read is waiting for: set when a chat is opened or a workspace switch starts.
    struct Expectation {
        var workspace: String? = nil
        var team: String? = nil
        var conversation: String? = nil
        var failed = false
        var until = Date() + switchWait
    }
    private static let switchWait: TimeInterval = 3
    private static var expectation: Expectation?

    static func expect(_ e: Expectation?) { lock.lock(); expectation = e; lock.unlock() }
    private static func pendingExpectation() -> Expectation? {
        lock.lock(); defer { lock.unlock() }
        if let e = expectation, Date() > e.until { expectation = nil }
        return expectation
    }

    // Polls the window's address, up to the expectation's limit. A failed switch stops at once.
    private static func waitUntilShowing(_ wanted: Expectation, window: AXUIElement) -> Bool {
        while !wanted.failed {
            if pendingExpectation()?.failed == true { break }
            let now = address(window), name = currentWorkspace(windowTitle: slackText(window, kAXTitleAttribute))
            let team = wanted.team.map { $0 == now.team } ?? true
            let chat = wanted.conversation.map { $0 == now.conversation } ?? true
            let workspace = wanted.workspace.map { w in name.map { SlackRows.matches(w, $0) } ?? false } ?? true
            if team && chat && workspace { expect(nil); return true }
            if Date() > wanted.until { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        expect(nil)
        return false
    }

    static let bundleIDs: Set<String> = ["com.tinyspeck.slackmacgap"]

    private static let maxItems = 40
    private static let budget: TimeInterval = 0.9          // hard limit is 1 s per call
    private static let axTimeout: Float = 0.5               // per Accessibility message

    // Per window: the sidebar outline element and the map child id -> Slack conversation id (the row's DOM id),
    // so open() can find the row again after Slack re-renders. Touched from the AX queue and the main thread.
    private static let lock = NSLock()
    private static var sidebars: [CGWindowID: AXUIElement] = [:]
    private static var conversationIDs: [CGWindowID: [String: String]] = [:]

    // MARK: Electron's accessibility switch

    // Electron keeps web content out of Accessibility until something asks, and AXManualAccessibility is its
    // documented switch for third-party tools (electronjs.org/docs/latest/tutorial/accessibility). Measured
    // 5 Nov 2026 on a fresh Electron 44 instance: no web area through 15 s of reads, web areas within 3 s of
    // setting it, and the attribute still reads 0 afterwards, so it cannot be read back and is only set.
    // The cost falls on Slack: it builds its accessibility tree, which Electron warns can slow rendering. So it
    // is on only while Return expands apps is on, once per Slack launch, and handed back when that goes off.
    private static var treeOn = Set<pid_t>()

    static func setTree(on: Bool, app: NSRunningApplication) {
        let pid = app.processIdentifier
        lock.lock(); let already = treeOn.contains(pid); lock.unlock()
        guard on != already else { return }
        let done = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString,
                                                on ? kCFBooleanTrue : kCFBooleanFalse) == .success
        guard done else { return }
        lock.lock(); if on { treeOn.insert(pid) } else { treeOn.remove(pid) }; lock.unlock()
    }

    // MARK: Nightly check

    // Attributes only: no press, no focus, no workspace switch. Names and ids stay inside this call. "info.otherView":
    // nothing to judge tonight: Slack's web content is switched off (Electron, see setTree; a separate process
    // cannot tell why, and this check changes nothing) or it is on a view with no chat and no sidebar.
    static func health(app: NSRunningApplication) -> [String: Bool] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)
        let windows = Health.windows(of: app)
        var web = false, addressed = false, outline = false, rows = false, chatOpen = false
        for (i, window) in windows.prefix(4).enumerated() {
            AXUIElementSetMessagingTimeout(window, axTimeout)
            if webArea(window) != nil { web = true }
            let here = address(window)
            if !here.team.isEmpty { addressed = true }
            if isConversationID(here.conversation) { chatOpen = true }
            let ref = ParentRef(app: app, window: window, id: CGWindowID(i + 1), title: "")
            guard sidebar(of: ref, deadline: Date() + budget) != nil else { continue }
            outline = true
            rows = true   // an outline only counts as the sidebar if its rows have conversation ids
        }
        return ["window": !windows.isEmpty, "webAreaClientPath": addressed, "sidebarOutline": outline, "conversationRows": rows,
                "workspaceMenu": !workspaceMenuEntries(appElement).isEmpty,
                "info.otherView": !web || (addressed && !outline && !chatOpen)]
    }

    // MARK: Workspaces

    static func workspaces(of app: NSRunningApplication) -> [SlackWorkspace] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)
        let entries = workspaceMenuEntries(appElement)
        let title = frontWindowTitle(appElement)
        let current = currentWorkspace(windowTitle: title)
        let unreadNow = slackTitleHasUnread(title)
        return entries.map { entry in
            var name = entry.name
            // Slack truncates long names in the menu ("Northwind Trading Li…"); the window title has the full one.
            if name.hasSuffix("…"), let full = current, full.hasPrefix(String(name.dropLast())) { name = full }
            let isCurrent = current != nil && name == current
            return SlackWorkspace(id: name, name: name, icon: nil, unread: isCurrent && unreadNow, shortcutIndex: entry.index)
        }
    }

    // "Slack (DM) - Acme - Slack", "* #general (Channel) - Northwind - Slack",
    // "Threads - Acme - 1 new item - Slack" all give the workspace name.
    static func currentWorkspace(windowTitle: String) -> String? {
        var title = windowTitle
        if title.hasPrefix("* ") { title.removeFirst(2) }
        guard title.hasSuffix(" - Slack") else { return nil }
        title.removeLast(" - Slack".count)
        var parts = title.components(separatedBy: " - ")
        // " - N new items": any language, but only with a chat in front of it, as a workspace name can start with a digit.
        if parts.count >= 3, let last = parts.last, last.range(of: #"^\d+\s"#, options: .regularExpression) != nil { parts.removeLast() }
        guard parts.count >= 2, let name = parts.last?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name
    }

    // Presses the workspace's item in Slack's menu. False when it can't: then nothing else is tried. A keystroke
    // here could land in whatever app is in front.
    @discardableResult
    static func switchTo(_ workspace: SlackWorkspace, app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)
        guard let entry = workspaceMenuEntries(appElement).first(where: { $0.index == workspace.shortcutIndex }) else { return false }
        return AXUIElementPerformAction(entry.element, kAXPressAction as CFString) == .success
    }

    static func switchFailed() {
        lock.lock(); expectation?.failed = true; lock.unlock()
    }

    private struct MenuEntry { let name: String; let index: Int; let element: AXUIElement }

    // File > Workspace > "<name> Cmd+N" items. Falls back to any top-level menu holding Cmd+digit items.
    private static func workspaceMenuEntries(_ appElement: AXUIElement) -> [MenuEntry] {
        guard let bar = slackElement(appElement, kAXMenuBarAttribute) else { return [] }
        let top = slackKids(bar)
        let ordered = top.sorted { slackText($0, kAXTitleAttribute) == "File" && slackText($1, kAXTitleAttribute) != "File" }
        for menuBarItem in ordered {
            for menu in slackKids(menuBarItem) {
                for item in slackKids(menu) {
                    for submenu in slackKids(item) {
                        let entries = digitEntries(in: submenu)
                        if entries.count >= 1 { return entries }
                    }
                }
            }
        }
        return []
    }

    private static func digitEntries(in menu: AXUIElement) -> [MenuEntry] {
        var out: [MenuEntry] = []
        for item in slackKids(menu) {
            let cmd = slackText(item, kAXMenuItemCmdCharAttribute)
            guard cmd.count == 1, let index = Int(cmd), index >= 1, slackText(item, kAXMenuItemCmdModifiersAttribute) == "0" else { continue }
            let name = slackText(item, kAXTitleAttribute)
            if !name.isEmpty { out.append(MenuEntry(name: name, index: index, element: item)) }
        }
        return out
    }

    private static func frontWindowTitle(_ appElement: AXUIElement) -> String {
        if let focused = slackElement(appElement, kAXFocusedWindowAttribute) { return slackText(focused, kAXTitleAttribute) }
        guard let first = (slackAttr(appElement, kAXWindowsAttribute) as? [AXUIElement])?.first else { return "" }
        return slackText(first, kAXTitleAttribute)
    }

    // MARK: Sidebar

    static func children(of parent: ParentRef) -> [ChildItem] {
        let start = Date()
        AXUIElementSetMessagingTimeout(parent.window, axTimeout)
        var rows = sidebarRows(of: parent, deadline: start + budget)
        if rows.isEmpty {   // the cached outline went stale after a re-render: look it up once more
            forget(parent.id)
            rows = sidebarRows(of: parent, deadline: start + budget)
        }
        var items: [ChildItem] = []
        var ids: [String: String] = [:]
        for row in rows {
            if items.count >= maxItems || Date() > start + budget { break }
            guard let parsed = parseRow(row) else { continue }
            if ids[parsed.item.id] != nil { continue }   // same name twice (rare): keep the first, the sidebar order
            ids[parsed.item.id] = parsed.conversationID
            items.append(parsed.item)
        }
        lock.lock(); conversationIDs[parent.id] = ids; lock.unlock()
        return items
    }

    struct Snapshot { let workspace: String; let team: String; let conversation: String; let rows: [(item: ChildItem, conversation: String)] }

    // What Slack's window shows now, or nil unless it all belongs together. Sidebar, address and title are separate
    // reads and Slack updates them one by one during a workspace switch, so: the address and title must not move
    // while the sidebar is read, and the sidebar's selected row must be the chat in the address. A team not seen
    // before has nothing to be compared with, so it must also hold still for a moment. Names, ids, unread marks only.
    static func snapshot(of parent: ParentRef, known: Set<String>) -> Snapshot? {
        let before = address(parent.window), title = slackText(parent.window, kAXTitleAttribute)
        guard !before.team.isEmpty, isConversationID(before.conversation), let name = currentWorkspace(windowTitle: title) else { return nil }
        let kids = children(of: parent)
        lock.lock(); let ids = conversationIDs[parent.id] ?? [:]; lock.unlock()
        if !known.contains(before.team) { Thread.sleep(forTimeInterval: 0.3) }
        let after = address(parent.window)
        guard after == before, currentWorkspace(windowTitle: slackText(parent.window, kAXTitleAttribute)) == name else { return nil }
        let rows = kids.compactMap { k in ids[k.id].map { (item: k, conversation: $0) } }
        guard rows.first(where: { $0.item.active })?.conversation == after.conversation else { return nil }
        return Snapshot(workspace: name, team: after.team, conversation: after.conversation, rows: rows)
    }

    private static func webArea(_ window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        func walk(_ el: AXUIElement, _ depth: Int) {
            if found != nil || depth > 12 { return }
            if slackText(el, kAXRoleAttribute) == "AXWebArea" { found = el; return }
            for k in slackKids(el) { walk(k, depth + 1) }
        }
        walk(window, 0)
        return found
    }

    // app.slack.com/client/<team>/<conversation> from the window's web area. Empty unless the team id looks right.
    private static func address(_ window: AXUIElement) -> Address {
        guard let web = webArea(window), let v = slackAttr(web, "AXURL") else { return Address() }
        let url = (v as? URL)?.absoluteString ?? (v as? String) ?? ""
        let path = url.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "client"), parts.count > i + 1, isTeamID(parts[i + 1]) else { return Address() }
        return Address(team: parts[i + 1], conversation: parts.count > i + 2 ? parts[i + 2] : "")
    }
    private struct Address: Equatable { var team = ""; var conversation = "" }

    static func open(_ child: ChildItem, in parent: ParentRef) { DispatchQueue.main.async { SlackRecents.open(child) } }

    private static func forget(_ id: CGWindowID) {
        lock.lock(); sidebars[id] = nil; lock.unlock()
    }

    private static func sidebarRows(of parent: ParentRef, deadline: Date) -> [AXUIElement] {
        guard let outline = sidebar(of: parent, deadline: deadline) else { return [] }
        return (slackAttr(outline, kAXRowsAttribute) as? [AXUIElement]) ?? []
    }

    private static func sidebar(of parent: ParentRef, deadline: Date) -> AXUIElement? {
        lock.lock(); let cached = sidebars[parent.id]; lock.unlock()
        if let el = cached, slackText(el, kAXRoleAttribute) == kAXOutlineRole as String { return el }
        var found: AXUIElement?
        var visited = 0
        // Depth-first, left to right: the sidebar column comes before the message pane, so the walk stops early.
        func walk(_ el: AXUIElement, _ depth: Int) {
            if found != nil || depth > 24 || visited > 600 || Date() > deadline { return }
            visited += 1
            let role = slackText(el, kAXRoleAttribute)
            if role == kAXOutlineRole as String {
                let list = (slackAttr(el, kAXRowsAttribute) as? [AXUIElement]) ?? []
                if list.prefix(60).contains(where: { isConversationID(slackText($0, "AXDOMIdentifier")) }) { found = el }
                return
            }
            // Never walk the message pane or the toolbars; the sidebar lives in groups and the web area.
            if role == kAXListRole as String || role == kAXToolbarRole as String || role == kAXTabGroupRole as String
                || role == kAXTextFieldRole as String || role == kAXStaticTextRole as String || role == kAXButtonRole as String { return }
            for child in slackKids(el) { walk(child, depth + 1) }
        }
        walk(parent.window, 0)
        if let el = found { lock.lock(); sidebars[parent.id] = el; lock.unlock() }
        return found
    }

    private struct ParsedRow { let item: ChildItem; let conversationID: String }

    // Conversation ids look like C0ABC1DEF / D0ABC1DEF2G (made-up examples); headings, Threads, Drafts etc. have other ids.
    static func isConversationID(_ id: String) -> Bool {
        guard id.count >= 9, let first = id.first, "CDG".contains(first) else { return false }
        return id.allSatisfy { ($0.isUppercase || $0.isNumber) && $0.isASCII }
    }
    static func isTeamID(_ id: String) -> Bool {
        guard id.count >= 7, let first = id.first, "TE".contains(first) else { return false }
        return id.allSatisfy { ($0.isUppercase || $0.isNumber) && $0.isASCII }
    }

    private static func parseRow(_ row: AXUIElement) -> ParsedRow? {
        let conversationID = slackText(row, "AXDOMIdentifier")
        guard isConversationID(conversationID) else { return nil }
        var classes = slackClasses(row)
        var texts: [String] = []
        var images: [String] = []
        var hasAvatar = false
        func collect(_ el: AXUIElement, _ depth: Int) {
            for child in slackKids(el) {
                let role = slackText(child, kAXRoleAttribute)
                if role == kAXStaticTextRole as String {
                    texts.append(slackText(child, kAXValueAttribute))
                } else if role == kAXImageRole as String {
                    images.append(slackText(child, kAXDescriptionAttribute).lowercased())
                } else if role == kAXGroupRole as String {
                    let cls = slackClasses(child)
                    if depth == 0 { classes += cls }
                    if cls.contains("p-channel_sidebar__user_avatar") { hasAvatar = true }
                    if depth < 2 { collect(child, depth + 1) }
                }
            }
        }
        collect(row, 0)

        var unread = 0
        if let last = texts.last, let count = Int(last.trimmingCharacters(in: .whitespaces)), !last.isEmpty {
            unread = count; texts.removeLast()   // trailing badge: "27" after "Drafts & sent", mention counts on rows
        }
        if texts.last == "you" { texts.removeLast() }
        let name = texts.joined().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        // The mention badge itself is hidden from Accessibility; "--unread" / "--has-badge" are the only flags.
        if unread == 0 && classes.contains(where: { $0.hasSuffix("--unread") || $0.hasSuffix("--has-badge") }) { unread = 1 }
        let active = classes.contains(where: { $0.hasSuffix("--selected") }) || slackText(row, kAXSelectedAttribute) == "1"

        let kind: String
        if conversationID.hasPrefix("D") || hasAvatar || classes.contains(where: { $0.hasSuffix("--mpim") }) || texts.contains(", ") {
            kind = "DM"      // group DMs ("--mpim") have a C… id but show "A, B" names
        } else if classes.contains(where: { $0.contains("private") }) || images.contains(where: { $0.contains("lock") || $0.contains("private") }) {
            kind = "private channel"
        } else {
            kind = "channel"  // Slack hides the # and lock glyphs from Accessibility, so a private channel reads as "channel"
        }
        // Channels show with their # in the list, as in Slack; the id keeps the bare name.
        let item = ChildItem(id: "\(kind):\(name)", title: kind.hasSuffix("channel") ? "#" + name : name, detail: kind, icon: nil, active: active, unread: unread)
        return ParsedRow(item: item, conversationID: conversationID)
    }

}

// MARK: - Accessibility helpers (private to this file; Windows.swift has its own)

private func slackAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref
}

private func slackText(_ el: AXUIElement, _ attr: String) -> String {
    guard let v = slackAttr(el, attr) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

private func slackElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let v = slackAttr(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)   // type checked on the line above
}

// "* " in front, or " - N new items" before " - Slack": Slack's two ways of flagging unreads in the title. Worded
// by count, not by the English, and only with a chat and a workspace in front, as a workspace name can start with a digit.
func slackTitleHasUnread(_ title: String) -> Bool {
    title.hasPrefix("* ") || title.range(of: #"^.+ - .+ - \d+ [^-]+ - Slack$"#, options: .regularExpression) != nil
}

private func slackKids(_ el: AXUIElement) -> [AXUIElement] {
    (slackAttr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

// Chromium exposes the DOM class list; Slack's state classes (--selected, --unread) are the only readable flags.
private func slackClasses(_ el: AXUIElement) -> [String] {
    (slackAttr(el, "AXDOMClassList") as? [String]) ?? []
}
