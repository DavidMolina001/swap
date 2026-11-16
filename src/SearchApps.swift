// Apps by name: the folders macOS installs apps in, read when the search row is first used. The list stays for a
// minute, so a new install shows up on the next search after that.
import AppKit

enum AppCatalog {
    struct App { let name: String; let url: URL; let bundleID: String? }
    private(set) static var apps: [App] = []
    private static var readAt = Date.distantPast
    private static let folders = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications"]

    static func refresh() {
        guard Date().timeIntervalSince(readAt) > 60 else { return }
        readAt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let list = read()
            DispatchQueue.main.async { apps = list }
        }
    }

    private static func read() -> [App] {
        let fm = FileManager.default
        var out: [App] = []
        var seen = Set<String>()
        func scan(_ dir: String, _ depth: Int) {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !name.hasPrefix(".") {
                let path = dir + "/" + name
                if name.hasSuffix(".app") {
                    let title = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                    if seen.insert(title).inserted { out.append(App(name: title, url: URL(fileURLWithPath: path), bundleID: Bundle(path: path)?.bundleIdentifier)) }
                } else if depth > 0, (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeDirectory {
                    scan(path, depth - 1)
                }
            }
        }
        for dir in folders { scan(dir, 2) }
        return out
    }
}
