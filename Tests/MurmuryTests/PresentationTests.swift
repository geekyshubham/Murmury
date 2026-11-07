import Foundation
import Testing
@testable import MurmuryKit

@MainActor @Suite("Source presentation")
struct PresentationTests {
    func presentation(_ state: BudsService.State, demo: Bool = false, rate: Double = 50) -> BudsPresentation {
        BudsPresentation(state: state, isDemo: demo, sampleRate: rate, batteryLeft: 80, batteryRight: 70,
                         placementLeft: .unknown, placementRight: .unknown, sensorSupported: true)
    }
    @Test func hardwareStateTable() {
        for (state, step, text) in [(BudsService.State.disconnected, 1, "Not connected"), (.searching, 1, "Looking for buds…"),
                                    (.connecting, 1, "Connecting…"), (.connected, 2, "Connected"), (.streaming, 3, "Streaming · 50 Hz"),
                                    (.failed("Retry"), 1, "Couldn't connect")] {
            let p = presentation(state)
            #expect(p.hardwareStep == step)
            #expect(p.chipText == text)
            #expect(p.demoBanner == nil)
        }
    }
    @Test func demoDoesNotInventHardware() {
        let p = presentation(.disconnected, demo: true)
        #expect(p.chipText == "Buds not connected")
        #expect(p.hardwareStep == 1)
        #expect(p.batteryText == "Connect to read")
        #expect(p.wearText == "Connect to read")
        #expect(p.trackingText == "Synthetic demo motion")
        #expect(p.demoBanner != nil)
        #expect(presentation(.disconnected).trackingText == "Not streaming")
    }
    @Test func sparseHardwareIsStreamingAndStoppedRateIsHidden() {
        #expect(presentation(.streaming, rate: 1).chipText == "Streaming · 1 Hz")
        #expect(presentation(.connected, rate: 50).trackingText == "Not streaming")
        #expect(presentation(.streaming).batteryText == "Left 80% · Right 70%")
    }
}

@Suite("Control setup")
struct ControlSetupTests {
    func setup(motion: Bool = true, demo: Bool = false, busy: Bool = false, trusted: Bool = true,
               mic: Bool = false, calibrated: Bool = false, enabled: Bool = false) -> ControlSetup {
        ControlSetup.evaluate(hasMotion: motion, isDemo: demo, budsBusy: busy, trusted: trusted,
                              micRunning: mic, calibrated: calibrated, enabled: enabled)
    }
    @Test func primaryPrecedence() {
        #expect(setup(motion: false, trusted: false, enabled: true).primary == .stop)
        #expect(setup(motion: false, trusted: false).primary == .connect)
        #expect(setup(motion: false, busy: true).primary == .connecting)
        #expect(setup(trusted: false).primary == .allowAccess)
        #expect(setup().primary == .start)
    }
    @Test func demoCanStartWithoutPretendingBudsAreReady() {
        let p = setup(demo: true)
        #expect(p.rows.count == 3)
        #expect(p.rows[0].state == .needed)
        #expect(p.rows[0].detail == "Demo motion — connect real buds")
        #expect(p.primary == .start)
    }
    @Test func checklistAndCalibrationNeverBlockStart() {
        #expect(setup(busy: true, trusted: false).rows[1].state == .needed)
        #expect(setup(motion: false, busy: true).rows[0].state == .inProgress)
        #expect(setup().rows[0].state == .done)
        #expect(setup().rows[1].state == .done)
        #expect(setup().rows[2].state == .needed)
        #expect(setup(mic: true).rows[2].state == .done)
        #expect(setup().recommendCalibration)
        #expect(!setup(calibrated: true).recommendCalibration)
        #expect(!setup(motion: false).recommendCalibration)
        #expect(setup(mic: false).primary == .start)
    }
}

@Suite("Runtime privacy copy")
struct RuntimePrivacyTests {
    @Test func speechAndCameraClaimsMatchRuntime() {
        #expect(PrivacyPresentation.detail(cameraRunning: false, micRunning: false, speechRunning: false, onDevice: false) == "Camera off · microphone off")
        #expect(PrivacyPresentation.detail(cameraRunning: false, micRunning: true, speechRunning: true, onDevice: true) == "Camera off · speech stays on this Mac")
        #expect(PrivacyPresentation.detail(cameraRunning: false, micRunning: true, speechRunning: true, onDevice: false) == "Camera off · system speech service")
        #expect(PrivacyPresentation.detail(cameraRunning: false, micRunning: true, speechRunning: false, onDevice: false) == "Camera off · microphone is on")
        #expect(PrivacyPresentation.detail(cameraRunning: true, micRunning: true, speechRunning: true, onDevice: true) == "Calibration camera in use")
    }
}

