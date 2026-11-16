// Finder always has a row, even with no windows open: picking it opens a new Finder window (Recents, on most Macs).
import AppKit

enum FinderProvider: AppProvider {
    static let bundleIDs: Set<String> = ["com.apple.finder"]
    static func children(of parent: ParentRef) -> [ChildItem] { [] }
    static func open(_ child: ChildItem, in parent: ParentRef) {}
    static var canExpand: Bool { false }

    static func addRows(to pages: [Windows.Page], current: Int) -> [Windows.Page] {
        #if SELFTEST
        if Scene.current != nil { return pages }
        #endif
        guard pages.indices.contains(current), let finder = Windows.candidateApps().first(where: { bundleIDs.contains($0.bundleIdentifier ?? "") }),
              !pages.contains(where: { $0.items.contains { $0.app?.bundleIdentifier == finder.bundleIdentifier } }) else { return pages }
        var out = pages
        let row = WindowItem(app: finder, window: nil, id: 0, title: "Finder", appName: "Finder", icon: finder.icon ?? NSImage(), minimized: false)
        out[current] = Windows.Page(title: pages[current].title, items: pages[current].items + [row])
        return out
    }

    static func openWithoutWindow(_ item: WindowItem) {
        if let app = item.app { AppCommand.send(Controller.newKey, to: app) }
    }
}
