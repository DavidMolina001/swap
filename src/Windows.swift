import AppKit
import ApplicationServices

// Private but long-stable call (used by most window managers) that gives an AX window its CGWindowID.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowID(_ w: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(w, &id) == .success && id != 0 ? id : nil
}

// One entry in the switcher: a single window of a running app.
struct WindowItem {
    let app: NSRunningApplication?
    let window: AXUIElement?
    let id: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage
    let minimized: Bool
    var desktop: String? = nil   // set when every desktop is shown in one list
    // Drill-in (Children.swift): a window row can expand into child rows (tabs, chats) shown indented under it.
    var depth = 0                 // 0 = window, 1 = child
    var child: ChildItem? = nil   // set on a child row; app, window and id are the parent's
    var expandable = false        // a window row that can expand (Return)
    var expanded = false          // a window row with its children on show
    var parentKey: String? = nil  // on a child row: its parent's key
    var workspace: String? = nil  // a Slack workspace row (SlackRows.swift): title is the workspace name
    var profile: String? = nil    // a browser window's profile ("Work"), shown after the app name
    var pinned = false            // a child row the user pinned (P): listed first, with a pin
    var dot = false               // something unread inside this app
    var opens: URL? = nil         // a search result that is a file or an app: NSWorkspace opens it
    var isSelf = false            // Swap's own row, last on the current desktop's page: picking it opens Swap's menu
    var key: String {
        if isSelf { return "swap" }
        return child.map { "c\(parentKey ?? "")/\($0.id)" } ?? (workspace.map { "w\(id)#\($0)" } ?? "w\(id)")
    }

    // Text shown in the row: the window title, or the app name when the window has none.
    var label: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? appName : title }

    // Swap's own row. It has no app and no window, so nothing that acts on windows can reach Swap through it.
    static func swapRow() -> WindowItem {
        var row = WindowItem(app: nil, window: nil, id: 0, title: "Swap", appName: "Menu",
                             icon: NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(), minimized: false)
        row.isSelf = true
        return row
    }
}

private func axValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref
}

// Remembers the order in which windows were focused, most recent first. Fed by app activations and by
// an Accessibility observer per app that reports every focused-window change. Main thread only.
enum Recency {
    private(set) static var order: [CGWindowID] = []
    private(set) static var times: [CGWindowID: Date] = [:]   // when each window was last used, for rows placed by time
    private static var observers: [pid_t: AXObserver] = [:]

    static func touch(_ id: CGWindowID) {
        times[id] = Date()
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        if order.count > 500 { order.removeLast(order.count - 500) }
    }

    // Asks the app for its focused window off the main thread (a slow app must not hold anything up).
    static func touchFocusedWindow(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !Windows.isSlow(pid) else { return }
        Windows.axQueue.async {
            let el = AXUIElementCreateApplication(pid)
            guard let w = axValue(el, kAXFocusedWindowAttribute), let id = windowID(w as! AXUIElement) else { return }
            DispatchQueue.main.async {
                touch(id)
                WindowCache.add(id, pid: pid, element: w as! AXUIElement)
            }
        }
    }

    // Start once Accessibility is granted: seed from the on-screen stacking order (front to back),
    // then follow focus changes in every app.
    static func start() {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        order = onScreen.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        if let front = NSWorkspace.shared.frontmostApplication { touchFocusedWindow(of: front) }
        NSWorkspace.shared.runningApplications.forEach { observe($0) }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            observe(app)   // often too early: AX is not ready right at launch, so try again shortly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { observe(app) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { observe(app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let obs = observers.removeValue(forKey: app.processIdentifier) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            }
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            observe(app)   // apps that were slow to start get watched the first time they are used
            touchFocusedWindow(of: app)
        }
    }

    private static func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ProcessInfo.processInfo.processIdentifier,
              observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, focusCallback, &obs) == .success, let obs else { return }
        let el = AXUIElementCreateApplication(pid)
        guard AXObserverAddNotification(obs, el, kAXFocusedWindowChangedNotification as CFString, nil) == .success
        else { return }
        AXObserverAddNotification(obs, el, kAXWindowCreatedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
    }
}

// Focus changes move a window to the top of the recency list; new and focused windows are remembered
// so they can still be listed after you move to another desktop.
private let focusCallback: AXObserverCallback = { _, element, notification, _ in
    guard let id = windowID(element) else { return }
    var pid: pid_t = 0
    if AXUIElementGetPid(element, &pid) == .success { WindowCache.add(id, pid: pid, element: element) }
    if (notification as String) == kAXFocusedWindowChangedNotification { Recency.touch(id) }
}

