import AppKit
import simd
import Testing
@testable import MurmuryKit

@Suite("Demo motion")
struct DemoMotionTests {
    func samples(_ range: ClosedRange<Double>) -> [MotionSample] {
        var k = Kinematics()
        return stride(from: range.lowerBound, through: range.upperBound, by: 0.02).map { k.ingest(DemoMotion.sample(at: $0), t: $0) }
    }

    @Test func scriptCyclesThroughRestNodAndShake() {
        #expect(DemoMotion.phase(at: 0.5) == "rest")
        #expect(DemoMotion.phase(at: 2.5) == "nod")
        #expect(DemoMotion.phase(at: 5.5) == "shake")
        #expect(DemoMotion.phase(at: 5.5 + DemoMotion.period) == "shake")
    }

    /// In the measured bud frame a nod turns about x (out of the ear) and a shake about y (up).
    @Test func nodRotatesAboutPitchAxisShakeAboutYaw() {
        let nod = samples(2.2...3.2), shake = samples(5.2...6.2)
        let nodX = nod.map { abs($0.wx) }.max()!, nodY = nod.map { abs($0.wy) }.max()!
        let shakeX = shake.map { abs($0.wx) }.max()!, shakeY = shake.map { abs($0.wy) }.max()!
        #expect(nodX > 5 * nodY)
        #expect(shakeY > 5 * shakeX)
    }
    /// The avatar shows the demo's shake as a turn and its nod as a nod, not a tilt.
    @Test func demoReadsAsTurnAndNodOnTheAvatar() {
        let rest = DemoMotion.sample(at: 0.5).q, shakeQ = DemoMotion.sample(at: 5.4).q, nodQ = DemoMotion.sample(at: 2.4).q
        func rel(_ q: Quat) -> simd_quatd { simd_quatd(ix: rest.x, iy: rest.y, iz: rest.z, r: rest.w).inverse * simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w) }
        let shake = HeadPose(relative: rel(shakeQ), axes: .standard), nod = HeadPose(relative: rel(nodQ), axes: .standard)
        #expect(abs(shake.yaw) > 5 && abs(shake.roll) < 0.2 * abs(shake.yaw), "\(shake)")
        #expect(abs(nod.pitch) > 5 && abs(nod.roll) < 0.2 * abs(nod.pitch), "\(nod)")
    }

    @Test func restIsQuiet() {
        #expect(samples(0.2...1.6).allSatisfy { $0.angularSpeed < 0.1 })
    }
}

@MainActor
@Suite("Launch arguments")
struct LaunchArgumentTests {
    @Test func screenUsesSingleTokenSoAppKitDoesNotTreatItAsAFile() {
        #expect(AppModel.screen(fromLaunchArguments: ["Murmury", "--screen=train"]) == .train)
        #expect(AppModel.screen(fromLaunchArguments: ["Murmury", "--screen=LIVE"]) == .live)
        #expect(AppModel.screen(fromLaunchArguments: ["Murmury", "--screen=control"]) == .mouse)
        #expect(AppModel.screen(fromLaunchArguments: ["Murmury", "--screen=Teach"]) == .train)
        #expect(AppModel.screen(fromLaunchArguments: ["Murmury", "--screen=nope"]) == nil)
        #expect(AppModel.screen(fromLaunchArguments: ["Murmury"]) == nil)
    }
}

@MainActor
@Suite("Appearance launch options")
struct AppearanceLaunchTests {
    @Test func explicitAppearanceOnly() {
        #expect(AppModel.launchOptions(from: ["--appearance=light"]).appearance == .aqua)
        #expect(AppModel.launchOptions(from: ["--appearance=dark"]).appearance == .darkAqua)
        #expect(AppModel.launchOptions(from: ["--appearance=purple"]).appearance == nil)
        #expect(AppModel.launchOptions(from: []).appearance == nil)
    }
    @Test func everyPublicScreenName() {
        for (name, screen) in zip(["control", "buds", "motion", "teach", "model", "detect"], AppModel.Screen.allCases) {
            #expect(AppModel.launchOptions(from: ["--screen=\(name)"]).screen == screen)
        }
    }
}

