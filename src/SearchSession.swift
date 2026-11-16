// The search row's session: what was typed, what matched, and the field's keys. Controller holds the list and the
// keyboard tap; this decides which rows go in it. Nothing here runs until the search row is selected. No app is
// named here: windows come from the list as it is, so a provider's rows are found like any other.
import AppKit

// Text matching for window titles, app names and file names.
enum SearchMatch {
    static func words(_ text: String) -> [String] { fold(text).split(whereSeparator: \.isWhitespace).map(String.init) }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    // 0 the whole text, 1 its start, 2 the start of a word, 3 anywhere; nil when a word is missing. Lower is better.
    static func score(_ text: String, _ words: [String]) -> Int? {
        let t = fold(text)
        var worst = 0
        for w in words {
            guard let r = t.range(of: w) else { return nil }
            var s = 3
            if t == w { s = 0 }
            else if r.lowerBound == t.startIndex { s = 1 }
            else if !t[t.index(before: r.lowerBound)].isLetter, !t[t.index(before: r.lowerBound)].isNumber { s = 2 }
            worst = max(worst, s)
        }
        return worst
    }
}

final class SearchSession: NSObject, NSTextFieldDelegate {
    weak var host: Controller?
    var onRow = false                // the selection is on the search row, not on a row of the list
    private(set) var typing = false  // the field has the keyboard
    private(set) var query = ""
    var inUse: Bool { onRow || typing }

    private let files = FileSearch()
    private var windows: [WindowItem] = []
    private var fileHits: [FileHit] = []     // the last answer: kept on screen until the next one arrives
    private var typedAt = Date.distantPast
    var listHeight: CGFloat = 0              // the height the list has reached this search: it only ever grows

    var emptyText: String? {
        guard typing, !query.isEmpty else { return nil }
        guard files.busy else { return Tokens.Copy.searchNone }
        return Date().timeIntervalSince(typedAt) < SearchSession.quietWait ? " " : Tokens.Copy.searchWorking
    }
    private static let quietWait: TimeInterval = 0.3   // "Searching" only when there is still nothing to show after this
    var filesOnly: Bool { query.lowercased().hasPrefix("f ") }   // Raycast's alias: f, then space
    private var text: String { (filesOnly ? String(query.dropFirst(2)) : query).trimmingCharacters(in: .whitespaces) }

