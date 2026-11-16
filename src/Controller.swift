// The switcher itself: the keyboard tap, the session, the rows on show. App-specific behaviour lives in providers.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AtomicFlag {
    private var value = false
    private let lock = NSLock()
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

// What a key types with no modifier, for the tap thread. NSEvent's characters and the input source calls may only run
// on the main thread (macOS stops the app if they don't), so the layout is fetched there and translated here.
enum PlainKeys {
    private static let lock = NSLock()
    private static var layout: Data?
    private static var keyboardType: UInt32 = 0

    static func refresh() {   // main thread
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let type = UInt32(LMGetKbdType())
        lock.lock(); layout = data; keyboardType = type; lock.unlock()
    }

    // nil for a key that types nothing (arrows, Return, Esc): those need no text of their own.
    static func text(_ code: Int64, shift: Bool) -> [UniChar]? {
        lock.lock(); let data = layout, type = keyboardType; lock.unlock()
        guard let data else { return nil }
        var dead: UInt32 = 0, length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let keys = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(keys, UInt16(code), UInt16(kUCKeyActionDown), shift ? UInt32(shiftKey >> 8) & 0xFF : 0, type,
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0, chars[0] >= 0x20, chars[0] != 0x7F else { return nil }
        return Array(chars.prefix(length))
    }
}

// MARK: - Switcher state machine (hold the modifier, tap Tab to step, release to switch)
//
// The keyboard tap runs on its own thread and only decides whether an event is swallowed; everything
// else happens on the main thread. So a slow app can never hold up the keyboard, and the switcher
// always closes when the modifier is released, even while the window list is still being read.

final class Controller {
    static let shared = Controller()

    static let tabKey: Int64 = 48, escKey: Int64 = 53, returnKey: Int64 = 36
    static let quitKey: Int64 = 12, closeKey: Int64 = 13   // Q and W, as in the Mac app switcher
    static let pinKey: Int64 = 35                           // P pins or unpins the selected tab or chat
    static let newKey: Int64 = 45, spaceKey: Int64 = 49
    // The letters that go to the selected app as Command+letter: N F T K G L O R. Short and safe on purpose, so a stray
    // key can't damage a document. Every other letter does nothing. W, Q and P are the list's own.
    static let commandLetters: Set<Int64> = [45, 3, 17, 40, 5, 37, 31, 15]
    static let leftKey: Int64 = 123, rightKey: Int64 = 124, downKey: Int64 = 125, upKey: Int64 = 126
    static let numberKeys: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
    static let showDelay = Tokens.Motion.showDelay   // a quick tap flips windows without flashing the panel
    static let maxItems = 500
    static let repeatingKeys: Set<Int64> = [tabKey, leftKey, rightKey, downKey, upKey]   // held down, only these act again

    var tap: CFMachPort?
    let panel = SwitcherPanel()

    // Read by the tap thread: is a session running? Set the moment the first shortcut arrives, so the
    // keys that follow are swallowed even while the main thread is still reading the window list.
    private let session = AtomicFlag()
    // Read by the tap thread: the list stays open when the modifier is released (menu, "keep open" setting).
    private let pinned = AtomicFlag()
    // Read by the tap thread: letting go of the modifier picks, though the list is pinned (Option+Tab while searching).
    private let pickOnRelease = AtomicFlag()
    // Read by the tap thread: the modifier that opened search is still down, so keys reach the field without it.
    private let dropModifier = AtomicFlag()
    // Tap thread only: every key swallowed and not yet let go, with when it was last seen. Its repeats and its key-up
    // stay Swap's too, even after the session has ended.
    private var heldKeys: [Int64: TimeInterval] = [:]
    // Read by the tap thread: which modifier opens Swap. Updated on the main thread when the setting changes.
    private var modifier: CGEventFlags = Settings.shortcut.modifier

    private var active = false
    private var loaded = false
    private var commitWhenLoaded = false
    private var generation = 0
    private var pendingSteps = 0               // Tabs pressed before the list was ready
    private var steps = 0                      // Tabs, arrows and flips in this session (1 = a quick flip)
    private var pages: [Windows.Page] = []     // one per desktop
    private var pageIndex = 0                  // page on show
    private var currentPage = 0                // desktop you are on
    private var items: [WindowItem] = []       // windows of the page on show
    private var sel = 0
    private var front: CGWindowID = 0
    private var previousElsewhere: (page: Int, index: Int)?   // the window used before this one, when on another desktop
    private struct Swipe {
        var x: CGFloat = 0, y: CGFloat = 0                          // finger travel, in the fingers' direction (left is negative)
        var used = false                                            // a key took over: this gesture does nothing more
        var recent: [(time: TimeInterval, x: CGFloat)] = []         // the last moments of travel, for the speed on letting go
    }
    private var swipe = Swipe()
    private var slide: PageSlide?              // the list moving between desktops
    private var slideTurned: (delta: Int, sel: Int)?   // the page it is landing on, and the row to go back to if caught
    private var shown = false
    // Drill-in: windows whose children are on show, the children read this session, and reads in flight.
    private var open = Set<String>()
    private var childCache: [String: [ChildItem]] = [:]
    private var loading = Set<String>()
    private var dressed = false              // the rows have had the providers' additions; a quick flip never asks for them
    private var labelled = false             // provider labels were refreshed this session
    private var searchWhenLoaded = false     // / or Space pressed before the list was ready
    private var noChildren = Set<String>()   // rows that turned out to have nothing inside: plain for this session
    private var closing = Set<String>()      // W pressed; the row stays until the window has gone
    private var outsideClicks: Any?          // while the list shows: a click on another app
    private var appChanges: NSObjectProtocol?
    private var keepThroughChanges = Date.distantPast   // a W or Q of ours may bring another app forward
    private var glanceRunning = false        // the engine samples once a second while the panel is on screen
    private var optionPoll: Timer?
    // The search row (Search*.swift). Read by the tap thread: the text field has the keyboard, keys pass through.
    private let searching = AtomicFlag()
    private var pinnedBeforeSearch = false
    let search = SearchSession()
    private(set) var showCount = 0       // read by the self-test
    var isActive: Bool { active }
    var slideState: [String: Any] {   // read by the self-test
        ["on": slide != nil, "settling": slide?.isSettling ?? false, "offset": slide.map { Double($0.offset) } ?? 0, "ticks": slide?.ticks ?? 0]
    }
    var isPinned: Bool { pinned.isSet }
    var selection: Int { sel }
    var page: Int { pageIndex }
    var pageCount: Int { pages.count }
    var pageTitle: String { pages.indices.contains(pageIndex) ? pages[pageIndex].title : "" }
    var selectedItem: WindowItem? { items.indices.contains(sel) ? items[sel] : nil }
    private(set) var lastRefusal = ""    // read by the self-test

