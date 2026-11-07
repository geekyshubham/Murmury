import Foundation

/// Permission state, independent of the frameworks that report it.
enum VoiceAuthorization: Equatable { case notDetermined, denied, authorized }

/// Why spoken click and pause are unavailable.
enum VoiceFailure: Equatable {
    case micDenied, speechDenied, recognizerUnavailable, device(String)
    /// Voice was running with the head mouse and stopped.
    case stopped

    /// Authorization status wins over error text; errors then decide between the recognizer and the device.
    static func classify(micAuth: VoiceAuthorization, speechAuth: VoiceAuthorization, audioError: String?, speechError: String?) -> VoiceFailure? {
        if micAuth == .denied { return .micDenied }
        if speechAuth == .denied { return .speechDenied }
        if let speechError { return speechError.localizedCaseInsensitiveContains("not authorized") ? .speechDenied : .recognizerUnavailable }
        if let audioError { return audioError.localizedCaseInsensitiveContains("denied") ? .micDenied : .device(audioError) }
        return nil
    }

    enum Action: Equatable { case openSettings(PrivacyPane), checkAgain, tryAgain, voiceSettings, restartVoice, startWithoutVoice }
    struct Recovery: Equatable {
        var text: String
        var primary: Action
        var secondary: Action?
        /// Shown when the round button carries `primary`, so the notice still offers two ways on.
        var tertiary: Action? = .startWithoutVoice
    }
    var recovery: Recovery {
        switch self {
        case .micDenied: Recovery(text: "Murmury can't hear you: microphone access is off", primary: .openSettings(.microphone), secondary: .startWithoutVoice)
        case .speechDenied: Recovery(text: "Murmury can't understand you: speech recognition is off", primary: .openSettings(.speechRecognition), secondary: .startWithoutVoice)
        case .recognizerUnavailable: Recovery(text: "Speech recognition isn't available right now", primary: .tryAgain, secondary: .startWithoutVoice)
        // Plain words on screen; the system's error text goes to the log (`AudioService`).
        case .device: Recovery(text: "The microphone didn't start. Check it's connected, then try again", primary: .voiceSettings, secondary: .tryAgain)
        case .stopped: Recovery(text: "Voice stopped — pointer paused", primary: .restartVoice, secondary: nil)
        }
    }
    /// Short detail for the Microphone setup row.
    var rowDetail: String {
        switch self {
        case .micDenied, .speechDenied: "Spoken commands need it"
        case .recognizerUnavailable: "Speech recognition unavailable"
        case .device: "Microphone didn't start"
        case .stopped: "Voice stopped"
        }
    }
}

extension VoiceFailure.Action {
    var title: String {
        switch self {
        case .openSettings: "Open Settings"
        case .checkAgain: "Check again"
        case .tryAgain: "Try again"
        case .voiceSettings: "Microphone…"
        case .restartVoice: "Retry voice"
        case .startWithoutVoice: "Continue without voice…"
        }
    }
    /// The same action on the round button: short, no ellipsis.
    var orbTitle: String {
        switch self {
        // One line on the 106 pt disc.
        case .openSettings: "Allow voice"
        case .checkAgain: "Check again"
        case .tryAgain: "Try again"
        case .voiceSettings: "Settings"
        case .restartVoice: "Retry voice"
        case .startWithoutVoice: "No voice"
        }
    }
}

enum PrivacyPane: String, Equatable {
    case microphone = "Privacy_Microphone", speechRecognition = "Privacy_SpeechRecognition", camera = "Privacy_Camera"
    case accessibility = "Privacy_Accessibility"
    var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }
}

/// How the pointer may run.
enum HandsFreeMode: Equatable {
    /// Spoken click and pause work.
    case voice
    /// The user explicitly chose to run without spoken commands after voice failed.
    case pointerOnly
    /// Voice commands are switched off in Settings.
    case voiceOff
}

/// The pointer never runs "hands-free" while spoken click or pause is unavailable, unless the user
/// explicitly confirmed pointer-only.
enum HandsFreeGate: Equatable {
    case enable(HandsFreeMode)
    case block(VoiceFailure)

