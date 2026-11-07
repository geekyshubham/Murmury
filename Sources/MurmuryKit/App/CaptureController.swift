import AppKit
import Foundation
import Observation

/// Owns manual capture; automatic segmentation continues to belong to Segmenter.
@MainActor @Observable
final class CaptureController {
    enum Source: Equatable { case pointer, space }
    enum Ownership: Equatable { case none, held(source: Source), toggled }
    enum FinishReason: Equatable { case released, toggled, timeLimit, auto }

    let segmenter: Segmenter
    private(set) var ownership: Ownership = .none
    private(set) var lastFinish: FinishReason?
    private(set) var recordingLabel = ""
    /// When the current manual take started, on `clock`'s timeline.
    private(set) var startedAt: TimeInterval?
    var onSegment: (([MotionSample], String) -> Void)?
    var onFinish: ((FinishReason, Bool) -> Void)?
    /// A take that stays open after the pointer or key lets go (toggle or a quick click).
    var onToggledStart: (() -> Void)?
    /// A press shorter than this is a click: the take stays open until the next click.
    static let tapThreshold: TimeInterval = 0.8
    @ObservationIgnored private let label: () -> String
    @ObservationIgnored private let hasMotion: () -> Bool
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var finishing: FinishReason?
    @ObservationIgnored private var deadline: Timer?
    @ObservationIgnored private var pointerDownAt: TimeInterval?
    @ObservationIgnored private var ignoreNextPointerUp = false

    init(segmenter: Segmenter, label: @escaping () -> String, hasMotion: @escaping () -> Bool,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.segmenter = segmenter; self.label = label; self.hasMotion = hasMotion; self.clock = clock
        segmenter.onSegment = { [weak self] samples in
            guard let self else { return }
            let reason = finishing ?? (ownership == .none ? .auto : .timeLimit)
            let name = recordingLabel
            clearOwnership()
            lastFinish = reason
            onSegment?(samples, name)
            onFinish?(reason, true)
        }
    }

    var canRecord: Bool { hasMotion() && !label().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var disabledReason: String? {
        if !hasMotion() { return "Connect a motion source or start the demo" }
        if label().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Name a gesture first" }
        return nil
    }

    func press(_ source: Source) { start(.held(source: source)) }
    func release(_ source: Source) {
        guard ownership == .held(source: source) else { return }
        finish(.released)
    }
    func toggle() {
        if ownership == .toggled { finish(.toggled) }
        else if ownership == .none, !segmenter.isCapturing { start(.toggled); if ownership == .toggled { onToggledStart?() } }
    }
    /// Pointer press on the record control. The take starts at once so the gesture's start is kept;
    /// `pointerUp` decides whether this was a click (keep recording) or a hold (save now).
    func pointerDown() {
        if ownership == .toggled { finish(.toggled); ignoreNextPointerUp = true; return }
        ignoreNextPointerUp = false
        guard ownership == .none else { return }
        start(.held(source: .pointer))
        pointerDownAt = ownership == .held(source: .pointer) ? clock() : nil
    }
    func pointerUp() {
        defer { pointerDownAt = nil }
        if ignoreNextPointerUp { ignoreNextPointerUp = false; return }
        guard ownership == .held(source: .pointer) else { return }
        if let down = pointerDownAt, clock() - down < Self.tapThreshold {
            ownership = .toggled
            onToggledStart?()
        } else {
            finish(.released)
        }
    }
    /// A cancelled gesture (the pointer left, the window changed) ends like a release.
    func pointerCancel() { pointerUp() }
    func cancelForNavigation() {
        if ownership != .none { finish(.released) }
        else if segmenter.isCapturing {
            // Segmenter's native off transition finishes an automatic segment.
            let enabled = segmenter.autoEnabled
            segmenter.autoEnabled = false
            segmenter.autoEnabled = enabled
        }
    }
    func ingest(_ sample: MotionSample) {
        if !segmenter.isCapturing { recordingLabel = label().trimmingCharacters(in: .whitespacesAndNewlines) }
        segmenter.ingest(sample)
        if !segmenter.isCapturing, ownership != .none { clearOwnership() }
    }
    private func start(_ owner: Ownership) {
        guard canRecord, ownership == .none, !segmenter.isCapturing else { return }
        recordingLabel = label().trimmingCharacters(in: .whitespacesAndNewlines)
        ownership = owner
        startedAt = clock()
        segmenter.begin()
        deadline = Timer.scheduledTimer(withTimeInterval: Segmenter.maxHoldSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.timeLimit) }
        }
    }
    private func finish(_ reason: FinishReason) {
        guard ownership != .none else { return }
        finishing = reason
        segmenter.end()
        // Tiny takes have no callback; they still release ownership.
        if ownership != .none {
            clearOwnership()
            lastFinish = reason
            onFinish?(reason, false)
        }
        finishing = nil
    }
    private func clearOwnership() {
        deadline?.invalidate(); deadline = nil
        ownership = .none
        startedAt = nil
    }
}

/// Space starts a held take only when nothing has keyboard focus: a focused button or the focused
/// record orb keeps Space for its own activation, and text fields type it.
@MainActor
func shouldCaptureSpace(isMainWindowKey: Bool, firstResponderIsText: Bool, modifiers: NSEvent.ModifierFlags,
                        sheetOrSettingsOpen: Bool, screen: AppModel.Screen, controlHasFocus: Bool = false) -> Bool {
    isMainWindowKey && !firstResponderIsText && !sheetOrSettingsOpen && !controlHasFocus
        && modifiers.intersection([.command, .option, .control, .shift, .function]).isEmpty
        && (screen == .train || screen == .live)
}

/// What AppKit's first responder says about keyboard focus.
enum ResponderKind: Equatable {
    case none, text, control
    @MainActor static func classify(responder: NSResponder?, window: NSWindow?) -> ResponderKind {
        guard let responder, responder !== window, responder !== window?.contentView else { return .none }
        if responder is NSText { return .text }
        // SwiftUI's own hosting views take first responder for the whole page; they are not a control.
        if String(describing: type(of: responder)).contains("HostingView") { return .none }
        return .control
    }
}
