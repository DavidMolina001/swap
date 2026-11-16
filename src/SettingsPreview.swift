import AppKit
import SwiftUI

// The Settings window's live preview, in the Appearance and Glance bar panes: a picture of the real panel on
// the blue desktop. It rests on the list as your settings draw it. Pointing at a row or changing it plays that
// setting once, then it rests again: nothing here ever loops. The stage stays AppKit (it draws a real
// SwitcherView); SwiftUI only hosts it.

// The preview stage: the blue desktop gradient, the panel picture at 72 percent, a caption pill bottom-left.
final class PreviewStage: NSView {
    static let zoom: CGFloat = 0.72
    private let gradient = CAGradientLayer()
    private let imageView = NSImageView()
    private let pill = NSView()
    private let caption = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        gradient.colors = [NSColor(srgbRed: 90/255, green: 169/255, blue: 255/255, alpha: 1).cgColor,
                           NSColor(srgbRed: 59/255, green: 126/255, blue: 224/255, alpha: 1).cgColor,
                           NSColor(srgbRed: 45/255, green: 99/255, blue: 184/255, alpha: 1).cgColor]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0.33, y: 1)
        gradient.endPoint = CGPoint(x: 0.67, y: 0)
        layer?.addSublayer(gradient)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        imageView.shadow = shadow
        addSubview(imageView)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        pill.layer?.cornerRadius = 6
        caption.font = NSFont.systemFont(ofSize: 11.5)
        caption.textColor = .white
        caption.lineBreakMode = .byTruncatingTail
        pill.addSubview(caption)
        addSubview(pill)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Preview of the list")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        place()
    }

    func show(_ image: NSImage, caption text: String) {
        imageView.image = image
        caption.stringValue = text
        setAccessibilityValue(text)
        place()
    }

    private func place() {
        guard bounds.width > 0 else { return }
        if let img = imageView.image {
            var size = NSSize(width: img.size.width * PreviewStage.zoom, height: img.size.height * PreviewStage.zoom)
            let maxH = bounds.height - 44, maxW = bounds.width - 24
            let k = min(1, maxH / max(1, size.height), maxW / max(1, size.width))
            size = NSSize(width: size.width * k, height: size.height * k)
            imageView.frame = NSRect(x: round(bounds.midX - size.width / 2), y: round(bounds.midY - size.height / 2 + 8), width: size.width, height: size.height)
        }
        caption.sizeToFit()
        let cs = caption.frame.size
        let w = min(cs.width + 16, bounds.width - 28)
        pill.frame = NSRect(x: 14, y: 10, width: w, height: cs.height + 8)
        caption.frame = NSRect(x: 8, y: 4, width: w - 16, height: cs.height)
    }
}

// One picture of the panel for the preview: fake rows, optional header and bar, and the settings the frame
// needs that differ from the user's own (nil = use the user's value).
struct PreviewScene {
    var items: [WindowItem]
    var header: SwitcherView.Header?
    var glance: [Glance.Reading]? = nil
    var dark: Bool? = nil
    var dots: Settings.Dots? = nil
    var appName: Bool? = nil
    var width: Settings.Width? = nil
    var density: Glance.Density? = nil
    var caption: String? = nil   // nil: keep the caption showing
}

enum PreviewRenderer {
    // Draws a real SwitcherView offscreen (solid background, no window) into a picture at the screen's scale.
    static func render(_ s: PreviewScene) -> NSImage {
        let d = UserDefaults.standard
        var saved: [String: Any?] = [:]
        func override(_ key: String, _ value: Any?) {
            guard let value else { return }
            saved[key] = .some(d.object(forKey: key))
            d.set(value, forKey: key)
        }
        override("appearance", s.dark.map { $0 ? Settings.Appearance.dark.rawValue : Settings.Appearance.light.rawValue })
        override("pageDots", s.dots?.rawValue)
        override("showAppName", s.appName)
        override("panelWidth", s.width?.rawValue)
        override("glanceDensity", s.density?.rawValue)
        override("hintShows", Tokens.Copy.hintShows)   // never the "swipe" hint in the preview
        defer {
            for (k, v) in saved {
                if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
            }
        }
        let view = SwitcherView(items: s.items, selected: 0, screen: nil, solidBackground: true, header: s.header, glance: s.glance,
                                searchRow: Settings.searchRow)
        let theme = view.theme
        let b = view.bounds
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard b.width > 0, b.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = b.size
        view.cacheDisplay(in: b, to: rep)
        let r = Tokens.Size.panelRadius
        return NSImage(size: b.size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).addClip()
            theme.color(Tokens.Color.panelSolid).setFill()
            rect.fill()
            rep.draw(in: rect)
            theme.rim.setStroke()
            let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
            rim.lineWidth = 1
            rim.stroke()
            return true
        }
    }
}

