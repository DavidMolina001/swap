// Helper for the live self-test (not part of Swap).
//   SwapTestWindow window "Title"   opens one plain window on the current desktop and stays running
//   SwapTestWindow window "Title" ghost   also opens a borderless "Swap test ghost" window (a helper window
//                                   like a browser's tab search popup: Accessibility lists it, Swap must not)
//   SwapTestWindow window "Title" noclose   a window that refuses to close, as one does while a Save prompt is up
//   SwapTestWindow desk             prints the index of the desktop showing (0 = first)
//   SwapTestWindow key left|right   presses Control+Left/Right (the system's "move a desktop" keys)
import AppKit

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "desk":
    let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    typealias Conn = @convention(c) () -> Int32
    typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
    let cid = unsafeBitCast(dlsym(sky, "CGSMainConnectionID"), to: Conn.self)()
    let displays = unsafeBitCast(dlsym(sky, "CGSCopyManagedDisplaySpaces"), to: Copy.self)(cid)!.takeRetainedValue() as! [[String: Any]]
    let d = displays[0]
    let ids = (d["Spaces"] as! [[String: Any]]).map { ($0["ManagedSpaceID"] as! NSNumber).uint64Value }
    let cur = ((d["Current Space"] as! [String: Any])["ManagedSpaceID"] as! NSNumber).uint64Value
    print(ids.firstIndex(of: cur) ?? -1)
case "key":
    let code: CGKeyCode = args.count > 2 && args[2] == "left" ? 123 : 124
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = [.maskControl, .maskSecondaryFn]
        e?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
default:
    final class StaysOpen: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    }
    let staysOpen = StaysOpen()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let w = NSWindow(contentRect: NSRect(x: 260, y: 260, width: 460, height: 220),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.title = args.count > 2 ? args[2] : "Swap test desktop 2"
    if args.contains("noclose") { w.delegate = staysOpen }
    w.makeKeyAndOrderFront(nil)
    var ghost: NSWindow?
    if args.contains("ghost") {
        let g = NSWindow(contentRect: NSRect(x: 300, y: 200, width: 200, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        g.title = "Swap test ghost"
        g.backgroundColor = .systemPink
        g.orderFront(nil)
        ghost = g
    }
    app.activate(ignoringOtherApps: true)
    app.run()
    _ = ghost
    _ = staysOpen
}