// Accessibility elements of windows on other desktops, keyed by window id. Accessibility only lists the
// current desktop, so Swap remembers every window it sees: when the switcher opens, when you arrive on
// a desktop, when a window is created or focused, plus a background scan (works for some apps only).
// The dictionary lives on the main thread; Accessibility calls run on Windows.axQueue.
enum WindowCache {
    // title: last one seen, for apps that stop answering. standard: false for a dialog, panel or helper window
    // (never listed), nil until known. Accessibility hides other desktops, so the type is checked when seen.
    typealias Entry = (pid: pid_t, element: AXUIElement, title: String, standard: Bool?)
    private static var elements: [CGWindowID: Entry] = [:]
    private static let queue = DispatchQueue(label: "swap.window-scan", qos: .utility)
    private static var scanning = false

    static func add(_ id: CGWindowID, pid: pid_t, element: AXUIElement, title: String? = nil, standard: Bool? = nil) {
        elements[id] = (pid, element, title ?? elements[id]?.title ?? "", standard ?? elements[id]?.standard)
    }
    static func element(_ id: CGWindowID) -> Entry? { elements[id] }
    static func ids(of pid: pid_t) -> [CGWindowID] { elements.filter { $0.value.pid == pid }.map { $0.key } }
    static func snapshot() -> [CGWindowID: Entry] { elements }

    static func start() {
        scan(Windows.candidateApps())
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { scan([app]) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            elements = elements.filter { $0.value.pid != app.processIdentifier }
        }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            rememberCurrentDesktop()
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { remember([app]) }   // new windows settle late
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in rememberCurrentDesktop() }
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in scan(Windows.candidateApps()) }
        rememberCurrentDesktop()
    }

    static func rememberCurrentDesktop() { remember(Windows.candidateApps()) }

    // Reads the windows of these apps off the main thread and stores them.
    static func remember(_ apps: [NSRunningApplication]) {
        let pids = apps.filter { $0.activationPolicy == .regular && !Windows.isSlow($0.processIdentifier) }.map { $0.processIdentifier }
        Windows.axQueue.async {
            var found: [(CGWindowID, pid_t, AXUIElement)] = []
            for pid in pids {
                let el = AXUIElementCreateApplication(pid)
                guard let wins = axValue(el, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                for w in wins { if let id = windowID(w) { found.append((id, pid, w)) } }
            }
            DispatchQueue.main.async { for (id, pid, w) in found { add(id, pid: pid, element: w) } }
        }
    }

    static func scan(_ apps: [NSRunningApplication]) {
        guard !scanning else { return }   // a stuck scan must not pile up behind itself
        scanning = true
        let pids = apps.filter { $0.activationPolicy == .regular }.map { $0.processIdentifier }
        queue.async {
            let results = pids.map { ($0, Spaces.findAllWindows(pid: $0)) }
            DispatchQueue.main.async {
                for (pid, wins) in results { for (id, el) in wins { add(id, pid: pid, element: el) } }
                scanning = false
            }
        }
    }
}

enum Windows {
    // Process ids, most recently used app first. Fed by the activation notification in main.swift.
    static var mru: [pid_t] = []

    // Accessibility calls that may wait on an app run here, never on the main thread. Switching has a
    // queue of its own so it never waits behind a background refresh.
    static let axQueue = DispatchQueue(label: "swap.ax", qos: .userInitiated)
    private static let focusQueue = DispatchQueue(label: "swap.focus", qos: .userInteractive)
    private static let listQueue = DispatchQueue(label: "swap.list", qos: .userInteractive)

    // Apps that did not answer in time, with when; skipped for 30 s so the next open is quick.
    private static var slowApps: [pid_t: Date] = [:]
    static func isSlow(_ pid: pid_t) -> Bool { slowApps[pid].map { Date().timeIntervalSince($0) < 30 } ?? false }

    static func noteActive(_ pid: pid_t) {
        mru.removeAll { $0 == pid }
        mru.insert(pid, at: 0)
    }

    // One page of the switcher: the windows on one desktop.
    struct Page {
        let title: String
        let items: [WindowItem]
    }

