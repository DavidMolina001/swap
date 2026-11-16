// Browser tabs as the children of a browser window (Chrome, Edge, Brave, Chromium, Safari).
// Two routes. Accessibility reads the window's own tab strip in a few milliseconds with the permission Swap
// already has, but only for windows it can reach and without URLs. Apple Events (the browser's scripting
// interface) also reach windows on other desktops and know every tab's URL, but need the Automation grant and
// cost tens of milliseconds, so they are the second choice and never relied on. A normal call uses both: tab
// list and active tab from Accessibility, site names from Apple Events.
// A tab's id is its address (without the #part), so a pin survives moving the tab and a changing title. Without an
// address, as with no Automation grant, it is the title. Private windows get ids that mean nothing outside this run,
// so no page of theirs reaches the preferences file through a pin. Safari has no way to tell a script a window is
// private, so its private windows are treated as normal: unverified, Chromium only.
import AppKit
import ApplicationServices

enum BrowserTabs: AppProvider {
    static func decorate(_ row: inout WindowItem, window: AXUIElement) {
        guard let app = row.app else { return }
        row.profile = profile(of: ParentRef(app: app, window: window, id: row.id, title: row.title))
    }

    // Tidies pins from older builds and from private windows, which mean nothing in a new run.
    static func start() {
        var pins = Settings.pins
        let before = pins
        for group in bundleIDs {
            guard let list = pins[group] else { continue }
            let clean = list.compactMap { id -> String? in
                if id.hasPrefix(sessionPrefix) { return nil }
                if id.hasPrefix("u:") || id.hasPrefix("t:") { return id }
                guard let colon = id.firstIndex(of: ":"), Int(id[..<colon]) != nil else { return id }
                return "t:" + id[id.index(after: colon)...]    // "3:Inbox", the old position-and-title id
            }
            pins[group] = clean.isEmpty ? nil : clean
        }
        if pins != before { Settings.pins = pins }
    }