    init() {
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.modifier = Settings.shortcut.modifier
        }
        search.host = self
    }

    // Runs on the tap thread. Decides at once whether the event is swallowed and hands the work to the
    // main thread; it never talks to other apps.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let mod = modifier
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            heldKeys = [:]   // key-ups may have been missed
            DispatchQueue.main.async { [self] in checkModifierHeld() }   // a release may have been missed
            return pass
        case .scrollWheel:
            guard session.isSet, !searching.isSet else { return pass }
            if let copy = event.copy() { DispatchQueue.main.async { [self] in handleScroll(copy) } }
            return nil
        case .flagsChanged:
            if !event.flags.contains(mod) {
                dropModifier.set(false)
                if session.isSet && (!pinned.isSet || pickOnRelease.isSet) {
                    session.set(false)   // from now on keys belong to the user again, even before main catches up
                    DispatchQueue.main.async { [self] in commit() }
                }
            }
            return pass
        case .keyDown, .keyUp:
            if event.getIntegerValueField(.eventSourceUserData) == AppCommand.ownEvent { return pass }   // Swap's own: a command or a replayed key
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let down = type == .keyDown
            let inSession = session.isSet
            if !down, heldKeys.removeValue(forKey: code) != nil { return nil }
            // A key down without a key up is that key repeating, whatever the event says. Old entries are key-ups lost on the way.
            let now = ProcessInfo.processInfo.systemUptime
            var repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if down, let seen = heldKeys[code] {
                if repeated || now - seen < 2.5 { heldKeys[code] = now; repeated = true; if !Controller.repeatingKeys.contains(code) || !inSession { return nil } }
                else { heldKeys[code] = nil }
            }
            // Only a Tab with the modifier held starts or extends a session; a plain Tab never does.
            let all: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl]
            let others = all.subtracting(mod)
            if code == Controller.tabKey, flags.contains(mod), flags.intersection(others).isEmpty {
                if down {
                    heldKeys[code] = now
                    session.set(true)
                    let reverse = flags.contains(.maskShift)
                    DispatchQueue.main.async { [self] in step(reverse: reverse) }
                }
                return nil
            }
            // Every other key while the list is open is Swap's: used or dropped, never typed into the app behind.
            if inSession {
                if searching.isSet {   // typing in Swap's own search field
                    if dropModifier.isSet, flags.contains(mod), flags.intersection(others).isEmpty { Controller.remove(mod, from: event) }
                    return pass
                }
                guard down else { return pass }   // the key-up of something pressed before the list opened
                if repeated, !Controller.repeatingKeys.contains(code) { return nil }
                heldKeys[code] = now
                let shift = flags.contains(.maskShift)
                let copy = event.copy()   // read on main: NSEvent's characters may not be asked for on this thread
                DispatchQueue.main.async { [self] in
                    key(code, shift: shift, text: copy.flatMap { NSEvent(cgEvent: $0)?.charactersIgnoringModifiers })
                }
                return nil
            }
            // A command is on its way to an app: what is typed now comes after it.
            if AppCommand.holding {
                if let copy = event.copy() {
                    if copy.flags.contains(mod), copy.flags.intersection(others).isEmpty { Controller.remove(mod, from: copy) }
                    AppCommand.hold(copy)
                }
                return nil
            }
            return pass
        default:
            return pass
        }
    }

    // The same key without the held modifier, characters included: Option+A reaches the field as a, not as å.
    private static func remove(_ mod: CGEventFlags, from event: CGEvent) {
        event.flags = event.flags.subtracting(mod)
        guard var units = PlainKeys.text(event.getIntegerValueField(.keyboardEventKeycode), shift: event.flags.contains(.maskShift)) else { return }
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
    }

    private static func verb(for code: Int64, shift: Bool) -> Verb? {
        switch code {
        case closeKey: return .close
        case quitKey: return .quit
        case pinKey: return .pin
        default: return commandLetters.contains(code) && !shift ? .command : nil
        }
    }

    private func isTyped(_ text: String?) -> Bool {
        guard let u = text?.unicodeScalars.first else { return false }
        return !CharacterSet.controlCharacters.contains(u) && !(0xF700...0xF8FF).contains(u.value)   // not an arrow or a function key
    }

    private func key(_ code: Int64, shift: Bool, text: String?) {
        guard active else { return }
        finishSlide()
        guard active else { return }
        steps += 1   // any key after the first Tab means this is no quick flip
        if search.typing {   // pressed just before the field took the keyboard
            if code == Controller.escKey { cancel() } else if isTyped(text), let text { search.type(text) }
            return
        }
        let opensSearch = text == "/" || code == Controller.spaceKey
        if !loaded, opensSearch { searchWhenLoaded = true; return }
        dress()
        if search.onRow {   // the field opens on Return, on the first letter, or when the modifier is released
            switch code {
            case Controller.escKey: cancel()
            case Controller.returnKey: startTyping()
            case Controller.upKey: move(-1)     // on round to the last row
            case Controller.downKey, Controller.tabKey: move(1)
            default:
                if opensSearch { startTyping() } else if isTyped(text), let text { startTyping(); search.type(text) }
            }
            return
        }
        if opensSearch { openSearch(); return }
        switch code {
        case Controller.escKey: cancel()
        case Controller.tabKey: if loaded, !shown { showPanel() }; move(shift ? -1 : 1)   // the modifier is up: the list is pinned
        case Controller.returnKey: shift ? collapse() : activate()
        case Controller.upKey: if loaded, !shown { showPanel() }; up()
        case Controller.downKey: if loaded, !shown { showPanel() }; move(1)
        case Controller.leftKey: flip(-1)
        case Controller.rightKey: flip(1)
        default:
            // 1 to 9 picks that row straight away.
            if let n = Controller.numberKeys[code] {
                if Settings.numberKeys, loaded, items.indices.contains(n - 1) { sel = n - 1; finish(focus: true) }
            } else if let verb = Controller.verb(for: code, shift: shift) {
                if Settings.actionKeys { perform(verb, key: code) }
            } else if isTyped(text), loaded {
                refuse(Verbs.notAKey, beep: false)
            }
        }
    }

    // W, Q, P or a letter on the selected row, as the verb table says.
    private func perform(_ verb: Verb, key: Int64) {
        guard loaded else { return }
        if !shown, verb != .command { showPanel() }
        guard let item = selectedItem else { return }
        guard Verbs.allows(verb, on: item) else { refuse(Verbs.kind(of: item) == .menu ? Verbs.menuRow : Verbs.refusal(verb)); return }
        switch verb {
        case .close: closeRow(item)
        case .quit: quitRow(item)
        case .pin: togglePin(item)
        case .command: sendCommand(key, to: item)
        }
    }

    // A clear no: nothing happens, and the list says why.
    private func refuse(_ text: String, beep: Bool = true) {
        lastRefusal = text
        if beep { NSSound.beep() }
        if !shown { showPanel() }
        panel.switcher?.searchRow?.show(note: text)
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // First shortcut starts a session; the window list is read on a background queue meanwhile.
    // Tabs pressed before it is ready are counted.
    private func step(reverse: Bool) {
        finishSlide()
        let d = reverse ? -1 : 1
        if !active {
            begin()
            pendingSteps = d; steps = 1
            if Settings.keepOpen { pinned.set(true) }
            let gen = generation
            load(gen) { [self] in
                if commitWhenLoaded { finish(focus: true); return }
                let delay = (Settings.quickFlip && !pinned.isSet) ? Controller.showDelay : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                    guard active, gen == generation, !shown else { return }
                    showPanel()
                }
            }
        } else if !loaded {
            pendingSteps += d; steps += 1
        } else {
            steps += 1
            if !shown { showPanel() }   // a second key means you are choosing, so show the list at once
            if search.typing { pickOnRelease.set(true) }   // as in the list: let go and you are there
            move(d)
        }
    }

    // "Show window list" in the menu: the list opens and stays until you pick or press Esc.
    func showFromMenu() {
        guard !active else { return }
        begin()
        pinned.set(true)
        pendingSteps = 0; steps = 2
        let gen = generation
        load(gen) { [self] in
            dress()
            if items.indices.contains(1), !items[1].isSelf { sel = 1 }
            showPanel()
        }
    }

    private func begin() {
        active = true; session.set(true); loaded = false; commitWhenLoaded = false; shown = false
        previousElsewhere = nil
        generation += 1
        // Baselines only (CPU ticks, byte counters); a quick flip that never shows the panel reads nothing else.
        if Settings.glanceBar { GlanceEngine.shared.prime() }
        startModifierPoll()
    }

    private func load(_ gen: Int, then: @escaping () -> Void) {
        Windows.pagesAsync { [self] p in
            guard active, gen == generation else { return }
            pages = p.pages.map { Windows.Page(title: $0.title, items: Array($0.items.prefix(Controller.maxItems))) }
            currentPage = p.current; pageIndex = p.current
            front = p.front
            dressed = false; labelled = false
            rebuildItems()
            loaded = true
            place()
            if !pages.contains(where: { !$0.items.isEmpty }) { dress() }    // only a provider's rows can be left
            // Nothing open anywhere: with Swap's own row on, the list still opens on that one row (a quick flip ends on it
            // and does nothing; see finish). Without it there is nothing to show, as before.
            guard pages.contains(where: { !$0.items.isEmpty }) || items.contains(where: { $0.isSelf }) else { reset(); return }
            previousElsewhere = Windows.previousWindow(in: pages, exceptPage: currentPage, front: p.front)
            if searchWhenLoaded { searchWhenLoaded = false; commitWhenLoaded = false; openSearch(); return }
            then()
        }
    }

    // Row 1 is normally the window in front, so the first Tab lands on row 2. When nothing listed
    // is in front (a dialog, the desktop, an app with only minimised windows), it lands on row 1.
    // Swap's own row is never where the first Tab lands, either way round: one more step passes it, so a quick flip
    // goes from window to window exactly as it does without the row.
    private func place() {
        let frontIsFirst = items.first.map { $0.id != 0 && $0.id == front } ?? false
        let offset = (!frontIsFirst && pendingSteps > 0) ? -1 : 0
        let n = items.count
        sel = items.isEmpty ? 0 : (((pendingSteps + offset) % n) + n) % n
        if items.indices.contains(sel), items[sel].isSelf, abs(pendingSteps) == 1, n > 1 {
            sel = (((sel + pendingSteps) % n) + n) % n
        }
    }

    // What providers add to the list, on the first moment it can be seen: their rows, their order and the labels last
    // read. A quick flip ends before this, so it goes from recency and the window list alone and calls no provider.
    private func dress() {
        guard loaded, !dressed else { return }
        dressed = true
        PlainKeys.refresh()
        pages = Children.Labels.apply(to: Children.addRows(to: pages, current: currentPage))
        rebuildItems()
        place()
    }

    // Reads labels and dots again now the panel is up. A slow app shows last time's until it answers.
    private func refreshLabels() {
        guard !labelled, Settings.drillIn else { return }
        labelled = true
        let gen = generation
        Children.Labels.refresh(pages.flatMap { $0.items }) { [self] in
            guard active, gen == generation else { return }
            pages = Children.Labels.apply(to: pages)
            guard !search.typing else { return }
            rebuildItems(select: selectedItem?.key)
            showRows()
        }
    }

    private func move(_ delta: Int) {
        guard loaded, !items.isEmpty else { return }
        if search.onRow { leaveSearchRow(); sel = delta > 0 ? 0 : items.count - 1; panel.select(sel); return }
        sel = (((sel + delta) % items.count) + items.count) % items.count
        if shown { panel.select(sel) }
    }

    // Show another desktop's windows. On another desktop the window you used last there is selected;
    // back on your own desktop, the previous window is, as when the switcher opened.
    private func flip(_ delta: Int) {
        guard loaded, !search.inUse else { return }
        dress()
        guard pages.indices.contains(pageIndex + delta) else { return }
        if shown, let moving = startSlide() {
            let row = sel
            turnPage(delta)
            slideTurned = (delta, row)
            moving.settle(to: delta, speed: 0) { [weak self] in self?.slideLanded() }
            return
        }
        turnPage(delta)
        showPanel()
    }

    private func turnPage(_ delta: Int) {
        steps += 1
        pageIndex += delta
        rebuildItems()
        sel = arrivalRow(on: pageIndex, rows: items)
    }

    // The row a page opens on when you arrive at it.
    private func arrivalRow(on page: Int, rows: [WindowItem]) -> Int { page == currentPage && rows.filter({ !$0.isSelf }).count > 1 ? 1 : 0 }

    private func startSlide() -> PageSlide? {
        let base = pageIndex
        slide = panel.beginSlide { [weak self] side in
            guard let self, self.pages.indices.contains(base + side) else { return nil }
            let rows = self.pageRows(base + side)
            return (rows, self.arrivalRow(on: base + side, rows: rows), self.header(forPage: base + side, rows: rows))
        }
        return slide
    }

    private func slideLanded() {
        slide = nil
        slideTurned = nil
        showPanel()
    }

    // A key, or the modifier going up, while the list is moving: it finishes at once, so what you press acts on the
    // page you can see arriving. With fingers still down the position decides.
    private func finishSlide() {
        guard let moving = slide else { return }
        if !moving.isSettling { letGo(moving, speed: 0); swipe.used = true }
        moving.land()
    }

    private func letGo(_ moving: PageSlide, speed: CGFloat) {
        let M = Tokens.Motion.self
        let side = moving.offset < 0 ? 1 : -1
        var carry = abs(moving.offset) > moving.width * M.pageCommitShare
        if abs(speed) > M.pageFlickSpeed { carry = (speed < 0) == (moving.offset < 0) }   // a flick decides, either way
        if carry, moving.offset != 0, pages.indices.contains(pageIndex + side) {
            let row = sel
            turnPage(side)
            slideTurned = (side, row)
            moving.settle(to: side, speed: speed) { [weak self] in self?.slideLanded() }
        } else {
            moving.settle(to: 0, speed: speed) { [weak self] in self?.slideLanded() }
        }
    }

    // Fingers down on a list still moving: it stops under them, and letting go decides again.
    private func catchSlide(_ moving: PageSlide) {
        moving.hold()
        if let turned = slideTurned {
            steps -= 1
            pageIndex -= turned.delta
            rebuildItems()
            sel = turned.sel
            slideTurned = nil
        }
        swipe = Swipe()
        swipe.x = moving.offset / Tokens.Motion.pageGain
    }

    // Content speed over the last moments before letting go, in points a second. Fingers that rested first have none.
    private func swipeSpeed(at time: TimeInterval) -> CGFloat {
        let recent = swipe.recent.filter { time - $0.time < 0.08 }
        guard let first = recent.first, let last = recent.last, recent.count > 1 else { return 0 }
        return (last.x - first.x) / CGFloat(max(last.time - first.time, 0.008)) * Tokens.Motion.pageGain
    }

    // MARK: drill-in (Return expands a row into its tabs or chats; see Children.swift)

    // The rows on show: the page's windows, each expanded one followed by its children, indented.
    private func rebuildItems(select key: String? = nil) {
        let rows = pageRows(pageIndex)
        items = rows
        if let key, let i = rows.firstIndex(where: { $0.key == key }) { sel = i }
        else if !rows.isEmpty { sel = min(sel, rows.count - 1) } else { sel = 0 }
    }

    private func pageRows(_ page: Int) -> [WindowItem] {
        var rows: [WindowItem] = []
        var base = pages.indices.contains(page) ? pages[page].items : []
        if dressed { Children.arrange(&base) }
        for w in base {
            var row = w
            row.expandable = dressed && Settings.drillIn && !noChildren.contains(w.key) && Children.canExpand(w)
            row.expanded = row.expandable && open.contains(w.key)
            rows.append(row)
            guard row.expanded else { continue }
            for kid in Children.order(childCache[w.key] ?? [], key: w.key, group: Children.pinGroup(w)) {
                var r = WindowItem(app: w.app, window: w.window, id: w.id, title: kid.title, appName: w.appName,
                                   icon: kid.icon ?? w.icon, minimized: false, depth: 1, child: kid, parentKey: w.key,
                                   workspace: w.workspace, pinned: Children.isPinned(kid, in: w))
                let groupKey = "group:\(w.key)/\(kid.id)"
                r.expandable = kid.isGroup; r.expanded = kid.isGroup && open.contains(groupKey)
                rows.append(r)
                guard r.expanded else { continue }
                for a in childCache[groupKey] ?? [] {
                    rows.append(WindowItem(app: w.app, window: w.window, id: w.id, title: a.title, appName: w.appName, icon: w.icon,
                                           minimized: false, depth: 2, child: a, parentKey: w.key))
                }
            }
        }
        // Swap's own row, always last and only on the desktop you are on. It is not in `pages`, so recency, the quick flip,
        // "the window you came from" and search never see it.
        if page == currentPage, Settings.showSelfInList { rows.append(.swapRow()) }
        return rows
    }

    // Return: a child opens; a window that can expand does; anything else is picked.
    private func activate() {
        guard loaded, let item = selectedItem else { finish(focus: true); return }
        if item.child?.isGroup == true { expandGroup(item); return }
        guard item.child == nil, item.expandable, !item.expanded else { finish(focus: true); return }
        expand(item)
    }

    // A row that holds more rows, inside an expanded app: Return lists them under it.
    private func expandGroup(_ row: WindowItem) {
        guard let parentKey = row.parentKey, let parent = items.first(where: { $0.key == parentKey }), let group = row.child else { return }
        let key = "group:\(parentKey)/\(group.id)"
        func show() {
            guard search.query.isEmpty else { return }
            rebuildItems(select: childCache[key]?.first.map { "c\(parentKey)/\($0.id)" } ?? row.key)
            showPanel()
        }
        open.insert(key)
        if childCache[key] != nil { show(); return }
        guard !loading.contains(key) else { return }
        loading.insert(key)
        let gen = generation
        Children.groupChildren(of: group, item: parent) { [self] list in
            guard active, gen == generation else { return }
            loading.remove(key)
            if let list { childCache[key] = list } else { open.remove(key) }   // no answer: nothing is remembered, and it can be tried again
            show()
        }
    }

    private func expand(_ item: WindowItem) {
        let key = item.key
        if !shown { showPanel() }
        open.insert(key)
        if childCache[key] != nil { rebuildItems(select: firstChildKey(key) ?? key); showPanel(); return }
        guard !loading.contains(key) else { return }
        loading.insert(key)
        let gen = generation
        let delay = Children.prepare(item, expanding: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard active, gen == generation else { return }
            Children.fetch(item) { [self] kids in
                guard active, gen == generation else { return }
                let first = loading.remove(key) != nil
                guard first || open.contains(key) else { return }   // a later, fresher list for a row that has since folded
                if let kids, kids.count > 1 || kids.contains(where: { $0.isGroup }) {
                    childCache[key] = kids
                    guard search.query.isEmpty else { return }
                    rebuildItems(select: first ? firstChildKey(key) ?? key : selectedItem?.key)
                    showPanel()
                    return
                }
                if first { fallToPlain(key, known: kids != nil) }
            }
        }
    }

    // Nothing inside, or no answer in time: the row is an ordinary window row and Return does what it does on one.
    // Nothing is stored for a read that timed out, so the next session tries again.
    private func fallToPlain(_ key: String, known: Bool) {
        open.remove(key)
        if known { noChildren.insert(key) }
        guard search.query.isEmpty else { return }
        let stillOn = selectedItem?.key == key
        rebuildItems(select: selectedItem?.key)
        if stillOn { finish(focus: true) } else { showRows() }
    }

    // A letter: bring the selected row forward (its chat or tab too), then send that app Command+letter there.
    private func sendCommand(_ key: Int64, to item: WindowItem) {
        guard let app = item.app else { return }
        let prepared = dressed ? Children.prepare(item, expanding: false) : 0
        var openChild: (() -> Void)?
        if let kid = item.child { Children.noteUsed(kid, in: item); openChild = Children.openStep(kid, in: item) }
        reset()
        keepThroughChanges = Date().addingTimeInterval(1)
        Windows.focus(item)
        AppCommand.send(key, to: app, window: item.id, settle: prepared, before: openChild)
    }

    // P on a tab or chat: pinned ones come first under their row, now and next time.
    private func togglePin(_ item: WindowItem) {
        guard let kid = item.child, let parentKey = item.parentKey, let parent = items.first(where: { $0.key == parentKey }) else { return }
        Children.togglePin(kid, in: parent)
        rebuildItems(select: item.key)
        showPanel()
    }

    private func firstChildKey(_ parent: String) -> String? {
        guard let kids = childCache[parent], let p = items.first(where: { $0.key == parent }) else { return nil }
        // The first real chat: an Archived row sits above it but never takes the focus.
        return Children.order(kids, key: parent, group: Children.pinGroup(p)).first { !$0.isGroup }.map { "c\(parent)/\($0.id)" }
    }

    // Shift+Return folds the row the selection is in (or on) back up and selects that window.
    private func collapse() {
        guard loaded, search.query.isEmpty, let item = selectedItem else { return }
        let key = item.parentKey ?? item.key
        if let group = open.first(where: { $0.hasPrefix("group:\(key)/") }) {   // what's inside a group folds first
            open.remove(group)
            rebuildItems(select: "c\(key)/" + group.dropFirst("group:\(key)/".count))
            showPanel()
            return
        }
        guard open.contains(key) else { return }
        open.remove(key)
        rebuildItems(select: key)
        showPanel()
    }

    // W closes the selected window or tab, Q quits its app, like Command+W / Command+Q in the Mac app switcher.
    // The list stays open, so you can keep choosing; release or Return picks as usual. A row goes only once the thing
    // has gone. If it stays, a Save prompt is the likely reason: the row is kept and its window comes forward. When
    // nothing is left anywhere the session ends.
    private func closeRow(_ item: WindowItem) {
        if let kid = item.child, let parentKey = item.parentKey {
            Children.closeChild(kid, in: item) { [self] closed in
                guard active else { return }
                guard closed else { refuse(Verbs.stayedOpen); return }
                childCache[parentKey]?.removeAll { $0.id == kid.id }
                guard search.query.isEmpty else { return }
                let at = sel
                rebuildItems()
                if !items.indices.contains(at) || items[at].parentKey != parentKey, at > 0 { sel = at - 1 }   // stay among its neighbours
                showRows()
            }
            return
        }
        guard closing.insert(item.key).inserted else { return }
        keepThroughChanges = Date().addingTimeInterval(2)
        Windows.close(item)
        watchClose(item, waited: 0)
    }

    private func watchClose(_ item: WindowItem, waited: TimeInterval) {
        let gen = generation, tick = 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + tick) { [self] in
            guard active, gen == generation else { return }
            if Windows.isGone(item) {
                closing.remove(item.key)
                let wasSelected = selectedItem?.key == item.key
                drop { $0.id == item.id }
                if wasSelected, active, !search.typing { stayOnApp(of: item) }
                return
            }
            let t = waited + tick
            if t >= 0.59, t < 0.61 { bringForward(item) }
            if t < 1.5 { watchClose(item, waited: t) } else { closing.remove(item.key) }
        }
    }

    // After a close the selection stays with the same app when it has another window, so the next key can't land on a
    // different app by accident.
    private func stayOnApp(of item: WindowItem) {
        guard let pid = item.app?.processIdentifier, selectedItem?.app?.processIdentifier != pid,
              let i = items.firstIndex(where: { $0.app?.processIdentifier == pid && $0.child == nil }) else { return }
        sel = i
        if shown { panel.select(i) }
    }

    private func quitRow(_ item: WindowItem) {
        keepThroughChanges = Date().addingTimeInterval(4)
        Windows.quit(item)
        watchQuit(item, waited: 0)
    }

    private func watchQuit(_ item: WindowItem, waited: TimeInterval) {
        let gen = generation, tick = 0.15
        DispatchQueue.main.asyncAfter(deadline: .now() + tick) { [self] in
            guard active, gen == generation, let app = item.app else { return }
            if app.isTerminated {
                let pid = app.processIdentifier
                drop { $0.app?.processIdentifier == pid }
                return
            }
            let t = waited + tick
            if t >= 1.49, t < 1.51 { bringForward(item) }
            if t < 3 { watchQuit(item, waited: t) }
        }
    }

    // The app is asking something, behind the list: keep the row, put its window in front, and make it the row that a
    // release goes to.
    private func bringForward(_ item: WindowItem) {
        keepThroughChanges = Date().addingTimeInterval(2)
        Windows.focus(item)
        guard !search.typing, !search.onRow, let i = items.firstIndex(where: { $0.key == item.key }) else { return }
        sel = i
        if shown { panel.select(i) }
    }

    private func drop(_ gone: (WindowItem) -> Bool) {
        pages = pages.map { Windows.Page(title: $0.title, items: $0.items.filter { !gone($0) }) }
        guard pages.contains(where: { !$0.items.isEmpty }) else { reset(); return }
        previousElsewhere = nil
        if search.typing, !search.query.isEmpty { search.remove(gone); return }
        rebuildItems(select: selectedItem.flatMap { gone($0) ? nil : $0.key })
        showPanel()
    }

    // Two-finger horizontal swipe while the switcher is open, in the same direction as the system's three-finger desktop
    // swipe (fingers left = desktop to the right). The list follows the fingers (PageSlide.swift). With Reduce Motion on
    // there is nothing to follow, so one swipe changes the page at once.
    private func handleScroll(_ event: CGEvent) {
        guard active, let e = NSEvent(cgEvent: event), e.hasPreciseScrollingDeltas, e.momentumPhase.isEmpty else { return }
        if e.phase.contains(.began) || e.phase.contains(.mayBegin) {
            if let moving = slide { if moving.isSettling { catchSlide(moving) } } else { swipe = Swipe() }
        }
        // With natural scrolling the deltas already follow the fingers; otherwise they are reversed.
        swipe.x += e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        swipe.y += abs(e.scrollingDeltaY)
        if e.scrollingDeltaX != 0 { swipe.recent.append((e.timestamp, swipe.x)) }   // the lift itself is not a slowing down
        if swipe.recent.count > 12 { swipe.recent.removeFirst() }
        let M = Tokens.Motion.self
        let along = abs(swipe.x) > swipe.y
        if !swipe.used, !PageSlide.allowed {
            if abs(swipe.x) > 40, along { swipe.used = true; flip(swipe.x < 0 ? 1 : -1) }
        } else if !swipe.used, slide == nil, abs(swipe.x) > M.pageStartAfter, along, loaded, !search.inUse {
            if !shown { showPanel() }
            swipe.x -= swipe.x < 0 ? -M.pageStartAfter : M.pageStartAfter   // the list starts from where it rests, without a jump
            swipe.recent = []
            if startSlide() == nil { swipe.used = true }
        }
        if !swipe.used, let moving = slide, !moving.isSettling { moving.track(swipe.x * M.pageGain) }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            if !swipe.used, let moving = slide, !moving.isSettling { letGo(moving, speed: swipeSpeed(at: e.timestamp)) }
            swipe = Swipe()
        }
    }

    private func header(forPage page: Int, rows: [WindowItem]) -> SwitcherView.Header? {
        guard pages.count > 1 else { return nil }
        var hint: String?
        if rows.isEmpty {
            if page + 1 < pages.count { hint = String(format: Tokens.Copy.emptyHintRight, pages[page + 1].title) }
            else if page > 0 { hint = String(format: Tokens.Copy.emptyHintLeft, pages[page - 1].title) }
        }
        return SwitcherView.Header(title: pages[page].title, index: page, count: pages.count, emptyHint: hint)
    }

    private func showPanel() {
        if search.typing { showRows(); return }   // the panel stays put: the field keeps the keyboard
        guard slide == nil else { return }        // the slide draws the page when it lands
        dress()
        shown = true
        showCount += 1
        watchOutside()
        let header = self.header(forPage: pageIndex, rows: items)
        let screen = SwitcherPanel.targetScreen(frontWindow: front)
        // On a desktop change the bar is drawn from the engine's latest readings at once; no restart.
        let glance: [Glance.Reading]? = Settings.glanceBar ? GlanceEngine.shared.current : nil
        panel.onChevron = { [weak self] index in   // the chevron folds and unfolds; the rest of the row picks
            guard let self, self.items.indices.contains(index) else { return }
            self.sel = index
            if self.items[index].expanded { self.collapse() } else { self.activate() }
        }
        panel.show(items: items, selected: sel, screen: screen, header: header, glance: glance, searchRow: Settings.searchRow) { [weak self] index in
            guard let self else { return }
            self.sel = index
            self.finish(focus: true)
        }
        panel.switcher?.searchRow?.onClick = { [weak self] in self?.clickSearchRow() }
        if search.onRow { panel.switcher?.searchRow?.state = .selected; panel.select(-1) }
        refreshLabels()
        if Settings.glanceBar, !glanceRunning {
            glanceRunning = true
            GlanceEngine.shared.start { [weak self] readings in self?.panel.updateGlance(readings) }
        }
    }

    // A pinned list has no key to let go of, so it goes when you leave it: a click anywhere else, or another app coming
    // forward. Search has the same rule through the keyboard (SearchSession.panelLostKeyboard).
    private func watchOutside() {
        guard outsideClicks == nil else { return }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.leftTheList() }
        appChanges = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, Date() >= self.keepThroughChanges else { return }
            self.leftTheList()
        }
    }

    private func stopWatchingOutside() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let appChanges { NSWorkspace.shared.notificationCenter.removeObserver(appChanges) }
        outsideClicks = nil; appChanges = nil
    }

    private func leftTheList() {
        if active, pinned.isSet { cancel() }
    }

    // Belt and braces: if the release never reached the tap, the session still ends as soon as the key
    // is up. Checked every 50 ms while a session runs (not when the list is pinned open).
    private func startModifierPoll() {
        optionPoll?.invalidate()
        optionPoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkModifierHeld() }
    }

    private func checkModifierHeld() {
        guard active else { optionPoll?.invalidate(); optionPoll = nil; return }
        if pickOnRelease.isSet {
            if !CGEventSource.flagsState(.combinedSessionState).contains(modifier) { commit() }
            return
        }
        if search.onRow, !search.typing {   // released on the search row: the list stays and takes the keyboard
            if !CGEventSource.flagsState(.combinedSessionState).contains(modifier) { startTyping() }
            return
        }
        guard !pinned.isSet else { return }
        if !CGEventSource.flagsState(.combinedSessionState).contains(modifier) { commit() }
    }

    private func commit() {
        finishSlide()
        if pickOnRelease.isSet { pickOnRelease.set(false); if active { finish(focus: true) }; return }
        if active, search.onRow { session.set(true); return }   // the release raced the Up key: stay open
        guard active, !pinned.isSet else { return }
        if loaded { finish(focus: true) } else { commitWhenLoaded = true }
    }

    private func cancel() {
        guard active else { return }
        finish(focus: false)
    }

    private func finish(focus: Bool) {
        var item = items.indices.contains(sel) ? items[sel] : nil
        // A quick tap goes back to the window you came from, even when that is on another desktop.
        if focus, !shown, steps == 1, pendingSteps == 1, let p = previousElsewhere,
           pages.indices.contains(p.page), pages[p.page].items.indices.contains(p.index) {
            item = pages[p.page].items[p.index]
        }
        if focus, let url = item?.opens { reset(); SearchSession.open(url); return }
        // Swap's own row: the list closes and Swap's menu opens. Only when it was chosen: on the list, or with a key other
        // than Tab. A Tab tapped before the list appeared never opens a menu out of nowhere.
        if let mine = item, mine.isSelf {
            let chosen = focus && (shown || steps > abs(pendingSteps))
            let screen = panel.screen
            reset()
            if chosen { AppCommand.abandon(); SwapMenu.open(on: screen) }
            return
        }
        // Gone behind the list: say so and keep the list, rather than land somewhere else.
        if focus, shown, let gone = item, gone.child == nil, gone.id != 0, gone.window != nil, !Windows.stillThere(gone) {
            refuse(Verbs.windowGone)
            drop { $0.id == gone.id }
            return
        }
        if focus { AppCommand.abandon() }   // you are going elsewhere: a letter still on its way must not follow you
        let prepared = focus && dressed && item != nil ? Children.prepare(item!, expanding: false) : 0
        reset()
        guard focus, let item, item.app?.isTerminated != true else { return }
        Windows.focus(item)
        let delay = max(0.25, prepared)   // a chat or tab opens once its window is in front
        if let kid = item.child { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Children.open(kid, in: item) } }
        else if item.window == nil { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Children.openWithoutWindow(item) } }
    }

    // MARK: search row (finding things is in Search*.swift; this is how the row joins the session)

    // Up from the first row reaches it. Tab never lands on it, so a session without Up is exactly as before.
    private func up() {
        if loaded, !search.onRow, sel == 0 || items.isEmpty, search.query.isEmpty, panel.switcher?.searchRow != nil { enterSearchRow(); return }
        move(-1)
    }

    // / or Space, from any row: straight into the field, modifier held or not.
    private func openSearch() {
        if loaded, !shown { showPanel() }
        guard panel.switcher?.searchRow != nil else { return }
        if !search.onRow { enterSearchRow() }
        startTyping()
    }

    private func enterSearchRow() {
        if !search.typing {
            pinnedBeforeSearch = pinned.isSet
            pinned.set(true)
            panel.switcher?.searchRow?.state = .selected
        }
        search.onRow = true
        panel.select(-1)
    }

    private func leaveSearchRow() {
        search.onRow = false
        guard !search.typing else { return }
        pinned.set(pinnedBeforeSearch)
        panel.switcher?.searchRow?.state = .idle
    }

    private func clickSearchRow() {
        guard active, loaded, !search.typing else { return }
        if !search.onRow { enterSearchRow() }
        startTyping()
    }

    // The field takes the keyboard. From here keys pass through the tap, and the list stays until a pick or Esc.
    private func startTyping() {
        guard panel.switcher?.searchRow != nil else { return }
        pinned.set(true); session.set(true); searching.set(true)
        // The hand may still be on the modifier: until it comes up it means nothing to the field.
        dropModifier.set(CGEventSource.flagsState(.combinedSessionState).contains(modifier))
        search.begin(windows: searchableRows())
        panel.beginTyping(search)
        panel.switcher?.searchRow?.field?.onReveal = { [weak self] in self?.search.reveal() }
        panel.switcher?.searchRow?.field?.onCommand = { [weak self] code in self?.searchCommand(code) ?? false }
    }

    // Command+1 to 9, Command+W, Q, P and the letters in the field: the list's own keys, on the selected result. The
    // plain keys are the query.
    private func searchCommand(_ code: UInt16) -> Bool {
        let key = Int64(code)
        guard active, loaded, !search.onRow else { return false }
        if let n = Controller.numberKeys[key] {
            if items.indices.contains(n - 1) { sel = n - 1; steps += 1; finish(focus: true) }
            return true
        }
        guard let verb = Controller.verb(for: key, shift: false) else { return false }
        steps += 1
        perform(verb, key: key)
        return true
    }

    // Every window on every desktop as the list shows it, this desktop first.
    private func searchableRows() -> [WindowItem] {
        var out: [WindowItem] = []
        for i in pages.indices.sorted(by: { ($0 == currentPage ? 0 : 1, $0) < ($1 == currentPage ? 0 : 1, $1) }) {
            var rows = pages[i].items
            Children.arrange(&rows)
            for var r in rows {
                if i != currentPage, r.desktop == nil, !pages[i].title.isEmpty { r.desktop = pages[i].title }
                out.append(r)
            }
        }
        return out
    }

    private func showRows() {
        guard slide == nil else { return }        // the slide draws the page when it lands
        if search.typing { panel.updateTypingRows(items, selected: search.onRow ? -1 : sel, emptyText: search.emptyText, session: search) }
        else { panel.updateRows(items, selected: search.onRow ? -1 : sel, emptyText: search.emptyText) }
    }

    // Results take the place of the window rows, so every key and the drawing are the list's own.
    func showResults(_ rows: [WindowItem], keepSelection: Bool) {
        guard active else { return }
        items = rows
        search.onRow = false
        sel = keepSelection ? min(sel, max(0, rows.count - 1)) : 0
        showRows()
    }

    func showWindowList() {
        guard active else { return }
        sel = 0
        search.onRow = true
        rebuildItems()
        showRows()
    }

    func searchMove(_ delta: Int) {
        guard active else { return }
        steps += 1
        if delta < 0 { up() } else { move(1) }
    }

    func searchReturn(shift: Bool) {
        guard active, !search.onRow, !items.isEmpty else { return }
        steps += 1
        if shift { collapse() } else { activate() }
    }

    func searchCancel() { cancel() }

    // The keyboard tap is being taken down: no key can reach a session any more, so none stays open.
    func tapRemoved() {
        session.set(false)
        if active { reset() }
    }

    private func reset() {
        generation += 1
        if search.inUse { searching.set(false); search.end(); panel.endTyping() }
        active = false; session.set(false); pinned.set(false); loaded = false; shown = false; commitWhenLoaded = false
        pickOnRelease.set(false); dropModifier.set(false); searchWhenLoaded = false
        items = []; pages = []; steps = 0; previousElsewhere = nil; front = 0
        open = []; childCache = [:]; loading = []; noChildren = []; closing = []
        if dressed { Children.sessionEnded() }   // a quick flip asked no provider for anything
        dressed = false; labelled = false
        stopWatchingOutside()
        slide?.stop(); slide = nil; slideTurned = nil; swipe = Swipe()
        optionPoll?.invalidate(); optionPoll = nil
        if glanceRunning { GlanceEngine.shared.stop(); glanceRunning = false }
        panel.hide()
    }
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    autoreleasepool { Controller.shared.handle(type: type, event: event) }
}

// MARK: - App
