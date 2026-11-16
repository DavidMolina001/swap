import AppKit

// How the panel looks right now: dark or light, the accessibility switches, and the size class.
// Every value comes from design/tokens.json through Tokens.swift.
struct Theme {
    let dark: Bool
    let contrast: Bool          // Increase Contrast
    let solid: Bool             // Reduce Transparency, or an offscreen render
    let noColour: Bool          // Differentiate Without Colour
    let large: Bool             // a 27 inch class screen: slightly bigger rows and text
    let blackInk: Bool          // the accent colour is too light for white text on the selected row
    let palette: Palette        // the colour theme picked in Settings (tokens.json "themes")

    init(screen: NSScreen?, solid: Bool = false) {
        let ws = NSWorkspace.shared
        dark = Settings.isDark
        palette = Settings.palette
        var contrast = ws.accessibilityDisplayShouldIncreaseContrast
        #if SELFTEST
        if ProcessInfo.processInfo.environment["SWAP_CONTRAST"] == "1" { contrast = true }   // QA renders: no system setting changed
        #endif
        self.contrast = contrast
        self.solid = solid || ws.accessibilityDisplayShouldReduceTransparency
        noColour = ws.accessibilityDisplayShouldDifferentiateWithoutColor
        large = (screen?.frame.width ?? 1440) >= Tokens.Size.largeScreenWidth
        blackInk = Theme.needsBlackInk(accent: NSColor.controlAccentColor, alpha: contrast ? 1 : 0.9,
                                       over: dark ? Tokens.Color.panelSolid.dark : Tokens.Color.panelSolid.light)
    }