    static func decide(wantsVoice: Bool, pointerOnlyConfirmed: Bool, voiceRunning: Bool, failure: VoiceFailure?) -> HandsFreeGate {
        if !wantsVoice { return .enable(.voiceOff) }
        if voiceRunning { return .enable(.voice) }
        if pointerOnlyConfirmed { return .enable(.pointerOnly) }
        return .block(failure ?? .recognizerUnavailable)
    }
}

/// Retry timing is independent of microphone, pointer, UI and wall-clock sleeps.
struct VoiceRecoveryPolicy {
    enum Phase { case idle, waiting, restarting, failed }
    private(set) var attempt = 0
    var phase: Phase = .idle
    private(set) var nextAttemptAt: Date?
    var shouldAnnounce: Bool { attempt == 1 || attempt % 4 == 0 }
    mutating func schedule(at now: Date) -> Double {
        let delay = [2.0, 5, 15, 30][min(attempt, 3)]
        attempt += 1; nextAttemptAt = now.addingTimeInterval(delay); phase = .waiting
        return delay
    }
    mutating func restarting() { nextAttemptAt = nil; phase = .restarting }
}

/// Recovery only: this never classifies normal motion or drives the pointer.
struct DoubleNodDetector {
    /// How far down a nod has to go (degrees) and how slow it may be: adjustable for limited neck
    /// movement (Settings › Pointer › Nodding).
    var depth = 10.0
    var slowness = 1.0
    init(depth: Double = 10, slowness: Double = 1) { self.depth = depth; self.slowness = slowness }
    private var history: [(time: Double, pitch: Double)] = []
    private var lastTime: Double?
    private var dip: (time: Double, baseline: Double)?
    private var firstNod: Double?
    private var refractoryUntil = -Double.infinity
    /// The resting pitch, kept across stream gaps: buds send about one sample a second while the
    /// head is still, so the first nod after resting starts from a gap with no recent history.
    private var rest: Double?
    private var lastPitch: Double?
    static func isArmed(stopped: Bool, enabled: Bool, paused: Bool, calibrating: Bool, demo: Bool) -> Bool {
        stopped && enabled && paused && !calibrating && !demo
    }
    /// After one retry, the next double nod goes on without voice, however long it took: no
    /// hidden time limit for someone who moves slowly. With no other way to click, going on
    /// turns dwell clicking on, so nobody is left with a pointer that cannot click.
    static func offersPointerOnly(lastRetry: Double?, now: Double) -> Bool {
        guard let lastRetry else { return false }
        return now >= lastRetry
    }
    mutating func ingest(pitch: Double, time: Double, armed: Bool) -> Bool {
        // Disarmed: forget the motion, keep the person's settings (depth and pace).
        guard armed, pitch.isFinite, time.isFinite else { self = Self(depth: depth, slowness: slowness); return false }
        if let lastTime, time <= lastTime || time - lastTime > 0.5 {
            // A gap means the head was still (the stream slows) or the stream restarted: the last
            // pitch before it is where the head rests. A nod in progress doesn't survive a gap.
            if time > lastTime, let lastPitch { rest = lastPitch }
            history = []; dip = nil
            if time - lastTime > 2 { firstNod = nil }
        }
        lastTime = time
        history.removeAll { time - $0.time > 1.5 }
        let sorted = history.map(\.pitch).sorted()
        if sorted.count >= 10 { rest = sorted[sorted.count / 2] }
        let baseline = sorted.count >= 10 ? sorted[sorted.count / 2] : (rest ?? pitch)
        defer { history.append((time, pitch)); lastPitch = pitch }
        guard time >= refractoryUntil else { dip = nil; firstNod = nil; return false }
        if let started = dip {
            if time - started.time > 0.9 * slowness { dip = nil; firstNod = nil }
            else if abs(pitch - started.baseline) <= 0.4 * depth {
                dip = nil
                if let firstNod, time - firstNod <= 2 * slowness {
                    self.firstNod = nil; refractoryUntil = time + 3; return true
                }
                firstNod = time
            }
        } else if history.count >= 10 || rest != nil, pitch <= baseline - depth {
            dip = (time, baseline)
        }
        return false
    }
}
