// Draws the Swap icon (two overlapping windows) and writes src/Swap.icns.
// Run from the project folder: swift src/Icon/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bg = NSBezierPath(roundedRect: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88),
                          xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1), NSColor(red: 0.17, green: 0.22, blue: 0.38, alpha: 1)])!
        .draw(in: bg, angle: -60)
    func window(_ r: NSRect, _ a: CGFloat) {
        NSColor.white.withAlphaComponent(a).setFill()
        NSBezierPath(roundedRect: r, xRadius: s * 0.05, yRadius: s * 0.05).fill()
        NSColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 0.35).setFill()
        NSRect(x: r.minX, y: r.maxY - s * 0.07, width: r.width, height: s * 0.07).fill()
    }
    window(NSRect(x: s * 0.2, y: s * 0.4, width: s * 0.44, height: s * 0.36), 0.45)
    window(NSRect(x: s * 0.36, y: s * 0.24, width: s * 0.44, height: s * 0.36), 0.95)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = NSTemporaryDirectory() + "Swap.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16", 16), ("16@2x", 32), ("32", 32), ("32@2x", 64), ("128", 128), ("128@2x", 256),
                   ("256", 256), ("256@2x", 512), ("512", 512), ("512@2x", 1024)] {
    let base = name.replacingOccurrences(of: "@2x", with: "")
    let file = name.hasSuffix("@2x") ? "icon_\(base)x\(base)@2x.png" : "icon_\(base)x\(base).png"
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/\(file)"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir, "-o", "src/Swap.icns"]; try! p.run(); p.waitUntilExit()
