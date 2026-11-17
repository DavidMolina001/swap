// WhatsApp's chat list, read through Accessibility: no sign-in and no network. WhatsApp keeps its list newest first,
// so the top rows are the recent chats. Used: chat names and the unread mark.
// Message previews: a chat row carries its name in one attribute and its preview in another, and no separate unread
// element is known, so the mark for one chat can only come from the preview attribute. That attribute is read only
// on Return, only while the Dock badge says something is unread, stops as soon as the badge is accounted for, and is
// searched and dropped in the same line: never kept, logged or shown. NOT confirmed on a real unread chat and English
// only. The dot on the WhatsApp row needs none of this: it is the app's Dock badge, read from the Dock, which any app
// can see. Reading never presses anything in WhatsApp; only opening a chat or the Archived row does.
import AppKit
import ApplicationServices

enum WhatsAppSource: AppProvider {
    static func decorate(_ row: inout WindowItem, window: AXUIElement) { row.dot = (row.app.map(dockBadge) ?? 0) > 0 }
    static func command(_ key: Int64, app: NSRunningApplication) -> Bool {
        guard key == Controller.newKey else { return false }   // WhatsApp has no Cmd+N: its + button is the new chat
        newChat(app)
        return true
    }
    static func groupChildren(of group: ChildItem, in parent: ParentRef) -> [ChildItem] { archived(of: parent) }

    static let bundleIDs: Set<String> = ["net.whatsapp.WhatsApp"]
    static func canExpand(row: WindowItem) -> Bool { Settings.whatsappChats }   // opt-in: a plain row (with its Dock badge dot) until switched on
    private static let shown = 6
    private static let timeout: Float = 0.5

