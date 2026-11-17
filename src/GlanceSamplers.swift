import AppKit
import IOKit
import Darwin

// The samplers behind the glance bar (GlanceModel.swift has the vocabulary). GlanceEngine owns one source per
// widget in the user's list, takes baselines at the first Option+Tab (`prime`), and while the panel is open
// reads them once a second and hands the readings to the panel. Everything runs on the main thread, each
// read returns in well under 5 ms, and nothing runs while the engine is stopped: no timers, no watchers.
// Nothing leaves the Mac.
final class GlanceEngine {
    static let shared = GlanceEngine()

    // QA hook: when set, these readings stand in for the real ones (idle ones removed, capped like real
    // readings) and no source is primed or read.
    var override: [Glance.Reading]?

    private(set) var isRunning = false
    private var sources: [Glance.Source] = []
    private var builtFor: [Glance.Widget] = []
    private var primed = false
    private var timer: Timer?
    private var onUpdate: (([Glance.Reading]) -> Void)?
    private var last: [Glance.Reading] = []

    // The latest readings in the user's order, idle ones removed, capped to Glance.maxWidgets.
    var current: [Glance.Reading] {
        if let o = override { return GlanceEngine.visible(o) }
        if last.isEmpty {                       // first show before start(): prime if the controller has not yet
            if !primed { prime() }
            last = readAll()
        }
        return last
    }

    // First Option+Tab of a session: take the baselines (CPU ticks, byte counters). No figures yet.
    func prime() {
        if override != nil { return }
        rebuildIfNeeded()
        sources.forEach { $0.prime() }
        primed = true
    }

    // Read once now, then once a second until stop(). The panel gets the readings on the main thread.
    func start(onUpdate: @escaping ([Glance.Reading]) -> Void) {
        stop()
        self.onUpdate = onUpdate
        isRunning = true
        if override == nil, !primed { prime() }
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        onUpdate = nil
        isRunning = false
        sources.forEach { ($0 as? GlanceStoppable)?.didStop() }
    }

    // Fixtures for QA scenes and previews: the mock figures, with the Timer cell replaced by the real timer.
    static func fixtures(busy: Bool = false) -> [Glance.Reading] {
        Glance.samples(Settings.glanceWidgetList, busy: busy).map { $0.widget == .timer ? GlanceTimer.shared.reading() : $0 }
    }

    static func visible(_ readings: [Glance.Reading]) -> [Glance.Reading] {
        Array(readings.filter { !$0.idle }.prefix(Glance.maxWidgets))
    }

    private func tick() {
        let r: [Glance.Reading]
        if let o = override { r = GlanceEngine.visible(o) } else { r = readAll() }
        last = r
        onUpdate?(r)
    }

    private func readAll() -> [Glance.Reading] {
        rebuildIfNeeded()
        return GlanceEngine.visible(sources.map { $0.read() })
    }

    // Sources follow the user's list; the Downloads source exists only while Downloads is in it, because its
    // folder read is what makes macOS ask for access.
    private func rebuildIfNeeded() {
        let wanted = Settings.glanceWidgetList
        if wanted == builtFor, !sources.isEmpty || wanted.isEmpty { return }
        var kept: [Glance.Widget: Glance.Source] = [:]
        for s in sources { kept[s.widget] = s }
        sources = wanted.map { w in
            if let s = kept[w] { return s }
            let s = GlanceEngine.makeSource(w)
            if primed { s.prime() }
            return s
        }
        builtFor = wanted
    }

    static func makeSource(_ w: Glance.Widget) -> Glance.Source {
        switch w {
        case .cpu: return CPUSource()
        case .memory: return MemorySource()
        case .gpu: return GPUSource()
        case .network: return NetworkSource()
        case .downloads: return DownloadsSource()
        case .quota: return QuotaSource()
        case .timer: return TimerSource()
        case .calendar: return CalendarSource()
        }
    }
}

// Sources that hold something while running (an IOKit handle) release it here.
protocol GlanceStoppable: AnyObject { func didStop() }

// MARK: - CPU: host_processor_info deltas, whole Mac

final class CPUSource: Glance.Source {
    let widget = Glance.Widget.cpu
    private var base: (user: UInt64, sys: UInt64, idle: UInt64)?
    private var hot = 0                       // consecutive reads at 85% or more
    private var lastReading: Glance.Reading?