@Suite("Calibration recovery")
struct CalibrationRecoveryTests {
    func evaluate(phase: CameraCalibration.Phase = .idle, auth: VoiceAuthorization = .authorized, hasCamera: Bool = true,
                  motion: Bool = true, step: HeadMouse.CalibrationStep? = nil, failed: Bool = false,
                  message: String? = nil) -> CalibrationRecovery? {
        CalibrationRecovery.evaluate(cameraPhase: phase, cameraAuth: auth, hasCamera: hasCamera, hasMotion: motion,
                                     noCameraStep: step, noCameraFailed: failed, message: message)
    }
    @Test func everyRoute() {
        #expect(evaluate() == nil)
        let denied = evaluate(phase: .failed("Camera access denied."), auth: .denied)
        #expect(denied?.actions == [.openCameraSettings, .calibrateWithoutCamera])
        #expect(evaluate(auth: .denied)?.actions == [.openCameraSettings, .calibrateWithoutCamera])
        #expect(evaluate(phase: .failed("No camera found."), hasCamera: false)?.actions == [.calibrateWithoutCamera])
        #expect(evaluate(hasCamera: false)?.actions == [.calibrateWithoutCamera])
        let fit = evaluate(phase: .failed("The movements didn't line up clearly enough."))
        #expect(fit?.actions == [.tryAgain, .calibrateWithoutCamera])
        #expect(fit?.text == "The movements didn't line up clearly enough.")
        #expect(evaluate(motion: false)?.actions == [.connectBuds])
        let running = evaluate(step: .turnRight)
        #expect(running?.actions == [])
        #expect(running?.text == "Step 1 of 2 · Turn right about 20°, then back to center")
        #expect(evaluate(step: .lookUp)?.text == "Step 2 of 2 · Look up about 20°, then back to center")
        let failed = evaluate(failed: true, message: "No movement seen.")
        #expect(failed?.actions == [.tryAgain, .useCamera])
        #expect(failed?.text == "No movement seen.")
        #expect(failed?.tone == .warn)
    }
    @Test func runningRouteWinsOverOlderFailures() {
        #expect(evaluate(phase: .failed("x"), auth: .denied, step: .turnRight)?.actions == [])
        #expect(evaluate(motion: false, failed: true, message: "m")?.actions == [.tryAgain, .useCamera])
    }
    @Test func noticeCarriesTwoActions() {
        let notice = StatusNotice(tone: .warn, text: "t", actionTitle: "A", action: {}, secondaryTitle: "B", secondaryAction: {})
        #expect(notice.secondaryTitle == "B")
        #expect(notice.secondaryAction != nil)
    }
}

@Suite("Control setup v2")
struct ControlSetupV2Tests {
    func setup(motion: Bool = true, demo: Bool = false, busy: Bool = false, trusted: Bool = true, mic: Bool = false,
               enabled: Bool = false, failure: VoiceFailure? = nil) -> ControlSetup {
        ControlSetup.evaluate(hasMotion: motion, isDemo: demo, budsBusy: busy, trusted: trusted, micRunning: mic,
                              calibrated: true, enabled: enabled, voiceFailure: failure)
    }
    @Test func fixVoiceIsThePrimaryOnFailure() {
        #expect(setup(failure: .micDenied).primary == .fixVoice)
        #expect(setup(trusted: false, failure: .micDenied).primary == .allowAccess)
        #expect(setup(motion: false, failure: .micDenied).primary == .connect)
        #expect(setup(enabled: true, failure: .stopped).primary == .stop)
        #expect(setup().primary == .start)
    }
    @Test func visibleRowsAreOnlyMissingSteps() {
        #expect(setup().visibleRows.isEmpty)
        #expect(setup(trusted: false).visibleRows.map(\.title) == ["Clicking permission"])
        #expect(setup(motion: false).visibleRows.map(\.title) == ["Buds"])
        let voice = setup(failure: .micDenied).visibleRows
        #expect(voice.map(\.title) == ["Microphone"])
        #expect(voice.first?.detail == "Spoken commands need it")
        #expect(setup(demo: true).visibleRows.isEmpty)
        #expect(!setup(mic: false).visibleRows.contains { $0.title == "Microphone" })
    }
    @Test func howItWorksOnceComplete() {
        let rows = setup().howItWorks
        #expect(rows.map(\.title) == ["Turn to point", "Murmur “click”", "Say “mouse off” to pause"])
        #expect(rows.map(\.detail) == ["Follows your head", "Also “right click”, “scroll down”", "Or press ⇧⌘M"])
        #expect(setup().isComplete)
        #expect(!setup(trusted: false).isComplete)
        #expect(!setup(failure: .speechDenied).isComplete)
    }
}

@MainActor @Suite("Sidebar status")
struct SidebarStatusTests {
    func buds(_ state: BudsService.State, demo: Bool = false) -> BudsPresentation {
        BudsPresentation(state: state, isDemo: demo, sampleRate: 50, batteryLeft: nil, batteryRight: nil,
                         placementLeft: .unknown, placementRight: .unknown, sensorSupported: nil)
    }
    @Test func priorityOrder() {
        let recording = SidebarStatus.evaluate(isDemo: true, hasMotion: true, recordingSession: true, presentation: buds(.disconnected, demo: true))
        #expect(recording.text == "Recording session")
        #expect(recording.tone == .danger)
        #expect(recording.items == [.openBuds, .stopDemo, .stopSession])
        let demo = SidebarStatus.evaluate(isDemo: true, hasMotion: true, recordingSession: false, presentation: buds(.disconnected, demo: true))
        #expect(demo.text == "Demo · not real buds")
        #expect(demo.tone == .demo)
        #expect(demo.items == [.openBuds, .stopDemo, .recordSession])
        let live = SidebarStatus.evaluate(isDemo: false, hasMotion: true, recordingSession: false, presentation: buds(.streaming))
        #expect(live.text == "Streaming · 50 Hz")
        #expect(live.tone == .live)
        #expect(live.items == [.openBuds, .recordSession])
        let none = SidebarStatus.evaluate(isDemo: false, hasMotion: false, recordingSession: false, presentation: buds(.disconnected))
        #expect(none.text == "Not connected")
        #expect(none.tone == .quiet)
        #expect(none.items == [.openBuds, .tryDemo, .recordSession])
    }
}