@MainActor @Suite("Screenshot window sizing")
struct ScreenshotWindowTests {
    @Test func onlySupportedSizes() {
        #expect(AppModel.launchOptions(from: ["--window-size=1600x1000"]).windowSize == NSSize(width: 1600, height: 1000))
        #expect(AppModel.launchOptions(from: ["--window-size=1120x740"]).windowSize == NSSize(width: 1120, height: 740))
        #expect(AppModel.launchOptions(from: ["--window-size=0x0"]).windowSize == nil)
    }
}

@MainActor @Suite("App presentation state", .serialized)
struct AppPresentationStateTests {
    func isolated() -> AppModel {
        AppModel(store: DatasetStore(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-data/app-\(UUID())")))
    }
    @Test func trainingDefaults() {
        let m = isolated()
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        #expect(m.trainWindow == Double(MotionModelTrainer.defaultWindow))
        #expect(m.trainAugment == 12)
        #expect(m.trainIterations == 40)
    }
    @Test func demoStopClearsMotionReadiness() {
        let m = isolated()
        defer { m.stopDemo(); try? FileManager.default.removeItem(at: m.store.directory) }
        m.startDemo()
        #expect(m.activeSource == .demo)
        #expect(m.hasMotion)
        m.stopDemo()
        #expect(!m.hasMotion)
        #expect(m.latest == nil && m.history.isEmpty && m.sampleRate == 0)
        #expect(m.headPose == nil)
    }
    @Test func deviceSamplesReplaceDemoAndRecenter() {
        let m = isolated()
        defer { m.stopDemo(); try? FileManager.default.removeItem(at: m.store.directory) }
        m.startDemo()
        m.receiveDeviceMotion([DemoMotion.sample(at: 2.5)], arrival: 100)
        #expect(!m.isDemo)
        #expect(m.activeSource == .device)
        #expect(m.history.count == 1)
        #expect(m.sampleRate == 0)
        #expect(abs(m.pipeline.relativeAngles?.pitch ?? 99) < 0.001)
        // The demo stopping is announced, then the real buds' arrival.
        #expect(m.lastAnnouncement == "Buds connected. Head tracking is live.")
    }
    @Test func navigatingSavesOriginalLabelInIsolatedStore() {
        let m = isolated()
        defer { m.stopDemo(); try? FileManager.default.removeItem(at: m.store.directory) }
        m.screen = .train; m.startDemo(); m.currentLabel = "nod"
        m.capture.toggle()
        for i in 0..<50 { m.capture.ingest(MotionSample(t: Double(i) / 50, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0)) }
        m.currentLabel = "shake"; m.screen = .model
        #expect(m.takes.count == 1)
        #expect(m.takes.first?.label == "nod")
    }
    @Test func connectedDeviceStopsDemoBeforeItsFirstSample() {
        let m = isolated()
        defer { m.stopDemo(); try? FileManager.default.removeItem(at: m.store.directory) }
        m.startDemo()
        m.reconcileMotionSource(state: .connected)
        #expect(!m.isDemo)
        #expect(m.activeSource == .device)
        #expect(m.latest == nil && m.sampleRate == 0)
        #expect(m.lastAnnouncement == "Demo stopped.")
    }

}

@MainActor @Suite("Scenario launch options")
struct ScenarioLaunchTests {
    @Test func everyScenarioParsesAndOthersAreNil() {
        let names = ["control-pointer-only", "control-voice-off", "control-voice-retrying", "control-voice-recovery-failed", "control-voice-denied", "control-voice-lost", "control-running", "control-calibration-failed",
                     "control-calibrating", "teach-recording", "model-failed", "detect-feedback", "model-gestures", "control-buds-lost", "control-buds-escalated"]
        for name in names {
            #expect(AppModel.launchOptions(from: ["--scenario=\(name)"]).scenario?.rawValue == name)
        }
        #expect(AppModel.Scenario.allCases.count == names.count)
        #expect(AppModel.launchOptions(from: ["--scenario=nope"]).scenario == nil)
        #expect(AppModel.launchOptions(from: ["--scenario="]).scenario == nil)
        #expect(AppModel.launchOptions(from: ["--demo"]).scenario == nil)
    }
    @Test func scenarioScreens() {
        #expect(AppModel.Scenario.controlVoiceDenied.screen == .mouse)
        #expect(AppModel.Scenario.teachRecording.screen == .train)
        #expect(AppModel.Scenario.modelFailed.screen == .model)
        #expect(AppModel.Scenario.detectFeedback.screen == .live)
    }
    @Test func accessibilityDumpPath() {
        #expect(AppModel.launchOptions(from: ["--dump-ax=/tmp/ax.txt"]).axDumpPath == "/tmp/ax.txt")
        #expect(AppModel.launchOptions(from: ["--dump-ax="]).axDumpPath == nil)
        #expect(AppModel.launchOptions(from: []).axDumpPath == nil)
    }
    @Test func withoutFlagsNothingIsOverridden() {
        let m = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-data/scenario-\(UUID())")))
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        m.applyLaunchArguments(["Murmury"])
        #expect(m.scenario == nil)
        #expect(m.screen == .mouse)
    }
}

@MainActor @Suite("Buds lost mid-session")
struct BudsLossTests {
    /// The buds stop streaming under a running head mouse: paused, said, reconnecting; back: resumed.
    @Test func lossPausesAnnouncesAndRecovers() async {
        let m = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-data/app-\(UUID())")))
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        var reconnects = 0
        m.reconnectMotion = { reconnects += 1 }
        let sample = HeadSample(q: Quat(w: 1, x: 0, y: 0, z: 0), gyro: nil, accel: nil, bud: 0)
        m.receiveDeviceMotion([sample], arrival: 1)
        m.headMouse.isEnabled = true
        m.reconcileMotionSource(state: .disconnected)
        #expect(m.motionLost && m.headMouse.isPaused)
        #expect(m.controlCopy.chip == "Paused · buds disconnected")
        #expect(m.lastAnnouncement == "Buds disconnected. Pointer paused. Reconnecting.")
        m.reconnectNow()
        #expect(reconnects == 1)
        m.receiveDeviceMotion([sample], arrival: 2)
        #expect(!m.motionLost && !m.headMouse.isPaused)
        #expect(m.lastAnnouncement == "Buds are back. Pointer resumed.")
        m.headMouse.isEnabled = false
    }
}

@MainActor @Suite("Buds lost during a pause")
struct BudsLossDuringPauseTests {
    /// A deliberate pause survives the buds leaving and coming back; the loss is quiet.
    @Test func returnKeepsAUserPause() {
        let m = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-data/app-\(UUID())")))
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        m.reconnectMotion = {}
        let sample = HeadSample(q: Quat(w: 1, x: 0, y: 0, z: 0), gyro: nil, accel: nil, bud: 0)
        m.receiveDeviceMotion([sample], arrival: 1)
        m.headMouse.isEnabled = true
        m.headMouse.perform(.pause)                 // "mouse off" for a break
        m.reconcileMotionSource(state: .disconnected)
        #expect(m.lastAnnouncement == "Buds disconnected. Reconnecting.")
        m.headMouse.perform(.resume)                // nothing to follow while the buds are gone
        #expect(m.headMouse.isPaused)
        #expect(m.lastAnnouncement == "Buds still disconnected. Pointer stays paused.")
        #expect(m.controlCopy.subtitle == "Paused by you; reconnecting the buds.")
        m.receiveDeviceMotion([sample], arrival: 2)
        #expect(m.headMouse.isPaused && !m.motionLost)
        #expect(m.lastAnnouncement == "Buds are back. Pointer still paused.")
        m.headMouse.isEnabled = false
    }
}


@MainActor @Suite("Buds outage escalation")
struct BudsEscalationTests {
    /// After 4 failed reconnects the outage is spoken once, for someone working in another app.
    @Test func fourFailedReconnectsAreAnnounced() async {
        let m = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-data/app-\(UUID())")))
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        var reconnects = 0
        m.reconnectMotion = { reconnects += 1 }
        m.motionRetryDelays = [0.01]
        let sample = HeadSample(q: Quat(w: 1, x: 0, y: 0, z: 0), gyro: nil, accel: nil, bud: 0)
        m.receiveDeviceMotion([sample], arrival: 1)
        m.headMouse.isEnabled = true
        m.reconcileMotionSource(state: .disconnected)
        for _ in 0..<200 where m.motionRetries < AppModel.motionEscalateAfter { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(m.motionRetries >= AppModel.motionEscalateAfter && reconnects >= 4)
        #expect(m.lastAnnouncement == "Still can't reach the buds. Check they're out of the case and charged.")
        m.headMouse.isEnabled = false
        await m.setHeadMouse(false)
    }
}
