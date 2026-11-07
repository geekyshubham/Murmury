import Foundation
import Testing
@testable import MurmuryKit

@Suite("Hands-free gate")
struct HandsFreeGateTests {
    @Test func everyBranch() {
        #expect(HandsFreeGate.decide(wantsVoice: true, pointerOnlyConfirmed: false, voiceRunning: true, failure: nil) == .enable(.voice))
        #expect(HandsFreeGate.decide(wantsVoice: true, pointerOnlyConfirmed: false, voiceRunning: false, failure: .micDenied) == .block(.micDenied))
        #expect(HandsFreeGate.decide(wantsVoice: true, pointerOnlyConfirmed: false, voiceRunning: false, failure: nil) == .block(.recognizerUnavailable))
        #expect(HandsFreeGate.decide(wantsVoice: true, pointerOnlyConfirmed: true, voiceRunning: false, failure: .speechDenied) == .enable(.pointerOnly))
        #expect(HandsFreeGate.decide(wantsVoice: true, pointerOnlyConfirmed: true, voiceRunning: true, failure: nil) == .enable(.voice))
        #expect(HandsFreeGate.decide(wantsVoice: false, pointerOnlyConfirmed: false, voiceRunning: false, failure: .micDenied) == .enable(.voiceOff))
    }
    @Test func failureClassificationPrefersAuthorization() {
        #expect(VoiceFailure.classify(micAuth: .denied, speechAuth: .denied, audioError: "x", speechError: "y") == .micDenied)
        #expect(VoiceFailure.classify(micAuth: .authorized, speechAuth: .denied, audioError: nil, speechError: "Speech recognizer unavailable.") == .speechDenied)
        #expect(VoiceFailure.classify(micAuth: .authorized, speechAuth: .authorized, audioError: nil, speechError: "Speech recognizer unavailable.") == .recognizerUnavailable)
        #expect(VoiceFailure.classify(micAuth: .authorized, speechAuth: .authorized, audioError: nil, speechError: "Speech recognition not authorized.") == .speechDenied)
        #expect(VoiceFailure.classify(micAuth: .authorized, speechAuth: .authorized, audioError: "Microphone access denied. Enable it.", speechError: nil) == .micDenied)
        #expect(VoiceFailure.classify(micAuth: .authorized, speechAuth: .authorized, audioError: "Input device busy", speechError: nil) == .device("Input device busy"))
        #expect(VoiceFailure.classify(micAuth: .notDetermined, speechAuth: .notDetermined, audioError: nil, speechError: nil) == nil)
    }
    @Test func recoveryRoutes() {
        #expect(VoiceFailure.micDenied.recovery.primary == .openSettings(.microphone))
        #expect(VoiceFailure.micDenied.recovery.secondary == .startWithoutVoice)
        #expect(VoiceFailure.speechDenied.recovery.primary == .openSettings(.speechRecognition))
        #expect(VoiceFailure.speechDenied.recovery.secondary == .startWithoutVoice)
        #expect(VoiceFailure.recognizerUnavailable.recovery.primary == .tryAgain)
        #expect(VoiceFailure.recognizerUnavailable.recovery.secondary == .startWithoutVoice)
        #expect(VoiceFailure.device("Busy").recovery.primary == .voiceSettings)
        #expect(VoiceFailure.device("Busy").recovery.secondary == .tryAgain)
        #expect(VoiceFailure.stopped.recovery.primary == .restartVoice)
        #expect(VoiceFailure.stopped.recovery.text == "Voice stopped — pointer paused")
        #expect(PrivacyPane.microphone.url.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(PrivacyPane.speechRecognition.url.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        #expect(PrivacyPane.camera.url.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }
}

@MainActor @Suite("Hands-free start", .serialized)
struct HandsFreeStartTests {
    final class Voice { var running = false; var failure: VoiceFailure?; var starts = 0
        var auth = (mic: VoiceAuthorization.denied, speech: VoiceAuthorization.authorized) }
    func make(_ voice: Voice) -> (AppModel, FakePointer) {
        let fake = FakePointer()
        let m = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-data/handsfree-\(UUID())")),
                         headMouse: HeadMouse(driver: fake, defaults: nil, ticks: false))
        m.startVoice = { voice.starts += 1; if voice.failure == nil { voice.running = true }; return voice.failure }
        m.voiceIsRunning = { voice.running }
        m.voiceAuthorization = { voice.auth }
        return (m, fake)
    }
    @Test func failingVoiceNeverEnablesThePointer() async {
        let voice = Voice(); voice.failure = .micDenied
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        await m.setHeadMouse(true)
        #expect(!m.headMouse.isEnabled)
        #expect(m.voiceFailure == .micDenied)
        #expect(m.handsFreeMode == nil)
        #expect(m.lastAnnouncement?.hasPrefix("Head mouse not started: voice commands unavailable.") == true)
    }
    /// A pause chosen in pointer-only mode reads as the user's pause, not a voice error, even with
    /// the voice failure that led there still on record.
    @Test func voicelessPauseIsTheUsersOwn() async {
        let voice = Voice(); voice.failure = .micDenied
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        await m.setHeadMouse(true, pointerOnly: true)
        m.headMouse.perform(.pause)
        #expect(m.controlCopy.chip == "Paused")
        #expect(m.controlCopy.rows[0].detail == "Nod twice to resume")
    }
    /// Voice and buds lost together: the pointer resumes only when both are back, in either order.
    @Test(arguments: [true, false]) func simultaneousLossesResumeOnlyWhenBothAreBack(voiceFirst: Bool) async {
        let voice = Voice(); voice.auth = (.authorized, .authorized)
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        m.reconnectMotion = {}
        m.voiceRecoverySleep = { _ in try await Task.sleep(for: .seconds(100)) }
        let sample = HeadSample(q: Quat(w: 1, x: 0, y: 0, z: 0), gyro: nil, accel: nil, bud: 0)
        m.receiveDeviceMotion([sample], arrival: 1)
        await m.setHeadMouse(true)
        #expect(m.headMouse.isEnabled && !m.headMouse.isPaused)
        // Voice drops, then the buds.
        voice.running = false; m.checkVoiceHealth()
        m.reconcileMotionSource(state: .disconnected)
        #expect(m.headMouse.isPaused && m.motionLost && m.voiceFailure == .stopped)
        if voiceFirst {
            voice.running = true; m.checkVoiceHealth()
            #expect(m.headMouse.isPaused)            // the buds are still gone
            m.receiveDeviceMotion([sample], arrival: 2)
        } else {
            m.receiveDeviceMotion([sample], arrival: 2)
            #expect(m.headMouse.isPaused)            // voice is still down
            voice.running = true; m.checkVoiceHealth()
        }
        #expect(!m.headMouse.isPaused && !m.motionLost && m.voiceFailure == nil)
        await m.setHeadMouse(false)
    }

