import AppKit
import Testing
@testable import MurmuryKit

@MainActor @Suite("Offline evidence launch options")
struct LaunchEvidenceTests {
    @Test func pointerCoordinatesAreStrictAndNormalised() {
        #expect(AppModel.launchOptions(from: ["--pointer-at=0.25,0.35"]).pointerAt == CGPoint(x: 0.25, y: 0.35))
        #expect(AppModel.launchOptions(from: ["--pointer-at=0,1"]).pointerAt == CGPoint(x: 0, y: 1))
        for value in ["-0.1,0", "1.01,0", "0,nan", "inf,0", "0", "0,0,0", ",0", "0,"] {
            #expect(AppModel.launchOptions(from: ["--pointer-at=\(value)"]).pointerAt == nil)
        }
    }
    @Test func evidenceStatesDoNotActivateHardware() async throws {
        for name in ["control-pointer-only", "control-voice-off", "control-voice-retrying", "control-voice-recovery-failed"] {
            let scenario = try #require(AppModel.Scenario(rawValue: name))
            let mouse = HeadMouse(driver: FakePointer(), defaults: nil, ticks: false)
            let model = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: ".build/scenario-tests")), headMouse: mouse)
            model.startVoice = { Issue.record("Evidence requested voice"); return nil }
            model.applyScenario(scenario)
            #expect(!mouse.isEnabled)
            #expect(model.showsMouseOn)
            #expect(model.screen == .mouse)
        }
    }
}
