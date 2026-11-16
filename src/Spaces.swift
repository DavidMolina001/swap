import AppKit
import ApplicationServices
import ColorSync

// Desktops (Spaces) through private SkyLight calls, looked up at run time so that if a future macOS
// removes one, Swap falls back to the current desktop only instead of crashing.
enum Spaces {
    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static func fn<T>(_ lib: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
        guard let p = dlsym(lib, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias RemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let mainConnection = fn(sky, "CGSMainConnectionID", MainConnection.self)
    private static let copyDisplaySpaces = fn(sky, "CGSCopyManagedDisplaySpaces", CopyDisplaySpaces.self)
    private static let copySpacesForWindows = fn(sky, "CGSCopySpacesForWindows", CopySpacesForWindows.self)
    private static let setFrontProcess = fn(sky, "_SLPSSetFrontProcessWithOptions", SetFrontProcess.self)
    private static let postEventRecord = fn(sky, "SLPSPostEventRecordTo", PostEventRecord.self)
    private static let processForPID = fn(hiServices, "GetProcessForPID", ProcessForPID.self)
    private static let remoteToken = fn(hiServices, "_AXUIElementCreateWithRemoteToken", RemoteToken.self)

    static var available: Bool { mainConnection != nil && copyDisplaySpaces != nil && copySpacesForWindows != nil }

    struct Desktop {
        let id: UInt64
        let fullScreen: Bool
    }

    // The desktops of the display under the mouse, left to right, and which one is showing.
    // Off the main thread, pass the display found with mouseDisplayUUID() on the main thread.
    static func desktops(display uuid: String? = nil) -> (list: [Desktop], current: UInt64)? {
        guard available, let cid = mainConnection?(),
              let displays = copyDisplaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]], !displays.isEmpty else { return nil }
        var display = displays[0]
        if displays.count > 1, let uuid = uuid ?? (Thread.isMainThread ? mouseDisplayUUID() : nil),
           let match = displays.first(where: { ($0["Display Identifier"] as? String) == uuid }) { display = match }
        let spaces = (display["Spaces"] as? [[String: Any]]) ?? []
        let list = spaces.compactMap { s -> Desktop? in
            guard let id = (s["ManagedSpaceID"] as? NSNumber)?.uint64Value else { return nil }
            return Desktop(id: id, fullScreen: (s["type"] as? Int) == 4)
        }
        guard let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value,
              !list.isEmpty else { return nil }
        return (list, current)
    }

    static func mouseDisplayUUID() -> String? {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let n = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    // The desktop a window is on (nil for minimised windows, which belong to none).
    static func space(of window: CGWindowID) -> UInt64? {
        guard let cid = mainConnection?(),
              let ids = copySpacesForWindows?(cid, 7, [window] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return ids.first?.uint64Value
    }

    // Make one specific window the key window of its app and bring the app forward. macOS then shows
    // the desktop the window is on. Same technique as other window managers (e.g. yabai).
    @discardableResult
    static func bringForward(pid: pid_t, window: CGWindowID) -> Bool {
        guard let setFront = setFrontProcess, let post = postEventRecord, let forPID = processForPID else { return false }
        var psn = ProcessSerialNumber()
        guard forPID(pid, &psn) == noErr, setFront(&psn, window, 0x200) == 0 else { return false }   // 0x200 = user generated
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: window) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01; _ = post(&psn, &bytes)
        bytes[0x08] = 0x02; _ = post(&psn, &bytes)
        return true
    }

    // Accessibility only returns windows on the current desktop. Windows on other desktops are found by
    // asking an app for its UI elements by number. Slow-ish (about 20 ms per app), so run off the main thread.
    static func findAllWindows(pid: pid_t, maxElement: UInt64 = 3000) -> [(CGWindowID, AXUIElement)] {
        guard let make = remoteToken else { return [] }
        var out: [(CGWindowID, AXUIElement)] = []
        var header = Data()
        withUnsafeBytes(of: pid) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(0)) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(0x636f636f)) { header.append(contentsOf: $0) }   // "coco"
        var slow = 0
        for element in UInt64(0)..<maxElement {
            var token = header
            withUnsafeBytes(of: element) { token.append(contentsOf: $0) }
            guard let el = make(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.05)   // before the first call, so a hung app costs 50 ms a probe
            let started = Date()
            let id = windowID(el)
            if Date().timeIntervalSince(started) > 0.04 { slow += 1; if slow >= 3 { break } }   // not answering: give up on it
            guard let id else { continue }
            var sub: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub) == .success,
               (sub as? String) == kAXStandardWindowSubrole { out.append((id, el)) }
        }
        return out
    }
}
