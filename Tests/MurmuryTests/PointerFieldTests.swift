import AppKit
import SwiftUI
import QuartzCore
import Testing
@testable import MurmuryKit

@Suite("Pointer field")
struct PointerFieldTests {
    @Test func clampSmoothRelaxAndReduceMotion() {
        var motion = PointerParallax()
        for _ in 0..<60 {
            let value = motion.advance(target: CGPoint(x: 5, y: -5), dt: 0.01, reduceMotion: false)
            #expect((0...1).contains(value.x) && (-1...0).contains(value.y))
        }
        #expect(abs(motion.value.x - 1) < 0.007 && abs(motion.value.y + 1) < 0.007)
        for _ in 0..<60 { _ = motion.advance(target: nil, dt: 0.01, reduceMotion: false) }
        #expect(abs(motion.value.x) < 0.007 && abs(motion.value.y) < 0.007)
        let reduced = motion.advance(target: CGPoint(x: 1, y: 1), dt: 1, reduceMotion: true)
        #expect(reduced == .zero)
    }
    @Test func deterministicOverrideWinsAndUnchangedPollingIsNotMovement() {
        let signal = PointerSignal()
        signal.update(normalized: CGPoint(x: 0.1, y: 0.2), inside: true, at: 0)
        signal.update(normalized: CGPoint(x: 0.1, y: 0.2), inside: true, at: 0.1)
        #expect(signal.movementCount == 1)
        signal.setOverride(CGPoint(x: 0.25, y: 0.35))
        signal.update(normalized: CGPoint(x: 0.9, y: 0.9), inside: false, at: 1)
        let state = signal.snapshot(at: 2, reduceMotion: false)
        #expect(state.inside)
        #expect(abs(state.point.x + 0.5) < 0.001 && abs(state.point.y - 0.3) < 0.001)
        #expect(signal.snapshot(at: 3, reduceMotion: true).point == .zero)
    }
    @Test func hoverFocusPressDisabledAndMotionPreferences() {
        for focused in [false, true] {
            let raised = HoverLiftState.make(hovered: !focused, focused: focused, pressed: false, enabled: true, reduceMotion: false, lift: 2)
            #expect(raised.offset == -2 && raised.glow > 0)
        }
        #expect(HoverLiftState.make(hovered: true, focused: true, pressed: false, enabled: false, reduceMotion: false).offset == 0)
        let pressed = HoverLiftState.make(hovered: true, focused: false, pressed: true, enabled: true, reduceMotion: false)
        #expect(pressed.scale == 0.98 && pressed.offset == 0)
        let reduced = HoverLiftState.make(hovered: true, focused: false, pressed: false, enabled: true, reduceMotion: true)
        #expect(reduced.offset == 0 && reduced.scale == 1 && reduced.glow == 0 && reduced.fill == 0.05)
    }
    @Test func pointerEnvelopeKeepsCopySidebarAndStatusContrast() {
        for size in [CGSize(width: 1120, height: 740), CGSize(width: 1600, height: 1000)] {
            for hue in Hue.all { for dark in [true, false] { for px in 0..<6 { for py in 0..<4 {
                let pointer = CGPoint(x: Double(px) / 5, y: Double(py) / 3)
                let palette = dark ? Palette.dark : .light
                let origin = CGPoint(x: PageLayout.sidebar, y: 0)
                let page = CGSize(width: size.width - origin.x, height: size.height)
                for point in PageLayout.copySamplePoints(in: page) {
                    let at = CGPoint(x: point.x + origin.x, y: point.y)
                    let bg = FieldModel.sample(at: at, size: size, hue: hue, dark: dark, origin: origin, pointer: pointer)
                    #expect(contrast(palette.primary, bg) >= 7)
                    #expect(contrast(palette.secondary, bg) >= 4.5 && contrast(palette.tertiary, bg) >= 4.5)
                    #expect(contrast(palette.disabledText, bg) >= 3)
                    if dark {
                        #expect(bg.luminance <= 0.1)
                        for color in [palette.live, palette.warn, palette.danger] { #expect(contrast(color, bg) >= 3) }
                    }
                }
                for y in 0..<8 {
                    let at = CGPoint(x: 120, y: CGFloat(y) / 7 * size.height)
                    let base = FieldModel.sample(at: at, size: size, hue: hue, dark: dark, origin: origin)
                    let side = SidebarSurface.sample(over: base, hue: hue, dark: dark)
                    let bg = PointerLightSpec.sample(over: side, at: at, pointer: pointer, size: size, hue: hue, dark: dark)
                    #expect(contrast(palette.primary, bg) >= 7 && contrast(palette.secondary, bg) >= 4.5)
                }
            } } } }
        }
    }
    @Test func lightPreferencesAndOpacityAreDeterministic() {
        let size = CGSize(width: 1120, height: 740), pointer = CGPoint(x: 0.8, y: 0.7)
        let base = RGB(0x4A1C9E)
        #expect(PointerLightSpec.sample(over: base, at: pointer, pointer: pointer, size: size, hue: .control, dark: true, reduceMotion: true) == base)
        let normal = PointerLightSpec.opacity(pointer: pointer, size: size, dark: true)
        #expect(normal == 0.07)
        #expect(PointerLightSpec.opacity(pointer: pointer, size: size, dark: true, increasedContrast: true) == normal / 2)
    }
    @MainActor @Test func headGazePreservesLivePoseAndRespectsReduceMotion() {
        let rig = HeadRig(assetURL: nil)
        var input = HeadRig.Inputs(); input.pointer = .init(point: CGPoint(x: 1, y: 0), inside: true)
        for step in 0..<40 { rig.apply(input, time: Double(step) / 60) }
        #expect(abs(rig.displayedPose.yaw - 14) < 0.01)
        input.pose = HeadPose(yaw: 30)
        for step in 0..<40 { rig.apply(input, time: Double(step) / 60) }
        #expect(abs(rig.displayedPose.yaw - 30) < 0.01)
        input.pose = nil; input.reduceMotion = true
        for step in 0..<40 { rig.apply(input, time: Double(step) / 60) }
        #expect(abs(rig.displayedPose.yaw) < 0.01)
    }
    @MainActor @Test func liveHeadOrbitKeepsBustInTheFade() {
        for pitch in [-35.0, 35] { for pointerY in [-1.0, 1] {
            let rig = HeadRig(assetURL: HeroTests.assetURL)
            var input = HeadRig.Inputs(); input.pose = HeadPose(pitch: pitch); input.idle = false
            input.pointer = .init(point: CGPoint(x: 1, y: pointerY), inside: true)
            for step in 0..<40 { rig.apply(input, time: Double(step) / 60) }
            #expect(HeroFraming.projectedBottom(rig: rig, aspect: 1 / PageLayout.visualAspect) >= 0.93)
            #expect(abs(rig.displayedPose.pitch - pitch) < 0.01)
        } }
    }
    @Test func productsTiltWithinTheSpecifiedAngles() {
        let p = HeroPointerSpec.product(point: CGPoint(x: 1, y: 1), reduceMotion: false)
        #expect(abs(p.yaw - 7 * .pi / 180) < 0.0001)
        #expect(abs(p.pitch - 4.5 * .pi / 180) < 0.0001)
        let still = HeroPointerSpec.product(point: CGPoint(x: 1, y: 1), reduceMotion: true)
        #expect(still.yaw == 0 && still.pitch == 0)
    }
}

private enum PointerPerformanceEvidence {
    static let result: [String: Any]? = {
        let directory = URL(fileURLWithPath: ".build/pointer-performance", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--pointer-perf-probe", directory.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["MURMURY_OFFLINE": "1"]) { _, new in new }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("probe.log").path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: directory.appendingPathComponent("probe.log")) else { return nil }
        defer { try? log.close() }
        process.standardOutput = log; process.standardError = log
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: directory.appendingPathComponent("performance.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }()
}
@Suite("Pointer layer performance")
struct PointerPerformanceTests {
    @Test(.enabled(if: PointerPerformanceEvidence.result != nil, "Offscreen AppKit probe unavailable; see .build/pointer-performance/probe.log"))
    func layersHandleSixHundredSamplesWithoutInvalidatingPages() throws {
        let result = try #require(PointerPerformanceEvidence.result)
        #expect((result["positionUpdates"] as? Int ?? 0) >= 590)
        #expect((result["mainThreadMilliseconds"] as? Double ?? 1000) < 400)
        for name in ["Page", "Aura", "PageHeader"] { #expect((result[name] as? Int ?? 1000) <= 2) }
        #expect((result["nativeEventUpdates"] as? Int ?? 0) >= 1)
        #expect((result["polledUpdates"] as? Int ?? 0) >= 1)
        #expect(result["unchangedPollIsMovement"] as? Bool == false)
    }
    @MainActor @Test func pointerTransformsReuseTheSceneAndEnvironment() {
        let rig = HeadRig(assetURL: nil)
        var input = HeadRig.Inputs(); input.pose = HeadPose(yaw: 30)
        rig.apply(input, time: 0)
        let before = BodyCounters.snapshot()
        for i in 0..<600 {
            input.pointer = .init(point: CGPoint(x: sin(Double(i) / 20), y: cos(Double(i) / 20)), inside: true)
            rig.apply(input, time: Double(i) / 120)
        }
        let after = BodyCounters.snapshot()
        #expect(before["SceneBuild"] == after["SceneBuild"])
        #expect(before["EnvironmentBuild"] == after["EnvironmentBuild"])
        #expect(abs(rig.displayedPose.yaw - 30) < 0.001)
    }
}

#if DEBUG
@MainActor func runPointerPerformanceProbe(to directory: URL) throws -> Int32 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    // This probe intentionally omits all SceneKit surfaces; scene caching has a separate numeric test.
    guard ProcessInfo.processInfo.environment["MURMURY_OFFLINE"] == "1" else { print("Set MURMURY_OFFLINE=1; no SceneKit rendering is supported by this probe."); return 3 }
    let model = AppModel(store: DatasetStore(directory: directory.appendingPathComponent("isolated-data")),
                         headMouse: HeadMouse(driver: FakePointer(), defaults: nil, ticks: false))
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 1120, height: 740), styleMask: .borderless, backing: .buffered, defer: false)
    let host = NSHostingView(rootView: ContentView().environment(model))
    window.contentView = host; window.orderFrontRegardless(); host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    host.layoutSubtreeIfNeeded()
    func find(_ view: NSView) -> PointerLightNativeView? {
        if let view = view as? PointerLightNativeView { return view }
        return view.subviews.lazy.compactMap { find($0) }.first
    }
    guard let native = find(host), let event = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 100, y: 200),
        modifierFlags: [], timestamp: CACurrentMediaTime(), windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) else { return 3 }
    let initial = native.signal.movementCount
    native.mouseMoved(with: event)
    let eventUpdates = native.signal.movementCount - initial
    let location = window.convertPoint(toScreen: CGPoint(x: 300, y: 400))
    let beforePoll = native.signal.movementCount
    native.pollScreenLocation(location, at: CACurrentMediaTime())
    let polled = native.signal.movementCount - beforePoll
    let beforeUnchanged = native.signal.movementCount
    native.pollScreenLocation(location, at: CACurrentMediaTime())
    let unchanged = native.signal.movementCount != beforeUnchanged
    BodyCounters.reset()
    let startUpdates = native.positionUpdateCount, start = CACurrentMediaTime()
    for i in 0..<600 {
        let phase = Double(i) / 599
        native.process(normalized: CGPoint(x: phase, y: 0.5 + 0.4 * sin(phase * 2 * .pi)), inside: true, at: start + Double(i) / 120)
    }
    let milliseconds = (CACurrentMediaTime() - start) * 1000
    var result: [String: Any] = BodyCounters.snapshot().mapValues { $0 as Any }
    for name in ["Page", "Aura", "PageHeader", "SceneBuild", "EnvironmentBuild"] { result[name] = result[name] ?? 0 }
    result["positionUpdates"] = native.positionUpdateCount - startUpdates
    result["mainThreadMilliseconds"] = milliseconds
    result["nativeEventUpdates"] = eventUpdates; result["polledUpdates"] = polled
    result["unchangedPollIsMovement"] = unchanged
    result["timestamps"] = "600 samples at simulated 120 Hz; main-thread CPU time only"
    result["SceneKitSurfaces"] = "unavailable offline; caching verified separately without rendering"
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("performance.json"))
    window.orderOut(nil); window.contentView = nil
    return 0
}
#endif