    /// User pause → voice loss → buds loss: the user's pause survives both recovery orders, and
    /// each announcement says the pointer stays paused.
    @Test(arguments: [true, false]) func userPauseSurvivesStackedFailures(voiceFirst: Bool) async {
        let voice = Voice(); voice.auth = (.authorized, .authorized)
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        m.reconnectMotion = {}
        m.voiceRecoverySleep = { _ in try await Task.sleep(for: .seconds(100)) }
        let sample = HeadSample(q: Quat(w: 1, x: 0, y: 0, z: 0), gyro: nil, accel: nil, bud: 0)
        m.receiveDeviceMotion([sample], arrival: 1)
        await m.setHeadMouse(true)
        m.headMouse.perform(.pause)                          // the user's own pause
        voice.running = false; m.checkVoiceHealth()
        m.reconcileMotionSource(state: .disconnected)
        if voiceFirst {
            voice.running = true; m.checkVoiceHealth()
            #expect(m.lastAnnouncement == "Voice is back. Pointer stays paused until the buds are back.")
            m.receiveDeviceMotion([sample], arrival: 2)
            #expect(m.lastAnnouncement == "Buds are back. Pointer still paused.")
        } else {
            m.receiveDeviceMotion([sample], arrival: 2)
            #expect(m.lastAnnouncement == "Buds are back. Pointer stays paused until voice is back.")
            voice.running = true; m.checkVoiceHealth()
            #expect(m.lastAnnouncement == "Voice is back. Pointer remains paused.")
        }
        #expect(m.headMouse.isPaused && m.pauseCauses.isEmpty)
        await m.setHeadMouse(false)
    }

