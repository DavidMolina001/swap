import AppKit

// The glance bar: the strip of readings at the top of the panel, drawn to the approved design B
// (QA reports/Glance bar - 2026-11-01/mocks/Glance bar widgets - 2026-11-02.html). Every widget is a tinted
// tile with a white glyph, then the value (and at Regular and Detailed the label under it). Widgets sit at their
// natural width, spread edge to edge between iconInset and textInsetRight; when the gap between them would
// fall under the minimum, widgets are dropped from the end. The bar's height comes from the density alone.
final class GlanceBarView: NSView {
    let theme: Theme
    let density: Glance.Density
    // What is drawn right now: the readings that fit, in the user's order.
    private(set) var readings: [Glance.Reading] = []
    private var all: [Glance.Reading] = []   // the last readings given, before fitting
    // A cell never shrinks within a session, so a value going from "23%" to "9%" does not shuffle the row.
    private var sticky: [Glance.Widget: CGFloat] = [:]
    private var quotaNames = true   // Quota's service names under the figures; dropped first when the bar is short of room

    init(frame: NSRect, readings: [Glance.Reading], density: Glance.Density, theme: Theme) {
        self.theme = theme
        self.density = density
        super.init(frame: frame)
        update(readings)
    }
    required init?(coder: NSCoder) { fatalError() }

