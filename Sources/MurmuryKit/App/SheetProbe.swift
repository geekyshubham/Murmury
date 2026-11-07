import AppKit
import ApplicationServices

/// `--sheet-probe=<path> --sheet-probe-plan=<steps>`: drives a real sheet the way a VoiceOver user
/// does, through the accessibility API, and writes what an assistive app would see: where keyboard
/// focus is, the sheet's reading order, every announcement the app requests (with its priority),
/// and whether Esc closes the sheet and returns focus. It runs in a child process, as `AXDump` does,
/// because a process can't observe its own accessibility tree. Needs Accessibility permission.
///
/// Steps, separated by `|`: `focus`, `order`, `open:<More menu item>`, `press:<button>`,
/// `pick:<segment>`, `tap:<button in the window, outside a sheet>`, `label:<prefix>` (reads one
/// element), `esc`, `wait:<seconds>`, and for a live
/// VoiceOver run (scripts/voiceover-check.sh) keys posted where VoiceOver hears them:
/// `vo:<key>` (Control-Option plus the key, e.g. `vo:right`), `key:<key>`, `down:<key>`, `up:<key>`,
/// with keys `left|right|up|down|space|return|tab|esc`, optionally prefixed `shift+`.
/// Each step line ends with `@<seconds since 1970>` so a caption log can be lined up with it.
@MainActor
enum SheetProbe {
    static func schedule(out: String, plan: String, after delay: TimeInterval = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--sheet-probe-pid=\(getpid())", "--sheet-probe-out=\(out)", "--sheet-probe-plan=\(plan)"]
            try? child.run()
        }
    }

    /// What the observer heard; appended from the accessibility callback on this thread's run loop.
    private final class Heard: @unchecked Sendable { var lines: [String] = [] }

    nonisolated static func run(pid: pid_t, out: String, plan: String) throws {
        var log = ["# Sheet probe, pid \(pid). Plan: \(plan)"]
        defer { try? (log.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        guard AXIsProcessTrusted() else { log.append("# Accessibility permission is off: no probe."); return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 4)

        let heard = Heard()
        var observer: AXObserver?
        let callback: AXObserverCallbackWithInfo = { _, element, notification, info, refcon in
            guard let refcon else { return }
            let box = Unmanaged<Heard>.fromOpaque(refcon).takeUnretainedValue()
            let dict = info as NSDictionary
            if (notification as String) == "AXAnnouncementRequested" {
                let text = dict["AXAnnouncementKey"] as? String ?? "(no text)"
                let priority = (dict["AXPriorityKey"] as? NSNumber)?.intValue
                let level = priority.map { $0 >= 90 ? "high" : $0 >= 50 ? "medium" : "low" } ?? "default"
                box.lines.append("  announced (\(level) priority): \"\(text)\"")
            } else {
                box.lines.append("  focus moved to: \(SheetProbe.describe(element))")
            }
        }
        if AXObserverCreateWithInfoCallback(pid, callback, &observer) == .success, let observer {
            let refcon = Unmanaged.passUnretained(heard).toOpaque()
            AXObserverAddNotification(observer, app, "AXAnnouncementRequested" as CFString, refcon)
            AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        } else {
            log.append("# Couldn't observe announcements.")
        }
        func pump(_ seconds: Double) {
            CFRunLoopRunInMode(.defaultMode, seconds, false)
            log += heard.lines; heard.lines = []
        }

        func mainWindow() -> AXUIElement? {
            (copy(app, kAXWindowsAttribute) as? [AXUIElement])?.first { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
        }
        func sheet() -> AXUIElement? {
            mainWindow().flatMap { children($0).first { string($0, kAXRoleAttribute) == kAXSheetRole as String } }
        }
        func focusLine() -> String {
            guard let focused = copy(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
                return "focus: none reported"
            }
            let element = focused as! AXUIElement
            let inSheet = ancestors(element).contains { string($0, kAXRoleAttribute) == kAXSheetRole as String }
            let window = (copy(app, kAXFocusedWindowAttribute)).map { describe($0 as! AXUIElement) } ?? "none"
            return "focus: \(describe(element)); inside a sheet: \(inSheet ? "yes" : "no"); focused window: \(window)"
        }
        func button(_ title: String, in root: AXUIElement, roles: Set<String>) -> AXUIElement? {
            find(root) { roles.contains(string($0, kAXRoleAttribute)) && label($0) == title }
        }

        // Settle: SwiftUI builds its tree on the first request.
        for _ in 0..<8 where mainWindow() == nil { pump(0.5) }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        pump(0.5)

        for raw in plan.split(separator: "|").map(String.init) {
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            let verb = parts[0], arg = parts.count > 1 ? parts[1] : ""
            log.append("> \(raw)  @" + String(format: "%.3f", Date().timeIntervalSince1970))
            switch verb {
            case "focus":
                log.append("  " + focusLine())
                if let s = sheet() { log.append("  sheet open: \(describe(s))") } else { log.append("  sheet open: no") }
            case "order":
                guard let s = sheet() else { log.append("  no sheet"); break }
                log.append("  reading order (VoiceOver navigation order):")
                log += order(s).map { "    " + $0 }
            case "open":
                guard let window = mainWindow(), let more = find(window, { string($0, kAXRoleAttribute) == kAXMenuButtonRole as String && label($0) == "More actions" }) else {
                    log.append("  no More actions button"); break
                }
                let opened = AXUIElementPerformAction(more, kAXPressAction as CFString)
                var item: AXUIElement?
                for _ in 0..<12 where item == nil {  // the menu fills in as it opens
                    pump(0.25)
                    item = find(more, { string($0, kAXRoleAttribute) == kAXMenuItemRole as String && label($0) == arg }, depth: 6)
                        ?? find(app, { string($0, kAXRoleAttribute) == kAXMenuItemRole as String && label($0) == arg }, depth: 12)
                }
                guard let item else { log.append("  menu opened (\(opened.rawValue)), but no item \"\(arg)\""); break }
                let pressed = AXUIElementPerformAction(item, kAXPressAction as CFString)
                var waited = 0.0
                repeat { pump(0.25); waited += 0.25 } while sheet() == nil && waited < 4
                log.append("  chose \"\(arg)\" from More actions (AXPress \(pressed == .success ? "ok" : "error \(pressed.rawValue)")); sheet appeared: \(sheet() != nil ? "yes, after \(String(format: "%.2f", waited)) s" : "no")")
                pump(0.6)
                log.append("  " + focusLine())
            case "press", "pick":
                guard let s = sheet() else { log.append("  no sheet"); break }
                let roles: Set<String> = verb == "pick" ? [kAXRadioButtonRole as String, kAXButtonRole as String] : [kAXButtonRole as String]
                guard let target = button(arg, in: s, roles: roles) else { log.append("  no \"\(arg)\" in the sheet"); break }
                let enabled = (copy(target, kAXEnabledAttribute) as? Bool) ?? true
                let before = describe(target)  // the button may be gone once pressed
                let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
                log.append("  \(before), enabled: \(enabled), AXPress: \(result == .success ? "ok" : "error \(result.rawValue)")")
                pump(1.0)
                log.append("  " + focusLine())
            case "tap":
                guard let window = mainWindow(), let target = button(arg, in: window, roles: [kAXButtonRole as String, kAXRadioButtonRole as String]) else {
                    log.append("  no \"\(arg)\" in the window"); break
                }
                let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
                log.append("  \(describe(target)), AXPress: \(result == .success ? "ok" : "error \(result.rawValue)")")
                pump(0.5)
            case "label":
                guard let s = sheet() else { log.append("  no sheet"); break }
                if let element = find(s, { label($0).hasPrefix(arg) || string($0, kAXValueAttribute).hasPrefix(arg) }) { log.append("  " + describe(element)) } else { log.append("  nothing labelled \"\(arg)…\"") }
            case "esc":
                AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                pump(0.3)
                let source = CGEventSource(stateID: .hidSystemState)
                for down in [true, false] { CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down)?.postToPid(pid) }
                pump(1.0)
                log.append("  sheet still open: \(sheet() != nil ? "yes" : "no")")
                log.append("  " + focusLine())
            case "wait":
                pump(Double(arg) ?? 1)
            case "vo", "key", "down", "up":
                guard let key = Self.key(arg) else { log.append("  unknown key \"\(arg)\""); break }
                var flags = key.flags
                if verb == "vo" { flags.formUnion([.maskControl, .maskAlternate]) }
                let source = CGEventSource(stateID: .hidSystemState)
                let phases: [Bool] = verb == "down" ? [true] : verb == "up" ? [false] : [true, false]
                for down in phases {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down)
                    if let event { event.flags = event.flags.union(flags) }  // keeps the arrows' own flags
                    event?.post(tap: .cghidEventTap)  // the HID stream, where VoiceOver listens
                    usleep(30_000)
                }
                pump(0.2)
            default:
                log.append("  unknown step")
            }
        }
        pump(0.3)
        log.append("# done")
    }

    nonisolated private static func key(_ name: String) -> (code: CGKeyCode, flags: CGEventFlags)? {
        let shifted = name.hasPrefix("shift+")
        let codes: [String: CGKeyCode] = ["left": 123, "right": 124, "down": 125, "up": 126, "space": 49, "return": 36, "tab": 48, "esc": 53]
        guard let code = codes[shifted ? String(name.dropFirst(6)) : name] else { return nil }
        return (code, shifted ? .maskShift : [])
    }

    // MARK: Accessibility helpers

    nonisolated private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        guard let value = copy(element, attribute) else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }
    nonisolated private static func label(_ element: AXUIElement) -> String {
        let description = string(element, kAXDescriptionAttribute)
        return description.isEmpty ? string(element, kAXTitleAttribute) : description
    }
    nonisolated static func describe(_ element: AXUIElement) -> String {
        let role = string(element, kAXRoleAttribute)
        let name = label(element), value = string(element, kAXValueAttribute)
        var text = role
        if !name.isEmpty { text += " \"\(name)\"" }
        if !value.isEmpty { text += " value \"\(value)\"" }
        return text.replacingOccurrences(of: "\n", with: " ")
    }
    nonisolated private static func children(_ element: AXUIElement) -> [AXUIElement] {
        for attribute in ["AXChildrenInNavigationOrder", kAXChildrenAttribute as String] {
            if let list = copy(element, attribute) as? [AXUIElement], !list.isEmpty { return list }
        }
        return []
    }
    nonisolated private static func ancestors(_ element: AXUIElement) -> [AXUIElement] {
        var chain: [AXUIElement] = [element], current = element
        while chain.count < 60, let parent = copy(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
            current = parent as! AXUIElement; chain.append(current)
        }
        return chain
    }
    nonisolated private static func find(_ root: AXUIElement, _ match: (AXUIElement) -> Bool, depth: Int = 30) -> AXUIElement? {
        if match(root) { return root }
        guard depth > 0 else { return nil }
        for child in children(root) { if let hit = find(child, match, depth: depth - 1) { return hit } }
        return nil
    }
    /// The elements VoiceOver stops on, in its navigation order.
    nonisolated private static func order(_ root: AXUIElement) -> [String] {
        var lines: [String] = []
        func visit(_ element: AXUIElement, _ depth: Int) {
            guard depth < 30 else { return }
            let role = string(element, kAXRoleAttribute)
            let stops = !label(element).isEmpty || !string(element, kAXValueAttribute).isEmpty || !["AXGroup", "AXUnknown", "AXScrollArea", ""].contains(role)
            if stops { lines.append(describe(element)) }
            for child in children(element) { visit(child, depth + 1) }
        }
        visit(root, 0)
        return lines
    }
}