    static let bundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "org.chromium.Chromium",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
    ]

    // Which route answered the last call: "ax", "ax+ae", "ae" or "none". For the QA harness and logs only.
    private(set) static var lastRoute = "none"

    // Time allowed per call. The protocol's hard limit is 1 s; the rest is left to the caller.
    private static let budget: TimeInterval = 0.8
    // How long the Accessibility route waits for Apple Events to add site names. Longer than one lost reply
    // plus its retry (see `run`), short enough that a drill-in still feels instant.
    private static let siteNamesWait: TimeInterval = 0.5
    private static let axTimeout: Float = 0.5   // per Accessibility message, so a hung browser cannot hold a call

    // MARK: ChildSource

    static func children(of parent: ParentRef) -> [ChildItem] {
        let deadline = Date().addingTimeInterval(budget)
        guard let family = Family(parent.app.bundleIdentifier) else { lastRoute = "none"; return [] }

        if let strip = axTabs(of: parent, deadline: deadline), !strip.isEmpty {
            // Apple Events add the URL of every tab. Without them only the active tab has one (the window's
            // document); the others get the address last seen for that title, if any.
            let ae = aeTabs(of: parent, family: family, deadline: min(deadline, Date().addingTimeInterval(siteNamesWait)))
            lastRoute = ae == nil ? "ax" : "ax+ae"
            if let ae = ae, ae.titles.count == strip.count {
                return items(parent, titles: ae.titles, urls: ae.urls, active: strip.firstIndex { $0.active } ?? ae.active, hidden: ae.incognito)
            }
            let activeURL = readString(parent.window, kAXDocumentAttribute)
            let known = knownSites(for: parent.app.processIdentifier)
            let urls = strip.map { $0.active && !activeURL.isEmpty ? activeURL : (known[$0.title] ?? "") }
            return items(parent, titles: strip.map { $0.title }, urls: urls, active: strip.firstIndex { $0.active } ?? -1, hidden: parent.title.hasSuffix("(Incognito)"))
        }

        // No reachable tab strip (another desktop, or a single-tab Safari window, which shows none).
        guard let ae = aeTabs(of: parent, family: family, deadline: deadline) else { lastRoute = "none"; return [] }
        lastRoute = "ae"
        return items(parent, titles: ae.titles, urls: ae.urls, active: ae.active, hidden: ae.incognito)
    }

    // The rows, and what `open` needs to find each tab again, which the id no longer holds.
    static func items(_ parent: ParentRef, titles: [String], urls: [String], active: Int, hidden: Bool) -> [ChildItem] {
        let pinned = Set(Settings.pins[parent.app.bundleIdentifier ?? ""] ?? [])
        var seen: [String: Int] = [:], refs: [String: TabRef] = [:], upgrades: [String: String] = [:]
        let out = titles.indices.map { i -> ChildItem in
            let base = tabKey(title: titles[i], url: urls[i], index: i, hidden: hidden, pinned: pinned)
            if base.hasPrefix("t:"), pinned.contains(base), let u = addressKey(urls[i]) { upgrades[base] = u }
            seen[base, default: 0] += 1
            let id = seen[base]! == 1 ? base : "\(base)#\(seen[base]!)"   // the same page open twice
            refs[id] = TabRef(index: i, title: titles[i], url: urls[i])
            return ChildItem(id: id, title: titles[i], detail: host(of: urls[i]), icon: nil, active: i == active, unread: 0)
        }
        sitesLock.lock(); tabs[parent.id] = refs; sitesLock.unlock()
        if !hidden, !upgrades.isEmpty, let group = parent.app.bundleIdentifier { DispatchQueue.main.async { upgradePins(upgrades, in: group) } }
        return out
    }

    // A pin made while only the title was known moves to the address once that is known.
    private static func upgradePins(_ upgrades: [String: String], in group: String) {
        var pins = Settings.pins
        guard let list = pins[group] else { return }
        pins[group] = list.map { upgrades[$0] ?? $0 }
        Settings.pins = pins
    }

    static func open(_ child: ChildItem, in parent: ParentRef) {
        let deadline = Date().addingTimeInterval(budget)
        guard let family = Family(parent.app.bundleIdentifier) else { return }
        sitesLock.lock(); let ref = tabs[parent.id]?[child.id]; sitesLock.unlock()
        let index = ref?.index ?? -1, title = ref?.title ?? child.title

        if let strip = axTabs(of: parent, deadline: deadline), let tab = pick(from: strip, index: index, title: title) {
            if AXUIElementPerformAction(tab.element, kAXPressAction as CFString) == .success { return }
        }
        guard !parent.app.isTerminated, let bundleID = parent.app.bundleIdentifier else { return }
        _ = onAEQueue(until: deadline) { () -> Bool in
            guard let script = compiledScript(for: bundleID, family: family),
                  let wid = aeWindowID(for: parent, script: script, deadline: deadline) else { return false }
            // The tab may have moved since it was listed: its address finds it, the old place is the fallback.
            var place = index
            if let want = ref.flatMap({ addressKey($0.url) }), let r = run(script, handler: "listTabs", [NSAppleEventDescriptor(int32: wid)], deadline: deadline),
               let urls = r.atIndex(3), let at = (0..<urls.numberOfItems).first(where: { addressKey(urls.atIndex($0 + 1)?.stringValue ?? "") == want }) { place = at }
            guard place >= 0 else { return false }
            let params = [NSAppleEventDescriptor(int32: wid), NSAppleEventDescriptor(int32: Int32(place + 1))]
            return run(script, handler: "activateTab", params, deadline: deadline) != nil
        }
    }

    // The Chrome profile shown in the window's toolbar avatar button ("Work", "Personal").
    // nil for Safari, for windows Accessibility cannot reach, and when the button has no text.
    static func profile(of parent: ParentRef) -> String? {
        guard Family(parent.app.bundleIdentifier) == .chromium else { return nil }
        let deadline = Date().addingTimeInterval(0.05)
        AXUIElementSetMessagingTimeout(parent.window, axTimeout)
        guard readString(parent.window, kAXRoleAttribute) == kAXWindowRole,
              let toolbar = firstDescendant(of: parent.window, role: "AXToolbar", deadline: deadline) else { return nil }
        for button in readChildren(toolbar) {
            let classes = readAttr(button, "AXDOMClassList") as? [String] ?? []
            guard classes.contains("AvatarToolbarButton") else { continue }
            let name = readString(button, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    // MARK: Nightly check

    // Is either route to the tabs open? Attributes and a scripting read of the window list; nothing is activated.
    // Apple Events go out only if already allowed, so this can never raise the consent dialog.
    static func health(app: NSRunningApplication) -> [String: Bool] {
        guard let id = app.bundleIdentifier, let family = Family(id) else { return [:] }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, axTimeout)
        let windows = Health.windows(of: app)
        var strip = false
        for w in windows.prefix(8) where !strip {
            AXUIElementSetMessagingTimeout(w, axTimeout)
            strip = tabStrip(in: w, deadline: Date().addingTimeInterval(budget))?.isEmpty == false
        }
        let wildCard: OSType = 0x2A2A2A2A   // '****': any event
        let allowed = AEDeterminePermissionToAutomateTarget(NSAppleEventDescriptor(bundleIdentifier: id).aeDesc, wildCard, wildCard, false) == noErr
        var scripting = false
        if allowed {
            let deadline = Date().addingTimeInterval(budget)
            scripting = onAEQueue(until: deadline) { () -> Bool in
                guard !app.isTerminated, let script = compiledScript(for: id, family: family) else { return false }
                return run(script, handler: "listWindows", [], deadline: deadline) != nil
            } ?? false
        }
        // A single-tab Safari window has no strip, and without the Automation grant nothing else can be asked: no verdict.
        let nothingToAsk = family == .safari && !strip && !allowed
        return ["window": !windows.isEmpty, "tabsReachable": strip || scripting, "info.tabStrip": strip, "info.scripting": scripting,
                "info.automationGranted": allowed, "info.otherView": nothingToAsk, "info.skipWeb": true]
    }

    // MARK: Child ids

    private static let sessionPrefix = "s:"

    // "u:https://mail.google.com/mail/u/0/": durable, so it is what pins and recent order hold. "t:Inbox" when the
    // address is not known. "s:…" in a private window: a hash that differs in every run, so nothing readable is stored.
    private static func tabKey(title: String, url: String, index: Int, hidden: Bool, pinned: Set<String>) -> String {
        if hidden {
            var h = Hasher()
            h.combine(url.isEmpty ? title : url)
            return "\(sessionPrefix)\(h.finalize())"
        }
        let byTitle = "t:" + (title.isEmpty ? String(index) : title)
        if pinned.contains(byTitle) { return byTitle }
        return addressKey(url) ?? byTitle
    }

    // The address without its #part, which is what single-page sites change as you move around them.
    static func addressKey(_ url: String) -> String? {
        let page = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return page.isEmpty || page == "about:blank" ? nil : "u:" + page
    }

    private struct TabRef { let index: Int; let title: String; let url: String }

    // MARK: Accessibility route

    private struct AXTab {
        let element: AXUIElement
        let title: String
        let active: Bool
    }

    private static func axTabs(of parent: ParentRef, deadline: Date) -> [AXTab]? {
        AXUIElementSetMessagingTimeout(parent.window, axTimeout)
        // The caller may pass something other than a window for windows on other desktops.
        guard readString(parent.window, kAXRoleAttribute) == kAXWindowRole,
              let buttons = tabStrip(in: parent.window, deadline: deadline) else { return nil }
        return buttons.map { button in
            var title = cleanTitle(readString(button, kAXTitleAttribute))
            if title.isEmpty { title = cleanTitle(readString(button, kAXDescriptionAttribute)) }
            if title.isEmpty {   // Safari's narrow pinned tabs: the text sits in a child field
                title = readChildren(button).lazy.map { readString($0, kAXValueAttribute) }.first { !$0.isEmpty } ?? ""
            }
            return AXTab(element: button, title: title, active: isActive(button))
        }
    }

    private static func isActive(_ button: AXUIElement) -> Bool {
        if let n = readAttr(button, kAXValueAttribute) as? NSNumber { return n.intValue == 1 }
        if let n = readAttr(button, kAXSelectedAttribute) as? NSNumber { return n.boolValue }
        return readString(button, "AXIdentifier").contains("isActive=true")   // Safari's tab identifier
    }

    // The tab buttons of the window, in strip order. Found by what the container holds (children with the
    // AXTabButton subrole) rather than where it sits: Chrome's AXTabGroup is seven levels down, Safari's tab bar
    // is a direct child of the window. Page content is skipped: it can hold thousands of nodes and never a tab.
    private static func tabStrip(in window: AXUIElement, deadline: Date) -> [AXUIElement]? {
        var visited = 0
        func search(_ el: AXUIElement, depth: Int) -> [AXUIElement]? {
            visited += 1
            if visited > 600 || depth > 12 || Date() > deadline { return nil }
            let role = readString(el, kAXRoleAttribute)
            if role == "AXWebArea" || role == "AXScrollArea" || role == "AXList" || role == "AXTable" || role == "AXOutline" { return nil }
            let kids = readChildren(el)
            let tabs = kids.filter { readString($0, kAXSubroleAttribute) == "AXTabButton" }
            if !tabs.isEmpty { return tabs }
            for kid in kids {
                if let found = search(kid, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(window, depth: 0)
    }

    private static func firstDescendant(of root: AXUIElement, role: String, deadline: Date) -> AXUIElement? {
        var visited = 0
        func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            visited += 1
            if visited > 400 || depth > 10 || Date() > deadline { return nil }
            let r = readString(el, kAXRoleAttribute)
            if r == role { return el }
            if r == "AXWebArea" || r == "AXScrollArea" || r == "AXList" { return nil }
            for kid in readChildren(el) {
                if let found = search(kid, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(root, depth: 0)
    }

    // The tab at `index` if its title still matches, else the tab with that title, else the index alone.
    private static func pick(from strip: [AXTab], index: Int, title: String) -> AXTab? {
        if strip.indices.contains(index), sameTitle(strip[index].title, title) { return strip[index] }
        if let byTitle = strip.first(where: { sameTitle($0.title, title) }) { return byTitle }
        return strip.indices.contains(index) ? strip[index] : nil
    }

    // Accessibility and Apple Events word the same tab slightly differently (suffixes, truncation).
    private static func sameTitle(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    // Chrome's accessible tab names carry hover card text: "… - Memory usage - 190 MB", "… - Audio playing". The
    // memory line is matched by its shape, so any language works; the others are English only.
    private static let titleNoise = try? NSRegularExpression(
        pattern: #"\s-\s([^-]+\s-\s[\d.,]+\s?[KMGT]?B|Audio playing|Audio muted|Media recording|Camera recording|Microphone recording)$"#)

    private static func cleanTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rx = titleNoise else { return s }
        var rounds = 0
        while rounds < 4, let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) {
            s.removeSubrange(r)
            rounds += 1
        }
        return s
    }

    private static func readAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static func readString(_ el: AXUIElement, _ name: String) -> String {
        guard let v = readAttr(el, name) else { return "" }
        if let s = v as? String { return s }
        if let u = v as? URL { return u.absoluteString }
        return ""
    }

    // Every element gets its own timeout: the setting does not carry over from parent to child.
    private static func readChildren(_ el: AXUIElement) -> [AXUIElement] {
        let kids = readAttr(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for k in kids { AXUIElementSetMessagingTimeout(k, axTimeout) }
        return kids
    }

    // MARK: Apple Events route

    private enum Family {
        case chromium, safari
        init?(_ bundleID: String?) {
            guard let id = bundleID, bundleIDs.contains(id) else { return nil }
            self = id.hasPrefix("com.apple.Safari") ? .safari : .chromium
        }
    }

    private struct AETabs {
        let windowID: Int32
        let active: Int        // 0-based
        let titles: [String]
        let urls: [String]
        let incognito: Bool
    }

    // NSAppleScript is not thread-safe, so every script runs on this one queue. Compiled scripts and the
    // CGWindowID to scripting-id map live here too and are only touched from it.
    private static let aeQueue = DispatchQueue(label: "com.davidmolina.swap.browsertabs.ae")
    private static var scripts: [String: NSAppleScript] = [:]
    private static var windowIDs: [CGWindowID: Int32] = [:]

    // Addresses seen per browser, by tab title, for when Apple Events are late, and how to find each listed tab
    // again. Memory only. Read from the caller's thread.
    private static let sitesLock = NSLock()
    private static var sites: [pid_t: [String: String]] = [:]
    private static var tabs: [CGWindowID: [String: TabRef]] = [:]
    private static var incognito: [CGWindowID: Bool] = [:]    // Apple Events queue only

    private static func knownSites(for pid: pid_t) -> [String: String] {
        sitesLock.lock(); defer { sitesLock.unlock() }
        return sites[pid] ?? [:]
    }

    private static func remember(_ tabs: AETabs, for pid: pid_t) {
        sitesLock.lock(); defer { sitesLock.unlock() }
        var known = sites[pid] ?? [:]
        if known.count > 2000 { known = [:] }
        for (title, url) in zip(tabs.titles, tabs.urls) where !title.isEmpty { known[title] = url }
        sites[pid] = known
    }

    private final class Box<T> { var value: T?; init() {} }

    // Runs `work` on the Apple Events queue and waits for it until `deadline`. A hung browser leaves the queue
    // busy (later calls just time out quickly) but never the caller.
    private static func onAEQueue<T>(until deadline: Date, _ work: @escaping () -> T) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        aeQueue.async {
            if Date() <= deadline { box.value = work() }   // a call that timed out while queued must not act later
            done.signal()
        }
        let wait = max(0, deadline.timeIntervalSinceNow)
        return done.wait(timeout: .now() + wait) == .success ? box.value : nil
    }

    private static func aeTabs(of parent: ParentRef, family: Family, deadline: Date) -> AETabs? {
        // Never `tell` an app that is not running: Apple Events would launch it.
        guard !parent.app.isTerminated, let bundleID = parent.app.bundleIdentifier else { return nil }
        let pid = parent.app.processIdentifier
        let result: AETabs?? = onAEQueue(until: deadline) { () -> AETabs? in
            guard let script = compiledScript(for: bundleID, family: family) else { return nil }
            var retried = false
            while true {
                guard let wid = aeWindowID(for: parent, script: script, deadline: deadline) else { return nil }
                if let r = run(script, handler: "listTabs", [NSAppleEventDescriptor(int32: wid)], deadline: deadline),
                   let active = r.atIndex(1)?.int32Value, let titles = r.atIndex(2), let urls = r.atIndex(3) {
                    let n = titles.numberOfItems
                    let tabs = AETabs(windowID: wid, active: Int(active) - 1,
                                      titles: (0..<n).map { titles.atIndex($0 + 1)?.stringValue ?? "" },
                                      urls: (0..<n).map { urls.atIndex($0 + 1)?.stringValue ?? "" },
                                      incognito: isIncognito(parent, wid: wid, family: family, script: script, deadline: deadline))
                    remember(tabs, for: pid)
                    return tabs
                }
                // The remembered id can belong to a window that has gone; match again once.
                windowIDs[parent.id] = nil
                if retried || Date() > deadline { return nil }
                retried = true
            }
        }
        return result ?? nil
    }

    // Chromium's window `mode`, asked once per window. A separate handler: a browser without it fails this one call,
    // not the tab list. Not asked of Safari, which has no such property.
    private static func isIncognito(_ parent: ParentRef, wid: Int32, family: Family, script: NSAppleScript, deadline: Date) -> Bool {
        guard family == .chromium else { return false }
        if let known = incognito[parent.id] { return known }
        guard let mode = run(script, handler: "windowMode", [NSAppleEventDescriptor(int32: wid)], deadline: deadline)?.stringValue else {
            return parent.title.hasSuffix("(Incognito)")
        }
        incognito[parent.id] = mode == "incognito"
        return mode == "incognito"
    }

    // Apple Events do not know CGWindowIDs. The match is by title (the Accessibility title is the scripting
    // name plus " - Google Chrome – Profile") and, when titles tie or are missing, by the window's frame.
    private static func aeWindowID(for parent: ParentRef, script: NSAppleScript, deadline: Date) -> Int32? {
        if let known = windowIDs[parent.id] { return known }
        guard let r = run(script, handler: "listWindows", [], deadline: deadline),
              let ids = r.atIndex(1), let names = r.atIndex(2), let bounds = r.atIndex(3) else { return nil }
        let frame = cgFrame(of: parent.id)
        var byTitle: [Int32] = [], byFrame: [Int32] = []
        for i in 1...max(ids.numberOfItems, 1) {
            guard let id = ids.atIndex(i)?.int32Value else { continue }
            let name = names.atIndex(i)?.stringValue ?? ""
            let b = (1...4).map { bounds.atIndex(i)?.atIndex($0)?.int32Value }
            let sameFrame: Bool = {
                guard let f = frame, let l = b[0], let t = b[1], let rt = b[2], let bt = b[3] else { return false }
                return abs(CGFloat(l) - f.minX) <= 2 && abs(CGFloat(t) - f.minY) <= 2
                    && abs(CGFloat(rt) - f.maxX) <= 2 && abs(CGFloat(bt) - f.maxY) <= 2
            }()
            if titleMatches(parent.title, name: name) {
                if sameFrame { byTitle.insert(id, at: 0) } else { byTitle.append(id) }
            }
            if sameFrame { byFrame.append(id) }
        }
        let found = byTitle.first ?? (byFrame.count == 1 ? byFrame[0] : nil)
        if let found = found { windowIDs[parent.id] = found }
        return found
    }

    private static func titleMatches(_ title: String, name: String) -> Bool {
        if title == name { return true }
        guard !name.isEmpty, title.hasPrefix(name) else { return false }
        let rest = title.dropFirst(name.count)
        return rest.hasPrefix(" - ") || rest.hasPrefix(" – ") || rest.hasPrefix(" — ")
    }

    // Works for windows on any desktop; both Quartz and the browsers use top-left screen coordinates.
    private static func cgFrame(of id: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let dict = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
        return rect
    }

    // One script per browser, compiled on first use (30 to 90 ms) and kept. The bundle id is baked in because
    // the terminology ("tabs", "active tab index") must resolve at compile time. The 0.4 s timeout is the
    // wait for each reply: the browsers answer in about 40 ms, and a reply that has not come by then is lost
    // (see `run`), so waiting longer only delays the retry.
    private static func compiledScript(for bundleID: String, family: Family) -> NSAppleScript? {
        if let s = scripts[bundleID] { return s }
        let tabs: String, activate: String
        switch family {
        case .chromium:
            tabs = "return {active tab index, title of tabs, URL of tabs}"
            activate = "set active tab index to i"
        case .safari:
            tabs = "return {index of current tab, name of tabs, URL of tabs}"
            activate = "set current tab to tab i"
        }
        let source = """
        on listWindows()
            with timeout of 0.4 seconds
                tell application id "\(bundleID)" to return {id of windows, name of windows, bounds of windows}
            end timeout
        end listWindows
        on listTabs(wid)
            with timeout of 0.4 seconds
                tell application id "\(bundleID)" to tell window id wid to \(tabs)
            end timeout
        end listTabs
        on activateTab(wid, i)
            with timeout of 0.4 seconds
                tell application id "\(bundleID)" to tell window id wid to \(activate)
            end timeout
            return true
        end activateTab
        \(family == .chromium ? """
        on windowMode(wid)
            with timeout of 0.4 seconds
                tell application id "\(bundleID)" to return mode of window id wid
            end timeout
        end windowMode
        """ : "")
        """
        guard let script = NSAppleScript(source: source), script.compileAndReturnError(nil) else { return nil }
        scripts[bundleID] = script
        return script
    }

    // Calls a handler of a compiled script. Four-char codes spelled out so Carbon is not imported:
    // 'ascr'/'psbr' is the "call subroutine" event, 'snam' its handler name, '----' the direct parameter list.
    // About one reply in ten never arrives (error -1712 after the timeout) although the browser is idle and
    // answers the same request again in 40 ms, so a timed-out call is sent once more while time remains.
    private static func run(_ script: NSAppleScript, handler: String, _ params: [NSAppleEventDescriptor], deadline: Date) -> NSAppleEventDescriptor? {
        let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272, targetDescriptor: target,
                                           returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: 0x736E616D)
        let list = NSAppleEventDescriptor.list()
        for (i, p) in params.enumerated() { list.insert(p, at: i + 1) }
        event.setParam(list, forKeyword: 0x2D2D2D2D)
        for attempt in 0..<2 {
            var error: NSDictionary?
            let result = script.executeAppleEvent(event, error: &error)
            if error == nil { return result }
            let timedOut = (error?["NSAppleScriptErrorNumber"] as? Int) == -1712
            if !timedOut || attempt == 1 || Date() > deadline { return nil }
        }
        return nil
    }

    // MARK: Site names

    // "https://www.google.com/search?q=x" -> "google.com"; browser pages keep their scheme ("chrome://settings");
    // pages that are no site at all (about:blank, Safari's favorites://) get nothing.
    private static func host(of urlString: String) -> String {
        guard !urlString.isEmpty, let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else { return "" }
        let h = url.host ?? ""
        switch scheme {
        case "http", "https": return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        case "file": return "file"
        default: return h.isEmpty ? "" : "\(scheme)://\(h)"
        }
    }
}
