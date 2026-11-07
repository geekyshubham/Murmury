import Foundation
import simd
import Testing
@testable import MurmuryKit

@Suite("Double nod recovery")
struct DoubleNodTests {
    func trace(_ pitch: (Double) -> Double, seconds: Double = 5, armed: Bool = true, gap: Bool = false) -> [Double] {
        var detector = DoubleNodDetector(), fires: [Double] = []
        for i in 0..<Int(seconds * 50) {
            let t = Double(i) / 50
            if gap && (2.3...3.0).contains(t) { continue }
            if detector.ingest(pitch: pitch(t), time: t, armed: armed) { fires.append(t) }
        }
        return fires
    }
    func crisp(_ t: Double) -> Double {
        for start in [2.0, 2.7, 3.4] {
            let u = t - start
            if (0...0.4).contains(u) { return -16 * sin(.pi * u / 0.4) }
        }
        return 0
    }
    @Test func crispPairFiresOnceAndRefractoryHolds() {
        #expect(trace(crisp).count == 1)
        #expect(trace(crisp, armed: false).isEmpty)
    }
    @Test func rejectsSingleNodDriftJitterAndGaps() {
        #expect(trace { t in (2...2.4).contains(t) ? -16 * sin(.pi * (t - 2) / 0.4) : 0 }.isEmpty)
        #expect(trace { -$0 * 2 }.isEmpty)
        #expect(trace { 6 * sin($0 * 12) }.isEmpty)
        #expect(trace(crisp, gap: true).isEmpty)
    }
    /// Real buds rest at about one sample a second; a double nod right after resting still counts.
    @Test func firstNodAfterTheOneHertzRestCounts() {
        var detector = DoubleNodDetector(), fires: [Double] = []
        for i in 0..<5 { _ = detector.ingest(pitch: 0.5, time: Double(i), armed: true) }  // resting, 1 Hz
        for i in 0..<100 {  // then two crisp nods at 50 Hz
            let t = 5 + Double(i) / 50, u1 = t - 5.0, u2 = t - 5.7
            let pitch = (0...0.4).contains(u1) ? -16 * sin(.pi * u1 / 0.4) : ((0...0.4).contains(u2) ? -16 * sin(.pi * u2 / 0.4) : 0)
            if detector.ingest(pitch: pitch, time: t, armed: true) { fires.append(t) }
        }
        #expect(fires.count == 1)
    }
    /// Limited neck movement: a 7° double nod is ignored at the default depth, counted at depth 6.
    @Test func shallowNodsCountWhenTheDepthIsLowered() {
        func shallow(_ t: Double) -> Double {
            for start in [2.0, 2.7] { let u = t - start; if (0...0.4).contains(u) { return -7 * sin(.pi * u / 0.4) } }
            return 0
        }
        func fires(depth: Double) -> Int {
            var d = DoubleNodDetector(); d.depth = depth
            return (0..<250).filter { i in d.ingest(pitch: shallow(Double(i) / 50), time: Double(i) / 50, armed: true) }.count
        }
        #expect(fires(depth: 10) == 0)
        #expect(fires(depth: 6) == 1)
    }
    /// Settings survive disarmed stretches (normal voice use feeds disarmed samples between losses).
    @Test func tunedDepthSurvivesDisarmedSamples() {
        var d = DoubleNodDetector(depth: 6, slowness: 1.5)
        for i in 0..<100 { _ = d.ingest(pitch: 0, time: Double(i) / 50, armed: false) }
        #expect(d.depth == 6 && d.slowness == 1.5)
        var fires = 0
        for i in 0..<250 {
            let t = 2 + Double(i) / 50, u1 = t - 4.0, u2 = t - 4.7
            let pitch = (0...0.4).contains(u1) ? -7 * sin(.pi * u1 / 0.4) : ((0...0.4).contains(u2) ? -7 * sin(.pi * u2 / 0.4) : 0)
            if d.ingest(pitch: pitch, time: t, armed: true) { fires += 1 }
        }
        #expect(fires == 1)
    }
    @Test func armingAndFallbackRules() {
        #expect(DoubleNodDetector.isArmed(stopped: true, enabled: true, paused: true, calibrating: false, demo: false))
        for excluded in 0..<5 {
            #expect(!DoubleNodDetector.isArmed(stopped: excluded != 0, enabled: excluded != 1, paused: excluded != 2,
                                             calibrating: excluded == 3, demo: excluded == 4))
        }
        #expect(DoubleNodDetector.offersPointerOnly(lastRetry: 10, now: 29))
        #expect(DoubleNodDetector.offersPointerOnly(lastRetry: 10, now: 310))
        #expect(!DoubleNodDetector.offersPointerOnly(lastRetry: nil, now: 15))
    }
    @Test func demoTraceNeverArms() {
        var detector = DoubleNodDetector()
        for i in 0..<500 {
            let t = Double(i) / 50
            let sample = DemoMotion.sample(at: t)
            let q = sample.q
            let pitch = Kinematics.euler(simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)).0 * 180 / .pi
            let fired = detector.ingest(pitch: pitch, time: t, armed: false)
            #expect(!fired)
        }
    }
    @MainActor @Test func secondDeliberatePairCanRecoverWithGestureClicks() async {
        let dir = URL(fileURLWithPath: ".build/nod-fallback-\(UUID())")
        let store = DatasetStore(directory: dir)
        var click = Synthetic.take("nothing", seed: 1); click.label = "click"
        store.save([click, Synthetic.take("nothing", seed: 2)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = AppModel(store: store, headMouse: HeadMouse(driver: FakePointer(), defaults: nil, ticks: false))
        var running = true, restarts = 0
        m.voiceIsRunning = { running }
        m.voiceAuthorization = { (.authorized, .authorized) }
        m.startVoice = { restarts += 1; return .recognizerUnavailable }
        m.voiceRecoverySleep = { _ in try await Task.sleep(for: .seconds(100)) }
        m.headMouse.motionCommands = true
        await m.setHeadMouse(true); running = false; m.checkVoiceHealth()
        func pair(_ offset: Double) {
            for i in 0..<225 { let t = Double(i) / 50; m.receiveRecoveryPitch(crisp(t), at: offset + t) }
        }
        pair(0)
        for _ in 0..<30 { await Task.yield() }
        #expect(restarts == 1 && m.headMouse.isPaused)
        pair(6)
        for _ in 0..<30 { await Task.yield() }
        #expect(m.handsFreeMode == .pointerOnly && !m.headMouse.isPaused)
        #expect(m.lastAnnouncement?.contains("pointer only") == true)
        await m.setHeadMouse(false)
    }

    /// Every running state has a hands-free stop: without voice, a double nod pauses the pointer and
    /// another resumes it.
    @MainActor @Test func withoutVoiceADoubleNodPausesAndResumes() async {
        let m = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: ".build/nod-pause-\(UUID())")),
                         headMouse: HeadMouse(driver: FakePointer(), defaults: nil, ticks: false))
        m.voiceIsRunning = { false }
        m.voiceAuthorization = { (.authorized, .authorized) }
        m.headMouse.voiceClicks = false
        await m.setHeadMouse(true)
        #expect(m.headMouse.isEnabled && m.handsFreeMode == .voiceOff && !m.headMouse.isPaused)
        func pair(_ offset: Double) {
            for i in 0..<225 { let t = Double(i) / 50; m.receiveRecoveryPitch(crisp(t), at: offset + t) }
        }
        pair(0)
        #expect(m.headMouse.isPaused && m.lastAnnouncement?.contains("Nod twice to resume") == true)
        pair(6)
        #expect(!m.headMouse.isPaused)
        await m.setHeadMouse(false)
    }

}