    func prime() { base = CPUSource.ticks() }

    func read() -> Glance.Reading {
        guard let now = CPUSource.ticks() else { return Glance.Reading(widget: .cpu, value: Tokens.Copy.glanceNA, label: "CPU", detail: "no figure on this Mac", level: .none) }
        var du = Double(now.user), ds = Double(now.sys), di = Double(now.idle)   // no baseline yet: average since boot
        if let b = base {
            let u = Double(now.user &- b.user), s = Double(now.sys &- b.sys), i = Double(now.idle &- b.idle)
            if u + s + i > 0 { du = u; ds = s; di = i; base = now }
            else if let r = lastReading { return r }      // read within the same 10 ms tick: keep the last figure
        } else { base = now }
        let total = du + ds + di
        guard total > 0 else { return lastReading ?? Glance.Reading(widget: .cpu, value: Tokens.Copy.glanceNA, label: "CPU", detail: "no figure on this Mac", level: .none) }
        let user = du / total, sys = ds / total, busy = min(1, user + sys)
        let pct = Int((busy * 100).rounded())
        hot = pct >= 85 ? hot + 1 : 0
        let r = Glance.Reading(widget: .cpu, value: "\(pct)%", label: "CPU",
                               detail: "\(Int((user * 100).rounded()))% user, \(Int((sys * 100).rounded()))% sys",
                               fraction: busy, level: hot >= 3 ? .warning : .normal)
        lastReading = r
        return r
    }

    private static func ticks() -> (user: UInt64, sys: UInt64, idle: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info = info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var user: UInt64 = 0, sys: UInt64 = 0, idle: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(count) {
            let o = cpu * states
            user += UInt64(UInt32(bitPattern: info[o + Int(CPU_STATE_USER)])) + UInt64(UInt32(bitPattern: info[o + Int(CPU_STATE_NICE)]))
            sys += UInt64(UInt32(bitPattern: info[o + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(UInt32(bitPattern: info[o + Int(CPU_STATE_IDLE)]))
        }
        return (user, sys, idle)
    }
}

// MARK: - Memory: host_statistics64, pressure from the kernel

final class MemorySource: Glance.Source {
    let widget = Glance.Widget.memory
    private let total = Double(ProcessInfo.processInfo.physicalMemory)
    private var pageSize: Double = Double(vm_kernel_page_size)

    func prime() {}

    func read() -> Glance.Reading {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS, total > 0 else {
            return Glance.Reading(widget: .memory, value: Tokens.Copy.glanceNA, label: "Memory", detail: "no figure on this Mac", level: .none)
        }
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
        let frac = min(1, max(0, used / total))
        let level: Glance.Level
        switch MemorySource.pressure() {
        case 4: level = .limit
        case 2: level = .warning
        default: level = .normal
        }
        return Glance.Reading(widget: .memory, value: "\(Int((frac * 100).rounded()))%", label: "Memory",
                              detail: "\(MemorySource.gb(used)) of \(MemorySource.gb(total)) GB", fraction: frac, level: level)
    }

    private static func pressure() -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &size, nil, 0) == 0 ? Int(v) : 1
    }

    // "19.5", "32": one decimal unless whole.
    static func gb(_ bytes: Double) -> String {
        let g = bytes / 1_073_741_824
        return g.rounded() == (g * 10).rounded() / 10 ? String(Int(g.rounded())) : String(format: "%.1f", g)
    }
}

// MARK: - GPU: IOAccelerator PerformanceStatistics

final class GPUSource: Glance.Source, GlanceStoppable {
    let widget = Glance.Widget.gpu
    private var service: io_registry_entry_t = 0

    func prime() { _ = lookup() }

    func didStop() {
        if service != 0 { IOObjectRelease(service); service = 0 }
    }

    deinit { didStop() }

    func read() -> Glance.Reading {
        let na = Glance.Reading(widget: .gpu, value: Tokens.Copy.glanceNA, label: "GPU", detail: "no figure on this Mac", fraction: nil, level: .none)
        guard let stats = statistics() else { return na }
        let util = GPUSource.number(stats["Device Utilization %"]) ?? GPUSource.number(stats["GPU Activity(%)"])
        guard let u = util else { return na }
        let frac = min(1, max(0, u / 100))
        var detail: String? = nil
        if let used = GPUSource.number(stats["In use system memory"]), let alloc = GPUSource.number(stats["Alloc system memory"]), alloc > 0 {
            detail = "\(MemorySource.gb(used)) of \(MemorySource.gb(alloc)) GB"
        }
        return Glance.Reading(widget: .gpu, value: "\(Int((frac * 100).rounded()))%", label: "GPU", detail: detail, fraction: frac)
    }

