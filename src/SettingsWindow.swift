import AppKit
import Combine
import SwiftUI

// The Settings window, built like System Settings: a sidebar and one grouped Form per pane (SettingsPanes.swift),
// one SwiftUI tree hosted in an AppKit window. Everything reads and writes `Settings`; the switcher picks the
// values up on its next open.

// The panes, in sidebar order. The raw value is the number `show(tab:)` takes and QA's `settings <n>` uses. It is
// not the position: About stays 4 and new panes take new numbers, so existing callers keep working.
enum SettingsPane: Int, CaseIterable, Identifiable {
    case general = 0, keys = 5, list = 1, insideApps = 3, appearance = 2, glanceBar = 6, about = 4

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .keys: return "Keys"
        case .list: return "List"
        case .insideApps: return "Inside apps"
        case .appearance: return "Appearance"
        case .glanceBar: return "Glance bar"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .keys: return "keyboard.fill"
        case .list: return "list.bullet"
        case .insideApps: return "rectangle.stack.fill"
        case .appearance: return "paintbrush.fill"
        case .glanceBar: return "gauge.with.needle.fill"
        case .about: return "info"
        }
    }
    var tint: Color {
        switch self {
        case .general, .about: return .gray
        case .keys: return .indigo
        case .list: return .blue
        case .insideApps: return .orange
        case .appearance: return .pink
        case .glanceBar: return .teal
        }
    }
}

// What SwiftUI watches: the selected pane, and every change to `Settings`.
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    @Published var pane: SettingsPane = .general
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// Swap is a menu bar app with no main menu, so nothing else answers Command + W.
private final class SettingsNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()
    static let repo = "https://github.com/DavidMolina001/swap"
    static let sidebarWidth: CGFloat = 200
    static let detailSize = NSSize(width: 560, height: 640)

    private let model = SettingsModel.shared
    private var titleWatch: AnyCancellable?

    private init() {
        let size = NSSize(width: Self.sidebarWidth + Self.detailSize.width, height: Self.detailSize.height)
        let host = NSHostingController(rootView: SettingsRoot(model: model))
        host.sizingOptions = []   // the window has a fixed size; panes never resize it
        host.view.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        host.view.heightAnchor.constraint(equalToConstant: size.height).isActive = true

        let window = SettingsNSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.contentViewController = host
        window.setContentSize(size)   // the hosting controller reports no size of its own
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "SwapSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        titleWatch = model.$pane.sink { [weak window] in window?.title = $0.title }   // follows the pane, as in System Settings
    }
    required init?(coder: NSCoder) { fatalError() }

    // Numbers: General 0, List 1, Appearance 2, Inside apps 3, About 4, Keys 5, Glance bar 6.
    func show(tab: Int = 0) {
        model.pane = SettingsPane(rawValue: tab) ?? .general
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    // The tracking separator keeps the toolbar's title over the detail side, clear of the sidebar.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
}

// MARK: - sidebar and detail

// One SwiftUI tree for both columns, so Tab moves from the sidebar into the form.
struct SettingsRoot: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(model: model)
        } detail: {
            SettingsDetail(model: model)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        List(selection: Binding(get: { Optional(model.pane) }, set: { if let p = $0 { model.pane = p } })) {
            ForEach(SettingsPane.allCases) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SymbolTile(symbol: pane.symbol, tint: pane.tint)
                }
                .tag(pane)
            }
        }
        .listStyle(.sidebar)
        .fixedSidebar()
        .navigationSplitViewColumnWidth(min: SettingsWindowController.sidebarWidth, ideal: SettingsWindowController.sidebarWidth,
                                        max: SettingsWindowController.sidebarWidth)
    }
}

private extension View {
    // The window has no room to spare and nothing to gain from a hidden sidebar, so no collapse button.
    @ViewBuilder func fixedSidebar() -> some View {
        if #available(macOS 14, *) { toolbar(removing: .sidebarToggle) } else { self }
    }
}

// The small coloured square System Settings puts in front of a sidebar row.
struct SymbolTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsDetail: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        switch model.pane {
        case .general: GeneralPane()
        case .keys: KeysPane()
        case .list: ListPane()
        case .insideApps: InsideAppsPane()
        case .appearance: AppearancePane()
        case .glanceBar: GlanceBarPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - "Swap is ready", shown once after the first Accessibility grant

enum ReadyPanel {
    static func showIfFirstTime() {
        guard !Settings.readyShown else { return }
        Settings.readyShown = true
        Settings.glanceInvited = true
        if SMAppServiceHelper.canRegister { Settings.launchAtLogin = true }
        let alert = NSAlert()
        alert.messageText = "Swap is ready"
        alert.informativeText = "Hold \(Settings.shortcut.name), tap Tab. Keep holding to see the list, release on the window you want."
            + "\n\nWhile the list is open: Return switches. W closes the window, Q quits its app. N, F, T, K, G, L, O and R are that app's own Command + letter. / or Space jumps to search."
            + "\n\nTo reach tabs and chats, and pin them with P, switch on Show tabs and chats inside apps in Settings."
            + "\n\nSwap now starts at login; change that in Settings."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Settings")
        NSApp.activate(ignoringOtherApps: true)
        let w = alert.window
        w.level = .floating
        // Non-blocking: run the alert as a sheet-less window so the keyboard tap keeps working meanwhile.
        alert.beginSheetModal(for: hostWindow) { response in
            hostWindow.orderOut(nil)
            if response == .alertSecondButtonReturn { SettingsWindowController.shared.show() }
        }
    }

    private static let hostWindow: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.alphaValue = 0; w.ignoresMouseEvents = true
        w.center(); w.orderFrontRegardless()
        return w
    }()
}

enum SMAppServiceHelper {
    // A copy run from a temp folder or the build folder should not be registered as a login item.
    static var canRegister: Bool { Bundle.main.bundlePath.hasPrefix("/Applications") }
}
