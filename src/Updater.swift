import AppKit
import Security

// Check for Updates: asks GitHub for the latest release of this repo, and when it is newer, downloads its DMG,
// checks the app inside is signed by the same identity as the running Swap (so it really is ours, and macOS keeps
// the Accessibility permission), puts it in place of this copy and relaunches. Nothing runs in the background and
// nothing is sent except the one request to GitHub. If anything is off it says so and offers the release page.
final class Updater {
    static let shared = Updater()
    static let repo = "DavidMolina001/swap"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }

    enum Result: Equatable {
        case upToDate(String)
        case available(version: String, dmg: URL, notes: String)
        case failed(String)
    }

    private(set) var busy = false

    // No caching anywhere: a cached "latest" answer would hide a new release.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    static func validVersion(_ v: String) -> Bool {
        v.range(of: #"^\d{1,4}(\.\d{1,4}){1,3}$"#, options: .regularExpression) != nil
    }

    // "0.10.0" is newer than "0.9.2".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: checking

    func check(current: String = appVersion, done: @escaping (Result) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Swap/\(current)", forHTTPHeaderField: "User-Agent")
        Updater.session.dataTask(with: req) { data, response, error in
            let result: Result
            if let error { result = .failed("Couldn't reach GitHub (\(error.localizedDescription)).") }
            else if (response as? HTTPURLResponse)?.statusCode != 200 { result = .failed("GitHub didn't answer the update check.") }
            else { result = Updater.parse(data ?? Data(), current: current) }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    static func parse(_ data: Data, current: String) -> Result {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return .failed("The release information was not readable.") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard validVersion(version) else { return .failed("The latest release has an unexpected version (\(tag)).") }
        guard isNewer(version, than: current) else { return .upToDate(current) }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        guard let link = assets.compactMap({ $0["browser_download_url"] as? String }).first(where: { $0.lowercased().hasSuffix(".dmg") }),
              let url = URL(string: link), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.path.hasPrefix("/\(repo)/releases/download/") else {
            return .failed("Swap \(version) is out, but its download is missing.")
        }
        return .available(version: version, dmg: url, notes: (json["body"] as? String) ?? "")
    }

    // MARK: installing

    // Downloads, verifies and swaps in the new copy. `done` gets nil once the relaunch is on its way, else the reason.
    func install(version: String, dmg: URL, relaunch: Bool = true, done: @escaping (String?) -> Void) {
        let here = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: here.deletingLastPathComponent().path),
              !here.path.contains("/AppTranslocation/") else {
            done("Swap can't replace itself where it is now. Move Swap to Applications, open it from there, and try again.")
            return
        }
        busy = true
        Updater.session.downloadTask(with: dmg) { file, response, error in
            let fail: (String) -> Void = { why in DispatchQueue.main.async { self.busy = false; done(why) } }
            guard let file, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else { fail("The download didn't finish."); return }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("swap-update-\(version)-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let image = work.appendingPathComponent("Swap.dmg")
                try FileManager.default.moveItem(at: file, to: image)
                if let why = Updater.swapIn(image: image, version: version, work: work, replacing: here) { fail(why); return }
            } catch { fail("The update couldn't be unpacked (\(error.localizedDescription)).") ; return }
            try? FileManager.default.removeItem(at: work)
            DispatchQueue.main.async { self.busy = false; done(nil); if relaunch { Updater.relaunch(here) } }
        }.resume()
    }

    // Mounts the image, checks the app inside, copies it next to this one and swaps the two. Returns the reason on failure.
    static func swapIn(image: URL, version: String, work: URL, replacing here: URL) -> String? {
        let mount = work.appendingPathComponent("mnt")
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path]) else {
            return "The downloaded disk image couldn't be opened."
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let newApp = mount.appendingPathComponent("Swap.app")
        if let why = verify(newApp, version: version) { return why }
        let staged = here.deletingLastPathComponent().appendingPathComponent(".Swap-\(version)-update.app")
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) else { return "The new version couldn't be copied next to this one." }
        _ = run("/usr/bin/xattr", ["-cr", staged.path])
        if let why = verify(staged, version: version) { try? FileManager.default.removeItem(at: staged); return why }
        do { _ = try FileManager.default.replaceItemAt(here, withItemAt: staged) }
        catch { try? FileManager.default.removeItem(at: staged); return "The new version couldn't be put in place (\(error.localizedDescription))." }
        return nil
    }

    // The new app must be Swap, the version the release says, intact, and signed by the same identity as this copy.
    static func verify(_ app: URL, version: String) -> String? {
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else { return "The download isn't Swap \(version)." }
        var me: SecCode?, mine: SecRequirement?, theirs: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(unsafeBitCast(me, to: SecStaticCode.self), [], &mine) == errSecSuccess, let mine,
              SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs else {
            return "The new version's signature couldn't be read."
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(theirs, flags, mine) == errSecSuccess else {
            return "The new version isn't signed the same way as this one, so it wasn't installed."
        }
        return nil
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: the button

    // The whole flow behind "Check for Updates…": ask, tell, and on yes install.
    func checkInteractively() {
        guard !busy else { return }
        busy = true
        check { result in
            self.busy = false
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            switch result {
            case .upToDate(let v):
                alert.messageText = "Swap is up to date"
                alert.informativeText = "You have the latest version, \(v)."
                alert.runModal()
            case .failed(let why):
                alert.messageText = "Couldn't check for updates"
                alert.informativeText = why
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Open Releases Page")
                if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Updater.releasesPage) }
            case .available(let version, let dmg, let notes):
                alert.messageText = "Swap \(version) is available"
                let short = notes.split(separator: "\n").prefix(6).joined(separator: "\n")
                alert.informativeText = "You have \(appVersion). " + (short.isEmpty ? "" : "\n\n" + short) + "\n\nSwap will restart to finish."
                alert.addButton(withTitle: "Install and Restart")
                alert.addButton(withTitle: "Later")
                alert.addButton(withTitle: "Release Notes")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    self.install(version: version, dmg: dmg) { why in
                        guard let why else { return }
                        let a = NSAlert()
                        a.messageText = "The update didn't install"
                        a.informativeText = why
                        a.addButton(withTitle: "OK")
                        a.addButton(withTitle: "Open Releases Page")
                        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Updater.releasesPage) }
                    }
                case .alertThirdButtonReturn: NSWorkspace.shared.open(Updater.releasesPage)
                default: break
                }
            }
        }
    }
}