    func begin(windows: [WindowItem]) {
        self.windows = windows
        typing = true
        query = ""
        fileHits = []
        listHeight = 0
        AppCatalog.refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(panelLostKeyboard), name: NSWindow.didResignKeyNotification, object: host?.panel)
    }

    func end() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: host?.panel)
        files.cancel()
        onRow = false; typing = false; query = ""
        windows = []; fileHits = []
    }

    // Keys pressed before the field had the keyboard, or just as it took it: they go in as if typed there.
    func type(_ text: String) {
        guard let field = host?.panel.switcher?.searchRow?.field else { return }
        field.stringValue += text
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        changed(field)
    }

    // W or Q took these rows away while results are on show.
    func remove(_ gone: (WindowItem) -> Bool) {
        windows.removeAll(where: gone)
        publish(keepSelection: true)
    }

    // A click on another app, or Command+Tab: the list goes, as Spotlight does.
    @objc private func panelLostKeyboard() {
        if typing { host?.searchCancel() }
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func reveal() {
        guard let url = host?.selectedItem?.opens else { return }
        host?.searchCancel()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: the field

    func controlTextDidChange(_ note: Notification) {
        if let field = note.object as? NSTextField { changed(field) }
    }

    private func changed(_ field: NSTextField) {
        query = field.stringValue
        host?.panel.switcher?.searchRow?.hint = query.isEmpty ? Tokens.Copy.searchFilesHint : (filesOnly ? Tokens.Copy.searchFiles : "")
        run()
    }

    // Option+Esc asks for word completion, and its popup would take the keyboard and the main thread with it.
    func control(_ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                 indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] { [] }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)): host?.searchMove(-1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): host?.searchMove(1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            host?.searchReturn(shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)): host?.searchCancel()
        default: return false
        }
        return true
    }

    // MARK: results

    // Every key narrows what is on show at once; the file answer replaces it when it arrives. So rows never empty out
    // and come back on each keystroke.
    private func run() {
        files.cancel()
        typedAt = Date()
        guard !query.isEmpty else { fileHits = []; host?.showWindowList(); return }
        if filesOnly || text.count >= 2 {
            files.search(text) { [weak self] hits in self?.fileHits = hits; self?.publish(keepSelection: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + SearchSession.quietWait) { [weak self] in
                guard let self, self.files.busy, Date().timeIntervalSince(self.typedAt) >= SearchSession.quietWait else { return }
                self.publish(keepSelection: true)
            }
        } else {
            fileHits = []
        }
        publish(keepSelection: false)
    }

    private func publish(keepSelection: Bool) {
        host?.showResults(filesOnly ? hitsOnShow().map(fileRow) : mixedRows(), keepSelection: keepSelection)
    }

    private func hitsOnShow() -> [FileHit] {
        let words = SearchMatch.words(text)
        return files.busy ? fileHits.filter { SearchMatch.score($0.name, words) != nil } : fileHits
    }

    private func fileRow(_ hit: FileHit) -> WindowItem {
        var row = WindowItem(app: nil, window: nil, id: 0, title: hit.name, appName: hit.folder, icon: FileSearch.icon(hit.type), minimized: false)
        row.opens = URL(fileURLWithPath: hit.path)
        return row
    }

    // Open windows by title, then apps, then files. Each keeps some room in the cap; spare room goes back up the list.
    private func mixedRows() -> [WindowItem] {
        let words = SearchMatch.words(text)
        guard !words.isEmpty else { return [] }
        var found: [(row: WindowItem, score: Int, order: Int)] = []
        for (i, w) in windows.enumerated() {
            if let s = SearchMatch.score(w.label, words) { found.append((w, s, i)) }
            else if let s = SearchMatch.score(w.appName, words) { found.append((w, s + 4, i)) }
            else if let s = SearchMatch.score(w.label + " " + w.appName, words) { found.append((w, s + 4, i)) }   // "textedit notes"
        }
        found.sort { $0.score != $1.score ? $0.score < $1.score : $0.order < $1.order }
        let winRows = found.map { $0.row }
        let inList = Set(winRows.compactMap { $0.app?.bundleIdentifier })
        var matched: [(app: AppCatalog.App, score: Int)] = []
        for a in AppCatalog.apps where !(a.bundleID.map(inList.contains) ?? false) {
            if let s = SearchMatch.score(a.name, words) { matched.append((a, s)) }
        }
        matched.sort { $0.score != $1.score ? $0.score < $1.score : $0.app.name < $1.app.name }
        let appHits = matched.map { $0.app }
        let cap = Int(Tokens.Size.searchMaxResults)
        let hits = hitsOnShow()
        var nWin = min(winRows.count, 6), nApp = min(appHits.count, 3)
        let nFile = min(hits.count, cap - nWin - nApp)
        var spare = cap - nWin - nApp - nFile
        let moreWin = min(spare, winRows.count - nWin); nWin += moreWin; spare -= moreWin
        nApp += min(spare, appHits.count - nApp)
        var rows = Array(winRows.prefix(nWin))
        for a in appHits.prefix(nApp) {
            var row = WindowItem(app: nil, window: nil, id: 0, title: a.name, appName: Tokens.Copy.searchApp,
                                 icon: NSWorkspace.shared.icon(forFile: a.url.path), minimized: false)
            row.opens = a.url
            rows.append(row)
        }
        return rows + hits.prefix(nFile).map(fileRow)
    }
}

extension SwitcherPanel {
    // New rows while typing. As updateRows, but the panel keeps the tallest height it has reached in this search and
    // the rows stay under the field, so a keystroke never makes the list shrink and grow back.
    func updateTypingRows(_ items: [WindowItem], selected: Int, emptyText: String?, session: SearchSession) {
        guard let view = switcher else { return }
        let needed = view.replaceRows(items, selected: selected, emptyText: emptyText)
        session.listHeight = max(session.listHeight, max(needed, frame.height))
        view.rows.setFrameOrigin(NSPoint(x: view.rows.frame.minX, y: view.rows.frame.minY + session.listHeight - needed))
        guard frame.height != session.listHeight else { return }
        let area = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        var f = frame
        let top = f.maxY
        f.size.height = session.listHeight
        f.origin.y = max(area.minY + Tokens.Size.panelPad, top - session.listHeight)
        setFrame(f, display: true)
        view.fitRim()
        invalidateShadow()
    }
}
