// Drill-in: a row in the list can expand into children (a browser window's tabs, a Slack workspace's chats).
// The shared types; each source (BrowserTabs.swift, SlackSource.swift) fills them. Sources take a ParentRef, not
// a WindowItem, so they compile and run on their own in the QA harness.
import AppKit
import ApplicationServices

enum ChildOrder { case natural, recent }   // tab strip order, or most recently used first

struct ParentRef {
    let app: NSRunningApplication
    let window: AXUIElement
    let id: CGWindowID
    let title: String
}

struct ChildItem {
    let id: String        // stable inside its parent: tab index or id, channel or DM name
    let title: String
    let detail: String    // right-hand text: "DM · 2 new", "channel", a site name
    let icon: NSImage?
    let active: Bool      // the tab or chat the window is showing now
    let unread: Int
    var isGroup = false   // a row that holds more rows, such as WhatsApp's Archived
}

// What a key does on a row. One table, in one place: W, Q, P and the letters mean the same on every row, and a key a
// row has no use for says so (Controller.refuse) instead of doing something else.
enum Verb { case close, quit, pin, command }

enum Verbs {
    enum Kind { case window, place, tab, chat, inner, group, windowless, found, menu }

    static let table: [Kind: Set<Verb>] = [
        .window: [.close, .quit, .command],
        .place: [.quit, .command],              // a Slack workspace: it shares one window, so W would take every workspace with it
        .tab: [.close, .quit, .pin, .command],  // a child its provider can close
        .chat: [.quit, .pin, .command],         // a child the app keeps open by itself
        .inner: [.quit, .command],              // inside a group, such as WhatsApp's Archived
        .group: [.quit],
        .windowless: [.command],                // Finder with no window: N opens one
        .found: [],                             // a file or an app from search: Return opens it, nothing else applies
        .menu: [],                              // Swap's own row: Return opens Swap's menu, nothing else applies
    ]

    static func kind(of item: WindowItem) -> Kind {
        if item.isSelf { return .menu }
        if item.opens != nil || item.app == nil { return .found }
        if let kid = item.child {
            if kid.isGroup { return .group }
            if item.depth > 1 { return .inner }
            return Children.canClose(kid, in: item) ? .tab : .chat
        }
        if item.window == nil { return .windowless }
        return item.workspace == nil ? .window : .place
    }

    static func allows(_ verb: Verb, on item: WindowItem) -> Bool { table[kind(of: item)]?.contains(verb) == true }

    static func refusal(_ verb: Verb) -> String {
        switch verb {
        case .close: return "W closes windows and tabs"
        case .quit: return "Q needs an app with a window"
        case .pin: return "P pins tabs and chats"
        case .command: return "That key needs an open app"
        }
    }
    static let notAKey = "Not a shortcut. / searches"
    static let menuRow = "Swap's row only opens its menu"
    static let stayedOpen = "That tab stayed open"
    static let windowGone = "That window has closed"
}

// The sources Swap knows, the fetch with its time limit, and which children were used last.
enum Children {
    static var sources: [AppProvider.Type] = []

    // Reads can only stop one provider: each has a queue of its own, and none of it runs on the main thread.
    private static let queueLock = NSLock()
    private static var queues: [ObjectIdentifier: DispatchQueue] = [:]
    static func queue(for provider: AppProvider.Type) -> DispatchQueue {
        queueLock.lock(); defer { queueLock.unlock() }
        let key = ObjectIdentifier(provider)
        if let q = queues[key] { return q }
        let q = DispatchQueue(label: "swap.provider.\(provider)", qos: .userInitiated)
        queues[key] = q
        return q
    }
    static let timeLimit: TimeInterval = 1.2      // for one read, from when it starts
    static let queueLimit: TimeInterval = 3       // from when it was asked for, in case the provider's queue never reaches it