    // Everything the switcher needs when it opens: the pages, the one you are on, and the window in front.
    struct Listing {
        let pages: [Page]
        let current: Int
        let front: CGWindowID   // focused window of the frontmost app, 0 when there is none
    }

    static func candidateApps() -> [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let hidden = Set(Settings.hiddenApps)
        let showHidden = Settings.showHidden
        var apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
                && !hidden.contains($0.bundleIdentifier ?? "") && (showHidden || !$0.isHidden)
        }
        #if SELFTEST
        // The live test only switches between its own windows, never the tester's real ones.
        if let only = ProcessInfo.processInfo.environment["SWAP_ONLY_APP"]?.split(separator: ",").map(String.init) {
            apps = apps.filter { only.contains($0.bundleIdentifier ?? "") || only.contains($0.localizedName ?? "") }
        }
        #endif
        return apps
    }

    // The windows on the current desktop (plus minimised ones), most recently focused first.
    static func list() -> [WindowItem] {
        let p = pages()
        return p.pages[p.current].items
    }

    // Synchronous listing, used by the QA tools. The switcher itself uses pagesAsync.
    static func pages() -> (pages: [Page], current: Int) {
        #if SELFTEST
        if let scene = Scene.current { return scene }   // QA fixtures instead of the real windows
        #endif
        let r = build(input())
        apply(r)
        return (r.listing.pages, r.listing.current)
    }

    // Reads the window list on a background queue and reports on the main thread.
    static func pagesAsync(_ completion: @escaping (Listing) -> Void) {
        #if SELFTEST
        if let scene = Scene.current { completion(Listing(pages: scene.pages, current: scene.current, front: 0)); return }
        #endif
        let i = input()
        listQueue.async {
            let r = build(i)
            DispatchQueue.main.async { apply(r); completion(r.listing) }
        }
    }

    // The window used before the one in front, when it lives on another page: a quick flip goes there.
    static func previousWindow(in pages: [Page], exceptPage: Int, front: CGWindowID) -> (page: Int, index: Int)? {
        guard let prev = Recency.order.first(where: { $0 != front && $0 != 0 }) else { return nil }
        for (p, page) in pages.enumerated() where p != exceptPage {
            if let i = page.items.firstIndex(where: { $0.id == prev }) { return (p, i) }
        }
        return nil
    }

    // MARK: building the list (runs on any thread; main-thread state is handed in and out)

    private struct Input {
        let apps: [NSRunningApplication]
        let mru: [pid_t]
        let recency: [CGWindowID]
        let cache: [CGWindowID: WindowCache.Entry]
        let slow: Set<pid_t>
        let frontPid: pid_t?
        let display: String?   // display under the mouse, read on the main thread
        let flat: Bool         // every desktop in one list
        let hideEmpty: Bool    // skip desktops with no windows
    }

    private struct Result {
        let listing: Listing
        let adds: [(id: CGWindowID, pid: pid_t, element: AXUIElement, title: String?, standard: Bool?)]
        let timedOut: [pid_t]
    }

    private static func input() -> Input {
        let now = Date()
        slowApps = slowApps.filter { now.timeIntervalSince($0.value) < 30 }
        return Input(apps: candidateApps(), mru: mru, recency: Recency.order, cache: WindowCache.snapshot(),
                     slow: Set(slowApps.keys), frontPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                     display: Spaces.mouseDisplayUUID(), flat: Settings.desktops == .flat, hideEmpty: Settings.hideEmptyDesktops)
    }

    private static func apply(_ r: Result) {
        for a in r.adds { WindowCache.add(a.id, pid: a.pid, element: a.element, title: a.title, standard: a.standard) }
        for pid in r.timedOut { slowApps[pid] = Date() }
    }

    // One page per desktop of the display under the mouse, each in last-used order, and the index of
    // the desktop that is showing. Falls back to a single page when desktops can't be read.
    // Windows never focused since Swap started follow the used ones, in stacking order, then by app.
    // Uses the Accessibility API only, so no Screen Recording permission is needed.
    private static func build(_ input: Input) -> Result {
        var found: [(item: WindowItem, fallback: Int)] = []
        var seen = Set<CGWindowID>()
        var adds: [(id: CGWindowID, pid: pid_t, element: AXUIElement, title: String?, standard: Bool?)] = []
        var timedOut: [pid_t] = []
        var noAnswer = Set<pid_t>()
        for app in input.apps {
            let pid = app.processIdentifier
            if input.slow.contains(pid) { noAnswer.insert(pid); continue }   // its rows come from the cache below
            let el = AXUIElementCreateApplication(pid)
            var ref: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &ref)
            if err == .cannotComplete { timedOut.append(pid); noAnswer.insert(pid); continue }   // hung app
            guard let wins = ref as? [AXUIElement] else { continue }
            let appRank = input.mru.firstIndex(of: pid) ?? input.mru.count
            for (i, w) in wins.enumerated() {
                let id = windowID(w) ?? 0
                // A minimised window reports subrole AXDialog, so keep minimised ones regardless.
                let minimized = (axValue(w, kAXMinimizedAttribute) as? Bool) ?? false
                guard minimized || (axValue(w, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole else {
                    if id != 0 { seen.insert(id); adds.append((id, pid, w, nil, false)) }   // a dialog or panel: not listed, not even from the cache
                    continue
                }
                let row = item(app, w, id, minimized)
                if id != 0 { seen.insert(id); adds.append((id, pid, w, row.title, true)) }
                guard keep(row) else { continue }
                found.append((row, appRank * 1000 + i))
            }
        }

        var front: CGWindowID = 0
        if let fp = input.frontPid, !noAnswer.contains(fp) {
            let el = AXUIElementCreateApplication(fp)
            if let w = axValue(el, kAXFocusedWindowAttribute), let id = windowID(w as! AXUIElement) { front = id }
        }

        // The front app is not answering: its top row counts as the window in front, so a quick flip
        // still takes you to another app.
        func frontId(_ items: [WindowItem]) -> CGWindowID {
            guard front == 0, let fp = input.frontPid, noAnswer.contains(fp) else { return front }
            return items.first { $0.app?.processIdentifier == fp }?.id ?? 0
        }

        guard let desks = Spaces.desktops(display: input.display) else {
            let items = sorted(found, input.recency)
            return Result(listing: Listing(pages: [Page(title: "", items: items)], current: 0, front: frontId(items)),
                          adds: adds, timedOut: timedOut)
        }

        // Windows on other desktops, and of apps that did not answer: every on-screen-layer window the
        // window server knows, matched to the Accessibility elements remembered earlier.
        let byPid = Dictionary(input.apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for (i, info) in all.enumerated() where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !seen.contains(id),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, let app = byPid[pid],
                  let cached = input.cache[id], cached.pid == pid,
                  let space = Spaces.space(of: id) else { continue }   // on no desktop: an invisible helper window
            // On this desktop but not on screen, and the app is not hidden: a window the app keeps out of sight.
            if space == desks.current, (info[kCGWindowIsOnscreen as String] as? Bool) != true, !app.isHidden { continue }
            seen.insert(id)
            // Only real windows: a browser's helper windows (tab search, picture in picture, popups) sit on the
            // same layer and reach the cache, but the live list drops them, so the cached list must too.
            if cached.standard == false { continue }
            if cached.standard == nil, !noAnswer.contains(pid) {
                let minimized = (axValue(cached.element, kAXMinimizedAttribute) as? Bool) ?? false
                if let sub = axValue(cached.element, kAXSubroleAttribute) as? String {
                    let standard = sub == kAXStandardWindowSubrole || minimized
                    adds.append((id, pid, cached.element, nil, standard))
                    if !standard { continue }
                }
            }
            // An app that is not answering keeps its windows in the list, with the last title seen.
            let row = noAnswer.contains(pid)
                ? WindowItem(app: app, window: cached.element, id: id, title: cached.title, appName: app.localizedName ?? "App",
                             icon: app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(), minimized: false)
                : item(app, cached.element, id, false)
            guard keep(row) else { continue }
            found.append((row, 1_000_000 + i))
        }
        var buckets = Dictionary(uniqueKeysWithValues: desks.list.map { ($0.id, [(item: WindowItem, fallback: Int)]()) })
        for f in found {
            let space = Spaces.space(of: f.item.id)
            let key = (space != nil && buckets[space!] != nil) ? space! : desks.current   // minimised: current page
            buckets[key]?.append(f)
        }
        var number = 0
        var pages = desks.list.map { d -> Page in
            let items = sorted(buckets[d.id] ?? [], input.recency)
            if d.fullScreen { return Page(title: items.first?.appName ?? "Full screen", items: items) }
            number += 1
            return Page(title: "Desktop \(number)", items: items)
        }
        var current = desks.list.firstIndex { $0.id == desks.current } ?? 0
        if input.flat {
            // One list for every desktop, last used first; each row says where it lives.
            var all: [(item: WindowItem, fallback: Int)] = []
            for (p, page) in pages.enumerated() {
                let desk = (pages.count > 1 && p != current) ? page.title : nil
                all += page.items.enumerated().map { (i, w) in var w = w; w.desktop = desk; return (w, p * 10_000 + i) }
            }
            let items = sorted(all, input.recency)
            return Result(listing: Listing(pages: [Page(title: "", items: items)], current: 0, front: frontId(items)), adds: adds, timedOut: timedOut)
        }
        if input.hideEmpty {
            // Desktops with nothing on them are skipped; the ones left keep their real numbers.
            let keepIdx = pages.indices.filter { !pages[$0].items.isEmpty || $0 == current }
            current = keepIdx.firstIndex(of: current) ?? 0
            pages = keepIdx.map { pages[$0] }
        }
        return Result(listing: Listing(pages: pages, current: current, front: frontId(pages[current].items)), adds: adds, timedOut: timedOut)
    }

    // The user's filters: minimised windows and windows with no title can be left out.
    private static func keep(_ row: WindowItem) -> Bool {
        if row.minimized, !Settings.showMinimised { return false }
        if Settings.hideUntitled, row.title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private static func item(_ app: NSRunningApplication, _ w: AXUIElement, _ id: CGWindowID, _ minimized: Bool) -> WindowItem {
        WindowItem(app: app, window: w, id: id,
                   title: (axValue(w, kAXTitleAttribute) as? String) ?? "",
                   appName: app.localizedName ?? "App",
                   icon: app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(),
                   minimized: minimized)
    }

    private static func sorted(_ list: [(item: WindowItem, fallback: Int)], _ recency: [CGWindowID]) -> [WindowItem] {
        let rank = Dictionary(recency.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.sorted { a, b in
            let ra = rank[a.item.id], rb = rank[b.item.id]
            switch (ra, rb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.fallback < b.fallback
            }
        }.map { $0.item }
    }

    // Close one window: press its close button through Accessibility (the app may still ask to save).
    // Off the main thread, like focus, so a slow app never holds the keyboard.
    static func close(_ item: WindowItem) {
        guard let w = item.window else { return }
        focusQueue.async {
            if let button = axValue(w, kAXCloseButtonAttribute) {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            } else {
                AXUIElementPerformAction(w, "AXCancel" as CFString)
            }
        }
    }

    // Has this window really gone? Asks the window server, so a slow app holds nothing up. A window the app only
    // hid (ordered out, on no desktop) counts as gone; a minimised one has no desktop either and does not.
    static func isGone(_ item: WindowItem) -> Bool {
        guard item.id != 0 else { return false }
        return !stillThere(item) || (!item.minimized && Spaces.space(of: item.id) == nil)
    }
    // Is the window still open? The window server knows, except for a minimised window: some apps (iPhone Mirroring)
    // drop those from its list altogether, so then the app itself is asked.
    static func stillThere(_ item: WindowItem) -> Bool {
        if exists(item.id) { return true }
        guard item.minimized, let w = item.window else { return false }
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &role) == .success
    }
    static func exists(_ id: CGWindowID) -> Bool {
        !((CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]) ?? []).isEmpty
    }

    // Quit the window's app the polite way (a Quit Apple event), so it can ask about unsaved work.
    static func quit(_ item: WindowItem) {
        guard let app = item.app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        app.terminate()
    }

    // Bring one window to the front: unhide / un-minimise, make its app frontmost, raise it.
    // The Accessibility part runs off the main thread, so a slow app never holds the keyboard.
    static func focus(_ item: WindowItem) {
        guard let app = item.app else { return }
        if item.id != 0 { Recency.touch(item.id) }
        if app.isHidden { app.unhide() }
        let pid = app.processIdentifier, id = item.id, window = item.window, minimized = item.minimized
        focusQueue.async {
            let appEl = AXUIElementCreateApplication(pid)
            if let w = window, minimized {
                AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            // Make this exact window key and its app frontmost; macOS moves to its desktop if needed.
            let exact = id != 0 && Spaces.bringForward(pid: pid, window: id)
            if let w = window {
                if !exact { AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue) }
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            if !exact { DispatchQueue.main.async { app.activate() } }
        }
    }
}
