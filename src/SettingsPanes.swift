import AppKit
import Combine
import SwiftUI
import UserNotifications

// The Settings panes. Each is a grouped Form, so controls, spacing, dark mode and contrast are Apple's.
// A setting that has no effect because of another one is dimmed, not hidden.

// MARK: - building blocks

// A binding onto one value of `Settings`.
private func setting<T>(_ get: @autoclosure @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
    Binding(get: get, set: set)
}

private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .toggleStyle(.switch)
    }
}

// A title and, where it earns its place, one line of help under it.
private struct RowLabel: View {
    let title: String
    var help: String? = nil

    var body: some View {
        Text(title)
        if let help { Text(help) }
    }
}

private struct SwitchRow: View {
    let title: String
    var help: String? = nil
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) { RowLabel(title: title, help: help) }
    }
}

private struct PickerRow<Value: Hashable>: View {
    let title: String
    var help: String? = nil
    let selection: Binding<Value>
    let options: [(Value, String)]

    var body: some View {
        Picker(selection: selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        } label: {
            RowLabel(title: title, help: help)
        }
    }
}

// The preview on top of a pane. It stays put while the form scrolls under it, so the row under the pointer
// always plays where you can see it.
private struct PreviewedForm<Content: View>: View {
    @ObservedObject var preview: PanelPreview
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            PreviewStageView(stage: preview.stage)
                .frame(height: 170)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            SettingsForm { content }
        }
        .onAppear { preview.appeared() }
        .onDisappear { preview.disappeared() }
    }
}