    static func provider(for app: NSRunningApplication?) -> AppProvider.Type? {
        guard let b = app?.bundleIdentifier else { return nil }
        return sources.first { $0.bundleIDs.contains(b) }
    }
    static func addRows(to pages: [Windows.Page], current: Int) -> [Windows.Page] { sources.reduce(pages) { $1.addRows(to: $0, current: current) } }
    static func arrange(_ rows: inout [WindowItem]) { for p in sources { p.arrange(&rows) } }
    static func prepare(_ item: WindowItem, expanding: Bool) -> TimeInterval { provider(for: item.app)?.prepare(item, expanding: expanding) ?? 0 }
    static func openWithoutWindow(_ item: WindowItem) {
        guard let src = provider(for: item.app) else { return }
        queue(for: src).async { src.openWithoutWindow(item) }
    }
    static func sessionEnded() { sources.forEach { $0.sessionEnded() } }
    static func start() { sources.forEach { $0.start() } }
    // What's inside a group row, with the same limits as a fetch. nil when there is no answer in time.
    static func groupChildren(of group: ChildItem, item: WindowItem, _ done: @escaping ([ChildItem]?) -> Void) {
        guard let src = provider(for: item.app), let ref = parent(of: item) else { done(nil); return }
        let reply = Reply(done)
        reply.expire(after: queueLimit)
        queue(for: src).async {
            reply.expire(after: timeLimit)
            let kids = src.groupChildren(of: group, in: ref)
            reply.send(kids)
        }
    }
    static func canClose(_ child: ChildItem, in item: WindowItem) -> Bool { provider(for: item.app)?.canClose(child) == true }
    // W on a tab, off the main thread. done(true) when the provider closed it.
    static func closeChild(_ child: ChildItem, in item: WindowItem, _ done: @escaping (Bool) -> Void) {
        guard let src = provider(for: item.app), let ref = parent(of: item) else { done(false); return }
        queue(for: src).async {
            let closed = src.closeChild(child, in: ref)
            DispatchQueue.main.async { done(closed) }
        }
    }
    // Pins are shared by all windows of one browser, and by one Slack workspace across sessions.
    static func pinGroup(_ item: WindowItem) -> String { item.workspace ?? item.app?.bundleIdentifier ?? item.appName }
    static func isPinned(_ child: ChildItem, in item: WindowItem) -> Bool { Settings.pins[pinGroup(item)]?.contains(child.id) == true }
    static func togglePin(_ child: ChildItem, in item: WindowItem) {
        var pins = Settings.pins
        var list = pins[pinGroup(item)] ?? []
        if let i = list.firstIndex(of: child.id) { list.remove(at: i) } else { list.append(child.id) }
        pins[pinGroup(item)] = list.isEmpty ? nil : list
        Settings.pins = pins
    }
    static func canExpand(_ item: WindowItem) -> Bool {
        guard item.child == nil, item.window != nil, let src = provider(for: item.app), src.canExpand else { return false }
        return src.canExpand(row: item)
    }
    static func parent(of item: WindowItem) -> ParentRef? {
        guard let app = item.app, let w = item.window else { return nil }
        return ParentRef(app: app, window: w, id: item.id, title: item.title)
    }

