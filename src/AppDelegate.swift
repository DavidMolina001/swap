// Start-up, permissions, the menu bar item and the Dock icon.
import AppKit
import ApplicationServices
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hintItem: NSMenuItem!
    private var trustItem: NSMenuItem!
    private var trustSeparator: NSMenuItem!
    private var appearanceItems: [Settings.Appearance: NSMenuItem] = [:]
    private var dotsItems: [Settings.Dots: NSMenuItem] = [:]
    private var widthItems: [Settings.Width: NSMenuItem] = [:]
    private var hideEmptyItem: NSMenuItem!
    private var glanceBarItem: NSMenuItem!
    private var densityItems: [Glance.Density: NSMenuItem] = [:]
    private var widgetsMenu: NSMenu!
    private var animationsItem: NSMenuItem!
    private var dockItem: NSMenuItem!
    private var selfRowItem: NSMenuItem!
    private var timerItem: NSMenuItem!
    private var timerStopItem: NSMenuItem!
    private var poll: Timer?
    private var tapThread: Thread?
    private var tapLoop: CFRunLoop?
    private var watchdog: Timer?
    private var trustChecksOut = 0              // answers still outstanding: the trust check itself can stall
    private let tapAnswered = AtomicFlag()
    // Menu bar icon flash when a timer reaches zero.
    private var normalIcon: NSImage?
    private var flashTimer: Timer?
    private var flashUntil: Date?
    private var flashOn = false

    func applicationDidFinishLaunching(_ note: Notification) {
        // No Accessibility call waits more than a quarter second on an app, whatever element it is made on.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        if let front = NSWorkspace.shared.frontmostApplication { Windows.noteActive(front.processIdentifier) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                Windows.noteActive(app.processIdentifier)
            }
        }
        buildMenu()
        buildMainMenu()
        applyDockIcon()   // after launch, so becoming a Dock app never brings Swap to the front
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMenu()
            self?.applyDockIcon()
        }
        NotificationCenter.default.addObserver(forName: GlanceTimer.changed, object: nil, queue: .main) { [weak self] _ in self?.refreshTimerMenu() }
        NotificationCenter.default.addObserver(forName: GlanceTimer.fired, object: nil, queue: .main) { [weak self] _ in self?.timerFired() }
        startTapWhenTrusted()
        // Installers can switch on "Start at login" without opening the menu.
        if CommandLine.arguments.contains("--enable-login-item"), SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        #if SELFTEST
        Settings.readyShown = true   // QA copies never show the welcome
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), CommandLine.arguments.count > i + 1 {
            Children.sources.insert(TestChildren.self, at: 0)   // fake children for TextEdit windows (SelfTest.swift)
            SelfTest.start(log: CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--hook"), CommandLine.arguments.count > i + 1 {
            Hook.start(CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--showtest"), CommandLine.arguments.count > i + 1 {
            SelfTest.showOnly(log: CommandLine.arguments[i + 1])
        }
        #endif
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        normalIcon = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Swap")
        if let button = statusItem.button { button.image = normalIcon }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "Swap \(appVersion)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        trustItem = NSMenuItem(title: "Accessibility needed. Click to open settings", action: #selector(openAccessibility), keyEquivalent: "")
        trustItem.target = self
        menu.addItem(trustItem)
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show window list", action: #selector(showList), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        // Timer: presets, a custom length, Stop. The title shows the time left while one runs.
        timerItem = NSMenuItem(title: "Timer", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        timerMenu.autoenablesItems = false
        for minutes in GlanceTimer.presets {
            let i = NSMenuItem(title: "\(minutes) minutes", action: #selector(startTimer(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = minutes
            timerMenu.addItem(i)
        }
        let custom = NSMenuItem(title: "Custom…", action: #selector(customTimer), keyEquivalent: "")
        custom.target = self
        timerMenu.addItem(custom)
        timerMenu.addItem(.separator())
        timerStopItem = NSMenuItem(title: "Stop", action: #selector(stopTimer), keyEquivalent: "")
        timerStopItem.target = self
        timerMenu.addItem(timerStopItem)
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Personalisation: the quick looks, also in Settings > List.
        let personal = NSMenuItem(title: "Personalisation", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let appearance = NSMenu()
        appearance.autoenablesItems = false
        for (a, name) in [(Settings.Appearance.system, "Match system"), (.light, "Light"), (.dark, "Dark")] {
            let i = NSMenuItem(title: name, action: #selector(pickAppearance(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = a.rawValue
            appearance.addItem(i); appearanceItems[a] = i
        }
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        sub.addItem(appearanceItem)
        let dots = NSMenu()
        dots.autoenablesItems = false
        for (d, name) in [(Settings.Dots.all, "One dot per desktop"), (.compact, "Compact (5 at most)")] {
            let i = NSMenuItem(title: name, action: #selector(pickDots(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = d.rawValue
            dots.addItem(i); dotsItems[d] = i
        }
        let dotsItem = NSMenuItem(title: "Page dots", action: nil, keyEquivalent: "")
        dotsItem.submenu = dots
        sub.addItem(dotsItem)
        let width = NSMenu()
        width.autoenablesItems = false
        for (wd, name) in [(Settings.Width.fixed, "Same width every time"), (.fit, "Fit the longest name")] {
            let i = NSMenuItem(title: name, action: #selector(pickWidth(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = wd.rawValue
            width.addItem(i); widthItems[wd] = i
        }
        let widthItem = NSMenuItem(title: "Panel width", action: nil, keyEquivalent: "")
        widthItem.submenu = width
        sub.addItem(widthItem)
        hideEmptyItem = NSMenuItem(title: "Hide desktops with no windows", action: #selector(toggleHideEmpty), keyEquivalent: "")
        hideEmptyItem.target = self
        sub.addItem(hideEmptyItem)

        // Glance bar: on/off, density, which widgets. Same choices as Settings > Personalisation.
        sub.addItem(.separator())
        glanceBarItem = NSMenuItem(title: "Show glance bar", action: #selector(toggleGlanceBar), keyEquivalent: "")
        glanceBarItem.target = self
        sub.addItem(glanceBarItem)
        let density = NSMenu()
        density.autoenablesItems = false
        for dn in [Glance.Density.compact, .regular, .detailed] {
            let i = NSMenuItem(title: dn.name, action: #selector(pickDensity(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = dn.rawValue
            density.addItem(i); densityItems[dn] = i
        }
        let densityItem = NSMenuItem(title: "Density", action: nil, keyEquivalent: "")
        densityItem.submenu = density
        sub.addItem(densityItem)
        widgetsMenu = NSMenu()
        widgetsMenu.autoenablesItems = false
        let widgetsItem = NSMenuItem(title: "Widgets", action: nil, keyEquivalent: "")
        widgetsItem.submenu = widgetsMenu
        sub.addItem(widgetsItem)
        sub.addItem(.separator())
        animationsItem = NSMenuItem(title: "Animations", action: #selector(toggleAnimations), keyEquivalent: "")
        animationsItem.target = self
        sub.addItem(animationsItem)
        // Swap itself: the same two switches as Settings > Appearance > Swap itself.
        sub.addItem(.separator())
        dockItem = NSMenuItem(title: "Show in the Dock", action: #selector(toggleDock), keyEquivalent: "")
        dockItem.target = self
        sub.addItem(dockItem)
        selfRowItem = NSMenuItem(title: "Show Swap at the bottom of the list", action: #selector(toggleSelfRow), keyEquivalent: "")
        selfRowItem.target = self
        sub.addItem(selfRowItem)
        personal.submenu = sub
        menu.addItem(personal)

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Swap", action: #selector(openAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit Swap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
        refreshMenu()
    }

    fileprivate func refreshMenu() {
        let trusted = AXIsProcessTrusted()
        hintItem.title = "Hold \(Settings.shortcut.name), tap Tab"
        trustItem.isHidden = trusted
        for (a, i) in appearanceItems { i.state = Settings.appearance == a ? .on : .off }
        for (d, i) in dotsItems { i.state = Settings.dots == d ? .on : .off }
        for (wd, i) in widthItems { i.state = Settings.panelWidth == wd ? .on : .off }
        hideEmptyItem.state = Settings.hideEmptyDesktops ? .on : .off
        glanceBarItem.state = Settings.glanceBar ? .on : .off
        for (dn, i) in densityItems { i.state = Settings.glanceDensity == dn ? .on : .off }
        animationsItem.state = Settings.animations ? .on : .off
        dockItem.state = Settings.showInDock ? .on : .off
        selfRowItem.state = Settings.showSelfInList ? .on : .off
        rebuildWidgetsMenu()
        refreshTimerMenu()
    }

    // One check item per widget: the user's own order first (that is the bar's order), then the rest.
    private func rebuildWidgetsMenu() {
        widgetsMenu.removeAllItems()
        let chosen = Settings.glanceWidgetList
        let others = Glance.Widget.allCases.filter { $0.available && !chosen.contains($0) }
        for w in chosen + others {
            let i = NSMenuItem(title: w.title, action: #selector(toggleWidget(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = w.rawValue
            i.state = chosen.contains(w) ? .on : .off
            widgetsMenu.addItem(i)
        }
    }

    private func refreshTimerMenu() {
        guard timerItem != nil else { return }
        let t = GlanceTimer.shared
        if t.isRunning {
            let r = Int(t.remaining.rounded(.up))
            let text = r >= 3600 ? String(format: "%d:%02d:%02d", r / 3600, (r / 60) % 60, r % 60) : String(format: "%d:%02d", r / 60, r % 60)
            timerItem.title = "Timer · \(text)"
        } else {
            timerItem.title = "Timer"
        }
        timerStopItem.isEnabled = t.isRunning
    }

    @objc private func pickWidth(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let w = Settings.Width(rawValue: raw) { Settings.panelWidth = w }
    }
    @objc private func toggleGlanceBar() { Settings.glanceBar.toggle() }
    @objc private func toggleAnimations() { Settings.animations.toggle() }
    @objc private func toggleDock() { Settings.showInDock.toggle() }
    @objc private func toggleSelfRow() { Settings.showSelfInList.toggle() }
    @objc private func pickDensity(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let dn = Glance.Density(rawValue: raw) { Settings.glanceDensity = dn }
    }
    @objc private func toggleWidget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let w = Glance.Widget(rawValue: raw), w.available else { return }
        var list = Settings.glanceWidgets
        if let at = list.firstIndex(of: raw) {
            list.remove(at: at)
        } else {
            if w == .downloads, !GlanceConsent.askDownloads() { return }
            list.append(raw)
        }
        Settings.glanceWidgets = list
    }

    // MARK: Timer

    @objc private func startTimer(_ sender: NSMenuItem) {
        if let minutes = sender.representedObject as? Int { GlanceTimer.shared.start(minutes: Double(minutes)) }
    }
    @objc private func stopTimer() { GlanceTimer.shared.stop() }

    @objc private func customTimer() {
        let alert = NSAlert()
        alert.messageText = "Timer length"
        alert.informativeText = "Minutes, up to 24 hours."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.placeholderString = "25"
        field.alignment = .right
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = NSNumber(value: 0.1)
        formatter.maximum = NSNumber(value: 24 * 60)
        field.formatter = formatter
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let minutes = (field.formatter as? NumberFormatter)?.number(from: field.stringValue)?.doubleValue ?? Double(field.stringValue) ?? 0
        guard minutes > 0 else { NSSound.beep(); return }
        GlanceTimer.shared.start(minutes: min(minutes, 24 * 60))
    }

    // At zero: the system alert sound and ten seconds of a flashing menu bar icon; a notification if asked for.
    private func timerFired() {
        if Settings.timerAlert {
            if let sound = NSSound(named: "Glass") { sound.play() } else { NSSound.beep() }
            startFlash()
        }
        if Settings.timerNotify { postTimerNotification() }
    }

    private func startFlash() {
        flashTimer?.invalidate()
        flashUntil = Date().addingTimeInterval(10)
        flashOn = false
        let alt = NSImage(systemSymbolName: "timer.circle.fill", accessibilityDescription: "Timer done")
            ?? NSImage(systemSymbolName: "timer", accessibilityDescription: "Timer done")
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self, let button = self.statusItem.button else { t.invalidate(); return }
            if let until = self.flashUntil, Date() >= until {
                t.invalidate(); self.flashTimer = nil; self.flashUntil = nil; self.flashOn = false
                button.image = self.normalIcon
                return
            }
            self.flashOn.toggle()
            button.image = self.flashOn ? alt : self.normalIcon
        }
        RunLoop.main.add(flashTimer!, forMode: .common)   // keeps flashing while a menu is open
    }

    private func postTimerNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }   // UNUserNotificationCenter needs a bundle
        let centre = UNUserNotificationCenter.current()
        centre.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = Tokens.Copy.timerDone
            content.body = "Your Swap timer has reached zero."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "swap.timer.done", content: content, trigger: nil)
            centre.add(request)
        }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func showList() { Controller.shared.showFromMenu() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openAbout() { SettingsWindowController.shared.show(tab: 4) }
    @objc private func pickAppearance(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let a = Settings.Appearance(rawValue: raw) { Settings.appearance = a }
    }
    @objc private func pickDots(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = Settings.Dots(rawValue: raw) { Settings.dots = d }
    }
    @objc private func toggleHideEmpty() { Settings.hideEmptyDesktops.toggle() }

    // The keyboard tap only works once Accessibility is granted; ask, then keep checking.
    private func startTapWhenTrusted() {
        if installTap() { ReadyPanel.showIfFirstTime(); return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            if self?.installTap() == true { t.invalidate(); self?.refreshMenu(); ReadyPanel.showIfFirstTime() }
        }
    }

    private var recencyStarted = false

    private func installTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)   // again, now that Accessibility is on
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback, userInfo: nil) else { return false }
        Controller.shared.tap = tap
        // The tap gets a thread of its own: the main thread may be waiting on an app, the keyboard never does.
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            DispatchQueue.main.async { self?.tapLoop = loop }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "swap.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
        if !recencyStarted { recencyStarted = true; Recency.start(); WindowCache.start(); Children.start() }
        tapAnswered.set(true)
        trustChecksOut = 0
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkTap() }
        return true
    }

    // An active event tap with no permission behind it can hold up the whole Mac's input, and Accessibility can be
    // switched off at any time. So while the tap is live: every 5 s, off the main thread, is the permission still there,
    // is the tap on, and does its thread still answer? If not the tap comes down, and goes back up once it can.
    // Untested on a real revocation: that needs a change to the Mac's grants.
    private func checkTap() {
        trustChecksOut += 1
        if trustChecksOut > 2 { takeDownTap(); waitForTrust(); return }   // nothing has come back for 10 s
        DispatchQueue.global(qos: .utility).async {
            let trusted = AXIsProcessTrusted()
            DispatchQueue.main.async { [weak self] in self?.tapChecked(trusted: trusted) }
        }
    }

    private func tapChecked(trusted: Bool) {
        trustChecksOut = 0
        guard let tap = Controller.shared.tap else { return }
        guard trusted else { takeDownTap(); waitForTrust(); return }
        if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        if !CGEvent.tapIsEnabled(tap: tap) || !tapAnswered.isSet {
            takeDownTap()
            if !installTap() { waitForTrust() }
            return
        }
        guard let loop = tapLoop else { return }
        tapAnswered.set(false)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [tapAnswered] in tapAnswered.set(true) }
        CFRunLoopWakeUp(loop)
    }

    private func takeDownTap() {
        watchdog?.invalidate(); watchdog = nil
        guard let tap = Controller.shared.tap else { return }
        Controller.shared.tapRemoved()
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        Controller.shared.tap = nil
        if let tapLoop { CFRunLoopStop(tapLoop) }
        tapLoop = nil; tapThread = nil
        refreshMenu()
    }

    private func waitForTrust() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            if self?.installTap() == true { t.invalidate(); self?.refreshMenu() }
        }
    }

    #if SELFTEST
    func rebuildTapForTest() { takeDownTap(); _ = installTap() }
    #endif

    // MARK: Dock icon and the menu away from the menu bar

    // The menu bar item's menu, for SwapMenu.
    fileprivate var itemMenu: NSMenu? { statusItem?.menu }
    fileprivate func refreshForShow() { refreshMenu() }

    // A Dock icon while showInDock is on (a regular app), the menu bar only while it is off (an accessory app, as
    // Info.plist starts it). Applied at once whenever the setting changes. Becoming a Dock app does not bring Swap to
    // the front. Going back to the menu bar only can leave an open Settings window behind other apps, so it is brought
    // back when Swap was the app in front.
    private func applyDockIcon() {
        let want: NSApplication.ActivationPolicy = Settings.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != want else { return }
        let wasActive = NSApp.isActive
        guard NSApp.setActivationPolicy(want) else { return }
        guard want == .accessory, wasActive else { return }
        DispatchQueue.main.async {
            let open = NSApp.windows.filter { $0.isVisible && !($0 is SwitcherPanel) && $0.canBecomeKey }
            guard !open.isEmpty else { return }
            NSApp.activate(ignoringOtherApps: true)
            open.forEach { $0.makeKeyAndOrderFront(nil) }
        }
    }

    // The bar at the top of the screen while Swap is the app in front (a Dock click, Settings). Only the app menu,
    // nothing more. Its keys could reach it while the search field has the keyboard, so they do nothing while the list
    // is open: Command+Q in search must never quit Swap.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "Swap", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Swap")
        let about = NSMenuItem(title: "About Swap", action: #selector(mainMenuAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(mainMenuSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Swap", action: #selector(mainMenuQuit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }
    @objc private func mainMenuAbout() { if !Controller.shared.isActive { openAbout() } }
    @objc private func mainMenuSettings() { if !Controller.shared.isActive { openSettings() } }
    @objc private func mainMenuQuit() { if !Controller.shared.isActive { NSApp.terminate(nil) } }

    // A click on the Dock icon (or opening Swap again while it runs): Swap's menu, at the pointer.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SwapMenu.open(at: NSEvent.mouseLocation)
        return false
    }

    // Right-click on the Dock icon: the same items as the menu bar menu. The Dock adds its own Quit, so ours is left out.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        refreshMenu()
        guard let copy = statusItem?.menu?.copy() as? NSMenu else { return nil }
        copy.delegate = nil
        for item in copy.items where item.action == #selector(NSApplication.terminate(_:)) { copy.removeItem(item) }
        if copy.items.last?.isSeparatorItem == true, let last = copy.items.last { copy.removeItem(last) }
        return copy
    }
}

// Swap's menu away from the menu bar: from Swap's own row in the list and from the Dock icon. The same NSMenu as the
// menu bar item, so the two never differ. NSMenu.popUp runs a tracking loop until the menu closes, so it is started on a
// fresh turn of the main loop, never inside a key or click handler. It fails to plain: with no menu to show, Settings
// opens instead.
enum SwapMenu {
    private(set) static var opens = 0   // read by the self-test: how many times the menu was asked for
    #if SELFTEST
    static var dryRun = false            // the self-test counts the decision and shows nothing, so no tracking loop blocks it
    #endif

    // `point` is a place on screen (the pointer, for the Dock); nil puts the menu in the middle of `screen`.
    static func open(at point: NSPoint? = nil, on screen: NSScreen? = nil) {
        opens += 1
        #if SELFTEST
        if dryRun { return }
        #endif
        DispatchQueue.main.async {
            let app = NSApp.delegate as? AppDelegate
            guard let menu = app?.itemMenu else { SettingsWindowController.shared.show(); return }
            app?.refreshForShow()
            var at = point
            if at == nil, let area = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                let size = menu.size
                at = NSPoint(x: area.midX - size.width / 2, y: area.midY + size.height / 2)   // the top left corner
            }
            guard let at else { SettingsWindowController.shared.show(); return }
            menu.popUp(positioning: nil, at: at, in: nil)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenu() }
}

// MARK: - Offscreen picture of the panel (used by QA; shows nothing on screen)

// `glance` nil means: the bar's fixtures when the glance bar setting is on, no bar otherwise.