private extension View {
    // Pointing at a row plays that setting's demo once. Outside `.disabled`, so dimmed rows still play.
    func plays(_ name: String, on preview: PanelPreview) -> some View {
        contentShape(Rectangle()).onHover { preview.hover(name, $0) }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        SettingsForm {
            Section {
                PickerRow(title: "Open Swap with",
                          help: Settings.shortcut == .commandTab ? "Replaces the Mac app switcher while Swap runs." : nil,
                          selection: setting(Settings.shortcut) { Settings.shortcut = $0 },
                          options: Settings.Shortcut.allCases.map { ($0, "\($0.name) + Tab") })
                PickerRow(title: "Show the list on",
                          selection: setting(Settings.showOnScreen) { Settings.showOnScreen = $0 },
                          options: [(.active, "Screen with the active window"), (.mouse, "Screen with the mouse")])
                SwitchRow(title: "Start Swap at login",
                          help: "Swap can only learn the windows on your other desktops while it runs, so leave this on.",
                          isOn: setting(Settings.launchAtLogin) { Settings.launchAtLogin = $0 })
            }
            Section {
                AccessibilityRow()
                PermissionRow(title: "Browser tabs", help: "Automation. macOS asks once per browser, for tabs Accessibility cannot reach.",
                              pane: "com.apple.preference.security?Privacy_Automation")
                PermissionRow(title: "File search", help: "Desktop, Documents and Downloads. macOS asks when you first search files.",
                              pane: "com.apple.preference.security?Privacy_FilesAndFolders")
                PermissionRow(title: "Timer notifications", help: "Only if you switch them on in Glance bar.",
                              pane: "com.apple.Notifications-Settings.extension")
            } header: {
                Text("Permissions")
            } footer: {
                Text("Only Accessibility is required. The others are asked for by macOS the first time a feature needs them. Say no and that feature does without.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let help: String
    let pane: String

    var body: some View {
        LabeledContent {
            Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:" + pane)!) }
                .controlSize(.small)
        } label: {
            RowLabel(title: title, help: help)
        }
    }
}

private struct AccessibilityRow: View {
    @State private var granted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()   // macOS does not announce the grant

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                Label(granted ? "On" : "Off", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(granted ? .green : .red)
                    .labelStyle(.titleAndIcon)
                if !granted {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        } label: {
            RowLabel(title: "Accessibility", help: "Needed to list windows and read the shortcut.")
        }
        .onReceive(poll) { _ in granted = AXIsProcessTrusted() }
    }
}

// MARK: - Keys

struct KeysPane: View {
    @ObservedObject private var model = SettingsModel.shared

    var body: some View {
        let hold = Settings.shortcut.name
        SettingsForm {
            Section("Behaviour") {
                SwitchRow(title: "Quick flip",
                          help: Settings.keepOpen ? "Needs Keep the list open to be off." : "A quick press flips to the previous window, no list.",
                          isOn: setting(Settings.quickFlip) { Settings.quickFlip = $0 })
                    .disabled(Settings.keepOpen)
                SwitchRow(title: "Number keys", help: "While the list is open, 1 to 9 pick a row.",
                          isOn: setting(Settings.numberKeys) { Settings.numberKeys = $0 })
                SwitchRow(title: "Letter keys", help: "W closes, Q quits, P pins. N, F, T, K, G, L, O and R are the app's own Command + letter.",
                          isOn: setting(Settings.actionKeys) { Settings.actionKeys = $0 })
                SwitchRow(title: "Keep the list open until I choose", help: "Releasing \(hold) does nothing. Return, a number or a click picks.",
                          isOn: setting(Settings.keepOpen) { Settings.keepOpen = $0 })
            }
            Section("All keys") {
                KeyRow("Open the list, next window", "\(hold) + Tab")
                KeyRow("Previous window", "\(hold) + Shift + Tab")
                KeyRow("Move up and down the list", "Up, Down")
                KeyRow("Next or previous desktop", "Left, Right, or swipe with two fingers")
                KeyRow("Switch to the selected window", Settings.keepOpen ? "Return, or click a row" : "Release \(hold), Return, or click a row")
                KeyRow("Jump to a row", "1 to 9", on: Settings.numberKeys)
                KeyRow("Close the selected window or tab", "W", on: Settings.actionKeys)
                KeyRow("Quit its app", "Q", on: Settings.actionKeys)
                KeyRow("The app's own Command + letter", "N, F, T, K, G, L, O, R", on: Settings.actionKeys)
                KeyRow("Expand into tabs or chats", "Return", on: Settings.drillIn, off: insideOff)
                KeyRow("Fold back up", "Shift + Return", on: Settings.drillIn, off: insideOff)
                KeyRow("Pin a tab or chat", "P", on: Settings.drillIn && Settings.actionKeys, off: Settings.drillIn ? "Off" : insideOff)
                KeyRow("Search", "/ or Space, or Up from the first row", on: Settings.searchRow)
                KeyRow("In search: files only", "f then Space", on: Settings.searchRow)
                KeyRow("In search: show a file in Finder", "Command + Return", on: Settings.searchRow)
                KeyRow("Cancel", "Esc")
                if !Settings.drillIn {
                    Button("Go to Inside apps") { SettingsModel.shared.pane = .insideApps }
                }
            }
        }
    }

    private let insideOff = "Off: turn on in Inside apps"
}

private struct KeyRow: View {
    let action: String
    let keys: String
    let on: Bool
    let off: String

    init(_ action: String, _ keys: String, on: Bool = true, off: String = "Off") {
        self.action = action
        self.keys = keys
        self.on = on
        self.off = off
    }

    var body: some View {
        LabeledContent(action, value: on ? keys : off)
    }
}

// MARK: - List

struct ListPane: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var running: [NSRunningApplication] = []
    private let launches = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
    private let quits = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)

    var body: some View {
        SettingsForm {
            Section("Show in the list") {
                SwitchRow(title: "Minimised windows", help: "Shown with a Minimised tag, restored when picked.",
                          isOn: setting(Settings.showMinimised) { Settings.showMinimised = $0 })
                SwitchRow(title: "Windows of hidden apps", help: "Apps you hid with Command + H.",
                          isOn: setting(Settings.showHidden) { Settings.showHidden = $0 })
                SwitchRow(title: "Windows with no title", help: "Palettes and helper windows that have no name.",
                          isOn: setting(!Settings.hideUntitled) { Settings.hideUntitled = !$0 })
                SwitchRow(title: "Search row", help: "Above the first row. Press / or Space to jump to it.",
                          isOn: setting(Settings.searchRow) { Settings.searchRow = $0 })
            }
            Section {
                ForEach(Settings.hiddenApps, id: \.self) { HiddenAppRow(bundleID: $0) }
                LabeledContent(Settings.hiddenApps.isEmpty ? "No apps left out" : "Leave out another") {
                    Menu("Add app") {
                        ForEach(addable, id: \.processIdentifier) { app in
                            Button {
                                Settings.hiddenApps = Settings.hiddenApps + [app.bundleIdentifier!]
                            } label: {
                                Label { Text(app.localizedName ?? app.bundleIdentifier!) } icon: { Image(nsImage: menuIcon(app.icon)) }
                            }
                        }
                    }
                    .disabled(addable.isEmpty)
                    .fixedSize()
                }
            } header: {
                Text("Leave these apps out")
            } footer: {
                Text("Add app lists the apps running now.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(launches) { _ in refresh() }
        .onReceive(quits) { _ in refresh() }
    }

    private var addable: [NSRunningApplication] {
        let hidden = Set(Settings.hiddenApps)
        return running.filter { !hidden.contains($0.bundleIdentifier ?? "") }
    }

    private func refresh() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0 != NSRunningApplication.current }   // Swap itself has a Dock icon now
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func menuIcon(_ image: NSImage?) -> NSImage {
        let copy = (image?.copy() as? NSImage) ?? NSImage()
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

private struct HiddenAppRow: View {
    let bundleID: String

    private var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    private var name: String { url.map(appName) ?? bundleID }

    var body: some View {
        LabeledContent {
            Button {
                Settings.hiddenApps = Settings.hiddenApps.filter { $0 != bundleID }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove \(name)")
        } label: {
            Label {
                Text(name)
            } icon: {
                if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20) }
                else { Image(systemName: "app") }
            }
        }
    }
}

private func appName(_ url: URL) -> String {
    FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}

// MARK: - Inside apps

struct InsideAppsPane: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var refresh = 0   // a provider's rows can change while Settings is in the background
    private let activated = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)

    var body: some View {
        SettingsForm {
            Section {
                SwitchRow(title: "Show tabs and chats inside apps",
                          help: "Off: Return switches to the window. On: a chevron marks browser, Slack and WhatsApp rows, Return lists what is inside them, and P pins.",
                          isOn: setting(Settings.drillIn) { Settings.drillIn = $0 })
                PickerRow(title: "Order of tabs and chats",
                          help: Settings.drillIn ? "Most recent first puts what you used last at the top." : needsInsideApps,
                          selection: setting(Settings.childOrder) { Settings.childOrder = $0 },
                          options: [(.natural, "As the app shows them"), (.recent, "Most recent first")])
                    .disabled(!Settings.drillIn)
            }
            ForEach(Children.sources.compactMap { ($0 as? ProviderSettings.Type)?.settingsSection }, id: \.title) { section in
                Section {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in ProviderRowView(row: row) }
                } header: {
                    Text(section.title)
                } footer: {
                    if let footer = section.footer {
                        Text(footer).font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
            PinsSection()
        }
        .id(refresh)
        .onReceive(activated) { _ in refresh += 1 }
    }
}

private struct ProviderRowView: View {
    let row: ProviderRow

    var body: some View {
        switch row {
        case let .toggle(title, help, isOn, enabled):
            SwitchRow(title: title, help: help, isOn: isOn).disabled(!enabled)
        case let .heading(title):
            Text(title).font(.footnote).foregroundColor(.secondary)
        case let .note(title, value):
            LabeledContent(title, value: value)
        case let .action(title, help, run):
            LabeledContent {
                Button(title, action: run)
            } label: {
                RowLabel(title: title, help: help)
            }
        }
    }
}

// What is pinned (Settings.pins), one row per app or workspace, by count: a pin is an id, not a name to show.
// Keyed by workspace name or browser bundle id.
private struct PinsSection: View {
    @ObservedObject private var model = SettingsModel.shared
    @State private var confirming = false

    var body: some View {
        let pins = Settings.pins
        Section {
            if pins.isEmpty {
                Text("Nothing pinned").foregroundColor(.secondary)
            }
            ForEach(pins.keys.sorted(), id: \.self) { group in
                LabeledContent(groupName(group)) {
                    HStack(spacing: 8) {
                        Text("\(pins[group]?.count ?? 0) pinned").foregroundColor(.secondary)
                        Button {
                            var left = Settings.pins
                            left[group] = nil
                            Settings.pins = left
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear these pins")
                        .accessibilityLabel("Clear pins for \(groupName(group))")
                    }
                }
            }
            if !pins.isEmpty {
                Button("Clear all pins") { confirming = true }
                    .confirmationDialog("Clear every pin?", isPresented: $confirming) {
                        Button("Clear all pins", role: .destructive) { Settings.pins = [:] }
                    }
            }
        } header: {
            Text("Pinned")
        } footer: {
            Text("P pins the selected tab or chat, so it is listed first under its row. Needs Show tabs and chats inside apps.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private func groupName(_ group: String) -> String {
        guard group.contains(".") else { return group }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: group).map(appName) ?? group
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject private var model = SettingsModel.shared
    @StateObject private var preview = PanelPreview()

    var body: some View {
        PreviewedForm(preview: preview) {
            Section("List") {
                PickerRow(title: "Appearance",
                          selection: setting(Settings.appearance, preview.mark("appearance") { Settings.appearance = $0 }),
                          options: [(.system, "Match system"), (.light, "Light"), (.dark, "Dark")])
                    .plays("appearance", on: preview)
                PickerRow(title: "List width", help: "At the same width, long names are shortened.",
                          selection: setting(Settings.panelWidth, preview.mark("width") { Settings.panelWidth = $0 }),
                          options: [(.fixed, "Same every time"), (.fit, "Fit the longest name")])
                    .plays("width", on: preview)
                SwitchRow(title: "App name on the right",
                          isOn: setting(Settings.showAppName, preview.mark("appName") { Settings.showAppName = $0 }))
                    .plays("appName", on: preview)
                SwitchRow(title: "Animations", help: "Fade in on the first open. Desktop swipes always follow your fingers, unless Reduce Motion is on.",
                          isOn: setting(Settings.animations, preview.mark("animations") { Settings.animations = $0 }))
                    .plays("animations", on: preview)
            }
            Section("Desktops") {
                PickerRow(title: "Show desktops as", help: "Swipe or press Left and Right to change page.",
                          selection: setting(Settings.desktops, preview.mark("desktops") { Settings.desktops = $0 }),
                          options: [(.pages, "One page per desktop"), (.flat, "All in one list")])
                    .plays("desktops", on: preview)
                PickerRow(title: "Page dots", help: "Compact shows at most 5, the current one in the middle.",
                          selection: setting(Settings.dots, preview.mark("dots") { Settings.dots = $0 }),
                          options: [(.all, "One per desktop"), (.compact, "Compact")])
                    .disabled(Settings.desktops == .flat)
                    .plays("dots", on: preview)
                SwitchRow(title: "Hide desktops with no windows", help: "The other desktops keep their real numbers.",
                          isOn: setting(Settings.hideEmptyDesktops, preview.mark("hideEmpty") { Settings.hideEmptyDesktops = $0 }))
                    .disabled(Settings.desktops == .flat)
                    .plays("hideEmpty", on: preview)
            }
            Section("Swap itself") {
                SwitchRow(title: "Show in the Dock", help: "Click the Dock icon to open Swap's menu. Off: Swap is in the menu bar only.",
                          isOn: setting(Settings.showInDock) { Settings.showInDock = $0 })
                SwitchRow(title: "Show Swap at the bottom of the list", help: "A last row for Swap. Pick it to open Swap's menu.",
                          isOn: setting(Settings.showSelfInList) { Settings.showSelfInList = $0 })
            }
        }
    }
}

// MARK: - Glance bar

struct GlanceBarPane: View {
    @ObservedObject private var model = SettingsModel.shared
    @StateObject private var preview = PanelPreview()
    @State private var timerText = GlanceBarPane.timerStatus()
    @State private var timerRunning = GlanceTimer.shared.isRunning
    private let timerTicks = NotificationCenter.default.publisher(for: GlanceTimer.changed)
    private static var askedNotifications = false

    var body: some View {
        PreviewedForm(preview: preview) {
            Section {
                SwitchRow(title: "Show glance bar", help: "Readings above the list, taken only while it is open. Nothing leaves the Mac.",
                          isOn: setting(Settings.glanceBar, preview.mark("show") { Settings.glanceBar = $0 }))
                    .plays("show", on: preview)
                PickerRow(title: "Density",
                          selection: setting(Settings.glanceDensity, preview.mark("density") { Settings.glanceDensity = $0 }),
                          options: Glance.Density.allCases.map { ($0, $0.name) })
                    .disabled(!Settings.glanceBar)
                    .plays("density", on: preview)
                PickerRow(title: "Quota widget text", help: "What the Quota widget shows when the Quota app is installed.",
                          selection: setting(Settings.quotaCell, preview.mark("quota") { Settings.quotaCell = $0 }),
                          options: [(.tightest, "Tightest limit"), (.pill, "Quota's menu bar text")])
                    .disabled(!Settings.glanceBar)
                    .plays("quota", on: preview)
            }
            Section {
                ForEach(orderedWidgets, id: \.self) { widget in
                    WidgetRow(widget: widget, preview: preview)
                        .disabled(!Settings.glanceBar)
                        .plays("widgets", on: preview)
                }
            } header: {
                Text("Widgets")
            } footer: {
                Text(GlanceBarPane.fitText())
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            Section("Timer") {
                LabeledContent {
                    HStack(spacing: 4) {
                        ForEach(GlanceTimer.presets, id: \.self) { minutes in
                            Button("\(minutes) min") { GlanceTimer.shared.start(minutes: Double(minutes)) }
                        }
                        Button("Stop") { GlanceTimer.shared.stop() }
                            .disabled(!timerRunning)
                    }
                    .controlSize(.small)
                } label: {
                    RowLabel(title: "Start a timer", help: timerText)
                }
                .plays("timer", on: preview)
                SwitchRow(title: "Sound and menu bar flash at zero",
                          isOn: setting(Settings.timerAlert, preview.mark("timer") { Settings.timerAlert = $0 }))
                    .plays("timer", on: preview)
                SwitchRow(title: "Also send a notification", help: "Asks for permission the first time.",
                          isOn: setting(Settings.timerNotify, preview.mark("timer") { on in
                              Settings.timerNotify = on
                              if on { GlanceBarPane.requestNotifications() }
                          }))
                    .plays("timer", on: preview)
            }
        }
        .onReceive(timerTicks) { _ in
            timerText = GlanceBarPane.timerStatus()
            timerRunning = GlanceTimer.shared.isRunning
        }
    }

    // The widgets that are on, in their order, then the rest.
    private var orderedWidgets: [Glance.Widget] {
        let on = Settings.glanceWidgetList
        return on + Glance.Widget.allCases.filter { !on.contains($0) && $0.available }
    }

    private static func timerStatus() -> String {
        let t = GlanceTimer.shared
        let reading = t.reading()
        if t.isRunning { return "\(reading.value) left \(reading.detail ?? "")" }
        return t.isDone ? Tokens.Copy.timerDone : "Not running"
    }

    // "x of y fit at your panel width", from the real bar layout at the user's panel width and density.
    private static func fitText() -> String {
        let list = Settings.glanceWidgetList
        guard !list.isEmpty else { return "No widgets on: the bar is not drawn." }
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = min(Tokens.Size.panelMaxWidth, area.width * Tokens.Size.panelWidthShare)
        let panel = floor(min(maxW, max(Tokens.Size.panelMinWidth, Tokens.Size.panelFixedWidth)))
        let shown = GlanceBarView.fitted(Glance.samples(list), width: panel - 2 * Tokens.Size.panelPad,
                                         density: Settings.glanceDensity, theme: Theme(screen: NSScreen.main, solid: true))
        var text = "\(shown.count) of \(list.count) fit at your panel width."
        let dropped = list.filter { w in !shown.contains { $0.widget == w } }
        if !dropped.isEmpty { text += " Not shown: " + dropped.map { $0.title }.joined(separator: ", ") + "." }
        return text + " Up to \(Glance.maxWidgets)."
    }

    private static func requestNotifications() {
        guard !askedNotifications, Bundle.main.bundleIdentifier != nil else { return }   // no bundle = no notification centre
        askedNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// One widget: on or off, and its place in the bar. The arrows keep the order reachable by keyboard and VoiceOver.
private struct WidgetRow: View {
    let widget: Glance.Widget
    let preview: PanelPreview
    @ObservedObject private var model = SettingsModel.shared

    private var isOn: Bool { Settings.glanceWidgetList.contains(widget) }
    private var place: Int { Settings.glanceWidgetList.firstIndex(of: widget) ?? 0 }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if isOn {
                    arrow("chevron.up", "Move \(widget.title) up", by: -1, enabled: place > 0)
                    arrow("chevron.down", "Move \(widget.title) down", by: 1, enabled: place < Settings.glanceWidgetList.count - 1)
                }
                Toggle(widget.title, isOn: setting(isOn) { set($0) })
                    .labelsHidden()
                    .disabled(!widget.available)
            }
        } label: {
            Label {
                RowLabel(title: widget.title, help: widget.available ? nil : "Next version")
            } icon: {
                SymbolTile(symbol: widget.symbol ?? "square.grid.3x3.fill", tint: Color(nsColor: widget.tint(Settings.isDark)))
            }
        }
    }

    private func arrow(_ symbol: String, _ label: String, by step: Int, enabled: Bool) -> some View {
        Button { move(by: step) } label: { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(label)
            .accessibilityLabel(label)
    }

    private func set(_ on: Bool) {
        var list = Settings.glanceWidgets.filter { $0 != widget.rawValue }
        if on {
            if widget == .downloads, !GlanceConsent.askDownloads(from: SettingsWindowController.shared.window) { return }
            list.append(widget.rawValue)
        }
        Settings.glanceWidgets = list
        preview.changed("widgets")
    }

    private func move(by step: Int) {
        var list = Settings.glanceWidgetList
        guard let i = list.firstIndex(of: widget), list.indices.contains(i + step) else { return }
        list.swapAt(i, i + step)
        Settings.glanceWidgets = list.map { $0.rawValue }
        preview.changed("widgets")
    }
}

// MARK: - About

struct AboutPane: View {
    private let repo = SettingsWindowController.repo

    var body: some View {
        SettingsForm {
            Section {
                VStack(spacing: 4) {
                    Image(nsImage: Bundle.main.url(forResource: "Swap", withExtension: "icns").flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("Swap").font(.title2.weight(.semibold))
                    Text("Version \(appVersion) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                        .foregroundColor(.secondary)
                    Text("Get to any window, tab, chat or file from the keyboard.\nNo screen recording, and nothing leaves your Mac.")
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            Section {
                LabeledContent("Updates") {
                    Button("See Releases on GitHub") { open(repo + "/releases/latest") }
                }
            }
            Section {
                LinkRow(title: "GitHub", url: repo)
                LinkRow(title: "Release notes", url: repo + "/releases")
                LinkRow(title: "Report a problem", url: repo + "/issues/new")
                LinkRow(title: "Sponsor", url: "https://github.com/sponsors/DavidMolina001")
            } footer: {
                Text("Open source, MIT licence. Made by David Molina.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func open(_ url: String) { NSWorkspace.shared.open(URL(string: url)!) }
}

private struct LinkRow: View {
    let title: String
    let url: String

    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title).foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.forward.square").foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