    // One answer to a main-thread caller, from whichever comes first: the provider or the time limit. An answer after
    // the first is passed on too (a saved list, then a fresh one); a time limit after an answer is not.
    private final class Reply {
        private var answered = false
        private let done: ([ChildItem]?) -> Void
        init(_ done: @escaping ([ChildItem]?) -> Void) { self.done = done }
        func send(_ kids: [ChildItem]?) { DispatchQueue.main.async { [self] in answered = true; done(kids) } }
        func expire(after seconds: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
                guard !answered else { return }
                answered = true
                done(nil)
            }
        }
    }

    // Children of a window as the app lists them, read off the main thread, delivered on main. nil when the
    // source has no answer in time. Callers order them with `order` every time they show them.
    static func fetch(_ item: WindowItem, _ done: @escaping ([ChildItem]?) -> Void) {
        guard let src = provider(for: item.app) else { done(nil); return }
        let reply = Reply(done)
        if src.fetch(item, { reply.send($0) }) { reply.expire(after: timeLimit); return }
        guard let p = parent(of: item) else { reply.send(nil); return }
        reply.expire(after: queueLimit)
        queue(for: src).async {
            reply.expire(after: timeLimit)
            let kids = src.children(of: p)
            reply.send(kids)
        }
    }

    // Called after the window is in front: remember the choice and switch to that tab or chat, on the provider's queue.
    static func open(_ child: ChildItem, in item: WindowItem) {
        noteUsed(child, in: item)
        guard let src = provider(for: item.app), let p = parent(of: item) else { return }
        queue(for: src).async { src.open(child, in: p) }
    }
    static func noteUsed(_ child: ChildItem, in item: WindowItem) { Recency.used(child.id, in: item.parentKey ?? item.key) }
    // The same open as a step in a longer job off the main thread: it returns when the provider has finished.
    static func openStep(_ child: ChildItem, in item: WindowItem) -> (() -> Void)? {
        guard let src = provider(for: item.app), let p = parent(of: item) else { return nil }
        return { _ = wait(for: src, limit: 1) { src.open(child, in: p) } }
    }
    // Runs work on a provider's queue and waits for it, off the main thread only. nil when the provider did not get to it
    // in time: whatever it is stuck on, the caller carries on.
    static func wait<T>(for src: AppProvider.Type, limit: TimeInterval, _ work: @escaping () -> T) -> T? {
        let done = DispatchSemaphore(value: 0)
        var result: T?
        queue(for: src).async { result = work(); done.signal() }
        return done.wait(timeout: .now() + limit) == .success ? result : nil
    }

    // Labels and dots a provider adds to a row (a Chrome profile, WhatsApp's unread dot). The first frame uses the last
    // ones seen for that window; the rows are read again after the panel appears, under one shared deadline. So
    // opening the list never waits for a provider, and a quick flip never calls one.
    enum Labels {
        private static var seen: [CGWindowID: (profile: String?, dot: Bool)] = [:]   // main thread
        private static let deadline: TimeInterval = 0.4

        static func apply(to pages: [Windows.Page]) -> [Windows.Page] {
            pages.map { page in
                Windows.Page(title: page.title, items: page.items.map { row in
                    guard let known = seen[row.id] else { return row }
                    var r = row
                    r.profile = known.profile; r.dot = known.dot
                    return r
                })
            }
        }

        static func refresh(_ rows: [WindowItem], changed: @escaping () -> Void) {
            let stop = Date().addingTimeInterval(deadline)
            var groups: [ObjectIdentifier: (provider: AppProvider.Type, rows: [WindowItem])] = [:]
            for row in rows where row.window != nil && row.id != 0 {
                guard let app = row.app, !Windows.isSlow(app.processIdentifier), let src = provider(for: app) else { continue }
                groups[ObjectIdentifier(src), default: (src, [])].rows.append(row)
            }
            for group in groups.values {
                queue(for: group.provider).async {
                    var read: [(CGWindowID, String?, Bool)] = []
                    for var row in group.rows where Date() < stop {
                        group.provider.decorate(&row, window: row.window!)
                        read.append((row.id, row.profile, row.dot))
                    }
                    DispatchQueue.main.async {
                        var different = false
                        if seen.count > 500 { seen = [:] }
                        for (id, profile, dot) in read {
                            if seen[id]?.profile != profile || seen[id]?.dot != dot { different = true }
                            seen[id] = (profile, dot)
                        }
                        if different { changed() }
                    }
                }
            }
        }
    }

    // "Most recent first": the one in use now, then the ones picked through Swap before, then the rest as
    // the app lists them. So Return, Return goes back to the previous tab, as the window list does.
    // Pinned ones first, in the order they were pinned.
    static func order(_ kids: [ChildItem], key: String, group: String) -> [ChildItem] {
        var out: [ChildItem] = []
        for id in Settings.pins[group] ?? [] { if let k = kids.first(where: { $0.id == id }) { out.append(k) } }
        let rest = kids.filter { k in !out.contains { $0.id == k.id } }
        if Settings.childOrder == .recent {
            if let active = rest.first(where: { $0.active }) { Recency.used(active.id, in: key) }
            for id in Recency.list(key) { if let k = rest.first(where: { $0.id == id }), !out.contains(where: { $0.id == id }) { out.append(k) } }
        }
        for k in rest where !out.contains(where: { $0.id == k.id }) { out.append(k) }
        return out
    }

    enum Recency {
        private static var lists: [String: [String]] = [:]   // parent key -> child ids, newest first (this run only)
        static func used(_ id: String, in key: String) {
            var l = lists[key] ?? []
            l.removeAll { $0 == id }
            l.insert(id, at: 0)
            lists[key] = Array(l.prefix(50))
        }
        static func list(_ key: String) -> [String] { lists[key] ?? [] }
    }
}