    private func statistics() -> [String: Any]? {
        guard lookup() else { return nil }
        guard let raw = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) else {
            didStop()      // the entry went away; look it up again next time
            return nil
        }
        return raw.takeRetainedValue() as? [String: Any]
    }

    // The first IOAccelerator that reports a utilisation figure.
    private func lookup() -> Bool {
        if service != 0 { return true }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        var fallback: io_registry_entry_t = 0
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            if let raw = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
               let d = raw.takeRetainedValue() as? [String: Any] {
                if d["Device Utilization %"] != nil || d["GPU Activity(%)"] != nil {
                    if fallback != 0 { IOObjectRelease(fallback) }
                    service = entry
                    return true
                }
                if fallback == 0 { fallback = entry; continue }
            }
            IOObjectRelease(entry)
        }
        if fallback != 0 { service = fallback; return true }
        return false
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}

// MARK: - Network: getifaddrs byte counters on en* interfaces

final class NetworkSource: Glance.Source {
    let widget = Glance.Widget.network
    private var base: (rx: UInt64, tx: UInt64, at: Date)?

    func prime() { base = NetworkSource.counters() }

    func read() -> Glance.Reading {
        guard let now = NetworkSource.counters() else {
            return Glance.Reading(widget: .network, value: Tokens.Copy.glanceNA, label: "Network", detail: "no figure on this Mac", level: .none)
        }
        defer { base = now }
        var down = 0.0, up = 0.0
        if let b = base {
            let dt = now.at.timeIntervalSince(b.at)
            if dt > 0.05 {
                down = Double(now.rx &- b.rx) / dt
                up = Double(now.tx &- b.tx) / dt
            }
        }
        return Glance.Reading(widget: .network, value: "↓ \(NetworkSource.rate(down))", label: "Network", detail: "↑ \(NetworkSource.rate(up))")
    }

    // "0 B/s", "812 KB/s", "2.4 MB/s": one decimal under 10.
    static func rate(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        func f(_ x: Double, _ unit: String) -> String { x < 10 && unit != "B/s" ? String(format: "%.1f %@", x, unit) : "\(Int(x.rounded())) \(unit)" }
        if v >= 1_000_000 { return f(v / 1_000_000, "MB/s") }
        if v >= 1_000 { return f(v / 1_000, "KB/s") }
        return f(v, "B/s")
    }

    // Per-interface counters are 32-bit; a wrap shows as one odd second, which the next read corrects.
    private static func counters() -> (rx: UInt64, tx: UInt64, at: Date)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = a.pointee.ifa_data else { continue }
            let name = String(cString: a.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }      // physical only: no lo, awdl, llw, utun, bridge
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes)
            tx += UInt64(d.ifi_obytes)
        }
        return (rx, tx, Date())
    }
}

// MARK: - Downloads: files still downloading in ~/Downloads

final class DownloadsSource: Glance.Source {
    let widget = Glance.Widget.downloads
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    private static let partialExtensions = ["download", "crdownload", "part", "partial"]

    func prime() {}    // the first read happens while the panel is open, never at prime

    func read() -> Glance.Reading {
        let idle = Glance.Reading(widget: .downloads, value: "", label: "Downloads", idle: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return idle }
        var files: [String] = []
        var progress: [Double] = []
        for n in names.sorted() {
            let ext = (n as NSString).pathExtension.lowercased()
            guard DownloadsSource.partialExtensions.contains(ext) else { continue }
            files.append((n as NSString).deletingPathExtension)
            if ext == "download", let p = safariProgress(bundle: n) { progress.append(p) }
        }
        guard !files.isEmpty else { return idle }
        var value = "\(files.count)"
        var fraction: Double? = nil
        if !progress.isEmpty {
            let mean = progress.reduce(0, +) / Double(progress.count)
            fraction = mean
            value += " · \(Int((mean * 100).rounded()))%"
        }
        return Glance.Reading(widget: .downloads, value: value, label: "Downloads", detail: files.first, fraction: fraction)
    }

