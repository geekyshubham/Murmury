import Foundation

/// SwiftUI keyboard focus is not visible to AppKit's responder chain: focusable controls register
/// here while focused.
@MainActor
final class FocusRegistry {
    static let shared = FocusRegistry()
    private var focused: Set<UUID> = []
    var count: Int { focused.count }
    var hasFocus: Bool { !focused.isEmpty }
    func update(_ id: UUID, focused isFocused: Bool) {
        if isFocused { focused.insert(id) } else { focused.remove(id) }
    }
    func remove(_ id: UUID) { focused.remove(id) }
}
