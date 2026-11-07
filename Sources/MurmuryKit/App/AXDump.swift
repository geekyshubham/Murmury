import AppKit
import ApplicationServices

/// `--dump-ax=<path>`: writes the main window's accessibility tree in VoiceOver navigation order,
/// so reading order, labels and actions can be reviewed without running VoiceOver. A child process
/// asks through the AXUIElement API, as assistive apps do (SwiftUI builds its tree for those
/// requests; a process can't query itself this way). Needs Accessibility permission.
@MainActor
enum AXDump {
    static func schedule(path: String, after delay: TimeInterval = 2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let window = NSApp.windows.first { $0.identifier?.rawValue == "Murmury.main" }
            let responder = "\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none") → \(ResponderKind.classify(responder: window?.firstResponder, window: window))"
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--ax-dump-pid=\(getpid())", "--ax-dump-out=\(path)", "--ax-dump-note=first responder: \(responder)"]
            try? child.run()
        }
    }

    /// The child-process side of `--dump-ax`.
    nonisolated static func write(pid: pid_t, to path: String, note: String) throws {
        // SwiftUI builds its accessibility tree on the first request: ask again until it is there.
        var text = AXIsProcessTrusted() ? dump(pid: pid) : "# Accessibility permission is off: no dump.\n"
        var tries = 0
        while AXIsProcessTrusted(), text.split(separator: "\n").count < 4, tries < 6 {
            Thread.sleep(forTimeInterval: 0.75); tries += 1
            text = dump(pid: pid)
        }
        try (text + "# \(note)\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    nonisolated static func dump(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        var lines = ["# role | label | value | help | actions | frame (screen points, y down)"]
        func string(_ element: AXUIElement, _ attribute: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return "" }
            if let s = value as? String { return s }
            if let n = value as? NSNumber { return n.stringValue }
            return ""
        }
        func frame(_ element: AXUIElement) -> String {
            var p: CFTypeRef?, s: CFTypeRef?
            var point = CGPoint.zero, size = CGSize.zero
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success, let p,
               CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &point) }
            if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success, let s,
               CFGetTypeID(s) == AXValueGetTypeID() { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            return String(format: "%.0f,%.0f %.0fx%.0f", point.x, point.y, size.width, size.height)
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            for attribute in ["AXChildrenInNavigationOrder", kAXChildrenAttribute as String] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let list = value as? [AXUIElement], !list.isEmpty { return list }
            }
            return []
        }
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 40 else { return }
            let role = string(element, kAXRoleAttribute as String)
            var label = string(element, kAXDescriptionAttribute as String)
            if label.isEmpty { label = string(element, kAXTitleAttribute as String) }
            let value = string(element, kAXValueAttribute as String)
            let help = string(element, kAXHelpAttribute as String)
            var names: CFArray?
            let actions = AXUIElementCopyActionNames(element, &names) == .success
                ? ((names as? [String]) ?? []).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" } : []
            let interesting = !label.isEmpty || !value.isEmpty || !actions.isEmpty || !["AXGroup", "AXUnknown", ""].contains(role)
            if interesting {
                lines.append(String(repeating: "  ", count: depth) + [role, label, value, help, actions.joined(separator: ","), frame(element)]
                    .map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | "))
            }
            for child in children(element) { visit(child, depth: interesting ? depth + 1 : depth) }
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement],
           let main = list.first(where: { string($0, kAXSubroleAttribute as String) == kAXStandardWindowSubrole as String }) {
            visit(main, depth: 0)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
