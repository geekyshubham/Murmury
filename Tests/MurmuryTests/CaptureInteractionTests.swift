import AppKit
import Foundation
import Testing
@testable import MurmuryKit

@MainActor @Suite("Capture interaction")
struct CaptureInteractionTests {
    func feed(_ capture: CaptureController, seconds: Double = 1) {
        for i in 0..<Int(seconds * 50) {
            capture.ingest(MotionSample(t: Double(i) / 50, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0, wx: 1))
        }
    }
    @Test func toggleSavesSamplesAndIgnoresStrayRelease() {
        var saved: [[MotionSample]] = []
        let c = CaptureController(segmenter: Segmenter(), label: { "nod" }, hasMotion: { true })
        c.onSegment = { samples, _ in saved.append(samples) }
        c.toggle(); feed(c); c.release(.space)
        #expect(c.ownership == .toggled)
        #expect(saved.isEmpty)
        c.toggle()
        #expect(saved.count == 1)
        #expect(saved.first?.count == 50)
        #expect(c.lastFinish == .toggled)
    }
    @Test func heldReleaseMatchesAndKeyRepeatDoesNotDuplicate() {
        var saves = 0
        let c = CaptureController(segmenter: Segmenter(), label: { "nod" }, hasMotion: { true })
        c.onSegment = { _, _ in saves += 1 }
        c.press(.space); c.press(.space); feed(c); c.release(.pointer)
        #expect(c.ownership == .held(source: .space))
        c.release(.space); c.release(.space)
        #expect(saves == 1)
        #expect(c.lastFinish == .released)
    }
    @Test func timeLimitHasNoSecondSave() {
        var saves = 0
        let c = CaptureController(segmenter: Segmenter(), label: { "nod" }, hasMotion: { true })
        c.onSegment = { _, _ in saves += 1 }
        c.toggle(); feed(c, seconds: 6.1)
        #expect(c.ownership == .none)
        #expect(c.lastFinish == .timeLimit)
        c.release(.space); c.cancelForNavigation()
        #expect(saves == 1)
    }
    @Test func navigationKeepsOriginalLabel() {
        var label = "nod", savedLabel = ""
        let c = CaptureController(segmenter: Segmenter(), label: { label }, hasMotion: { true })
        c.onSegment = { _, name in savedLabel = name }
        c.toggle(); feed(c); label = "shake"; c.cancelForNavigation()
        #expect(savedLabel == "nod")
    }
    @Test func emptyLabelAndInactiveSourceCannotStart() {
        let empty = CaptureController(segmenter: Segmenter(), label: { " \n" }, hasMotion: { true })
        let stopped = CaptureController(segmenter: Segmenter(), label: { "nod" }, hasMotion: { false })
        for c in [empty, stopped] {
            c.press(.pointer); c.toggle()
            #expect(c.ownership == .none)
            #expect(!c.segmenter.isCapturing)
        }
    }
    @Test func toggleNeverEndsAutomaticCapture() {
        let seg = Segmenter()
        let c = CaptureController(segmenter: seg, label: { "nod" }, hasMotion: { true })
        seg.calibrate()
        for i in 0..<130 { c.ingest(MotionSample(t: Double(i) / 50, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0)) }
        seg.autoEnabled = true
        c.ingest(MotionSample(t: 2.6, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0, wx: 10))
        #expect(seg.isCapturing)
        c.toggle(); c.release(.space)
        #expect(seg.isCapturing)
        c.cancelForNavigation()
        #expect(c.lastFinish == .auto)
    }
    @Test func tinyCaptureReleasesOwnership() {
        let c = CaptureController(segmenter: Segmenter(), label: { "nod" }, hasMotion: { true })
        c.press(.pointer); c.release(.pointer)
        #expect(c.ownership == .none)
        #expect(!c.segmenter.isCapturing)
    }
    @Test func spaceScope() {
        func allowed(key: Bool = true, text: Bool = false, modifiers: NSEvent.ModifierFlags = [], sheet: Bool = false, screen: AppModel.Screen = .train) -> Bool {
            shouldCaptureSpace(isMainWindowKey: key, firstResponderIsText: text, modifiers: modifiers, sheetOrSettingsOpen: sheet, screen: screen)
        }
        #expect(allowed())
        #expect(allowed(screen: .live))
        #expect(!allowed(key: false))
        #expect(!allowed(text: true))
        #expect(!allowed(modifiers: .shift))
        #expect(!allowed(modifiers: .command))
        #expect(!allowed(modifiers: .option))
        #expect(!allowed(modifiers: .control))
        #expect(!allowed(modifiers: .function))
        #expect(!allowed(sheet: true))
        for screen in [AppModel.Screen.mouse, .device, .sensors, .model] { #expect(!allowed(screen: screen)) }
    }
}

/// A spoken or ordinary click is a down and an up a few milliseconds apart: it toggles a take.
@MainActor @Suite("Click to record")
struct ClickToRecordTests {
    final class Clock { var now = 100.0 }
    func make(_ clock: Clock) -> (CaptureController, () -> [CaptureController.FinishReason], () -> Int) {
        var reasons: [CaptureController.FinishReason] = []
        var saves = 0
        let c = CaptureController(segmenter: Segmenter(), label: { "nod" }, hasMotion: { true }, clock: { clock.now })
        c.onSegment = { _, _ in saves += 1 }
        c.onFinish = { reason, saved in if saved { reasons.append(reason) } }
        return (c, { reasons }, { saves })
    }
    func feed(_ c: CaptureController, from t0: Double = 0, seconds: Double = 1) {
        for i in 0..<Int(seconds * 50) { c.ingest(MotionSample(t: t0 + Double(i) / 50, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0, wx: 1)) }
    }
    @Test func quickClickTogglesAndSecondClickSavesOnce() {
        let clock = Clock()
        let (c, reasons, saves) = make(clock)
        c.pointerDown(); clock.now += 0.01; c.pointerUp()
        #expect(c.ownership == .toggled)
        #expect(c.segmenter.isCapturing)
        feed(c)
        c.pointerDown(); clock.now += 0.01; c.pointerUp()
        #expect(saves() == 1)
        #expect(reasons() == [.toggled])
        #expect(c.ownership == .none)
    }
    @Test func holdingStillRecordsWhileHeld() {
        let clock = Clock()
        let (c, reasons, saves) = make(clock)
        c.pointerDown()
        #expect(c.ownership == .held(source: .pointer))
        feed(c); clock.now += 1.2; c.pointerUp()
        #expect(saves() == 1)
        #expect(reasons() == [.released])
    }
    @Test func clickDuringToggledTakeSavesToggled() {
        let clock = Clock()
        let (c, reasons, _) = make(clock)
        c.toggle(); feed(c)
        c.pointerDown(); clock.now += 0.02; c.pointerUp()
        #expect(reasons() == [.toggled])
        #expect(c.ownership == .none)
    }
    @Test func tapStartedTakeStopsAtTimeLimitWithoutSecondSave() {
        let clock = Clock()
        let (c, reasons, saves) = make(clock)
        c.pointerDown(); clock.now += 0.01; c.pointerUp()
        feed(c, seconds: 6.1)
        #expect(c.ownership == .none)
        #expect(c.lastFinish == .timeLimit)
        c.pointerDown(); clock.now += 0.01; c.pointerUp()
        #expect(saves() == 1)
        #expect(reasons() == [.timeLimit])
    }
    @Test func cancelBehavesLikeUp() {
        let clock = Clock()
        let (c, reasons, _) = make(clock)
        c.pointerDown(); clock.now += 0.01; c.pointerCancel()
        #expect(c.ownership == .toggled)
        feed(c); c.pointerDown(); clock.now += 1.5; c.pointerCancel()
        #expect(reasons() == [.toggled])
        let (held, heldReasons, _) = make(clock)
        held.pointerDown(); feed(held); clock.now += 1.0; held.pointerCancel()
        #expect(heldReasons() == [.released])
    }
    @Test func disabledCaptureIgnoresPointer() {
        let c = CaptureController(segmenter: Segmenter(), label: { "" }, hasMotion: { true })
        c.pointerDown(); c.pointerUp()
        #expect(c.ownership == .none)
        #expect(CaptureController.tapThreshold == 0.8)
    }
}

@MainActor @Suite("Space and focus")
struct SpaceFocusTests {
    @Test func focusedControlBlocksSpaceCapture() {
        #expect(shouldCaptureSpace(isMainWindowKey: true, firstResponderIsText: false, modifiers: [], sheetOrSettingsOpen: false, screen: .train))
        #expect(!shouldCaptureSpace(isMainWindowKey: true, firstResponderIsText: false, modifiers: [], sheetOrSettingsOpen: false,
                                    screen: .train, controlHasFocus: true))
    }
    @Test func responderKinds() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(); window.contentView = root
        let button = NSButton(); root.addSubview(button)
        #expect(ResponderKind.classify(responder: nil, window: window) == .none)
        #expect(ResponderKind.classify(responder: window, window: window) == .none)
        #expect(ResponderKind.classify(responder: root, window: window) == .none)
        #expect(ResponderKind.classify(responder: NSTextView(), window: window) == .text)
        #expect(ResponderKind.classify(responder: button, window: window) == .control)
    }
    @Test func registryCountsSetUnsetAndDisappear() {
        let registry = FocusRegistry()
        let a = UUID(), b = UUID()
        #expect(!registry.hasFocus)
        registry.update(a, focused: true)
        registry.update(a, focused: true)
        #expect(registry.count == 1)
        registry.update(b, focused: true)
        #expect(registry.count == 2)
        registry.update(a, focused: false)
        #expect(registry.count == 1 && registry.hasFocus)
        registry.remove(b)
        #expect(registry.count == 0 && !registry.hasFocus)
        registry.remove(b)
        #expect(registry.count == 0)
    }
}