// A letter while the list is open: that app's Command+letter, sent as a real keystroke once the window has the
// keyboard. A provider can answer instead, for an app with no such shortcut. Waiting happens on a queue of its own.
// From the key press until delivery the keyboard tap holds on to anything typed, so "F, then a word" puts the word in
// the Find field and not in the document; the keys are replayed after the command. Nothing is sent if the app is no
// longer in front at that moment, and a pick elsewhere (abandon) drops the command and what was held.
enum AppCommand {
    static let ownEvent: Int64 = 0x53_57_41_50   // eventSourceUserData of everything Swap posts: the tap lets it through

    private static let queue = DispatchQueue(label: "swap.command", qos: .userInteractive)
    private static let lock = NSLock()
    private static var ticket = 0
    private static var holdingKeys = false
    private static var held: [CGEvent] = []

    // Read by the tap thread.
    static var holding: Bool { lock.lock(); defer { lock.unlock() }; return holdingKeys }
    static func hold(_ event: CGEvent) { lock.lock(); if held.count < 128 { held.append(event) }; lock.unlock() }

    static func abandon() {
        lock.lock(); ticket += 1; holdingKeys = false; held = []; lock.unlock()
    }
    private static func isCurrent(_ t: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return ticket == t }

    // window: the window that must have the keyboard (0 for any window of the app). settle: seconds to leave after the
    // window is ready. before: a step to run once it is, such as opening the tab or chat the letter is aimed at.
    static func send(_ key: Int64, to app: NSRunningApplication, window: CGWindowID = 0, settle: TimeInterval = 0, before: (() -> Void)? = nil) {
        lock.lock(); ticket += 1; let t = ticket; holdingKeys = true; held = []; lock.unlock()
        // Whatever happens below, the keyboard comes back: every wait is bounded, and this is the bound on them all.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 3) { if isCurrent(t) { abandon() } }
        queue.async {
            let sent = deliver(key, to: app, window: window, settle: settle, before: before, ticket: t)
            finish(t, replay: sent)
        }
    }

    private static func deliver(_ key: Int64, to app: NSRunningApplication, window: CGWindowID, settle: TimeInterval, before: (() -> Void)?, ticket t: Int) -> Bool {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.25)
        // Asked of the app itself: NSWorkspace's answer goes stale off the main thread.
        func inFront() -> Bool { var r: CFTypeRef?; return AXUIElementCopyAttributeValue(el, kAXFrontmostAttribute as CFString, &r) == .success && (r as? Bool) == true }
        func ready() -> Bool {
            guard inFront() else { return false }
            guard window != 0 else { return true }
            var r: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &r) == .success, let r else { return false }
            return windowID(r as! AXUIElement) == window
        }
        let limit = Date().addingTimeInterval(1)
        while isCurrent(t), !ready(), Date() < limit { usleep(10_000) }
        guard isCurrent(t), inFront() else { return false }   // never into the wrong app
        before?()
        let settleUntil = Date().addingTimeInterval(max(before == nil ? 0.03 : 0.6, settle))
        while isCurrent(t), Date() < settleUntil { usleep(10_000) }
        guard isCurrent(t) else { return false }
        if let p = Children.provider(for: app), Children.wait(for: p, limit: 1, { p.command(key, app: app) }) != false { return true }
        guard isCurrent(t), inFront() else { return false }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            e.flags = .maskCommand   // set outright: Option may still be held
            e.setIntegerValueField(.eventSourceUserData, value: ownEvent)
            e.post(tap: .cghidEventTap)
            usleep(50_000)           // Electron drops a down and up that arrive together
        }
        return true
    }

    // The app has the command: give it a moment to act on it, then the held keys, and the keyboard goes back.
    private static func finish(_ t: Int, replay: Bool) {
        if replay { usleep(120_000) }
        while true {
            lock.lock()
            guard ticket == t else { lock.unlock(); return }
            let batch = held
            held = []
            if batch.isEmpty { holdingKeys = false; lock.unlock(); return }
            lock.unlock()
            guard replay else { continue }
            for e in batch {
                e.setIntegerValueField(.eventSourceUserData, value: ownEvent)
                e.post(tap: .cghidEventTap)
                usleep(2_000)
            }
        }
    }
}