    static func luminance(_ c: NSColor) -> CGFloat {
        guard let c = c.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    // White stays unless it would drop below 3:1 on the accent colour. The macOS blue, pink, red and purple sit at 3.3 to
    // 4.7:1 and white is what the system draws on them; yellow, orange and green fall to 1.5 to 2.6:1 and get black,
    // which reaches 8:1 or more there. Measured on the accent over the solid panel, the closest fixed stand-in for the blur.
    static func needsBlackInk(accent: NSColor, alpha: CGFloat, over panel: NSColor) -> Bool {
        guard let a = accent.usingColorSpace(.sRGB), let p = panel.usingColorSpace(.sRGB) else { return false }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func mixed(_ c: CGFloat, _ under: CGFloat) -> CGFloat { linear(c * alpha + under * (1 - alpha)) }
        let luminance = 0.2126 * mixed(a.redComponent, p.redComponent) + 0.7152 * mixed(a.greenComponent, p.greenComponent)
            + 0.0722 * mixed(a.blueComponent, p.blueComponent)
        return 1.05 / (luminance + 0.05) < 3
    }

    // A theme replaces some colours by token name. Its selected-row text is set per theme (measured to 4.5:1 or more),
    // so the black ink rule only applies to the System theme. With Increase Contrast the app name on a themed
    // selection takes the full title colour.
    func color(_ shade: Shade) -> NSColor {
        if let own = palette.colors[shade.key] {
            if contrast, shade.key == Tokens.Color.selectionSub.key, let text = palette.colors[Tokens.Color.selectionText.key] { return text(dark) }
            return own(dark)
        }
        if shade.onAccent, blackInk { return NSColor.black.withAlphaComponent(shade(dark).alphaComponent) }
        return contrast ? shade.contrast(dark) : shade(dark)
    }
    var themed: Bool { palette.colors[Tokens.Color.selection.key] != nil }
    var rowHeight: CGFloat { large ? Tokens.Size.rowHeightLarge : Tokens.Size.rowHeight }
    var icon: CGFloat { large ? Tokens.Size.iconLarge : Tokens.Size.icon }
    var titleFont: NSFont { large ? Tokens.Font.titleLarge : Tokens.Font.title }
    var titleSelectedFont: NSFont { large ? NSFont.systemFont(ofSize: Tokens.Font.titleLarge.pointSize, weight: .medium) : Tokens.Font.titleSelected }
    var selection: NSColor {
        if themed { return color(Tokens.Color.selection).withAlphaComponent(1) }
        return contrast ? NSColor.controlAccentColor : color(Tokens.Color.selection)
    }
    // Right inset of a row's text: rows keep the stripe tail clear while the theme has one, selected or not, so nothing shifts.
    var rowTrailing: CGFloat { palette.tail ? Tokens.Size.stripeTailReserve : Tokens.Size.textInsetRight }
    // Extra room at the top of the panel for the stripe band.
    var bandRoom: CGFloat { palette.band ? Tokens.Size.stripeBand + Tokens.Size.stripeBandGap : 0 }

    // The selected row's fill. With Increase Contrast a theme's selection that is under 3:1 on the panel (the pastel ones
    // in light mode) gets an edge, since its colour alone barely tells it from the panel. `tail` adds the theme's stripes.
    func drawSelection(in row: NSRect, tail: Bool) {
        let rect = row.insetBy(dx: Tokens.Size.selectionInsetX, dy: Tokens.Size.selectionInsetY)
        let shape = NSBezierPath(roundedRect: rect, xRadius: Tokens.Radius.selection, yRadius: Tokens.Radius.selection)
        selection.setFill()
        shape.fill()
        if tail, palette.tail, palette.stripes.count > 1 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let colours = palette.stripes.dropFirst().map { $0(dark) }   // stripe 1 is the selection colour
            let w = Tokens.Size.stripeTail, lean = Tokens.Size.stripeTailSlant
            for (i, c) in colours.enumerated() {
                let left = rect.maxX - CGFloat(colours.count - i) * w
                let right = i == colours.count - 1 ? rect.maxX + lean + 1 : left + w   // the last one runs off the edge
                let p = NSBezierPath()
                p.move(to: NSPoint(x: left, y: rect.minY))
                p.line(to: NSPoint(x: right, y: rect.minY))
                p.line(to: NSPoint(x: right - lean, y: rect.maxY))
                p.line(to: NSPoint(x: left - lean, y: rect.maxY))
                p.close()
                c.setFill()
                p.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if contrast, themed {
            let panel = color(Tokens.Color.panelSolid), l1 = Theme.luminance(selection), l2 = Theme.luminance(panel)
            if (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05) < 3 {
                let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Tokens.Radius.selection - 0.5, yRadius: Tokens.Radius.selection - 0.5)
                edge.lineWidth = 1
                color(Tokens.Color.label).withAlphaComponent(0.6).setStroke()
                edge.stroke()
            }
        }
        if noColour {   // a bar at the left edge marks the selection for people who turn colour cues off
            color(Tokens.Color.selectionText).setFill()
            NSBezierPath(roundedRect: NSRect(x: row.minX + 4, y: row.minY + 8, width: Tokens.Size.selectionBar, height: row.height - 16),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
    var separator: NSColor { contrast ? color(Tokens.Color.separator).withAlphaComponent(0.25) : color(Tokens.Color.separator) }
    var rim: NSColor { contrast ? color(Tokens.Color.rimContrast) : color(Tokens.Color.rimInner) }
    var textStart: CGFloat { Tokens.Size.iconInset + icon + Tokens.Size.iconGap }
}

private func para(_ alignment: NSTextAlignment = .left) -> NSMutableParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = .byTruncatingTail
    p.alignment = alignment
    return p
}

// The rows: app icon, window title, app name (or a "Minimised" capsule) on the right, the selected row on
// a solid accent fill. Shows up to 14 rows and scrolls to keep the selection in view, with a fade at the
// edge that has more rows and a "N more" footer. For the first few opens the footer also teaches the keys.
final class RowsView: NSView {
    let theme: Theme
    let items: [WindowItem]
    let visibleRows: Int
    let emptyHint: String?
    let emptyText: String?              // search: says so when nothing matched, in place of the empty-desktop line
    private(set) var selected: Int      // -1: nothing here, the search row has the selection
    private(set) var first = 0          // index of the top visible row
    private var hover: Int?
    private let fadeMask = CAGradientLayer()
    private let keyHint: Bool
    private let accessoryColumn: CGFloat // the same right-hand column on every row while any row has a chevron or pin
    var onClick: ((Int) -> Void)?
    var onChevron: ((Int) -> Void)?     // nil: the chevron clicks like the rest of the row

    var rowHeight: CGFloat { theme.rowHeight }
    var hasOverflow: Bool { items.count > visibleRows }
    var hasFooter: Bool { hasOverflow || keyHint }

    init(frame: NSRect, items: [WindowItem], selected: Int, visibleRows: Int, theme: Theme, emptyHint: String? = nil, emptyText: String? = nil,
         keyHint: Bool = false) {
        self.items = items
        self.selected = selected
        self.visibleRows = visibleRows
        self.theme = theme
        self.emptyHint = emptyHint
        self.emptyText = emptyText
        self.keyHint = keyHint && !items.isEmpty
        accessoryColumn = items.contains { $0.expandable || $0.depth > 0 } ? Tokens.Size.accessoryColumn : 0
        super.init(frame: frame)
        if !theme.solid { wantsLayer = true }
        scrollToSelection()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = row(at: p) else { return }
        // The chevron is a disclosure triangle: it opens or folds the row, the rest of the row switches.
        let chevronZone = Tokens.Size.chevronHit + theme.rowTrailing - Tokens.Size.textInsetRight   // follows the chevron left of a stripe tail
        if items[i].expandable, let onChevron, p.x >= bounds.maxX - chevronZone { onChevron(i); return }
        onClick?(i)
    }
    override func mouseMoved(with event: NSEvent) {
        let h = row(at: convert(event.locationInWindow, from: nil))
        if h != hover { hover = h; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { if hover != nil { hover = nil; needsDisplay = true } }

    private func row(at p: NSPoint) -> Int? {
        (first..<min(items.count, first + visibleRows)).first { rowRect($0)?.contains(p) == true }
    }

    func select(_ index: Int) {
        selected = index
        scrollToSelection()
        needsDisplay = true
        Announce.say(selectionSpoken)
    }

    private func scrollToSelection() {
        if selected < first { first = max(0, selected) }
        if selected >= first + visibleRows { first = selected - visibleRows + 1 }
        updateFade()
    }

    // The list fades out where it continues. Over the blur this has to be a mask: a painted colour cannot match what is
    // behind the panel and shows as a box. Solid panels have one colour, and offscreen renders ignore masks, so they
    // keep the painted fade in drawFades.
    private func updateFade() {
        guard !theme.solid, let layer else { return }
        let more = (above: first > 0, below: first + visibleRows < items.count)
        guard more.above || more.below, bounds.height > 0 else { if layer.mask != nil { layer.mask = nil }; return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = Float(bounds.height), fade = Float(Tokens.Size.fadeHeight) / height, floor = Float(hasFooter ? Tokens.Size.footerHeight : 0) / height
        let solid = NSColor.black.cgColor, faint = NSColor.black.withAlphaComponent(0.15).cgColor
        fadeMask.frame = bounds
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)   // the bottom edge: layers here have their origin there
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        // The footer below `floor` stays solid; only the rows fade.
        fadeMask.locations = [0, floor, floor, floor + fade, 1 - fade, 1].map { NSNumber(value: $0) }
        fadeMask.colors = [solid, solid, more.below ? faint : solid, solid, solid, more.above ? faint : solid]
        layer.mask = fadeMask
        CATransaction.commit()
    }

    // Frame of row `index` in this view, or nil when it is scrolled out of view.
    func rowRect(_ index: Int) -> NSRect? {
        let r = index - first
        guard r >= 0, r < visibleRows, index < items.count else { return nil }
        return NSRect(x: 0, y: bounds.height - CGFloat(r + 1) * rowHeight, width: bounds.width, height: rowHeight)
    }

    // What a screen reader says for a row.
    func spoken(_ index: Int) -> String {
        guard items.indices.contains(index) else { return "" }
        let item = items[index]
        if let kid = item.child {
            var s = kid.title
            if !kid.detail.isEmpty { s += ", \(kid.detail)" }
            if kid.unread > 0 { s += ", unread" }
            if item.pinned { s += ", pinned" }
            if kid.isGroup { s += ", press Return to expand" }
            return s + ", inside \(item.appName)"
        }
        var s = item.label
        if !item.title.isEmpty, !sameAsApp(item) { s += ", \(item.appName)" }
        if let profile = item.profile { s += ", \(profile) profile" }
        if let desktop = item.desktop { s += ", \(desktop)" }
        if item.dot { s += ", unread" }
        if item.minimized { s += ", \(Tokens.Copy.minimised.lowercased())" }
        if item.expandable { s += item.expanded ? ", expanded" : ", press Return to expand" }
        return s
    }

    // What VoiceOver hears for where the selection is now, which on screen is only a colour.
    var selectionSpoken: String {
        if items.isEmpty { return emptyText ?? Tokens.Copy.empty }
        guard items.indices.contains(selected) else { return "\(Tokens.Copy.searchPlaceholder), search" }
        return "\(spoken(selected)), \(selected + 1) of \(items.count)"
    }

    private func sameAsApp(_ item: WindowItem) -> Bool {
        item.title.isEmpty || item.title == item.appName || item.title.hasSuffix(item.appName)
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        let t = theme
        if items.isEmpty { drawEmpty(); return }
        let last = min(items.count, first + visibleRows)
        for i in first..<last {
            guard let row = rowRect(i) else { continue }
            let item = items[i]
            let isSel = i == selected
            if isSel {
                t.drawSelection(in: row, tail: true)
            } else if i == hover {
                t.color(Tokens.Color.hover).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: Tokens.Size.selectionInsetX, dy: Tokens.Size.selectionInsetY),
                             xRadius: Tokens.Radius.hover, yRadius: Tokens.Radius.hover).fill()
            }
            // A child row (a tab, a chat) sits indented under its window with a smaller icon.
            let indent = CGFloat(item.depth) * Tokens.Size.childIndent
            let s = item.child == nil ? t.icon : Tokens.Size.childIcon
            if item.dot || (item.child?.unread ?? 0) > 0 {   // unread: a small dot before the icon, like Slack's sidebar
                (isSel ? t.color(Tokens.Color.selectionText) : t.color(Tokens.Color.unreadDot)).setFill()
                NSBezierPath(ovalIn: NSRect(x: row.minX + indent + 2, y: row.midY - 3.5, width: 7, height: 7)).fill()
            }
            let slot = item.child == nil ? 0 : (t.icon - s) / 2   // the small icon sits in the middle of the normal icon's slot
            item.icon.draw(in: NSRect(x: row.minX + Tokens.Size.iconInset + indent + slot, y: row.midY - s / 2, width: s, height: s),
                           from: .zero, operation: .sourceOver, fraction: item.minimized && !isSel ? 0.6 : 1)

            // Right side first: the capsule or the app name decide how much room the title has.
            var rightEdge = row.maxX - t.rowTrailing
            if item.expandable {   // a chevron: right when folded, down when its children are on show
                if let img = NSImage(systemSymbolName: item.expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                    let tinted = img.tinted(isSel ? t.color(Tokens.Color.selectionSub) : t.color(Tokens.Color.chevron))
                    tinted.draw(in: NSRect(x: rightEdge - 10, y: row.midY - 5, width: 10, height: 10))
                }
            }
            if item.pinned, let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) {
                pin.tinted(isSel ? t.color(Tokens.Color.selectionSub) : t.color(Tokens.Color.secondary))
                    .draw(in: NSRect(x: rightEdge - 9, y: row.midY - 5, width: 9, height: 10))
            }
            rightEdge -= accessoryColumn   // chevrons and pins share one column, so the app names line up
            if let kid = item.child {
                let colour = isSel ? t.color(Tokens.Color.selectionSub) : t.color(Tokens.Color.secondary)
                let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.Font.appName, .foregroundColor: colour, .paragraphStyle: para(.right)]
                let natural = (kid.detail as NSString).size(withAttributes: attrs).width
                let w = min(natural, max(Tokens.Size.appNameMinWidth, (rightEdge - row.minX - t.textStart - indent) * 0.45))
                (kid.detail as NSString).draw(with: NSRect(x: rightEdge - w, y: row.midY - 8, width: w, height: 16),
                                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
                rightEdge -= w + 16
            } else if item.minimized {
                rightEdge = drawCapsule(rightOf: rightEdge, midY: row.midY, selected: isSel) - 10
            } else if Settings.showAppName || item.opens != nil, !sameAsApp(item), let d = item.desktop ?? (Settings.showAppName ? nil : nil) ?? Optional(item.appName) {
                let text = (item.desktop ?? item.profile).map { "\(item.appName) · \($0)" } ?? d
                let colour = isSel ? t.color(Tokens.Color.selectionSub) : t.color(Tokens.Color.secondary)
                let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.Font.appName, .foregroundColor: colour, .paragraphStyle: para(.right)]
                let natural = (text as NSString).size(withAttributes: attrs).width
                let titleRoom = rightEdge - (row.minX + t.textStart)
                let w = min(natural, max(Tokens.Size.appNameMinWidth, titleRoom * 0.45))
                (text as NSString).draw(with: NSRect(x: rightEdge - w, y: row.midY - 8, width: w, height: 16),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
                rightEdge -= w + 16
            }

            let titleColour: NSColor = isSel ? t.color(Tokens.Color.selectionText)
                : (item.minimized ? t.color(Tokens.Color.label).withAlphaComponent(0.7) : t.color(Tokens.Color.label))
            let attrs: [NSAttributedString.Key: Any] = [.font: isSel ? t.titleSelectedFont : t.titleFont, .foregroundColor: titleColour, .paragraphStyle: para()]
            let textX = row.minX + t.textStart + indent
            (item.label as NSString).draw(with: NSRect(x: textX, y: row.midY - 9, width: max(20, rightEdge - textX), height: 18),
                                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        drawFades(last: last)
        var moreWidth: CGFloat = 0
        if hasOverflow {
            let more = String(format: Tokens.Copy.more, items.count - visibleRows)
            let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.Font.footer, .foregroundColor: t.color(Tokens.Color.tertiary), .paragraphStyle: para(.right)]
            moreWidth = (more as NSString).size(withAttributes: attrs).width + 12
            (more as NSString).draw(with: NSRect(x: 0, y: 3, width: bounds.width - Tokens.Size.textInsetRight, height: 14),
                                    options: .usesLineFragmentOrigin, attributes: attrs)
        }
        if keyHint {
            let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.Font.footer, .foregroundColor: t.color(Tokens.Color.secondary), .paragraphStyle: para()]
            (KeyHint.text(for: items.indices.contains(selected) ? items[selected] : nil) as NSString).draw(
                with: NSRect(x: Tokens.Size.iconInset, y: 3, width: bounds.width - Tokens.Size.iconInset - Tokens.Size.textInsetRight - moreWidth, height: 14),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    // Returns the x where the capsule starts.
    private func drawCapsule(rightOf right: CGFloat, midY: CGFloat, selected: Bool) -> CGFloat {
        let t = theme
        let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.Font.capsule, .kern: Tokens.Font.capsuleTracking,
                                                    .foregroundColor: selected ? t.color(Tokens.Color.selectionSub) : t.color(Tokens.Color.secondary)]
        let text = Tokens.Copy.minimised as NSString
        let size = text.size(withAttributes: attrs)
        let w = size.width + 2 * Tokens.Size.capsulePadX, h = size.height + 2 * Tokens.Size.capsulePadY
        let rect = NSRect(x: right - w, y: midY - h / 2, width: w, height: h)
        (selected ? t.color(Tokens.Color.selectionText).withAlphaComponent(0.18) : t.color(Tokens.Color.capsuleFill)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Tokens.Radius.capsule, yRadius: Tokens.Radius.capsule).fill()
        text.draw(at: NSPoint(x: rect.minX + Tokens.Size.capsulePadX, y: rect.minY + Tokens.Size.capsulePadY), withAttributes: attrs)
        return rect.minX
    }

    // A soft edge where rows continue beyond the view.
    private func drawFades(last: Int) {
        guard theme.solid else { return }   // over the blur the fade is a mask: updateFade
        let base = theme.color(Tokens.Color.panelSolid)
        let h = Tokens.Size.fadeHeight
        let footer = hasFooter ? Tokens.Size.footerHeight : 0
        if first > 0, let g = NSGradient(starting: base, ending: base.withAlphaComponent(0)) {
            g.draw(in: NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h), angle: -90)
        }
        if last < items.count, let g = NSGradient(starting: base, ending: base.withAlphaComponent(0)) {
            g.draw(in: NSRect(x: 0, y: footer, width: bounds.width, height: h), angle: 90)
        }
    }

    private func drawEmpty() {
        let t = theme
        let centreY = bounds.midY
        if let symbol = NSImage(systemSymbolName: emptyText == nil ? "rectangle.dashed" : "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular)) {
            let tinted = symbol.tinted(emptyText == nil ? t.color(Tokens.Color.tertiary) : t.color(Tokens.Color.label).withAlphaComponent(1))
            let s = tinted.size
            tinted.draw(in: NSRect(x: bounds.midX - s.width / 2, y: centreY + 8, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: emptyText == nil ? 1 : 0.4)
        }
        ((emptyText ?? Tokens.Copy.empty) as NSString).draw(
            with: NSRect(x: 0, y: centreY - 14, width: bounds.width, height: 18), options: .usesLineFragmentOrigin,
            attributes: [.font: Tokens.Font.empty, .foregroundColor: t.color(Tokens.Color.secondary), .paragraphStyle: para(.center)])
        if let hint = emptyHint {
            (hint as NSString).draw(
                with: NSRect(x: 0, y: centreY - 34, width: bounds.width, height: 16), options: .usesLineFragmentOrigin,
                attributes: [.font: Tokens.Font.emptyHint, .foregroundColor: t.color(Tokens.Color.tertiary), .paragraphStyle: para(.center)])
        }
    }

    // MARK: accessibility (VoiceOver reads the list and each row)

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Window list" }
    override func accessibilityChildren() -> [Any]? {
        if items.isEmpty {   // "No results" and the empty desktop line are text too
            let el = NSAccessibilityElement()
            el.setAccessibilityRole(.staticText)
            el.setAccessibilityLabel(emptyText ?? Tokens.Copy.empty)
            el.setAccessibilityParent(self)
            return [el]
        }
        return (first..<min(items.count, first + visibleRows)).map { i -> NSAccessibilityElement in
            let el = NSAccessibilityElement()
            el.setAccessibilityRole(.staticText)
            el.setAccessibilityLabel(spoken(i))
            el.setAccessibilitySelected(i == selected)
            el.setAccessibilityParent(self)
            if let r = rowRect(i), let w = window { el.setAccessibilityFrame(w.convertToScreen(convert(r, to: nil))) }
            return el
        }
    }
}

extension NSImage {
    func tinted(_ colour: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            colour.set()
            rect.fill(using: .sourceIn)   // the colour, alpha included, in the symbol's shape; sourceAtop left its black showing through
            return true
        }
        img.isTemplate = false
        return img
    }
}

// Top line when there is more than one desktop: its name on the left, the page control in the middle
// (dots, the current one a pill, chevrons either side), and for the first few opens a hint on the right.
final class HeaderView: NSView {
    let theme: Theme
    let title: String, index: Int, count: Int, showHint: Bool
    // The next desktop while the list slides over to it: its name fades in and the pill moves across.
    var peek: (title: String, index: Int, amount: CGFloat)? { didSet { needsDisplay = true } }

    init(frame: NSRect, title: String, index: Int, count: Int, theme: Theme, showHint: Bool) {
        self.title = title; self.index = index; self.count = count; self.theme = theme; self.showHint = showHint
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Which dots are drawn: all of them, or a window of 5 that keeps the current one in the middle.
    static func dotWindow(count: Int, index: Int, compact: Bool) -> Range<Int> {
        let n = Int(Tokens.Size.dotWindow)
        guard compact, count > n else { return 0..<count }
        let start = min(max(index - n / 2, 0), count - n)
        return start..<(start + n)
    }

    override func draw(_ dirty: NSRect) {
        let t = theme
        let midY = bounds.height / 2
        // Title
        func drawTitle(_ text: String, alpha: CGFloat) {
            let colour = t.color(Tokens.Color.label)
            let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.Font.header, .foregroundColor: colour.withAlphaComponent(colour.alphaComponent * alpha), .paragraphStyle: para()]
            (text as NSString).draw(with: NSRect(x: Tokens.Size.iconInset, y: midY - 10, width: bounds.width * 0.34, height: 20),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        let moved = peek?.amount ?? 0
        drawTitle(title, alpha: 1 - moved)
        if let peek { drawTitle(peek.title, alpha: moved) }

        // Page control
        let compact = Settings.dots == .compact
        let range = HeaderView.dotWindow(count: count, index: index, compact: compact)
        let d = Tokens.Size.dot, pill = Tokens.Size.dotPill, gap = Tokens.Size.dotGap
        let dotsW = CGFloat(range.count - 1) * (d + gap) + pill
        var x = bounds.midX - dotsW / 2
        for i in range {
            let share = i == index ? 1 - moved : i == peek?.index ? moved : 0   // the widths always add up, so nothing shifts
            let w = d + (pill - d) * share
            (share >= 0.5 ? t.color(Tokens.Color.dotActive) : t.color(Tokens.Color.dotInactive)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: midY - d / 2, width: w, height: d), xRadius: d / 2, yRadius: d / 2).fill()
            x += w + gap
        }
        let chevronSize: CGFloat = 11
        func chevron(_ name: String, at cx: CGFloat, dim: Bool) {
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: chevronSize, weight: .medium)) else { return }
            let tinted = img.tinted(t.color(dim ? Tokens.Color.chevronEnd : Tokens.Color.chevron))
            tinted.draw(in: NSRect(x: cx - tinted.size.width / 2, y: midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
        }
        chevron("chevron.left", at: bounds.midX - dotsW / 2 - Tokens.Size.chevronGap - chevronSize / 2, dim: index == 0)
        chevron("chevron.right", at: bounds.midX + dotsW / 2 + Tokens.Size.chevronGap + chevronSize / 2, dim: index == count - 1)
        if !compact, count > 9 {   // too many dots to count: say where you are
            let s = "\(index + 1) of \(count)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.Font.hint, .foregroundColor: t.color(Tokens.Color.secondary)]
            s.draw(at: NSPoint(x: bounds.midX + dotsW / 2 + Tokens.Size.chevronGap * 2 + chevronSize, y: midY - 7), withAttributes: attrs)
        }

        // Hint, right aligned, first opens only
        if showHint {
            let hint = Tokens.Copy.hint as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Tokens.Font.hint, .foregroundColor: t.color(Tokens.Color.tertiary)]
            hint.draw(at: NSPoint(x: bounds.width - Tokens.Size.textInsetRight - hint.size(withAttributes: attrs).width, y: midY - 7), withAttributes: attrs)
        }

        // Separator under the header
        t.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Tokens.Size.separator).fill()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "\(title), desktop \(index + 1) of \(count)" }
}

// The theme's stripes as a thin band along the panel's top edge (Full Stripe). Equal shares of the width, each edge
// leaning like the brand stripes (28 degrees off vertical, falling from the top left). The panel's rounded corners clip it.
final class StripeBandView: NSView {
    let colours: [NSColor]

    init(frame: NSRect, colours: [NSColor]) {
        self.colours = colours
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        guard !colours.isEmpty else { return }
        let b = bounds, share = b.width / CGFloat(colours.count)
        let lean = b.height * tan(28 * .pi / 180)
        for (i, c) in colours.enumerated() {
            let left = i == 0 ? -lean : b.minX + CGFloat(i) * share - lean / 2
            let right = i == colours.count - 1 ? b.maxX + lean : b.minX + CGFloat(i + 1) * share - lean / 2
            let p = NSBezierPath()
            p.move(to: NSPoint(x: left + lean, y: b.minY))
            p.line(to: NSPoint(x: right + lean, y: b.minY))
            p.line(to: NSPoint(x: right, y: b.maxY))
            p.line(to: NSPoint(x: left, y: b.maxY))
            p.close()
            c.setFill()
            p.fill()
        }
    }

    override func isAccessibilityElement() -> Bool { false }   // decoration only
}

// The rounded, blurred (or solid) surface holding the glance bar (when on), the header and the rows.
final class SwitcherView: NSView {
    let theme: Theme
    private(set) var rows: RowsView
    private(set) var header: HeaderView?
    private(set) var glanceBar: GlanceBarView?
    // The readings actually drawn after fitting (empty when the bar is off or nothing fits), and the room the
    // bar takes: its height plus the separator under it, 0 when off. Both kept current by updateGlance.
    private(set) var glanceReadings: [Glance.Reading] = []
    private(set) var glanceHeight: CGFloat = 0
    private(set) var searchRow: SearchRowView?
    private var rim: [CALayer] = []
    var sliding = false                  // a click means nothing while the rows move
    private let fitRows: Int             // rows that fit on this screen
    private let aboveRows: CGFloat       // everything over the rows: glance bar, header, search row

    var count: Int { rows.items.count }

    struct Header {
        let title: String
        let index: Int
        let count: Int
        let emptyHint: String?
    }

    // `glance` nil = the bar is off and the panel is exactly the 0.5 one. With readings (even none that fit) the
    // layout from the top is: pad, bar (density.height), 1 pt separator, header (if any) with its separator,
    // headerGap, rows. `density` defaults to the user's setting.
    init(items: [WindowItem], selected: Int, screen: NSScreen?, solidBackground: Bool, header: Header? = nil,
         glance: [Glance.Reading]? = nil, density: Glance.Density = Settings.glanceDensity, searchRow showSearch: Bool = false,
         keyHint: Bool = false) {
        let theme = Theme(screen: screen, solid: solidBackground)
        self.theme = theme
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pad = Tokens.Size.panelPad
        let headerH = header == nil ? 0 : Tokens.Size.headerHeight + Tokens.Size.headerGap
        // Bar plus its separator; with no header the header gap sits under the separator instead.
        let barH = glance == nil ? 0 : density.height + Tokens.Size.separator
        let glanceH = glance == nil ? 0 : barH + (header == nil ? Tokens.Size.headerGap : 0)
        let searchH = showSearch ? theme.rowHeight + Tokens.Size.headerGap : 0
        let band = theme.bandRoom   // the stripe band sits in this extra room at the very top
        let top = pad + band        // from the top edge to the first thing drawn under the band
        let fit = max(1, Int((area.height * 0.85 - 2 * pad - band - headerH - glanceH - searchH) / theme.rowHeight))
        fitRows = fit
        aboveRows = band + headerH + glanceH + searchH
        let visible = min(items.count, min(fit, Int(Tokens.Size.maxVisibleRows)))
        let footerH = items.count > visible || keyHint ? Tokens.Size.footerHeight : 0

        // Width: the same every time (default), or wide enough for the longest row. Both stay within the limits.
        let maxW = min(Tokens.Size.panelMaxWidth, area.width * Tokens.Size.panelWidthShare)
        let w: CGFloat
        if Settings.panelWidth == .fixed {
            w = floor(min(maxW, max(Tokens.Size.panelMinWidth, Tokens.Size.panelFixedWidth)))
        } else {
            let column = items.contains { $0.expandable || $0.depth > 0 } ? Tokens.Size.accessoryColumn : 0
            let longest = items.prefix(60).map { item -> CGFloat in
                let titleW = (item.label as NSString).size(withAttributes: [.font: theme.titleSelectedFont]).width
                let right = item.child?.detail ?? item.appName
                let appW = item.minimized ? 70 : (right as NSString).size(withAttributes: [.font: Tokens.Font.appName]).width
                return theme.textStart + CGFloat(item.depth) * Tokens.Size.childIndent + titleW + 16 + appW + column
                    + theme.rowTrailing - Tokens.Size.textInsetRight
            }.max() ?? 0
            w = floor(min(maxW, max(Tokens.Size.panelMinWidth, longest + Tokens.Size.panelWidthExtra)))
        }

        let rowsH = items.isEmpty ? Tokens.Size.emptyHeight : CGFloat(visible) * theme.rowHeight + footerH
        let h = rowsH + aboveRows + 2 * pad
        rows = RowsView(frame: NSRect(x: pad, y: pad, width: w - 2 * pad, height: rowsH),
                        items: items, selected: selected, visibleRows: visible, theme: theme, emptyHint: header?.emptyHint, keyHint: keyHint)
        glanceHeight = barH
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        appearance = NSAppearance(named: theme.dark ? .darkAqua : .aqua)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Size.panelRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        if theme.solid {
            layer?.backgroundColor = theme.color(Tokens.Color.panelSolid).cgColor
        } else {
            let fx = NSVisualEffectView(frame: bounds)
            fx.material = theme.dark ? .hudWindow : .popover
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.autoresizingMask = [.width, .height]
            addSubview(fx)
            let tint = NSView(frame: bounds)
            tint.wantsLayer = true
            tint.layer?.backgroundColor = theme.color(Tokens.Color.panelTint).cgColor
            tint.autoresizingMask = [.width, .height]
            addSubview(tint)
        }
        if band > 0 {
            let strip = StripeBandView(frame: NSRect(x: 0, y: h - Tokens.Size.stripeBand, width: w, height: Tokens.Size.stripeBand),
                                       colours: theme.palette.stripes.map { $0(theme.dark) })
            strip.autoresizingMask = [.width, .minYMargin]
            addSubview(strip)
        }
        addSubview(rows)
        if showSearch {
            let row = SearchRowView(frame: NSRect(x: pad, y: pad + rowsH + Tokens.Size.headerGap, width: w - 2 * pad, height: theme.rowHeight), theme: theme)
            row.autoresizingMask = [.minYMargin]
            addSubview(row)
            searchRow = row
        }
        if let glance {
            let bar = GlanceBarView(frame: NSRect(x: pad, y: h - top - density.height, width: w - 2 * pad, height: density.height),
                                    readings: glance, density: density, theme: theme)
            bar.autoresizingMask = [.minYMargin]
            addSubview(bar)
            glanceBar = bar
            glanceReadings = bar.readings
            let sep = NSView(frame: NSRect(x: pad, y: h - top - barH, width: w - 2 * pad, height: Tokens.Size.separator))
            sep.wantsLayer = true
            sep.layer?.backgroundColor = theme.separator.cgColor
            sep.autoresizingMask = [.minYMargin]
            addSubview(sep)
        }
        if let header {
            let hv = HeaderView(frame: NSRect(x: pad, y: h - top - barH - Tokens.Size.headerHeight, width: w - 2 * pad, height: Tokens.Size.headerHeight),
                                title: header.title, index: header.index, count: header.count, theme: theme,
                                showHint: Settings.hintShows < Tokens.Copy.hintShows)
            hv.autoresizingMask = [.minYMargin]
            addSubview(hv)
            self.header = hv
        }
        // Rim: a hairline outside and a brighter line just inside, so the edge reads over any background.
        let outer = CALayer()
        outer.frame = bounds
        outer.cornerRadius = Tokens.Size.panelRadius
        outer.cornerCurve = .continuous
        outer.borderWidth = 0.5
        outer.borderColor = theme.color(Tokens.Color.rimOuter).cgColor
        layer?.addSublayer(outer)
        let inner = CALayer()
        inner.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        inner.cornerRadius = Tokens.Size.panelRadius - 0.5
        inner.cornerCurve = .continuous
        inner.borderWidth = 1
        inner.borderColor = theme.rim.cgColor
        layer?.addSublayer(inner)
        rim = [outer, inner]
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ index: Int) { rows.select(index) }

    override func hitTest(_ point: NSPoint) -> NSView? { sliding ? nil : super.hitTest(point) }

    // A desktop change in progress. The rows hang from the top of the panel, so a height change only moves its foot.
    func place(offset: CGFloat, pageWidth: CGFloat, incoming: RowsView?, side: Int) {
        let pad = Tokens.Size.panelPad
        func put(_ view: RowsView, _ x: CGFloat) { view.setFrameOrigin(NSPoint(x: x, y: bounds.height - aboveRows - pad - view.frame.height)) }
        put(rows, pad + offset)
        if let incoming {
            if incoming.superview !== self { addSubview(incoming, positioned: .above, relativeTo: rows) }
            put(incoming, pad + offset + CGFloat(side) * pageWidth)
        }
        fitRim()
    }

    // Search: new rows in place, so the text field keeps the keyboard. Returns the height the panel needs.
    func replaceRows(_ items: [WindowItem], selected: Int, emptyText: String?) -> CGFloat {
        let pad = Tokens.Size.panelPad
        let visible = min(items.count, min(fitRows, Int(Tokens.Size.maxVisibleRows)))
        let footerH = items.count > visible ? Tokens.Size.footerHeight : 0
        let rowsH = items.isEmpty ? Tokens.Size.emptyHeight : CGFloat(visible) * theme.rowHeight + footerH
        let new = RowsView(frame: NSRect(x: pad, y: pad, width: rows.frame.width, height: rowsH), items: items, selected: selected,
                           visibleRows: visible, theme: theme, emptyText: emptyText)
        new.onClick = rows.onClick
        new.onChevron = rows.onChevron
        replaceSubview(rows, with: new)
        rows = new
        return rowsH + aboveRows + 2 * pad
    }

    func fitRim() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.first?.frame = bounds
        rim.last?.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        CATransaction.commit()
    }

    // Fresh readings while the panel is open: the bar redraws in place, height and width stay.
    func updateGlance(_ readings: [Glance.Reading]) {
        guard let glanceBar else { return }
        glanceBar.update(readings)
        glanceReadings = glanceBar.readings
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Swap window switcher" }
}

// Floating window that never takes focus, so the app underneath stays active.
final class SwitcherPanel: NSPanel {
    private(set) var switcher: SwitcherView?
    private var hideGeneration = 0
    private var takesKeyboard = false   // only while the search field is in use
    private var sessionKeyHint = false  // decided once per open, so the list does not change height mid-session
    var onChevron: ((Int) -> Void)?     // kept across redraws; the row index, as with the onClick of `show`
    private var shownWith: (screen: NSScreen?, glance: [Glance.Reading]?, searchRow: Bool)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
    }
    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }

