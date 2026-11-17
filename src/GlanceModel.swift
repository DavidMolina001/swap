import AppKit

// The glance bar: a strip of small readings (widgets) at the top of the panel. Off unless the user switches
// it on; readings are taken only while the panel is open; nothing leaves the Mac. This file is the shared
// vocabulary: GlanceSamplers.swift produces readings, GlanceBarView.swift draws them, the Controller runs
// the engine while the panel is visible, Settings keeps the user's choices.
enum Glance {
    enum Density: String, CaseIterable {
        case compact, regular, detailed
        var height: CGFloat {
            switch self {
            case .compact: return Tokens.Size.glanceBarCompact
            case .regular: return Tokens.Size.glanceBarRegular
            case .detailed: return Tokens.Size.glanceBarDetailed
            }
        }
        var name: String { switch self { case .compact: return "Compact"; case .regular: return "Regular"; case .detailed: return "Detailed" } }
    }

    enum Widget: String, CaseIterable {
        case cpu, memory, gpu, quota, network, downloads, timer, calendar
        var title: String {
            switch self {
            case .cpu: return "CPU"; case .memory: return "Memory"; case .gpu: return "GPU"; case .quota: return "Quota"
            case .network: return "Network"; case .downloads: return "Downloads"; case .timer: return "Timer"; case .calendar: return "Calendar"
            }
        }
        // SF Symbol drawn white inside the tinted tile. GPU has no symbol: GlanceBarView draws a chip.
        var symbol: String? {
            switch self {
            case .cpu: return "cpu"; case .memory: return "memorychip"; case .gpu: return nil; case .quota: return "gauge.with.needle"
            case .network: return "arrow.up.arrow.down"; case .downloads: return "arrow.down.circle"; case .timer: return "timer"; case .calendar: return "calendar"
            }
        }
        var tint: Shade {
            switch self {
            case .cpu: return Tokens.Color.tileCPU; case .memory: return Tokens.Color.tileMemory; case .gpu: return Tokens.Color.tileGPU
            case .quota: return Tokens.Color.tileQuota; case .network: return Tokens.Color.tileNetwork; case .downloads: return Tokens.Color.tileDownloads
            case .timer: return Tokens.Color.tileTimer; case .calendar: return Tokens.Color.tileCalendar
            }
        }
        // Widgets that make macOS ask the user for access. Never read before the user adds them.
        var asksPermission: Bool { self == .downloads || self == .calendar }
        // Shipping in this version. Calendar is drawn in previews but cannot be switched on yet.
        var available: Bool { self != .calendar }
    }

    enum Level: String { case normal, warning, limit, none }   // none: no figure, drawn grey ("n/a")

    struct Reading: Equatable {
        var widget: Widget
        var value: String            // "23%", "42% 5h", "18:42", "2 · 68%"
        var label: String            // Regular: "CPU"; Detailed may use a longer label
        var detail: String? = nil    // Detailed only, after a middle dot: "19.5 of 32 GB", "resets 14:00"
        var fraction: Double? = nil  // 0...1 for the Detailed level bar; nil = no bar (Network, Calendar)
        var level: Level = .normal
        var idle: Bool = false       // hidden from the bar (timer not running, no download in progress)
        var parts: [QuotaPart]? = nil   // Quota only: one logo and figure per service, as Quota's own menu bar shows them
    }

    // One service in the Quota cell: "claude" and "12% · 12%". The logo comes from the installed Quota app.
    struct QuotaPart: Equatable {
        var service: String
        var text: String
        var level: Level = .normal
        var muted = false
    }

    // One sampler per widget. prime() takes the baseline (first Option+Tab); read() the figure (at show, then
    // once a second while the panel is visible). Both run on the main thread and must return in under 5 ms.
    protocol Source: AnyObject {
        var widget: Widget { get }
        func prime()
        func read() -> Reading
    }

    static var maxWidgets: Int { Int(Tokens.Size.glanceMaxWidgets) }

    // Hand-off from the Quota app (decision 11): Quota writes this after each refresh, Swap reads it once per
    // open. {"pill":"C 42% 5h · O 12%","tightest":{"text":"42% 5h","fraction":0.42,"level":"normal"},
    //        "detail":"Claude · resets 14:00","updated":1762000000}
    static let quotaFile = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Quota/glance.json")