// An app that plugs into Swap. The core knows nothing about any app: everything app-specific lives in a provider.
// See Behind the scenes/PRODUCT.md.
protocol AppProvider {
    static var bundleIDs: Set<String> { get }
    static func children(of parent: ParentRef) -> [ChildItem]      // background queue; aim for under 100 ms, 1 s is the hard limit
    static func open(_ child: ChildItem, in parent: ParentRef)     // this provider's queue, after the window is in front
    static var canExpand: Bool { get }
    static func canExpand(row: WindowItem) -> Bool                 // main thread, in memory only: false shows a plain row, no chevron
    static func start()                                            // once, when Swap has Accessibility
    static func sessionEnded()                                     // the list closed
    static func decorate(_ row: inout WindowItem, window: AXUIElement)              // this provider's queue, after the list shows: profile labels, unread dots
    static func addRows(to pages: [Windows.Page], current: Int) -> [Windows.Page]   // main thread, in memory only, never on a quick flip: rows that aren't windows
    static func arrange(_ rows: inout [WindowItem])                                 // main thread, in memory only, never on a quick flip: replace or reorder rows on a page
    static func fetch(_ item: WindowItem, _ done: @escaping ([ChildItem]?) -> Void) -> Bool   // true: handled instead of children(of:). Same time limit; done may be called twice
    static func prepare(_ item: WindowItem, expanding: Bool) -> TimeInterval        // main thread, before acting on a row, never on a quick flip; seconds to wait
    static func groupChildren(of group: ChildItem, in parent: ParentRef) -> [ChildItem]     // this provider's queue: inside a child row with isGroup
    static func openWithoutWindow(_ item: WindowItem)                               // this provider's queue: a row with no window was picked
    static func command(_ key: Int64, app: NSRunningApplication) -> Bool            // this provider's queue: true: handled, send no keystroke
    static func canClose(_ child: ChildItem) -> Bool                                // main thread, in memory only: W on this child closes it
    static func closeChild(_ child: ChildItem, in parent: ParentRef) -> Bool        // this provider's queue: true when it closed
    static func health(app: NSRunningApplication) -> [String: Bool]                 // nightly check, read-only: the structures this provider relies on. "info." keys are notes, not requirements
}

extension AppProvider {
    static var canExpand: Bool { true }
    static func canExpand(row: WindowItem) -> Bool { true }
    static func canClose(_ child: ChildItem) -> Bool { false }
    static func closeChild(_ child: ChildItem, in parent: ParentRef) -> Bool { false }
    static func start() {}
    static func sessionEnded() {}
    static func decorate(_ row: inout WindowItem, window: AXUIElement) {}
    static func addRows(to pages: [Windows.Page], current: Int) -> [Windows.Page] { pages }
    static func arrange(_ rows: inout [WindowItem]) {}
    static func fetch(_ item: WindowItem, _ done: @escaping ([ChildItem]?) -> Void) -> Bool { false }
    static func prepare(_ item: WindowItem, expanding: Bool) -> TimeInterval { 0 }
    static func groupChildren(of group: ChildItem, in parent: ParentRef) -> [ChildItem] { [] }
    static func openWithoutWindow(_ item: WindowItem) {}
    static func command(_ key: Int64, app: NSRunningApplication) -> Bool { false }
    static func health(app: NSRunningApplication) -> [String: Bool] { [:] }
}