// Hosts the AppKit stage in a SwiftUI pane.
struct PreviewStageView: NSViewRepresentable {
    let stage: PreviewStage
    func makeNSView(context: Context) -> PreviewStage { stage }
    func updateNSView(_ nsView: PreviewStage, context: Context) {}
}

// Plays the demos on one stage. Each pane with a preview owns one, kept alive by the pane.
final class PanelPreview: ObservableObject {
    private struct Demo {
        let caption: String
        let frames: [PreviewScene]
    }

    let stage = PreviewStage()
    private var ticker: Timer?
    private var step = 0
    private var currentCaption = ""
    private var hovered: String?
    private var playingName: String?
    private var onScreen = false

    deinit { ticker?.invalidate() }

    func appeared() {
        onScreen = true
        rest()
    }
    func disappeared() {
        onScreen = false
        stop()
    }

    func hover(_ name: String, _ inside: Bool) {
        if inside {
            hovered = name
            if playingName != name { play(name) }
        } else if hovered == name {
            hovered = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in   // moving to the next row is not leaving
                guard let self, self.hovered == nil, self.onScreen else { return }
                self.rest()
            }
        }
    }

    // Wraps a setter so the preview plays that setting after a change.
    func mark<T>(_ name: String, _ set: @escaping (T) -> Void) -> (T) -> Void {
        return { [weak self] v in
            set(v)
            self?.changed(name)
        }
    }
    func changed(_ name: String) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { rest() } else { play(name) }
    }

    // MARK: playing

    private func stop() {
        ticker?.invalidate(); ticker = nil
        playingName = nil
    }

    // The list as the user's own settings draw it: where the preview stays unless a demo is playing.
    private func rest() {
        stop()
        guard onScreen else { return }
        var s = PreviewScene(items: PanelPreview.rows(0..<3), header: PanelPreview.header("Desktop 1", 0, 3))
        if Settings.desktops == .flat { s.items = PanelPreview.rows(Array(PanelPreview.apps.prefix(3)), desktops: true); s.header = nil }
        if Settings.glanceBar, !Settings.glanceWidgetList.isEmpty { s.glance = Glance.samples(Settings.glanceWidgetList) }
        stage.show(PreviewRenderer.render(s), caption: "Your list")
    }

    // Once through, then back to rest. With Reduce Motion, only the last frame, until the pointer leaves.
    private func play(_ name: String) {
        guard let demo = PanelPreview.demos[name] else { return }
        ticker?.invalidate(); ticker = nil
        playingName = name
        step = 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            currentCaption = demo.caption
            for f in demo.frames { if let c = f.caption { currentCaption = c } }
            stage.show(PreviewRenderer.render(demo.frames[demo.frames.count - 1]), caption: currentCaption)
            return
        }
        show(demo, frame: 0)
        ticker = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.step += 1
            if self.step < demo.frames.count {
                self.show(demo, frame: self.step)
            } else {
                timer.invalidate(); self.ticker = nil
                let keep = self.playingName   // still set, so the row under the pointer does not start again
                self.rest()
                self.playingName = keep
            }
        }
    }

    private func show(_ demo: Demo, frame i: Int) {
        let s = demo.frames[i]
        currentCaption = s.caption ?? (i == 0 ? demo.caption : currentCaption)
        stage.show(PreviewRenderer.render(s), caption: currentCaption)
    }

    // MARK: the demos (same scripts as the approved mock, part 3)

    private static let apps: [(name: String, hex: UInt32, title: String)] = [
        ("Safari", 0x2f8ef5, "Quarterly numbers - Google Sheets"), ("Mail", 0x3b82f6, "Inbox"), ("Notes", 0xf5c242, "Shopping"),
        ("Xcode", 0x1a6ef5, "Panel.swift"), ("Finder", 0x3d9bf0, "Downloads"),
    ]
    private static let longApps: [(name: String, hex: UInt32, title: String)] = [
        ("Safari", 0x2f8ef5, "A very long browser tab title that goes on and on and on - The Guardian"), ("Mail", 0x3b82f6, "Re: Your order"),
    ]

    // The app's real icon when it is on this Mac, like the list itself; a coloured square when it is not.
    private static func icon(_ name: String, _ hex: UInt32) -> NSImage {
        for folder in ["/Applications", "/System/Applications", "/System/Library/CoreServices"] {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        let c = NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        return NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            c.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
            return true
        }
    }

    private static func rows(_ list: [(name: String, hex: UInt32, title: String)], desktops: Bool = false) -> [WindowItem] {
        list.enumerated().map { i, a in
            WindowItem(app: nil, window: nil, id: 0, title: a.title, appName: a.name, icon: icon(a.name, a.hex), minimized: false,
                       desktop: desktops && i % 3 != 0 ? "Desktop \(1 + i % 3)" : nil)
        }
    }
    private static func rows(_ range: Range<Int>) -> [WindowItem] { rows(Array(apps[range])) }

    private static func header(_ title: String, _ index: Int, _ count: Int, hint: String? = nil) -> SwitcherView.Header {
        SwitcherView.Header(title: title, index: index, count: count, emptyHint: hint)
    }

    private static let demos: [String: Demo] = {
        typealias S = PreviewScene
        let bar: [Glance.Widget] = [.cpu, .memory, .gpu, .quota]
        let base = S(items: PanelPreview.rows(0..<3), header: PanelPreview.header("Desktop 1", 0, 3))
        func with(_ s: S, _ f: (inout S) -> Void) -> S { var c = s; f(&c); return c }
        func bars(_ w: [Glance.Widget], _ cap: String? = nil, density: Glance.Density? = nil) -> S {
            with(base) { $0.glance = Glance.samples(w); $0.caption = cap; $0.density = density }
        }
        var quotaPill = Glance.sample(.quota); quotaPill.value = "C 42% · O 9%"
        var timerLow = Glance.sample(.timer); timerLow.value = "00:03"; timerLow.fraction = 0.002
        var timerDone = Glance.sample(.timer); timerDone.value = Tokens.Copy.timerDone; timerDone.detail = nil; timerDone.fraction = 1
        let timerBase = Glance.samples([.cpu, .memory, .timer])
        let timerCap = "Timer: 18:42 left, counting down"
        let widthCap = "List width: same size on Desktop 1 and Desktop 2"
        // Theme: everything a theme colours in one picture: the selected row, unread dots on a row and a chat, the tiles.
        func app(_ id: CGWindowID, _ name: String, _ hex: UInt32, _ title: String) -> WindowItem {
            WindowItem(app: nil, window: nil, id: id, title: title, appName: name, icon: PanelPreview.icon(name, hex), minimized: false)
        }
        var slack = app(1, "Slack", 0x4a154b, "Acme"); slack.expandable = true; slack.dot = true
        var whatsApp = app(2, "WhatsApp", 0x25d366, "WhatsApp"); whatsApp.expandable = true; whatsApp.expanded = true; whatsApp.dot = true
        let chats = [("Family", 2), ("Five-a-side", 0)].map { chat in
            WindowItem(app: nil, window: nil, id: whatsApp.id, title: chat.0, appName: whatsApp.appName, icon: whatsApp.icon, minimized: false,
                       depth: 1, child: ChildItem(id: chat.0, title: chat.0, detail: "", icon: nil, active: false, unread: chat.1), parentKey: whatsApp.key)
        }
        let themeScene = S(items: [slack, whatsApp] + chats, header: PanelPreview.header("Desktop 1", 0, 3), glance: Glance.samples(bar))

        return [
            "theme": Demo(caption: "Theme: selected row, unread dots and Glance bar tiles", frames: [themeScene]),
            "show": Demo(caption: "Show glance bar: off leaves the list as it is", frames: [
                base,
                bars(bar, "On: readings appear above the list, taken only while it is open"),
            ]),
            "density": Demo(caption: "Density: Regular, with labels", frames: [
                bars(bar, nil, density: .regular),
                bars(bar, "Compact: icon and value only", density: .compact),
                bars(bar, "Detailed: adds a level bar and a second line", density: .detailed),
            ]),
            "widgets": Demo(caption: "Widgets: switch them on in your order, up to 6", frames: [
                bars([.cpu]), bars([.cpu, .memory]), bars([.cpu, .memory, .gpu]), bars([.cpu, .memory, .gpu, .quota]),
                bars([.cpu, .memory, .gpu, .quota, .network, .timer], "Six on: the seventh would be dropped and Settings says so"),
            ]),
            "idle": Demo(caption: "Idle widgets: a timer that is running shows", frames: [
                bars([.cpu, .memory, .timer, .quota]),
                bars([.cpu, .memory, .quota], "Timer stopped: its cell hides, the others spread out, same height"),
            ]),
            "quota": Demo(caption: "Quota widget: tightest limit, e.g. 42% 5h", frames: [
                bars(bar),
                with(base) { $0.glance = [Glance.sample(.cpu), Glance.sample(.memory), Glance.sample(.gpu), quotaPill]; $0.caption = "Quota's own menu bar text, when it fits" },
                bars(bar, "Detailed density: full text and the next reset", density: .detailed),
            ]),
            "timer": Demo(caption: timerCap, frames: [
                with(base) { $0.glance = timerBase },
                with(base) { $0.glance = [Glance.sample(.cpu), Glance.sample(.memory), timerLow] },
                with(base) { $0.glance = [Glance.sample(.cpu), Glance.sample(.memory), timerDone]; $0.caption = "At zero: alert sound, menu bar icon flashes, \"Timer done\" for a minute" },
                with(base) { $0.glance = timerBase; $0.caption = timerCap },
            ]),
            "appearance": Demo(caption: "Appearance: follows the system, or your pick", frames: [
                with(base) { $0.dark = false },
                with(base) { $0.dark = true },
            ]),
            "width": Demo(caption: widthCap, frames: [
                with(base) { $0.header = PanelPreview.header("Desktop 1", 0, 2); $0.width = .fixed },
                S(items: PanelPreview.rows(PanelPreview.longApps), header: PanelPreview.header("Desktop 2", 1, 2), width: .fixed),
                with(base) { $0.header = PanelPreview.header("Desktop 1", 0, 2); $0.width = .fit; $0.caption = "Fit the longest name: as narrow as Desktop 1 needs" },
                S(items: PanelPreview.rows(PanelPreview.longApps), header: PanelPreview.header("Desktop 2", 1, 2), width: .fit,
                  caption: "Fit the longest name: the panel grows on Desktop 2"),
            ]),
            "dots": Demo(caption: "Page dots, compact: 5 at most, current one in the middle", frames: [
                S(items: PanelPreview.rows(0..<2), header: PanelPreview.header("Desktop 3", 2, 8), dots: .compact),
                S(items: PanelPreview.rows(1..<4), header: PanelPreview.header("Desktop 4", 3, 8), dots: .compact),
                S(items: PanelPreview.rows(2..<5), header: PanelPreview.header("Desktop 5", 4, 8), dots: .compact),
                S(items: PanelPreview.rows(2..<5), header: PanelPreview.header("Desktop 5", 4, 8), dots: .all, caption: "One dot per desktop: all 8 shown"),
            ]),
            "hideEmpty": Demo(caption: "Off: Desktop 2 is empty but still shown", frames: [
                S(items: PanelPreview.rows(0..<2), header: PanelPreview.header("Desktop 1", 0, 3)),
                S(items: [], header: PanelPreview.header("Desktop 2", 1, 3, hint: String(format: Tokens.Copy.emptyHintRight, "Desktop 3"))),
                S(items: PanelPreview.rows(2..<5), header: PanelPreview.header("Desktop 3", 2, 3)),
                S(items: PanelPreview.rows(0..<2), header: PanelPreview.header("Desktop 1", 0, 2), caption: "On: Desktop 2 skipped, Desktop 3 keeps its number"),
                S(items: PanelPreview.rows(2..<5), header: PanelPreview.header("Desktop 3", 1, 2)),
            ]),
            "appName": Demo(caption: "App name on the right: on", frames: [
                S(items: PanelPreview.rows(0..<4), header: base.header, appName: true),
                S(items: PanelPreview.rows(0..<4), header: base.header, appName: false, caption: "App name on the right: off"),
            ]),
            "desktops": Demo(caption: "One page per desktop: Left and Right change desktop", frames: [
                S(items: PanelPreview.rows(0..<2), header: PanelPreview.header("Desktop 1", 0, 3)),
                S(items: PanelPreview.rows(2..<4), header: PanelPreview.header("Desktop 2", 1, 3)),
                S(items: PanelPreview.rows(PanelPreview.apps, desktops: true), header: nil, appName: true,
                  caption: "All desktops in one list, most recent first"),
            ]),
            "animations": Demo(caption: "Off: the list appears at once. On: fades in on the first open", frames: [base]),
        ]
    }()
}