    private func safariProgress(bundle: String) -> Double? {
        let plist = folder.appendingPathComponent(bundle).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let d = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let so = (d["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.doubleValue,
              let total = (d["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.doubleValue, total > 0 else { return nil }
        return min(1, max(0, so / total))
    }
}

// MARK: - Quota: the glance.json the Quota app writes

final class QuotaSource: Glance.Source {
    let widget = Glance.Widget.quota
    private var cached: Glance.Reading?
    private var readAt: Date?
    static let refresh: TimeInterval = 10
    static let stale: TimeInterval = 15 * 60

    func prime() { cached = load(); readAt = Date() }

    func read() -> Glance.Reading {
        if let at = readAt, let c = cached, Date().timeIntervalSince(at) < QuotaSource.refresh { return c }
        let r = load()
        cached = r; readAt = Date()
        return r
    }

    private func loadFile() -> Glance.Reading {
        let idle = Glance.Reading(widget: .quota, value: "", label: "Quota", idle: true)
        let url = Glance.quotaFile
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return idle }
        let updated: Date
        if let u = (json["updated"] as? NSNumber)?.doubleValue { updated = Date(timeIntervalSince1970: u) }
        else if let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { updated = m }
        else { return idle }
        guard Date().timeIntervalSince(updated) < QuotaSource.stale else { return idle }
        let tightest = json["tightest"] as? [String: Any]
        let parts = (json["parts"] as? [[String: Any]])?.compactMap { p -> Glance.QuotaPart? in
            guard let svc = p["service"] as? String, let text = p["text"] as? String else { return nil }
            return Glance.QuotaPart(service: svc, text: text, level: Glance.Level(rawValue: p["level"] as? String ?? "") ?? .normal,
                                    muted: p["muted"] as? Bool ?? false)
        }
        guard let tightText = (tightest?["text"] as? String)?.trimmingCharacters(in: .whitespaces), !tightText.isEmpty else { return idle }
        var value = tightText
        if Settings.quotaCell == .pill, let pill = (json["pill"] as? String)?.trimmingCharacters(in: .whitespaces), !pill.isEmpty, pill.count <= 12 { value = pill }
        let levelText = (json["level"] as? String) ?? (tightest?["level"] as? String) ?? "normal"
        let level = Glance.Level(rawValue: levelText) ?? .normal
        let fraction = (tightest?["fraction"] as? NSNumber).map { min(1, max(0, $0.doubleValue)) }
        return Glance.Reading(widget: .quota, value: value, label: "Quota", detail: json["detail"] as? String, fraction: fraction, level: level == .none ? .normal : level,
                              parts: parts)
    }

    private func load() -> Glance.Reading {
        let fromFile = loadFile()
        if !fromFile.idle, fromFile.parts != nil { return fromFile }
        // Quota does not write glance.json yet: build the same per-service figures from its own log.
        if let parts = QuotaSource.partsFromLog(), !parts.isEmpty {
            let worst = parts.filter { !$0.muted }.map(\.level)
            let level: Glance.Level = worst.contains(.limit) ? .limit : worst.contains(.warning) ? .warning : .normal
            // value: what the single Quota tile shows when the services do not fit, the tightest figure
            let tight = parts.filter { !$0.muted }.flatMap { $0.text.components(separatedBy: " · ") }
                .compactMap { Int($0.replacingOccurrences(of: "%", with: "")) }.max()
            return Glance.Reading(widget: .quota, value: tight.map { "\($0)%" } ?? parts[0].text, label: "Quota", level: level, parts: parts)
        }
        return fromFile
    }

    // Quota's readings log (one JSON line per limit per refresh) read the way Quota's menu bar reads its state: each
    // service's latest refresh, Claude as its 5-hour and 7-day figures (the 5-hour falls back to the first limit, as in
    // Quota), other services all their limits, Antigravity only its tightest. Quota's own order, hidden services and
    // Claude choice come from its preferences. Read only; nothing is written.
    static func partsFromLog(now: Date = Date()) -> [Glance.QuotaPart]? {
        let url = Glance.quotaFile.deletingLastPathComponent().appendingPathComponent("readings.jsonl")
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        struct Row { let limit: String; let used: Double; let t: Double }
        var latest: [String: Double] = [:], rows: [String: [Row]] = [:]
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let p = j["provider"] as? String, let lim = j["limit"] as? String,
                  let used = (j["used"] as? NSNumber)?.doubleValue, let t = (j["t"] as? NSNumber)?.doubleValue else { continue }
            if t > (latest[p] ?? 0) { latest[p] = t; rows[p] = [] }
            if t == latest[p] { rows[p, default: []].append(Row(limit: lim, used: used, t: t)) }
        }
        let prefs = UserDefaults(suiteName: "com.quota.app")
        let hidden = Set(prefs?.stringArray(forKey: "hiddenInPill") ?? [])
        let saved = prefs?.stringArray(forKey: "serviceOrder") ?? []
        let order = saved + ["claude", "codex", "grok", "antigravity", "cursor"].filter { !saved.contains($0) }
        let claudePill = prefs?.string(forKey: "claudePill") ?? "both"
        func pct(_ u: Double) -> String { "\(Int(min(max(u, 0), 100).rounded()))%" }
        func level(_ u: Double) -> Glance.Level { u.rounded() >= 100 ? .limit : u >= 80 ? .warning : .normal }
        var out: [Glance.QuotaPart] = []
        for svc in order where !hidden.contains(svc) {
            guard var ws = rows[svc], !ws.isEmpty, let t = latest[svc] else { continue }
            let age = now.timeIntervalSince1970 - t
            if age > 24 * 3600 { continue }   // a service Quota stopped checking
            if svc == "claude" {
                let five = ws.first { $0.limit == "five_hour" } ?? ws.first, seven = ws.first { $0.limit == "seven_day" }
                switch claudePill {
                case "five": ws = [five].compactMap { $0 }
                case "seven": ws = [seven ?? five].compactMap { $0 }
                default: ws = [five, seven].compactMap { $0 }
                }
            }
            guard let top = ws.max(by: { $0.used < $1.used }) else { continue }
            let text = svc == "antigravity" ? pct(top.used) : ws.map { pct($0.used) }.joined(separator: " · ")
            out.append(Glance.QuotaPart(service: svc, text: text, level: level(top.used), muted: age > 6 * 3600))   // the log gets a line only when a figure changes, so a quiet service is not out of date
        }
        return out
    }
}

// MARK: - Timer and Calendar

final class TimerSource: Glance.Source {
    let widget = Glance.Widget.timer
    func prime() {}
    func read() -> Glance.Reading { GlanceTimer.shared.reading() }
}

// Not shipping yet (Widget.available is false): always idle, never touches EventKit.
final class CalendarSource: Glance.Source {
    let widget = Glance.Widget.calendar
    func prime() {}
    func read() -> Glance.Reading { Glance.Reading(widget: .calendar, value: "", label: "Calendar", idle: true) }
}

#if SELFTEST
// Shell self-check: prints every source's reading twice, one second apart, no window. Downloads only when
// it is in the user's list (its folder read triggers the macOS prompt).
extension GlanceEngine {
    static func selfCheck() {
        let list = Settings.glanceWidgetList
        var widgets = Glance.Widget.allCases.filter { $0.available && $0 != .downloads }
        if list.contains(.downloads) { widgets.append(.downloads) }
        let sources = widgets.map { makeSource($0) }
        func line(_ r: Glance.Reading) -> String {
            let frac = r.fraction.map { String(format: "%.2f", $0) } ?? "nil"
            return "  \(r.widget.title.padding(toLength: 9, withPad: " ", startingAt: 0)) value=\"\(r.value)\" detail=\(r.detail.map { "\"\($0)\"" } ?? "nil") fraction=\(frac) level=\(r.level.rawValue)\(r.idle ? " idle" : "")"
        }
        var t0 = Date()
        sources.forEach { $0.prime() }
        print(String(format: "prime: %.2f ms (widgets in user's list: %@)", Date().timeIntervalSince(t0) * 1000, list.map { $0.rawValue }.joined(separator: ",")))
        for pass in 1...2 {
            if pass == 2 { Thread.sleep(forTimeInterval: 1) }
            t0 = Date()
            let rs = sources.map { $0.read() }
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "read %d: %.2f ms", pass, ms))
            rs.forEach { print(line($0)) }
        }
        print("current (user's list, idle removed, capped): \(GlanceEngine.shared.current.map { "\($0.widget.rawValue)=\($0.value)" })")
    }
}
#endif
