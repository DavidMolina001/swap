// Builds src/Swap.icns from the Corner Fall source SVGs in this folder.
// Run from the project folder: swift src/Icon/make-icon.swift [folder to keep the .iconset in]
//
//   swap-icon.svg     full artwork: 824 x 824 body centred in 1024 (Apple icon grid), used for 64 px and up
//   swap-icon-32.svg  simplified for 32 px: three wider bands, bolder windows
//   swap-icon-16.svg  simplified for 16 px: three bands, one window
//
// The SVGs hold the artwork only; this script adds the drop shadow under the tile so the shadow scales
// with each size. Edit the SVGs in any vector editor, then run this again.
import AppKit

let dir = "src/Icon"
func load(_ name: String) -> NSImage {
    guard let img = NSImage(contentsOf: URL(fileURLWithPath: "\(dir)/\(name)")) else {
        fatalError("cannot read \(dir)/\(name); run from the project folder")
    }
    return img
}
let full = load("swap-icon.svg"), small32 = load("swap-icon-32.svg"), small16 = load("swap-icon-16.svg")

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let art: NSImage
    let shadow = NSShadow()
    switch px {
    case ..<24:
        art = small16
        shadow.shadowOffset = NSSize(width: 0, height: -0.5); shadow.shadowBlurRadius = 0.8
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    case ..<48:
        art = small32
        shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.shadowBlurRadius = 1.2
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    default:
        art = full   // Apple grid: shadow about 1% down, 2.3% blur, inside the 100 px margin at 1024
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.0098); shadow.shadowBlurRadius = s * 0.023
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    }
    shadow.set()
    art.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let keep = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let iconset = (keep ?? NSTemporaryDirectory()) + "/Swap.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let file = scale == 2 ? "icon_\(pt)x\(pt)@2x.png" : "icon_\(pt)x\(pt).png"
    try! render(pt * scale).write(to: URL(fileURLWithPath: "\(iconset)/\(file)"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "src/Swap.icns"]; try! p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
if keep == nil { try? FileManager.default.removeItem(atPath: iconset) }
print("wrote src/Swap.icns" + (keep.map { " (iconset kept in \($0))" } ?? ""))
