import ApplicationServices
import CoreGraphics

/// Posts real mouse events. Clicks and scrolls need Accessibility permission; without it only
/// pointer warping works.
@MainActor
final class SystemPointer: PointerDriver {
    private let source = CGEventSource(stateID: .hidSystemState)

    var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    var displays: [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestTrust() {
        // kAXTrustedCheckOptionPrompt's value; the global isn't concurrency-safe to read.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func move(to p: CGPoint) {
        guard isTrusted else { CGWarpMouseCursorPosition(p); return }
        // Keep a physical drag working: while a button is held, a move is a drag.
        let type: CGEventType = CGEventSource.buttonState(.combinedSessionState, button: .left) ? .leftMouseDragged
            : CGEventSource.buttonState(.combinedSessionState, button: .right) ? .rightMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func click(_ button: MouseButton, count: Int, at p: CGPoint) {
        let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) =
            button == .left ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
        for n in 1...max(count, 1) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    func press(_ button: MouseButton, at p: CGPoint) { post(button == .left ? .leftMouseDown : .rightMouseDown, button, at: p) }
    func release(_ button: MouseButton, at p: CGPoint) { post(button == .left ? .leftMouseUp : .rightMouseUp, button, at: p) }
    private func post(_ type: CGEventType, _ button: MouseButton, at p: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button == .left ? .left : .right)?
            .post(tap: .cghidEventTap)
    }

    func scroll(dx: Int32, dy: Int32) {
        // Wheel values are positive for "scroll up/left", the opposite of our view movement.
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }
}