    // The screen the list opens on: the one with the window in front (default), or the one with the mouse.
    static func targetScreen(frontWindow: CGWindowID) -> NSScreen? {
        let mouse = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard Settings.showOnScreen == .active, frontWindow != 0,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, frontWindow) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat], let w = b["Width"], let h = b["Height"], let x = b["X"], let y = b["Y"],
              let primary = NSScreen.screens.first else { return mouse }
        // Window bounds come with the origin top-left; flip into AppKit's bottom-left space.
        let centre = NSPoint(x: x + w / 2, y: primary.frame.height - (y + h / 2))
        return NSScreen.screens.first { $0.frame.contains(centre) } ?? mouse
    }

    func show(items: [WindowItem], selected: Int, screen: NSScreen?, header: SwitcherView.Header? = nil,
              glance: [Glance.Reading]? = nil, searchRow: Bool = false, onClick: @escaping (Int) -> Void) {
        hideGeneration += 1
        alphaValue = 1
        shownWith = (screen, glance, searchRow)
        if !isVisible {
            sessionKeyHint = KeyHint.due
            if sessionKeyHint { KeyHint.shown() }
        }
        let view = SwitcherView(items: items, selected: selected, screen: screen, solidBackground: false, header: header, glance: glance, searchRow: searchRow,
                                keyHint: sessionKeyHint)
        view.rows.onClick = onClick
        view.rows.onChevron = onChevron
        switcher = view
        // Size the window before handing it the view: setting contentView resizes the view to the
        // window's current size, which is zero on first show.
        let size = view.frame.size
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        setFrame(NSRect(x: floor(area.midX - size.width / 2), y: floor(area.midY - size.height / 2),
                        width: size.width, height: size.height), display: false)
        contentView = view
        if header != nil, Settings.hintShows < Tokens.Copy.hintShows { Settings.hintShows += 1 }
        let firstOpen = !isVisible
        orderFrontRegardless()
        // Open animation only when the user switched it on, only on the first open of a session (a desktop
        // change swaps the content in place), never with Reduce Motion.
        if firstOpen, Settings.animations, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = view.layer {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = Tokens.Motion.openScale; grow.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [fade, grow]
            group.duration = Tokens.Motion.open
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            layer.add(group, forKey: "open")
        }
        // Every open, desktop change, expand, fold and pin comes through here. The list never takes focus, so this is
        // all a VoiceOver user gets. Say's own check skips a repeat of the same words.
        Announce.say((header.map { "\($0.title), " } ?? "") + view.rows.selectionSpoken)
    }

    func select(_ index: Int) { switcher?.select(index) }

    // A slide over to a neighbouring desktop. `neighbour` gives that desktop's rows; the view built from them is the one
    // `show` will draw when the slide lands, so the end of the movement and the page at rest line up.
    func beginSlide(neighbour: @escaping (Int) -> (items: [WindowItem], selected: Int, header: SwitcherView.Header?)?) -> PageSlide? {
        guard let view = switcher, isVisible, let with = shownWith, PageSlide.allowed else { return nil }
        let keyHint = sessionKeyHint
        return PageSlide(panel: self, view: view) { side in
            guard let page = neighbour(side) else { return nil }
            return SwitcherView(items: page.items, selected: page.selected, screen: with.screen, solidBackground: false, header: page.header,
                                glance: with.glance, searchRow: with.searchRow, keyHint: keyHint)
        }
    }

    // The search field gets the keyboard. The panel was made with .nonactivatingPanel, so it turns key while the
    // app behind stays active. It never turns key otherwise: the normal list never touches the keyboard focus.
    func beginTyping(_ delegate: NSTextFieldDelegate) {
        guard let field = switcher?.searchRow?.startTyping(delegate: delegate) else { return }
        takesKeyboard = true
        makeKey()
        makeFirstResponder(field)
    }

    func endTyping() {
        takesKeyboard = false
        if isVisible { orderOut(nil) }   // gives the keyboard back at once, with or without the close animation
    }

    // New rows while typing: the top edge stays where it is, as in Spotlight.
    func updateRows(_ items: [WindowItem], selected: Int, emptyText: String?) {
        guard let view = switcher else { return }
        let h = view.replaceRows(items, selected: selected, emptyText: emptyText)
        let area = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        var f = frame
        let top = f.maxY
        f.size.height = h
        f.origin.y = max(area.minY + Tokens.Size.panelPad, top - h)
        setFrame(f, display: true)
        view.fitRim()
        invalidateShadow()
        Announce.say(view.rows.selectionSpoken)
    }

    func updateGlance(_ readings: [Glance.Reading]) { switcher?.updateGlance(readings) }

    func hide() {
        switcher = nil
        Announce.reset()
        guard isVisible else { contentView = nil; return }
        if !Settings.animations || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            orderOut(nil); contentView = nil; return
        }
        hideGeneration += 1
        let gen = hideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Tokens.Motion.close
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGeneration == gen else { return }
            self.orderOut(nil)
            self.contentView = nil
            self.alphaValue = 1
        })
    }
}

