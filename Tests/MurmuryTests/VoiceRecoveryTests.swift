import Foundation
import Testing
@testable import MurmuryKit

@MainActor @Suite("Voice recovery", .serialized)
struct VoiceRecoveryTests {
    final class Voice {
        var running = false
        var attempts = 0
        var failUntil = 0
        var auth = (mic: VoiceAuthorization.authorized, speech: VoiceAuthorization.authorized)
    }
    func model(_ voice: Voice) -> AppModel {
        let m = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: ".build/recovery-\(UUID())")),
                         headMouse: HeadMouse(driver: FakePointer(), defaults: nil, ticks: false))
        m.voiceIsRunning = { voice.running }
        m.voiceAuthorization = { voice.auth }
        m.startVoice = {
            voice.attempts += 1
            voice.running = voice.attempts > voice.failUntil
            return voice.running ? nil : .recognizerUnavailable
        }
        return m
    }
    func drain(_ condition: () -> Bool) async {
        for _ in 0..<2000 { if condition() { return }; await Task.yield() }
        #expect(condition())
    }
    @Test func scheduleAndAnnouncementCadence() {
        var policy = VoiceRecoveryPolicy()
        let now = Date(timeIntervalSince1970: 100)
        for (i, delay) in [2.0, 5, 15, 30, 30, 30, 30, 30].enumerated() {
            let scheduled = policy.schedule(at: now)
            #expect(scheduled == delay)
            #expect(policy.nextAttemptAt == now.addingTimeInterval(delay))
            #expect(policy.shouldAnnounce == [1, 4, 8].contains(i + 1))
        }
    }
    @Test func failuresThenSuccessResumeExactlyOnceAndNotificationsDoNotRestart() async {
        let voice = Voice(), m = model(voice)
        await m.setHeadMouse(true)
        voice.running = false; voice.attempts = 0; voice.failUntil = 2
        var delays: [Double] = [], resumed = 0
        m.voiceRecoverySleep = { seconds in delays.append(seconds); await Task.yield() }
        m.onAnnouncement = { if $0 == "Voice is back. Pointer resumed." { resumed += 1 } }
        m.checkVoiceHealth(); m.checkVoiceHealth(); m.checkVoiceHealth()
        await drain { !m.headMouse.isPaused }
        #expect(delays == [2, 5, 15])
        #expect(voice.attempts == 3 && resumed == 1)
        #expect(m.nextVoiceAttemptAt == nil)
        await m.setHeadMouse(false)
    }
    @Test func denialDoesNotPromptAndKeepsSettingsRoute() async {
        for denial in [VoiceFailure.micDenied, .speechDenied] {
            let voice = Voice(), m = model(voice)
            await m.setHeadMouse(true); voice.running = false
            voice.auth = denial == .micDenied ? (.denied, .authorized) : (.authorized, .denied)
            m.voiceRecoverySleep = { _ in await Task.yield() }
            m.checkVoiceHealth()
            await drain { m.voiceFailure == denial }
            #expect(voice.attempts == 1)
            #expect(m.nextVoiceAttemptAt == nil)
            #expect(m.voiceFailure?.recovery.primary == .openSettings(denial == .micDenied ? .microphone : .speechRecognition))
            await m.setHeadMouse(false)
        }
    }
    @Test func stoppedAndIneligibleModesCancelAndIgnoreStaleCompletion() async {
        for mode in 0..<3 {
            let voice = Voice(), m = model(voice)
            await m.setHeadMouse(true); voice.running = false
            var release: CheckedContinuation<Void, Never>?
            m.startVoice = { await withCheckedContinuation { release = $0 }; voice.running = true; return nil }
            m.voiceRecoverySleep = { _ in await Task.yield() }
            m.checkVoiceHealth()
            await drain { release != nil }
            if mode == 0 { await m.setHeadMouse(false) }
            else if mode == 1 { await m.setHeadMouse(true, pointerOnly: true) }
            else { m.headMouse.voiceClicks = false; m.checkVoiceHealth() }
            release?.resume()
            for _ in 0..<20 { await Task.yield() }
            #expect(m.nextVoiceAttemptAt == nil)
            #expect(m.handsFreeMode != .voice)
            #expect(m.lastAnnouncement != "Voice is back. Pointer resumed.")
            await m.setHeadMouse(false)
        }
    }
    @Test func voiceReturningBetweenAttemptsResumesOnce() async {
        let voice = Voice(), m = model(voice)
        await m.setHeadMouse(true); voice.running = false
        m.voiceRecoverySleep = { _ in try await Task.sleep(for: .seconds(100)) }
        var resumed = 0
        m.onAnnouncement = { if $0 == "Voice is back. Pointer resumed." { resumed += 1 } }
        m.checkVoiceHealth(); voice.running = true
        m.checkVoiceHealth(); m.checkVoiceHealth()
        #expect(!m.headMouse.isPaused && resumed == 1)
        #expect(m.nextVoiceAttemptAt == nil)
        await m.setHeadMouse(false)
    }
    @Test func alreadyPausedByUserStaysPausedWhenVoiceReturns() async {
        let voice = Voice(), m = model(voice)
        await m.setHeadMouse(true)
        m.headMouse.perform(.pause)
        voice.running = false
        m.voiceRecoverySleep = { _ in try await Task.sleep(for: .seconds(100)) }
        m.checkVoiceHealth()
        voice.running = true; m.checkVoiceHealth()
        #expect(m.headMouse.isPaused)
        #expect(m.lastAnnouncement == "Voice is back. Pointer remains paused.")
        await m.setHeadMouse(false)
    }

    @Test func returningFromPointerOnlyAnnouncesTheActualPauseState() async {
        for paused in [false, true] {
            let voice = Voice(), m = model(voice)
            await m.setHeadMouse(true, pointerOnly: true)
            if paused { m.headMouse.perform(.pause) }
            await m.restartVoice()
            #expect(m.handsFreeMode == .voice)
            #expect(m.headMouse.isPaused == paused)
            #expect(m.lastAnnouncement == (paused ? "Voice is back. Pointer remains paused." : "Voice is back. Pointer resumed."))
            await m.setHeadMouse(false)
        }
    }

    @Test func settingsVoiceSwitchCancelsLossAndReconcilesRunningMode() async {
        let voice = Voice(), m = model(voice)
        await m.setHeadMouse(true); voice.running = false
        m.voiceRecoverySleep = { _ in try await Task.sleep(for: .seconds(100)) }
        m.checkVoiceHealth()
        m.headMouse.voiceClicks = false; m.checkVoiceHealth()
        #expect(m.handsFreeMode == .voiceOff && !m.headMouse.isPaused)
        #expect(m.voiceFailure == nil && m.nextVoiceAttemptAt == nil)
        #expect(m.controlCopy.chip == "On · voice off")
        voice.running = true
        m.headMouse.voiceClicks = true; m.checkVoiceHealth()
        #expect(m.handsFreeMode == .voice)
        #expect(m.controlCopy.chip == "On · moving the pointer")
        await m.setHeadMouse(false)
    }
    @Test func settingsVoiceOffPreservesUserPauseAndNeverInvitesSpeech() async {
        let voice = Voice(), m = model(voice)
        await m.setHeadMouse(true); m.headMouse.perform(.pause)
        m.headMouse.voiceClicks = false; m.checkVoiceHealth()
        #expect(m.headMouse.isPaused)
        let copy = m.controlCopy
        #expect(!copy.rows.contains { $0.detail.localizedCaseInsensitiveContains("say") })
        await m.setHeadMouse(false)
    }

}
