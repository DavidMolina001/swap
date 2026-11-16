import AppKit
import ServiceManagement

// Every user choice, stored in UserDefaults under the keys listed in the README ("For developers").
// Reading is cheap (UserDefaults caches); writing posts `Settings.changed` so the menu and panel follow.
enum Settings {
    static let changed = Notification.Name("swap.settings.changed")
    private static let d = UserDefaults.standard

    enum Shortcut: String, CaseIterable { case optionTab, commandTab, controlTab
        var modifier: CGEventFlags { switch self { case .optionTab: return .maskAlternate; case .commandTab: return .maskCommand; case .controlTab: return .maskControl } }
        var name: String { switch self { case .optionTab: return "Option"; case .commandTab: return "Command"; case .controlTab: return "Control" } }
        var symbol: String { switch self { case .optionTab: return "⌥"; case .commandTab: return "⌘"; case .controlTab: return "⌃" } }
    }
    enum Appearance: String, CaseIterable { case system, light, dark }
    enum Screen: String, CaseIterable { case active, mouse }
    enum Desktops: String, CaseIterable { case pages, flat }
    enum Dots: String, CaseIterable { case all, compact }
    enum Width: String, CaseIterable { case fixed, fit }

    static var shortcut: Shortcut { get { Shortcut(rawValue: d.string(forKey: "shortcut") ?? "") ?? .optionTab } set { set("shortcut", newValue.rawValue) } }
    static var quickFlip: Bool { get { bool("quickFlip", true) } set { set("quickFlip", newValue) } }
    static var numberKeys: Bool { get { bool("numberKeys", true) } set { set("numberKeys", newValue) } }
    static var actionKeys: Bool { get { bool("actionKeys", true) } set { set("actionKeys", newValue) } }   // W closes, Q quits
    static var showOnScreen: Screen { get { Screen(rawValue: d.string(forKey: "showOnScreen") ?? "") ?? .active } set { set("showOnScreen", newValue.rawValue) } }
    static var desktops: Desktops { get { Desktops(rawValue: d.string(forKey: "desktops") ?? "") ?? .pages } set { set("desktops", newValue.rawValue) } }
    static var showMinimised: Bool { get { bool("showMinimised", true) } set { set("showMinimised", newValue) } }
    static var showHidden: Bool { get { bool("showHidden", true) } set { set("showHidden", newValue) } }
    static var appearance: Appearance { get { Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system } set { set("appearance", newValue.rawValue) } }
    // Colour theme: an id from tokens.json "themes" (Full Stripe by default; System is the macOS accent colour look).
    static var theme: String { get { Tokens.Themes.named(d.string(forKey: "theme") ?? "").id } set { set("theme", newValue) } }
    static var palette: Palette { Tokens.Themes.named(theme) }
    static var hiddenApps: [String] { get { d.stringArray(forKey: "hiddenApps") ?? [] } set { set("hiddenApps", newValue) } }
    static var hideUntitled: Bool { get { bool("hideUntitled", false) } set { set("hideUntitled", newValue) } }
    static var keepOpen: Bool { get { bool("keepOpen", false) } set { set("keepOpen", newValue) } }
    static var hideEmptyDesktops: Bool { get { bool("hideEmptyDesktops", false) } set { set("hideEmptyDesktops", newValue) } }
    static var dots: Dots { get { Dots(rawValue: d.string(forKey: "pageDots") ?? "") ?? .all } set { set("pageDots", newValue.rawValue) } }
    static var panelWidth: Width { get { Width(rawValue: d.string(forKey: "panelWidth") ?? "") ?? .fixed } set { set("panelWidth", newValue.rawValue) } }
    static var showAppName: Bool { get { bool("showAppName", true) } set { set("showAppName", newValue) } }