    private static func value(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var r: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &r) == .success ? r : nil
    }
    private static func text(_ e: AXUIElement, _ a: String) -> String {
        ((value(e, a) as? String) ?? "").replacingOccurrences(of: "\u{200E}", with: "").trimmingCharacters(in: .whitespaces)
    }
    private static func kids(_ e: AXUIElement) -> [AXUIElement] { (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    // Finds an element by its Accessibility identifier, staying out of the open conversation.
    private static func find(_ id: String, in e: AXUIElement, _ depth: Int = 0) -> AXUIElement? {
        guard depth < 10 else { return nil }
        let own = text(e, "AXIdentifier")
        if own == id { return e }
        if own == "ChatMessagesTableView" { return nil }
        for k in kids(e) { if let hit = find(id, in: k, depth + 1) { return hit } }
        return nil
    }

    private static func rows(_ window: AXUIElement) -> [AXUIElement] {
        AXUIElementSetMessagingTimeout(window, timeout)
        guard let table = find("ChatListView_TableView", in: window) else { return [] }
        return kids(table).filter { text($0, kAXRoleAttribute) == kAXButtonRole as String && !text($0, kAXDescriptionAttribute).isEmpty }
    }
    // The preview attribute is searched here and goes no further. See the top of the file.
    private static func isUnread(_ row: AXUIElement) -> Bool {
        text(row, kAXValueAttribute).range(of: #"\bunread\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // The red number on the app's Dock icon: how much is unread with no look inside WhatsApp, in any language. 0 when
    // there is none, or macOS has badges off for WhatsApp. "99+" counts as 99. Found by the item's app path; kept,
    // as asking a known item is one message and this runs on every list build.
    private static let dockLock = NSLock()
    private static var dockItem: AXUIElement?

    static func dockBadge(_ app: NSRunningApplication) -> Int {
        dockLock.lock(); defer { dockLock.unlock() }
        if dockItem == nil || text(dockItem!, kAXRoleAttribute).isEmpty { dockItem = findDockItem(app) }
        guard let dockItem else { return 0 }
        return Int(text(dockItem, "AXStatusLabel").filter(\.isNumber)) ?? (text(dockItem, "AXStatusLabel").isEmpty ? 0 : 1)
    }

    private static func findDockItem(_ app: NSRunningApplication) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let path = app.bundleURL?.resolvingSymlinksInPath().path else { return nil }
        let el = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.2)
        for list in kids(el) where text(list, kAXRoleAttribute) == kAXListRole as String {
            AXUIElementSetMessagingTimeout(list, 0.2)
            for item in kids(list) {
                AXUIElementSetMessagingTimeout(item, 0.2)
                if (value(item, kAXURLAttribute) as? URL)?.resolvingSymlinksInPath().path.trimmingCharacters(in: ["/"]) == path.trimmingCharacters(in: ["/"]) { return item }
            }
        }
        return nil
    }

    // WhatsApp may be showing Archived: go back so the normal chat list is what gets read.
    private static func showChats(_ window: AXUIElement) {
        AXUIElementSetMessagingTimeout(window, timeout)
        guard find("ChatListView_TableView", in: window) == nil else { return }
        for id in ["SidebarButton_Chats", "BackButton"] {   // the Back button answers but does nothing, so the sidebar comes first
            guard let b = find(id, in: window) else { continue }
            AXUIElementPerformAction(b, kAXPressAction as CFString)
            if waitFor("ChatListView_TableView", in: window, seconds: 0.5) != nil { return }
        }
    }

    // Opens the Archived view. Pressing the row is what WhatsApp itself does; no chat opens.
    private static func showArchived(_ window: AXUIElement) -> AXUIElement? {
        showChats(window)
        guard let cell = find("ChatListView_archiveCell", in: window) else { return nil }
        AXUIElementPerformAction(kids(cell).first ?? cell, kAXPressAction as CFString)
        return waitFor("WAArchivedChatsViewController", in: window, seconds: 0.7)
    }

    // Reads again until the view is there: the Archived round trip has to fit inside a provider's time limit.
    private static func waitFor(_ id: String, in window: AXUIElement, seconds: TimeInterval) -> AXUIElement? {
        let stop = Date().addingTimeInterval(seconds)
        while true {
            if let hit = find(id, in: window) { return hit }
            if Date() > stop { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // The archived chats, read with a quick visit to the Archived view and back, so WhatsApp is left as it was.
    static func archived(of parent: ParentRef) -> [ChildItem] {
        guard let list = showArchived(parent.window) else { return [] }
        let items = kids(list).filter { text($0, kAXRoleAttribute) == kAXButtonRole as String && !text($0, kAXDescriptionAttribute).isEmpty }.map {
            ChildItem(id: "arch:" + text($0, kAXDescriptionAttribute), title: text($0, kAXDescriptionAttribute), detail: "archived", icon: nil, active: false, unread: 0)
        }
        showChats(parent.window)
        return items
    }

    // A list that isn't on show (Calls, Status, Settings, Archived) gives nothing and WhatsApp is left where it is.
    static func children(of parent: ParentRef) -> [ChildItem] {
        let list = rows(parent.window)
        let open = find("NavigationBar_HeaderViewButton", in: parent.window).map { text($0, kAXDescriptionAttribute) }
        var unread: [ChildItem] = [], recent: [ChildItem] = []
        var left = list.isEmpty ? 0 : dockBadge(parent.app)
        for r in list {
            let name = text(r, kAXDescriptionAttribute), new = left > 0 && isUnread(r)
            if new { left -= 1 }
            let item = ChildItem(id: name, title: name, detail: "", icon: nil, active: name == open, unread: new ? 1 : 0)
            if new { unread.append(item) } else if recent.count < shown { recent.append(item) }
        }
        let archive = Settings.whatsappArchive ? [ChildItem(id: archiveID, title: "Archived", detail: "", icon: nil, active: false, unread: 0, isGroup: true)] : []
        return list.isEmpty ? [] : archive + unread + recent
    }

    private static let archiveID = "archive"

    static func open(_ child: ChildItem, in parent: ParentRef) {
        if child.id == archiveID { _ = showArchived(parent.window); return }
        if child.id.hasPrefix("arch:") {
            guard let list = showArchived(parent.window) else { return }
            if let row = kids(list).first(where: { text($0, kAXDescriptionAttribute) == child.title }) { AXUIElementPerformAction(row, kAXPressAction as CFString) }
            return
        }
        showChats(parent.window)
        if let row = rows(parent.window).first(where: { text($0, kAXDescriptionAttribute) == child.id }) {
            AXUIElementPerformAction(row, kAXPressAction as CFString)
        }
    }

    // Nightly check. Reads only: never showChats, which presses buttons. "info.otherView": WhatsApp is on Archived,
    // Calls, Status or Settings, so its sidebar is there but the chat list has nothing to say tonight.
    static func health(app: NSRunningApplication) -> [String: Bool] {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, timeout)
        guard let w = Health.windows(of: app).first else {
            return ["window": false, "chatListTable": false, "chatRows": false, "newChatButton": false]
        }
        AXUIElementSetMessagingTimeout(w, timeout)
        let table = find("ChatListView_TableView", in: w) != nil
        return ["window": true, "chatListTable": table, "chatRows": !rows(w).isEmpty, "newChatButton": find("NavigationBar_NewChatButton", in: w) != nil,
                "info.otherView": !table && (find("WAArchivedChatsViewController", in: w) != nil || find("SidebarButton_Chats", in: w) != nil),
                "info.dockItem": { dockLock.lock(); defer { dockLock.unlock() }; return findDockItem(app) != nil }()]
    }

    static func newChat(_ app: NSRunningApplication) {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, timeout)
        guard let w = (value(el, kAXWindowsAttribute) as? [AXUIElement])?.first, let b = find("NavigationBar_NewChatButton", in: w) else { return }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
    }
}
