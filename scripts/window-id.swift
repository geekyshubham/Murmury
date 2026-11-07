import AppKit
import CoreGraphics
import Foundation

// CGWindowList's CFArray bridge is unreliable in JXA on this CLT host.
guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("Usage: window-id <pid>\n".utf8))
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
          (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          (bounds["Width"] as? NSNumber)?.doubleValue ?? 0 >= 1100,
          let id = window[kCGWindowNumber as String] as? NSNumber else { continue }
    if CommandLine.arguments.contains("--scale") {
        let rect = CGRect(x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0, y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                          width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0, height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
        let displayHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitRect = CGRect(x: rect.minX, y: displayHeight - rect.maxY, width: rect.width, height: rect.height)
        let screen = NSScreen.screens.max { a, b in
            let ar = a.frame.intersection(appKitRect), br = b.frame.intersection(appKitRect)
            return ar.width * ar.height < br.width * br.height
        }
        print(screen?.backingScaleFactor ?? 1)
    } else { print(id.stringValue) }
    exit(0)
}
FileHandle.standardError.write(Data("Murmury window not visible; use an unlocked desktop with Screen Recording access.\n".utf8))
exit(3)