    // Drill-in (Children.swift): Return expands a browser window into its tabs, a Slack row into its chats.
    static var drillIn: Bool { get { bool("drillIn", false) } set { set("drillIn", newValue) } }
    // Pinned tabs and chats, listed first under their row. Keyed by Slack workspace name or browser bundle id.
    static var pins: [String: [String]] { get { d.dictionary(forKey: "pins") as? [String: [String]] ?? [:] } set { set("pins", newValue) } }
    static var whatsappArchive: Bool { get { bool("whatsappArchive", false) } set { set("whatsappArchive", newValue) } }   // an Archived row above the chats
    static var slackWorkspaces: Bool { get { bool("slackWorkspaces", true) } set { set("slackWorkspaces", newValue) } }   // one row per workspace
    static var slackHidden: [String] { get { d.stringArray(forKey: "slackHidden") ?? [] } set { set("slackHidden", newValue) } }
    static var childOrder: ChildOrder { get { d.string(forKey: "childOrder") == "recent" ? .recent : .natural }
                                        set { set("childOrder", newValue == .recent ? "recent" : "natural") } }

    // The search row above the first item (Search*.swift). Up from the first row reaches it.
    static var searchRow: Bool { get { bool("searchRow", true) } set { set("searchRow", newValue) } }

    // Off by default since 0.6.0: the open fade and zoom made David dizzy. On = fade in on the first open only.
    static var animations: Bool { get { bool("animations", false) } set { set("animations", newValue) } }

    // Glance bar (GlanceModel.swift). Off by default; widgets in the user's order, left to right.
    enum QuotaCell: String, CaseIterable { case tightest, pill }
    static var glanceBar: Bool { get { bool("glanceBar", false) } set { set("glanceBar", newValue) } }
    static var glanceDensity: Glance.Density { get { Glance.Density(rawValue: d.string(forKey: "glanceDensity") ?? "") ?? .regular } set { set("glanceDensity", newValue.rawValue) } }
    static var glanceWidgets: [String] { get { d.stringArray(forKey: "glanceWidgets") ?? ["cpu", "memory", "gpu", "quota", "timer"] } set { set("glanceWidgets", newValue) } }
    static var glanceWidgetList: [Glance.Widget] { glanceWidgets.compactMap { Glance.Widget(rawValue: $0) }.filter { $0.available } }
    static var quotaCell: QuotaCell { get { QuotaCell(rawValue: d.string(forKey: "quotaCell") ?? "") ?? .tightest } set { set("quotaCell", newValue.rawValue) } }
    static var timerAlert: Bool { get { bool("timerAlert", true) } set { set("timerAlert", newValue) } }       // sound + menu bar flash at zero
    static var timerNotify: Bool { get { bool("timerNotify", false) } set { set("timerNotify", newValue) } }   // asks for Notifications only when switched on
    static var glanceInvited: Bool { get { bool("glanceInvited", false) } set { set("glanceInvited", newValue) } }  // the welcome invitation was shown
    static var hintShows: Int { get { d.integer(forKey: "hintShows") } set { d.set(newValue, forKey: "hintShows") } }
    static var readyShown: Bool { get { bool("readyShown", false) } set { set("readyShown", newValue) } }

    // Swap itself (Settings > Appearance): a Dock icon whose click opens Swap's menu, and Swap's own row at the foot of
    // the list, which opens the same menu. Both on by default; off is the menu-bar-only Swap of 0.8.
    static var showInDock: Bool { get { bool("showInDock", true) } set { set("showInDock", newValue) } }
    static var showSelfInList: Bool { get { bool("showSelfInList", true) } set { set("showSelfInList", newValue) } }

    // Not stored by Swap: macOS keeps the login item itself.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSSound.beep() }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    // The panel's appearance right now: the user's choice, or the system's.
    static var isDark: Bool {
        if let forced = ProcessInfo.processInfo.environment["SWAP_APPEARANCE"] { return forced == "dark" }   // QA renders
        switch appearance {
        case .dark: return true
        case .light: return false
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
    private static func set(_ key: String, _ value: Any) {
        d.set(value, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