    /// Pointer-only with a voice failure on record: a nod pause is the user's, and survives the buds.
    @Test func pointerOnlyUserPauseSurvivesBudsLoss() async {
        let voice = Voice(); voice.failure = .micDenied
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        m.reconnectMotion = {}
        let sample = HeadSample(q: Quat(w: 1, x: 0, y: 0, z: 0), gyro: nil, accel: nil, bud: 0)
        m.receiveDeviceMotion([sample], arrival: 1)
        await m.setHeadMouse(true)                           // voice fails: blocked, failure recorded
        await m.setHeadMouse(true, pointerOnly: true)        // continue without voice; the failure stays on record
        #expect(m.voiceFailure != nil && m.handsFreeMode == .pointerOnly)
        m.headMouse.perform(.pause)
        m.reconcileMotionSource(state: .disconnected)
        m.receiveDeviceMotion([sample], arrival: 2)
        #expect(m.headMouse.isPaused)
        #expect(m.lastAnnouncement == "Buds are back. Pointer still paused.")
        await m.setHeadMouse(false)
    }

    /// "Start when buds connect" with failing voice: pointer-only with dwell, never a dead end.
    @Test func unattendedStartFallsBackToPointerOnlyWithDwell() async {
        let voice = Voice(); voice.failure = .micDenied
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        m.headMouse.dwellClicks = false
        await m.setHeadMouse(true, unattended: true)
        #expect(m.headMouse.isEnabled)
        #expect(m.handsFreeMode == .pointerOnly)
        #expect(m.headMouse.dwellClicks)
        #expect(m.voiceFailure == .micDenied)
        #expect(m.lastAnnouncement?.contains("without voice") == true)
    }
    @Test func voiceStartsBeforeThePointer() async {
        let voice = Voice()
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        await m.setHeadMouse(true)
        #expect(voice.starts == 1)
        #expect(m.headMouse.isEnabled)
        #expect(m.handsFreeMode == .voice)
        #expect(m.voiceFailure == nil)
        await m.setHeadMouse(false)
        #expect(!m.headMouse.isEnabled)
        #expect(m.handsFreeMode == nil)
    }
    @Test func pointerOnlyNeedsConfirmationAndVoiceOffSkipsVoice() async {
        let voice = Voice(); voice.failure = .speechDenied
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        await m.setHeadMouse(true, pointerOnly: true)
        #expect(m.headMouse.isEnabled)
        #expect(m.handsFreeMode == .pointerOnly)
        await m.setHeadMouse(false)
        m.headMouse.voiceClicks = false
        voice.starts = 0
        await m.setHeadMouse(true)
        #expect(voice.starts == 0)
        #expect(m.handsFreeMode == .voiceOff)
        #expect(m.headMouse.isEnabled)
    }
    @Test func recheckClearsAFixedFailureWithoutEnabling() async {
        let voice = Voice(); voice.failure = .micDenied
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        await m.setHeadMouse(true)
        m.recheckVoice()
        #expect(m.voiceFailure == .micDenied)
        voice.auth = (.authorized, .authorized)
        m.recheckVoice()
        #expect(m.voiceFailure == nil)
        #expect(!m.headMouse.isEnabled)
    }
    @Test func voiceDroppingPausesThePointer() async {
        let voice = Voice()
        let (m, _) = make(voice)
        defer { try? FileManager.default.removeItem(at: m.store.directory) }
        await m.setHeadMouse(true)
        m.checkVoiceHealth()
        #expect(!m.headMouse.isPaused)
        voice.running = false
        m.checkVoiceHealth()
        #expect(m.headMouse.isPaused)
        #expect(m.voiceFailure == .stopped)
        voice.running = true
        await m.restartVoice()
        #expect(!m.headMouse.isPaused)
        #expect(m.voiceFailure == nil)
    }
}
