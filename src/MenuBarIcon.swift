import AppKit

/// The Swap menu bar glyph: Corner Fall in one colour. Three bands fall from the top-left corner into two
/// overlapping windows (an outlined one at the back, a solid one in front), as on the app icon.
/// Both images are templates (alpha only), so macOS tints them for light, dark and highlighted menu bars.
enum MenuBarIcon {
    /// The normal glyph, 18 x 18 pt.
    static func image() -> NSImage { make(inverted: false, description: "Swap") }

    /// The second state for the timer flash: the same drawing cut out of a solid tile, so the icon
    /// blinks between outline and solid without changing shape or position.
    static func flashImage() -> NSImage { make(inverted: true, description: "Timer done") }

    // Geometry in points, top-left origin (the image draws flipped).
    private static let side: CGFloat = 18
    private static let tile = NSRect(x: 1, y: 1, width: 16, height: 16)
    private static let tileRadius: CGFloat = 4.2
    private static let back = NSRect(x: 9.25, y: 3.5, width: 7, height: 5.75)   // centre line of the outline
    private static let backStroke: CGFloat = 1.5
    private static let front = NSRect(x: 5.5, y: 8.25, width: 8.5, height: 7)
    private static let gap: CGFloat = 1.5
    /// Band edges, measured across the fall line through the tile centre (negative is down and left).
    private static let bands: [(CGFloat, CGFloat)] = [(-6.6, -5.0), (-4.2, -2.6), (-1.8, -0.2)]

    private static func make(inverted: Bool, description: String) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            if inverted {
                NSColor.black.setFill()
                rounded(tile, tileRadius).fill()
                cg.setBlendMode(.destinationOut)
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
                drawGlyph(cg)
                cg.endTransparencyLayer()
            } else {
                drawGlyph(cg)
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = description
        return img
    }

    private static func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    }

    /// One band: a strip across the tile at the logo's 61 degree fall, between two offsets from the centre.
    private static func band(_ o1: CGFloat, _ o2: CGFloat) -> NSBezierPath {
        let a = 61 * CGFloat.pi / 180
        let d = NSPoint(x: cos(a), y: sin(a))            // along the band: down and right
        let n = NSPoint(x: sin(a), y: -cos(a))           // across the band: up and right
        let c = NSPoint(x: tile.midX, y: tile.midY), l: CGFloat = 30
        func p(_ o: CGFloat, _ t: CGFloat) -> NSPoint { NSPoint(x: c.x + n.x * o + d.x * t, y: c.y + n.y * o + d.y * t) }
        let path = NSBezierPath()
        path.move(to: p(o1, -l)); path.line(to: p(o1, l)); path.line(to: p(o2, l)); path.line(to: p(o2, -l)); path.close()
        return path
    }

    private static func drawGlyph(_ cg: CGContext) {
        func clear(_ path: NSBezierPath) {
            cg.saveGState(); cg.setBlendMode(.clear); path.fill(); cg.restoreGState()
        }
        NSColor.black.setFill(); NSColor.black.setStroke()
        cg.saveGState()
        rounded(tile, tileRadius).addClip()
        // The bands stop level with the bottom of the front window, so no slivers show under it.
        NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: front.maxY - tile.minY).clip()
        for (o1, o2) in bands { band(o1, o2).fill() }
        cg.restoreGState()
        clear(rounded(back.insetBy(dx: -backStroke / 2 - gap, dy: -backStroke / 2 - gap), 3.4))
        let outline = rounded(back, 1.8)
        outline.lineWidth = backStroke
        outline.stroke()
        clear(rounded(front.insetBy(dx: -gap, dy: -gap), 3.7))
        rounded(front, 2.2).fill()
    }
}