    // New readings: refit, redraw in place. No subviews, no layout pass, so nothing flickers.
    func update(_ new: [Glance.Reading]) {
        all = new
        let shown = new.filter { !$0.idle }
        for r in shown where r.widget != .quota {   // Quota's width depends on how much room is left, so it never sticks
            let w = GlanceBarView.naturalWidth(r, density: density, theme: theme)
            sticky[r.widget] = max(sticky[r.widget] ?? 0, w)
        }
        // Everything chosen should fit. Quota gives way first: its service names go, then it becomes one tile.
        func fitted(_ list: [Glance.Reading], names: Bool) -> [Glance.Reading] {
            GlanceBarView.fit(list, width: bounds.width, density: density) { [sticky] r in
                r.widget == .quota ? GlanceBarView.naturalWidth(r, density: self.density, theme: self.theme, names: names)
                    : (sticky[r.widget] ?? GlanceBarView.naturalWidth(r, density: self.density, theme: self.theme))
            }
        }
        let wanted = min(shown.count, Glance.maxWidgets)
        quotaNames = true
        readings = fitted(shown, names: true)
        if readings.count < wanted, let q = shown.firstIndex(where: { $0.parts != nil }) {
            quotaNames = false
            readings = fitted(shown, names: false)
            if readings.count < wanted || !readings.contains(where: { $0.widget == .quota }) {
                var narrow = shown; narrow[q].parts = nil
                readings = fitted(narrow, names: false)
            }
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        update(all)
    }

    // MARK: metrics (design B)

    private struct Metrics {
        let tile: CGFloat, glyph: CGFloat, radius: CGFloat, iconGap: CGFloat, minGap: CGFloat
        let valueFont: NSFont, valueLine: CGFloat, labelLine: CGFloat
    }

    private static func metrics(_ d: Glance.Density) -> Metrics {
        switch d {
        case .compact:
            return Metrics(tile: Tokens.Size.glanceTileCompact, glyph: Tokens.Size.glanceGlyphCompact, radius: Tokens.Radius.tileCompact,
                           iconGap: Tokens.Size.glanceIconGapCompact, minGap: Tokens.Size.glanceMinGapCompact,
                           valueFont: NSFont.monospacedDigitSystemFont(ofSize: Tokens.Font.glanceValueCompact.pointSize, weight: .medium),
                           valueLine: 14, labelLine: 0)
        case .regular:
            return Metrics(tile: Tokens.Size.glanceTile, glyph: Tokens.Size.glanceGlyph, radius: Tokens.Radius.tile,
                           iconGap: Tokens.Size.glanceIconGap, minGap: Tokens.Size.glanceMinGap,
                           valueFont: NSFont.monospacedDigitSystemFont(ofSize: Tokens.Font.glanceValue.pointSize, weight: .medium),
                           valueLine: 15, labelLine: 12)
        case .detailed:
            return Metrics(tile: Tokens.Size.glanceTile, glyph: Tokens.Size.glanceGlyph, radius: Tokens.Radius.tile,
                           iconGap: Tokens.Size.glanceIconGap, minGap: Tokens.Size.glanceMinGap,
                           valueFont: NSFont.monospacedDigitSystemFont(ofSize: Tokens.Font.glanceValue.pointSize, weight: .medium),
                           valueLine: 16, labelLine: 12)
        }
    }

    private static let labelFont = Tokens.Font.glanceLabel
    private static let markFont = NSFont.systemFont(ofSize: Tokens.Font.glanceLabel.pointSize, weight: .semibold)   // the "!" without colour

    // The value as drawn: "Timer done" is "Done" when the label "Timer" sits under it (as in the mock).
    private static func valueText(_ r: Glance.Reading, density: Glance.Density) -> String {
        if r.widget == .timer, r.value == Tokens.Copy.timerDone, density != .compact { return "Done" }
        return r.value
    }

    private static func valueFont(_ r: Glance.Reading, _ m: Metrics) -> NSFont {
        r.level == .none ? NSFont.monospacedDigitSystemFont(ofSize: m.valueFont.pointSize, weight: .regular) : m.valueFont
    }

    private static func marked(_ r: Glance.Reading, theme: Theme) -> Bool {
        theme.noColour && (r.level == .warning || r.level == .limit)
    }

    private static func labelText(_ r: Glance.Reading, density: Glance.Density, theme: Theme) -> NSAttributedString? {
        guard density != .compact else { return nil }
        let s = NSMutableAttributedString(string: r.label, attributes: [.font: labelFont, .foregroundColor: theme.color(Tokens.Color.secondary)])
        if density == .detailed, let d = r.detail, !d.isEmpty {
            s.append(NSAttributedString(string: " · " + d, attributes: [.font: labelFont, .foregroundColor: theme.color(Tokens.Color.tertiary)]))
        }
        return s
    }

    // Width of one widget at rest: tile, gap, then the widest of value, label line and (Detailed) the level bar slot.
    static func naturalWidth(_ r: Glance.Reading, density: Glance.Density, theme: Theme, names: Bool = true) -> CGFloat {
        let m = metrics(density)
        if let parts = r.parts, !parts.isEmpty { return ceil(partsWidth(parts, m, names: names && density != .compact)) }
        var text = (valueText(r, density: density) as NSString).size(withAttributes: [.font: valueFont(r, m)]).width
        if marked(r, theme: theme) { text += 2 + ("!" as NSString).size(withAttributes: [.font: markFont]).width }
        if let l = labelText(r, density: density, theme: theme) { text = max(text, l.size().width) }
        if density == .detailed { text = max(text, Tokens.Size.glanceLevelBarWidth) }
        return ceil(m.tile + m.iconGap + text)
    }

    // Which readings fit in a bar `width` wide (the panel's inner width: panel width minus 2 x panelPad), in order.
    // Idle readings are skipped. Settings uses this to say "x of y fit at your panel width".
    static func fitted(_ readings: [Glance.Reading], width: CGFloat, density: Glance.Density, theme: Theme) -> [Glance.Reading] {
        fit(readings.filter { !$0.idle }, width: width, density: density) { naturalWidth($0, density: density, theme: theme) }
    }

    private static func fit(_ readings: [Glance.Reading], width: CGFloat, density: Glance.Density,
                            widthOf: (Glance.Reading) -> CGFloat) -> [Glance.Reading] {
        let avail = width - Tokens.Size.iconInset - Tokens.Size.textInsetRight
        let minGap = metrics(density).minGap
        let widths = readings.map(widthOf)
        var n = min(readings.count, Glance.maxWidgets)
        func sum(_ k: Int) -> CGFloat { widths.prefix(k).reduce(0, +) }
        while n > 1, sum(n) + minGap * CGFloat(n - 1) > avail { n -= 1 }
        return Array(readings.prefix(n))
    }

    // Left edge of each drawn widget: spread edge to edge, a single widget stays on the left.
    private func origins() -> [CGFloat] {
        let widths = readings.map { $0.widget == .quota ? GlanceBarView.naturalWidth($0, density: density, theme: theme, names: quotaNames)
                                                    : (sticky[$0.widget] ?? GlanceBarView.naturalWidth($0, density: density, theme: theme)) }
        let left = Tokens.Size.iconInset, right = bounds.width - Tokens.Size.textInsetRight
        guard widths.count > 1 else { return widths.isEmpty ? [] : [left] }
        let gap = max(0, (right - left - widths.reduce(0, +)) / CGFloat(widths.count - 1))
        var x = left, out: [CGFloat] = []
        for w in widths { out.append(x); x += w + gap }
        return out
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        guard !readings.isEmpty else { return }
        let m = GlanceBarView.metrics(density)
        let midY = bounds.midY
        for (r, x) in zip(readings, origins()) {
            let t = theme
            if let parts = r.parts, !parts.isEmpty { drawParts(parts, at: x, midY: midY, m: m); continue }
            // Colours: identity from the tint; state recolours tile and value together.
            let stateColour: NSColor? = {
                switch r.level {
                case .warning: return t.color(Tokens.Color.glanceWarning)
                case .limit: return t.color(Tokens.Color.glanceLimit)
                case .none: return t.color(Tokens.Color.tertiary)
                case .normal: return nil
                }
            }()
            let tileColour = stateColour ?? t.color(r.widget.tint)
            let valueColour = stateColour ?? t.color(Tokens.Color.label)

            // Tile with its inset hairline, glyph centred.
            let tile = NSRect(x: x, y: midY - m.tile / 2, width: m.tile, height: m.tile)
            tileColour.setFill()
            NSBezierPath(roundedRect: tile, xRadius: m.radius, yRadius: m.radius).fill()
            let hair = NSBezierPath(roundedRect: tile.insetBy(dx: 0.25, dy: 0.25), xRadius: m.radius - 0.25, yRadius: m.radius - 0.25)
            hair.lineWidth = 0.5
            (t.contrast ? NSColor.black.withAlphaComponent(0.25) : t.color(Tokens.Color.tileHairline)).setStroke()
            hair.stroke()
            drawGlyph(r.widget, in: tile, size: m.glyph)

            // Text column.
            let tx = x + m.tile + m.iconGap
            let value = GlanceBarView.valueText(r, density: density) as NSString
            let vAttrs: [NSAttributedString.Key: Any] = [.font: GlanceBarView.valueFont(r, m), .foregroundColor: valueColour]
            let label = GlanceBarView.labelText(r, density: density, theme: t)
            let barH: CGFloat = density == .detailed ? Tokens.Size.glanceLevelBarGap + Tokens.Size.glanceLevelBar : 0
            let block = m.valueLine + m.labelLine + barH
            let top = midY + block / 2
            value.draw(with: NSRect(x: tx, y: top - m.valueLine, width: 400, height: m.valueLine), options: .usesLineFragmentOrigin, attributes: vAttrs)
            if GlanceBarView.marked(r, theme: t) {
                let vw = value.size(withAttributes: vAttrs).width
                ("!" as NSString).draw(with: NSRect(x: tx + vw + 2, y: top - m.valueLine + 1, width: 20, height: m.valueLine),
                                       options: .usesLineFragmentOrigin, attributes: [.font: GlanceBarView.markFont, .foregroundColor: valueColour])
            }
            if let label {
                label.draw(with: NSRect(x: tx, y: top - m.valueLine - m.labelLine, width: 400, height: m.labelLine), options: .usesLineFragmentOrigin)
            }
            if density == .detailed, let f = r.fraction {   // the slot stays empty without a fraction, so text lines up
                let bar = NSRect(x: tx, y: top - block, width: Tokens.Size.glanceLevelBarWidth, height: Tokens.Size.glanceLevelBar)
                let rad = Tokens.Size.glanceLevelBar / 2
                t.color(Tokens.Color.glanceTrack).setFill()
                NSBezierPath(roundedRect: bar, xRadius: rad, yRadius: rad).fill()
                let fill: NSColor = r.level == .none ? .clear
                    : (r.widget == .timer && r.value == Tokens.Copy.timerDone ? t.color(Tokens.Color.secondary) : tileColour)
                let w = bar.width * CGFloat(min(1, max(0, f)))
                if w > 0, fill != .clear {
                    fill.setFill()
                    NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(w, Tokens.Size.glanceLevelBar), height: bar.height),
                                 xRadius: rad, yRadius: rad).fill()
                }
            }
        }
    }

    // MARK: the Quota cell, as Quota's own menu bar draws it: each service's logo and figures, a thin bar between

    private static var logos: [String: NSImage] = [:]
    private static func logo(_ service: String) -> NSImage? {
        if let l = logos[service] { return l }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.quota.app"),
              let img = NSImage(contentsOf: app.appendingPathComponent("Contents/Resources/Logos/\(service).png")) else { return nil }
        logos[service] = img
        return img
    }
    private static let sepGap: CGFloat = 10
    // Each service sits like any other widget: its logo at tile size, the figures on the value line and, at Regular and
    // Detailed, its name under them, so the Quota cell lines up with CPU, Memory and the rest.
    private static func serviceName(_ s: String) -> String {
        switch s { case "claude": return "Claude"; case "codex": return "Codex"; case "antigravity": return "Antigravity"
        case "grok": return "Grok"; case "cursor": return "Cursor"; default: return s.capitalized }
    }
    private static func partWidth(_ p: Glance.QuotaPart, _ m: Metrics, names: Bool) -> CGFloat {
        var text = (p.text as NSString).size(withAttributes: [.font: m.valueFont]).width
        if names { text = max(text, (serviceName(p.service) as NSString).size(withAttributes: [.font: labelFont]).width) }
        return m.tile + m.iconGap + text
    }
    private static func partsWidth(_ parts: [Glance.QuotaPart], _ m: Metrics, names: Bool) -> CGFloat {
        parts.map { partWidth($0, m, names: names) }.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * (sepGap * 2 + 1)
    }
    private func drawParts(_ parts: [Glance.QuotaPart], at x0: CGFloat, midY: CGFloat, m: Metrics) {
        let barH: CGFloat = density == .detailed ? Tokens.Size.glanceLevelBarGap + Tokens.Size.glanceLevelBar : 0
        let block = m.valueLine + m.labelLine + barH
        let top = midY + block / 2
        var x = x0
        for (i, p) in parts.enumerated() {
            if i > 0 {
                x += GlanceBarView.sepGap
                theme.color(Tokens.Color.separator).setFill()
                NSRect(x: x, y: midY - m.tile / 2, width: 1, height: m.tile).fill()
                x += 1 + GlanceBarView.sepGap
            }
            let box = NSRect(x: x, y: midY - m.tile / 2, width: m.tile, height: m.tile)
            if let img = GlanceBarView.logo(p.service) {
                img.draw(in: box, from: .zero, operation: .sourceOver, fraction: p.muted ? 0.45 : 1)
            } else {   // Quota not installed here: the service's initial in a tile
                theme.color(Tokens.Color.tileQuota).setFill()
                NSBezierPath(roundedRect: box, xRadius: m.radius, yRadius: m.radius).fill()
                let ch = String(p.service.prefix(1)).uppercased() as NSString
                let f = NSFont.systemFont(ofSize: m.tile * 0.55, weight: .bold)
                let cs = ch.size(withAttributes: [.font: f])
                ch.draw(at: NSPoint(x: box.midX - cs.width / 2, y: box.midY - cs.height / 2), withAttributes: [.font: f, .foregroundColor: theme.color(Tokens.Color.tileGlyph)])
            }
            let tx = x + m.tile + m.iconGap
            let colour: NSColor = p.muted ? theme.color(Tokens.Color.tertiary)
                : p.level == .limit ? theme.color(Tokens.Color.glanceLimit)
                : p.level == .warning ? theme.color(Tokens.Color.glanceWarning) : theme.color(Tokens.Color.label)
            let names = quotaNames && density != .compact
            let valueTop = names ? top : midY + m.valueLine / 2
            (p.text as NSString).draw(with: NSRect(x: tx, y: valueTop - m.valueLine, width: 400, height: m.valueLine), options: .usesLineFragmentOrigin,
                                      attributes: [.font: m.valueFont, .foregroundColor: colour])
            if names {
                (GlanceBarView.serviceName(p.service) as NSString).draw(with: NSRect(x: tx, y: top - m.valueLine - m.labelLine, width: 400, height: m.labelLine),
                    options: .usesLineFragmentOrigin, attributes: [.font: GlanceBarView.labelFont, .foregroundColor: theme.color(Tokens.Color.secondary)])
            }
            x += GlanceBarView.partWidth(p, m, names: names)
        }
    }

    // White SF Symbol in the tile; GPU has none, so a chip is drawn: a card with a fan and three pins (as in the mock).
    private func drawGlyph(_ w: Glance.Widget, in tile: NSRect, size: CGFloat) {
        let white = theme.color(Tokens.Color.tileGlyph)
        if let name = w.symbol,
           let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) {
            let g = img.tinted(white)
            g.draw(in: NSRect(x: tile.midX - g.size.width / 2, y: tile.midY - g.size.height / 2, width: g.size.width, height: g.size.height))
            return
        }
        // Chip, laid out on a 12 pt grid and scaled to the glyph size.
        let s = size / 12
        let ox = tile.midX - 6 * s, oy = tile.midY - 6 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + y * s) }
        white.setStroke()
        let card = NSBezierPath(roundedRect: NSRect(x: ox + 1.7 * s, y: oy + 2.8 * s, width: 8.6 * s, height: 7.5 * s), xRadius: 1.4 * s, yRadius: 1.4 * s)
        card.lineWidth = 1.3 * s
        card.stroke()
        let fan = NSBezierPath(ovalIn: NSRect(x: ox + (6 - 1.8) * s, y: oy + (6.55 - 1.8) * s, width: 3.6 * s, height: 3.6 * s))
        fan.lineWidth = 1.2 * s
        fan.stroke()
        let pins = NSBezierPath()
        pins.lineWidth = 1.2 * s
        pins.lineCapStyle = .round
        for px: CGFloat in [3.56, 6, 8.44] { pins.move(to: p(px, 2.8)); pins.line(to: p(px, 1.2)) }
        pins.stroke()
    }

    // MARK: accessibility: one group, read as a sentence

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "At a glance" }
    override func accessibilityValue() -> Any? { GlanceBarView.spoken(readings) }

    static func spoken(_ readings: [Glance.Reading]) -> String {
        readings.map { r -> String in
            let v = r.value.replacingOccurrences(of: " · ", with: ", ").replacingOccurrences(of: "%", with: " percent")
                .replacingOccurrences(of: "↓ ", with: "down ").replacingOccurrences(of: "↑ ", with: "up ")
            if let parts = r.parts, !parts.isEmpty {
                return "Quota " + parts.map { "\($0.service) \($0.text.replacingOccurrences(of: " · ", with: " and ").replacingOccurrences(of: "%", with: " percent"))" }.joined(separator: ", ")
            }
            return r.widget == .timer && r.value == Tokens.Copy.timerDone ? v : "\(r.label) \(v)"
        }.joined(separator: ", ")
    }
}