    // Fixtures for the Settings preview, the welcome box, QA scenes and the design sheet. Same figures as the
    // approved mock (Glance bar widgets - 2026-11-02.html).
    static func sample(_ w: Widget, busy: Bool = false) -> Reading {
        switch w {
        case .cpu: return busy ? Reading(widget: w, value: "91%", label: "CPU", detail: "84% user, 7% sys", fraction: 0.91, level: .warning)
                               : Reading(widget: w, value: "23%", label: "CPU", detail: "18% user, 5% sys", fraction: 0.23)
        case .memory: return busy ? Reading(widget: w, value: "84%", label: "Memory", detail: "26.9 of 32 GB", fraction: 0.84, level: .warning)
                                  : Reading(widget: w, value: "61%", label: "Memory", detail: "19.5 of 32 GB", fraction: 0.61)
        case .gpu: return Reading(widget: w, value: "8%", label: "GPU", detail: "1.3 of 16 GB", fraction: 0.08)
        case .quota: return busy ? Reading(widget: w, value: "86% 5h", label: "Quota", detail: "resets 14:00", fraction: 0.86, level: .warning,
                                           parts: [QuotaPart(service: "claude", text: "86% · 61%", level: .warning), QuotaPart(service: "codex", text: "12%"),
                                                   QuotaPart(service: "antigravity", text: "0%")])
                                 : Reading(widget: w, value: "42% 5h", label: "Quota", detail: "resets 14:00", fraction: 0.42,
                                           parts: [QuotaPart(service: "claude", text: "42% · 61%"), QuotaPart(service: "codex", text: "12%"),
                                                   QuotaPart(service: "antigravity", text: "0%")])
        case .network: return Reading(widget: w, value: "↓ 2.4 MB/s", label: "Network", detail: "↑ 0.3 MB/s")
        case .downloads: return Reading(widget: w, value: "2 · 68%", label: "Downloads", detail: "Report.pdf", fraction: 0.68)
        case .timer: return Reading(widget: w, value: "18:42", label: "Timer", detail: "of 25:00", fraction: 0.75)
        case .calendar: return Reading(widget: w, value: "11:00", label: "Stand-up", detail: "in 25 min, Meet")
        }
    }
    static func samples(_ widgets: [Widget], busy: Bool = false) -> [Reading] { widgets.map { sample($0, busy: busy) } }
}

// The countdown timer behind the Timer widget and the menu bar Timer menu. One at a time. At zero it posts
// `fired` (the app plays the alert sound and flashes the menu bar icon, see main.swift) and shows "Timer done"
// for a minute, then goes idle. `changed` is posted on start, stop, every second while running, and at zero.
final class GlanceTimer {
    static let shared = GlanceTimer()
    static let changed = Notification.Name("swap.timer.changed")
    static let fired = Notification.Name("swap.timer.fired")
    static let presets: [Int] = [5, 15, 25, 45]          // minutes

    private(set) var endsAt: Date?
    private(set) var total: TimeInterval = 0
    private(set) var doneUntil: Date?
    private var tick: Timer?

    var isRunning: Bool { endsAt != nil }
    var isDone: Bool { doneUntil.map { $0 > Date() } ?? false }
    var remaining: TimeInterval { max(0, endsAt?.timeIntervalSinceNow ?? 0) }

    func start(minutes: Double) {
        stop(notify: false)
        total = minutes * 60
        endsAt = Date().addingTimeInterval(total)
        doneUntil = nil
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
        NotificationCenter.default.post(name: GlanceTimer.changed, object: nil)
    }

    func stop(notify: Bool = true) {
        tick?.invalidate(); tick = nil
        endsAt = nil; doneUntil = nil; total = 0
        if notify { NotificationCenter.default.post(name: GlanceTimer.changed, object: nil) }
    }

    private func step() {
        guard let end = endsAt else { return }
        if end.timeIntervalSinceNow <= 0 {
            tick?.invalidate(); tick = nil
            endsAt = nil
            doneUntil = Date().addingTimeInterval(60)
            NotificationCenter.default.post(name: GlanceTimer.fired, object: nil)
        }
        NotificationCenter.default.post(name: GlanceTimer.changed, object: nil)
    }

    // The Timer widget's reading: counting down, "Timer done" for a minute, or idle.
    func reading() -> Glance.Reading {
        if isRunning {
            let r = Int(remaining.rounded(.up))
            let text = r >= 3600 ? String(format: "%d:%02d:%02d", r / 3600, (r / 60) % 60, r % 60) : String(format: "%d:%02d", r / 60, r % 60)
            let t = Int(total)
            return Glance.Reading(widget: .timer, value: text, label: "Timer",
                                  detail: String(format: "of %d:%02d", t / 60, t % 60), fraction: total > 0 ? remaining / total : nil)
        }
        if isDone {
            return Glance.Reading(widget: .timer, value: Tokens.Copy.timerDone, label: "Timer", detail: nil, fraction: 1)
        }
        return Glance.Reading(widget: .timer, value: "", label: "Timer", idle: true)
    }
}