// What the screen reader says. The text is built even with VoiceOver off, so QA can read it; only the post is skipped.
enum Announce {
    private(set) static var last = ""

    static func say(_ text: String) {
        guard text != last else { return }
        last = text
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    static func reset() { last = "" }
}

// The quiet line at the foot of the list, for the first few opens: what the keys do on the selected row. It covers
// Return, the letters, pins and search. Only keys that work right now, so it follows the Settings switches.
enum KeyHint {
    private static let key = "keyHintShows"
    static var due: Bool { UserDefaults.standard.integer(forKey: key) < Tokens.Copy.keyHintShows }
    static func shown() { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key) }

    static func text(for item: WindowItem?) -> String {
        let c = Tokens.Copy.self
        guard let item else { return [c.keyReturnType, c.keyCancel].joined(separator: " · ") }   // the search row
        var keys: [String] = []
        if let kid = item.child { keys.append(kid.isGroup ? c.keyReturnExpand : c.keyReturnOpen) }
        else if item.expandable { keys.append(item.expanded ? c.keyFold : c.keyReturnExpand) }
        else if Verbs.kind(of: item) == .found { keys.append(c.keyReturnOpen) }
        else { keys.append(c.keyReturnSwitch) }
        if Settings.actionKeys {   // the same table the keys themselves go through, so a row never promises what it refuses
            if Verbs.allows(.close, on: item) { keys.append(c.keyClose) }
            if Verbs.allows(.quit, on: item) { keys.append(c.keyQuit) }
            if Verbs.allows(.pin, on: item) { keys.append(c.keyPin) }
            if Verbs.allows(.command, on: item) { keys.append(c.keyLetters) }
        }
        if item.child != nil { keys.append(c.keyFold) }
        if Settings.searchRow, Verbs.kind(of: item) != .found { keys.append(c.keySearch) }
        return keys.joined(separator: " · ")
    }
}
