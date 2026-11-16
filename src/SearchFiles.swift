// File search: Apple's Spotlight index through NSMetadataQuery. Public API, no prompt, and the only thing that comes
// back is metadata the Mac already holds. Nothing here reads a file or leaves the Mac.
// Tested 4 Nov 2026 (Studio, macOS 26.5.1): Spotlight leaves out Desktop, Documents and Downloads for an app that has
// not been granted them, silently and with no prompt. MDQuery, an mdfind child and every NSMetadataQuery scope do the same.
import AppKit
import UniformTypeIdentifiers

struct FileHit {
    let path: String
    let name: String
    let folder: String    // right-hand text
    let type: String?     // content type, for the icon: no file is touched to draw it
    let used: Date?
}

// One query at a time, started after a short pause in the typing. A new search cancels the last one.
final class FileSearch {
    private(set) var busy = false
    private var query: NSMetadataQuery?
    private var waiting: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var started = Date()
    private var generation = 0

    func search(_ text: String, done: @escaping ([FileHit]) -> Void) {
        cancel()
        busy = true
        let work = DispatchWorkItem { [weak self] in self?.start(text, done) }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.searchDebounce, execute: work)
    }

    func cancel() {
        generation += 1
        busy = false
        waiting?.cancel()
        waiting = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        query?.stop()
        query = nil
    }

    // Desktop, Documents and Downloads stay hidden from search until macOS has asked about them. Listing each one
    // once triggers Apple's own prompt, and only when file search is first used.
    private static func askForFoldersOnce() {
        guard !UserDefaults.standard.bool(forKey: "searchFoldersAsked") else { return }
        UserDefaults.standard.set(true, forKey: "searchFoldersAsked")
        for dir in [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let url = FileManager.default.urls(for: dir, in: .userDomainMask).first { _ = try? FileManager.default.contentsOfDirectory(atPath: url.path) }
        }
    }

    private func start(_ text: String, _ done: @escaping ([FileHit]) -> Void) {
        Self.askForFoldersOnce()
        guard let predicate = NSPredicate(fromMetadataQueryString: FileSearch.queryString(text)) else { busy = false; done([]); return }
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.predicate = predicate
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        q.notificationBatchingInterval = 0.05
        query = q
        started = Date()
        generation += 1
        let gen = generation
        func finish() {
            guard gen == generation, let q = query else { return }
            q.disableUpdates()
            let hits = FileSearch.rank(q, text)
            cancel()
            done(hits)
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in finish() })
        // A very common word has tens of thousands of hits and takes seconds to gather: take what has come in.
        observers.append(nc.addObserver(forName: .NSMetadataQueryGatheringProgress, object: q, queue: .main) { [weak self] _ in
            guard let self, q.resultCount >= 3000 || Date().timeIntervalSince(self.started) > Tokens.Motion.searchLimit else { return }
            finish()
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + Tokens.Motion.searchLimit + 0.3) { finish() }
        if !q.start() { finish() }
    }

    // Spotlight's own query language. Under 3 letters it matches the start of a word and only in files used this
    // year, which keeps it instant (106,000 hits in 9.7 s without that limit, 246 in 0.07 s with it, on David's Mac).
    static func queryString(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return "kMDItemLastUsedDate >= $time.today(-30)" }
        var parts = words.map { word -> String in
            let safe = word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
            return word.count >= 3 ? "kMDItemFSName == \"*\(safe)*\"cd" : "kMDItemFSName == \"\(safe)*\"cdw"
        }
        if words.joined().count < 3 { parts.append("kMDItemLastUsedDate >= $time.today(-365)") }
        return parts.joined(separator: " && ")
    }

    // Build output, app insides, caches: never what anyone is looking for.
    static func isNoise(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        if path.hasPrefix(home + "/Library/"), !path.hasPrefix(home + "/Library/Mobile Documents/") { return true }
        if path.contains("/.") { return true }
        for part in [".app/", ".framework/", ".bundle/", "/node_modules/", "/DerivedData/", "/site-packages/", "/Pods/"] where path.contains(part) { return true }
        return false
    }

    // Best match first, and a file used lately beats a slightly better name nobody opens.
    private static func rank(_ q: NSMetadataQuery, _ text: String) -> [FileHit] {
        let words = SearchMatch.words(text)
        var scored: [(hit: FileHit, score: Int)] = []
        let now = Date()
        for i in 0..<min(q.resultCount, 800) {
            guard let item = q.result(at: i) as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !isNoise(path) else { continue }
            let type = item.value(forAttribute: "kMDItemContentType") as? String
            if type == "com.apple.application-bundle" { continue }   // apps have their own section
            let name = (path as NSString).lastPathComponent
            let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
            var score = words.isEmpty ? 0 : (SearchMatch.score(name, words) ?? 4)
            if let used { let days = now.timeIntervalSince(used) / 86400; score -= days < 7 ? 2 : (days < 90 ? 1 : 0) }
            scored.append((FileHit(path: path, name: name, folder: folderLabel(path), type: type, used: used), score))
        }
        let sorted = scored.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score < b.element.score : a.offset < b.offset
        }
        return sorted.prefix(Int(Tokens.Size.searchMaxResults)).map { $0.element.hit }
    }

    // ~/Downloads, or the last two folders when the path is long.
    static func folderLabel(_ path: String) -> String {
        var dir = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        if dir.hasPrefix(home + "/Library/Mobile Documents/com~apple~CloudDocs") {
            dir = "iCloud Drive" + dir.dropFirst((home + "/Library/Mobile Documents/com~apple~CloudDocs").count)
        } else if dir.hasPrefix(home) { dir = "~" + dir.dropFirst(home.count) }
        let parts = dir.split(separator: "/")
        return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : dir
    }

    // Asks the type, never the file: drawing the row reads nothing inside ~/Documents or ~/Downloads.
    static func icon(_ type: String?) -> NSImage {
        NSWorkspace.shared.icon(for: type.flatMap { UTType($0) } ?? .data)
    }
}
