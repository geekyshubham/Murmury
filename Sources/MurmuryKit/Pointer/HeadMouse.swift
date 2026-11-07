import CoreGraphics
import Foundation
import Observation

enum MouseButton: Equatable, Sendable { case left, right }

/// Where pointer movement, clicks and scrolls go. `SystemPointer` posts real events; tests use a fake.
@MainActor
protocol PointerDriver: AnyObject {
    /// Global display coordinates, origin top-left of the main display, y down.
    var location: CGPoint { get }
    var displays: [CGRect] { get }
    /// Posting clicks needs the Accessibility permission.
    var isTrusted: Bool { get }
    func requestTrust()
    func move(to p: CGPoint)
    func click(_ button: MouseButton, count: Int, at p: CGPoint)
    /// Press and hold, then release: a drag between them (moves while held post as drags).
    func press(_ button: MouseButton, at p: CGPoint)
    func release(_ button: MouseButton, at p: CGPoint)
    /// Moves the view by this many points: `dy > 0` scrolls down, `dx > 0` scrolls right.
    func scroll(dx: Int32, dy: Int32)
}

/// Head mouse: head rotation moves the pointer (or scrolls), spoken commands click and scroll.
@MainActor @Observable
final class HeadMouse {
    enum Mode: String, Equatable { case pointer, scroll }
    enum CalibrationStep: Equatable { case turnRight, lookUp }

    var isEnabled = false { didSet { if oldValue != isEnabled { enabledChanged() } } }
    var isPaused = false
    /// Resume is unavailable (the buds are gone): nothing to follow until they are back.
    var holdPaused = false
    /// A resume asked for while held (so it can be answered, not ignored in silence).
    @ObservationIgnored var onResumeRefused: (() -> Void)?
    var mode: Mode = .pointer { didSet { pointer.reset(); scrollRemainder = .zero; velocity = .zero; lastScrollAt = nil } }
    var voiceClicks = true { didSet { save() } }
    var holdWhileSpeaking = true { didSet { save() } }
    /// Trained motion labels named like a command ("click", "right click") also trigger it.
    /// Off by default: moving the pointer is head movement too, and could be misread as a gesture.
    var motionCommands = false { didSet { save() } }
    /// Hold the pointer still to click: for people who can't use voice. Off by default.
    var dwellClicks = false { didSet { save(); dwell = DwellClicker(seconds: dwellSeconds) } }
    /// What the next dwell click does; right and double apply once, then it returns to left.
    enum DwellAction: String, CaseIterable, Equatable {
        case left, right, double, drag
        var command: MouseCommand { switch self { case .left: .leftClick; case .right: .rightClick; case .double: .doubleClick; case .drag: .drag } }
    }
    /// The left button is held by a drag (voice "drag", or the palette's Drag then a dwell).
    private(set) var isDragging = false
    var dwellAction = DwellAction.left
    /// The floating click-type palette (Left, Right, Double, Drag), itself usable by dwelling on it.
    var dwellPalette = true { didSet { save() } }
    /// Every performed command, for announcements (VoiceOver hears what was done).
    @ObservationIgnored var onCommand: ((MouseCommand, CommandSource) -> Void)?
    /// Where the last command came from, so feedback can say "Heard" only for voice.
    enum CommandSource: Equatable { case voice, gesture, dwell, other }
    private(set) var lastSource: CommandSource?
    /// The last command voice produced (shown as "Heard …").
    private(set) var lastVoiceCommand: MouseCommand?
    /// How long the pointer holds still before a dwell click (Settings › Pointer). Observable
    /// properties must not assign themselves in `didSet` (it recurses), so values are clamped on use.
    var dwellSeconds = DwellClicker.defaultSeconds {
        didSet { save(); dwell = DwellClicker(seconds: dwellSeconds) }
    }
    var config: HeadPointer.Config { didSet { pointer.config = config; save() } }

    private(set) var lastCommand: MouseCommand?
    private(set) var lastCommandAt: Date?
    private(set) var isSpeaking = false
    /// The pointer is holding still for speech right now: only for speech short enough to be a
    /// command (see `commandHold`), so talking or dictating never freezes it.
    private(set) var isHoldingForSpeech = false
    private(set) var isTrusted = false
    private(set) var calibration: CalibrationStep? {
        didSet { if oldValue != calibration { onCalibrationStep?(calibration) } }
    }
    /// Called on every calibration step change (nil when it ends), so it can be announced.
    @ObservationIgnored var onCalibrationStep: ((CalibrationStep?) -> Void)?
    private(set) var calibrationMessage: String?
    /// The last camera-free calibration ended without a result (not cancelled).
    private(set) var lastCalibrationFailed = false
    /// How the last calibration ended, set before `calibration` clears so the step callback
    /// (and its announcement) sees the real result.
    enum CalibrationOutcome: Equatable { case succeeded, failed, cancelled }
    private(set) var lastCalibrationOutcome: CalibrationOutcome?

    /// A step records this long once you start moving…
    static let calibrationWindow: TimeInterval = 2.0
    /// …and gives up if you haven't started moving after this long.
    static let calibrationTimeout: TimeInterval = 6.0
    /// Rotation faster than this (°/s) counts as starting the movement.
    static let calibrationStartSpeed = 15.0

    @ObservationIgnored let driver: PointerDriver
    @ObservationIgnored private var pointer: HeadPointer
    @ObservationIgnored private var parser = VoiceCommandParser()
    @ObservationIgnored private var voice = VoiceActivity()
    @ObservationIgnored private var scrollRemainder = CGVector.zero
    @ObservationIgnored private var dwell = DwellClicker()
    /// Latest pointer velocity (pt/s), applied by `tick` at display rate so clumped packets
    /// don't turn into jumps and stalls.
    @ObservationIgnored private var velocity = CGVector.zero
    @ObservationIgnored private var lastSampleAt: TimeInterval?
    @ObservationIgnored private var lastTick: TimeInterval?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let ticks: Bool
    /// No new sample for this long: the stream stalled, stop gliding.
    static let staleAfter: TimeInterval = 0.25
    @ObservationIgnored private var calibrationSamples: [MotionSample] = []
    @ObservationIgnored private var calibrationStepStart: TimeInterval?
    @ObservationIgnored private var calibratedHorizontal: AxisMap?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults?

    init(driver: PointerDriver, defaults: UserDefaults? = .standard, ticks: Bool = true) {
        self.driver = driver
        self.ticks = ticks
        self.defaults = defaults
        let saved = defaults?.data(forKey: Keys.config).flatMap { try? JSONDecoder().decode(HeadPointer.Config.self, from: $0) }
        let config = saved ?? HeadPointer.Config()
        self.config = config
        pointer = HeadPointer(config: config)
        if let defaults {
            // Read everything first: each assignment below saves all settings, so loading one at
            // a time would overwrite the stored values not yet read.
            let voice = defaults.object(forKey: Keys.voice) as? Bool ?? true
            let hold = defaults.object(forKey: Keys.hold) as? Bool ?? true
            let motion = defaults.bool(forKey: Keys.motion)
            let dwellOn = defaults.bool(forKey: Keys.dwell)
            let dwellTime = (defaults.object(forKey: Keys.dwellSeconds) as? Double).map(DwellClicker.clamp) ?? DwellClicker.defaultSeconds
            let palette = defaults.object(forKey: Keys.dwellPalette) as? Bool ?? true
            voiceClicks = voice; holdWhileSpeaking = hold; motionCommands = motion
            dwellSeconds = dwellTime; dwellPalette = palette; dwellClicks = dwellOn
        }
        isTrusted = driver.isTrusted
    }

    // MARK: Inputs

    func ingest(_ s: MotionSample) {
        lastSampleAt = s.t
        if calibration != nil { velocity = .zero; collectCalibration(s); return }
        let speaking = voice.isSpeaking(at: s.t) || murmuring(at: s.t)
        if speaking != isSpeaking { isSpeaking = speaking }
        let holding = holdsForSpeech(speaking, at: s.t)
        if holding != isHoldingForSpeech { isHoldingForSpeech = holding }
        guard isEnabled, !isPaused, !holding else {
            velocity = .zero
            pointer.reset()
            return
        }
        velocity = pointer.velocity(for: s)
    }

    /// Moves the pointer (or scrolls) by the current velocity. Runs at 120 Hz in the app.
    func tick(at now: TimeInterval) {
        defer { lastTick = now }
        dwellIfStill(at: now)
        guard let lastTick, now > lastTick, let lastSampleAt, now - lastSampleAt <= Self.staleAfter,
              isEnabled, !isPaused, calibration == nil, !holdsForSpeech(voice.isSpeaking(at: now), at: now),
              velocity != .zero else { return }
        let dt = min(now - lastTick, 0.05)
        apply(CGVector(dx: velocity.dx * dt, dy: velocity.dy * dt), at: now)
    }

    /// Dwell needs a live stream: a stalled stream also holds the pointer still, and must not click.
    /// Never leave the button held: pausing, switching mode or stopping lets go.
    private func releaseDrag() {
        guard isDragging else { return }
        driver.release(.left, at: driver.location); isDragging = false
    }

    /// Buds send about one sample a second while the head is still, so dwell tolerates gaps up to
    /// this long; a click still needs a sample from during the hold (see `DwellClicker.update`).
    static let dwellStaleAfter: TimeInterval = 1.6
    /// In scroll mode, holding still this many dwell times returns to pointing (after scrolling).
    static let scrollExitFactor = 1.5
    /// When the last scroll event was posted in this scroll mode (nil until it scrolls).
    @ObservationIgnored private var lastScrollAt: TimeInterval?

    private func dwellIfStill(at now: TimeInterval) {
        guard dwellClicks, isEnabled, !isPaused, calibration == nil,
              let lastSampleAt, now - lastSampleAt <= Self.dwellStaleAfter else {
            dwell = DwellClicker(seconds: dwellSeconds); dwellLive = false; return
        }
        if mode == .scroll {
            // The hands-free way out of scroll mode: after scrolling, hold still to point again.
            // A sample from during the stillness is required, as for a click.
            dwellLive = false
            if let since = lastScrollAt, now - since >= dwellSeconds * Self.scrollExitFactor, lastSampleAt > since {
                perform(.pointerMode, source: .dwell)
            }
            return
        }
        dwellLive = true
        if dwell.update(driver.location, at: now, confirmedAt: lastSampleAt) {
            // Drag takes two dwells: the first presses, the next (wherever you hold still) drops.
            if dwellAction == .drag {
                perform(isDragging ? .drop : .drag, source: .dwell)
                if !isDragging { dwellAction = .left }
            } else {
                perform(dwellAction.command, source: .dwell)
                if dwellAction != .left { dwellAction = .left }
            }
        }
    }
    @ObservationIgnored private var dwellLive = false
    /// 0…1 while a dwell click builds (for the ring by the pointer); nil when none is underway.
    func dwellProgress(at now: TimeInterval) -> Double? { dwellLive ? dwell.progress(at: now) : nil }

    private func apply(_ d: CGVector, at now: TimeInterval) {
        switch mode {
        case .pointer:
            let from = driver.location
            driver.move(to: Self.clamp(CGPoint(x: from.x + d.dx, y: from.y + d.dy), from: from, displays: driver.displays))
        case .scroll:
            // Scroll along the dominant direction only, so reading down a page doesn't drift sideways.
            let k = config.scrollSpeed * (config.invertScroll ? -1 : 1)
            let step = abs(d.dy) >= abs(d.dx) ? CGVector(dx: 0, dy: d.dy * k) : CGVector(dx: d.dx * k, dy: 0)
            scrollRemainder.dx += step.dx
            scrollRemainder.dy += step.dy
            let dx = scrollRemainder.dx.rounded(.towardZero), dy = scrollRemainder.dy.rounded(.towardZero)
            guard dx != 0 || dy != 0 else { return }
            scrollRemainder.dx -= dx
            scrollRemainder.dy -= dy
            lastScrollAt = now
            driver.scroll(dx: Int32(dx), dy: Int32(dy))
        }
    }

    /// Latest live transcript from the speech recognizer.
    /// `actionsAllowed: false` consumes the transcript's commands without acting on them.
    func hear(text: String, actionsAllowed: Bool = true) {
        let tokens = VoiceCommandParser.tokenize(text)
        // A recogniser restart starts a fresh, shorter transcript: the utterance starts with it.
        if tokens.count < utteranceStart { utteranceStart = 0 }
        transcriptTokens = tokens
        let commands = parser.commands(in: text)
        guard actionsAllowed, isEnabled, voiceClicks else { pending = []; return }
        // While teaching the murmur model the person reads command words aloud: none may act.
        guard commandsAllowed?() ?? true else { pending = []; return }
        // With "only my voice" on, a command counts only if the wearer's buds felt them speak it.
        guard ownVoiceGate?() ?? true else {
            if !commands.isEmpty { FieldJournal.shared?.event("not-wearer", ["words": tokens.suffix(8).joined(separator: " ")]) }
            pending = []; return
        }
        // Without the microphone's level there are no pauses to find utterances by: act at once.
        guard heardLevels else { commands.forEach { perform($0, source: .voice) }; return }
        pending += commands
        if !micSpeaking { settleUtterance() }
    }

    // MARK: Utterances
    // A command is something said on its own: "click", "scroll down", then a pause. The same
    // words inside a sentence ("so I click the button and it scrolls down") are conversation or
    // dictation and never act. Utterances are the words heard between the microphone's pauses.

    /// Speech longer than this is talk, not a command: the pointer stops holding for it.
    static let commandHold: TimeInterval = 1.5
    /// Words that may surround a command without making it conversation.
    static let fillers: Set<String> = ["um", "uh", "er", "erm", "hmm", "please", "now", "ok", "okay"]
    @ObservationIgnored private var transcriptTokens: [String] = []
    @ObservationIgnored private var utteranceStart = 0
    @ObservationIgnored private var pending: [MouseCommand] = []
    @ObservationIgnored private var heardLevels = false
    @ObservationIgnored private var micSpeaking = false
    @ObservationIgnored private var speechOnset: TimeInterval?

    /// The microphone hears speech now (its own voice activity, without felt murmur).
    var micHearsSpeech: Bool { micSpeaking }
    /// The words of the utterance in progress (or just ended).
    var utteranceWords: [String] { Array(transcriptTokens[min(utteranceStart, transcriptTokens.count)...]) }

    /// Acts on the utterance's commands only if it held nothing but commands (and fillers).
    private func settleUtterance() {
        defer { pending = [] }
        guard !pending.isEmpty else { return }
        guard VoiceCommandParser.commandsAlone(utteranceWords, fillers: Self.fillers) != nil else {
            FieldJournal.shared?.event("conversation", ["words": utteranceWords.suffix(12).joined(separator: " ")])
            return
        }
        pending.forEach { perform($0, source: .voice) }
    }

    /// Hold the pointer for heard speech only while it is short enough to be a command.
    private func holdsForSpeech(_ speaking: Bool, at t: TimeInterval) -> Bool {
        guard holdWhileSpeaking, speaking else { return false }
        guard let speechOnset else { return true }  // felt murmur, no microphone: hold
        return t - speechOnset <= Self.commandHold
    }
    /// Whether a heard command may act (set by the app from the murmur model).
    @ObservationIgnored var ownVoiceGate: (() -> Bool)?
    /// False while commands must not act at all (murmur teaching reads them aloud).
    @ObservationIgnored var commandsAllowed: (() -> Bool)?

    /// The buds felt the wearer murmuring at `t` (sample time): holds the pointer like heard speech,
    /// so a quiet "click" that the microphone barely catches still doesn't jog the pointer.
    func feel(murmur: Bool, at t: TimeInterval) {
        if murmur { lastMurmur = t }
    }
    @ObservationIgnored private var lastMurmur: TimeInterval?
    private func murmuring(at t: TimeInterval) -> Bool {
        guard let lastMurmur else { return false }
        return t >= lastMurmur && t - lastMurmur <= MurmurDetector.hangover
    }

    /// Microphone level (0…1) at `t` seconds since boot, the clock motion samples use.
    func hear(level: Float, at t: TimeInterval) {
        heardLevels = true
        let speaking = voice.update(level: level, at: t)
        FieldJournal.shared?.heard(speaking: speaking)
        if speaking, !micSpeaking {
            // Speech starts: a new utterance, from the words the transcript has so far.
            micSpeaking = true; speechOnset = t; utteranceStart = transcriptTokens.count; pending = []
        } else if !speaking, micSpeaking {
            // A pause: the utterance is over; act on it if it was a command said on its own.
            micSpeaking = false; speechOnset = nil
            settleUtterance()
        }
        if speaking != isSpeaking { isSpeaking = speaking }
    }

    /// An accepted prediction from the trained motion model or templates.
    func perform(label: String) {
        guard motionCommands, commandsAllowed?() ?? true, let command = VoiceCommandParser.command(forLabel: label) else { return }
        perform(command, source: .gesture)
    }

    func perform(_ command: MouseCommand, source: CommandSource = .other) {
        guard isEnabled else { return }
        if isPaused, command != .resume { return }
        let step = Int32(config.scrollStep) * (config.invertScroll ? -1 : 1)
        switch command {
        case .pause: isPaused = true; releaseDrag()
        case .resume:
            guard !holdPaused else { onResumeRefused?(); return }
            isPaused = false
        case .drag:
            guard !isDragging else { break }
            driver.press(.left, at: driver.location); isDragging = true
        case .drop: releaseDrag()
        case .leftClick: driver.click(.left, count: 1, at: driver.location)
        case .rightClick: driver.click(.right, count: 1, at: driver.location)
        case .doubleClick: driver.click(.left, count: 2, at: driver.location)
        case .scrollUp: driver.scroll(dx: 0, dy: -step)
        case .scrollDown: driver.scroll(dx: 0, dy: step)
        case .scrollLeft: driver.scroll(dx: -step, dy: 0)
        case .scrollRight: driver.scroll(dx: step, dy: 0)
        case .scrollMode: releaseDrag(); mode = .scroll
        case .pointerMode: mode = .pointer
        }
        lastCommand = command
        lastCommandAt = Date()
        lastSource = source
        if source == .voice { lastVoiceCommand = command }
        onCommand?(command, source)
    }

    // MARK: Permission

    func refreshTrust() { isTrusted = driver.isTrusted }
    func requestTrust() { driver.requestTrust(); refreshTrust() }

    // MARK: Calibration

    /// Two steps: turn right and back, then look up and back. Works out which sensor axis is
    /// which for the bud that's currently reporting.
    func startCalibration() {
        lastCalibrationFailed = false
        lastCalibrationOutcome = nil
        calibration = .turnRight
        calibrationMessage = nil
        calibrationSamples = []
        calibrationStepStart = nil
        calibratedHorizontal = nil
    }

    /// Axes learned elsewhere (webcam calibration) for the bud that's reporting.
    func applyCalibration(_ axes: HeadPointer.Axes, bud: UInt8, message: String, fromCamera: Bool = true, model: HeadModel? = nil) {
        config.learn(axes, bud: bud, fromCamera: fromCamera, model: model)
        calibrationMessage = message
        pointer.reset()
    }

    func cancelCalibration() {
        guard calibration != nil else { return }
        lastCalibrationOutcome = .cancelled
        calibration = nil
        calibrationSamples = []
    }

    private func collectCalibration(_ s: MotionSample) {
        if calibrationSamples.isEmpty {
            let stepStart = calibrationStepStart ?? s.t
            calibrationStepStart = stepStart
            guard s.angularSpeed * 180 / .pi >= Self.calibrationStartSpeed else {
                if s.t - stepStart > Self.calibrationTimeout {
                    failCalibration("No movement seen. Choose Try again, then move when asked.")
                }
                return
            }
        }
        calibrationSamples.append(s)
        guard let first = calibrationSamples.first, s.t - first.t >= Self.calibrationWindow else { return }
        let samples = calibrationSamples
        calibrationSamples = []
        calibrationStepStart = nil
        switch calibration {
        case .turnRight:
            guard let h = AxisCalibrator.detect(samples) else {
                return failCalibration("Didn't see a clear turn. Turn about 20° to the right and back, then try again.")
            }
            calibratedHorizontal = h
            calibration = .lookUp
        case .lookUp:
            guard let h = calibratedHorizontal, let up = AxisCalibrator.detect(samples, excluding: h.axis) else {
                return failCalibration("Didn't see a clear look up. Tilt your head up about 20° and back, then try again.")
            }
            let axes = HeadPointer.Axes(horizontal: h, vertical: AxisMap(axis: up.axis, sign: -up.sign))  // up is −y
            config.learn(axes, bud: s.bud, fromCamera: false)
            lastCalibrationFailed = false
            lastCalibrationOutcome = .succeeded
            calibrationMessage = "Calibrated: turning uses axis \(AxisMap.names[h.axis]), nodding uses axis \(AxisMap.names[up.axis])"
            calibration = nil
            pointer.reset()
        case nil:
            break
        }
    }

    private func failCalibration(_ message: String) {
        lastCalibrationFailed = true
        lastCalibrationOutcome = .failed
        calibrationMessage = message
        calibration = nil
    }

    // MARK: Geometry

    /// Keeps the pointer on a display: a point off every display is clamped to the display the
    /// pointer was on.
    static func clamp(_ p: CGPoint, from old: CGPoint, displays: [CGRect]) -> CGPoint {
        if displays.contains(where: { $0.contains(p) }) { return p }
        guard let r = displays.first(where: { $0.contains(old) }) ?? displays.first else { return p }
        return CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
    }

    // MARK: Private

    private func enabledChanged() {
        pointer.reset()
        scrollRemainder = .zero
        velocity = .zero
        isPaused = false
        mode = .pointer
        dwell = DwellClicker(seconds: dwellSeconds); dwellLive = false
        releaseDrag(); dwellAction = .left
        ticker?.invalidate()
        ticker = nil
        if isEnabled, ticks {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(at: ProcessInfo.processInfo.systemUptime) }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        if isEnabled {
            refreshTrust()
            if !isTrusted { driver.requestTrust() }
            // The pointer has to keep up while other apps are in front; App Nap would throttle us.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Head mouse is on")
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private enum Keys {
        static let config = "headMouse.config.v2"  // v2: defaults retuned on real Buds3 Pro data
        static let voice = "headMouse.voiceClicks"
        static let hold = "headMouse.holdWhileSpeaking"
        static let motion = "headMouse.motionCommands"
        static let dwell = "headMouse.dwellClicks"
        static let dwellSeconds = "headMouse.dwellSeconds"
        static let dwellPalette = "headMouse.dwellPalette"
    }

    private func save() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: Keys.config) }
        defaults.set(voiceClicks, forKey: Keys.voice)
        defaults.set(holdWhileSpeaking, forKey: Keys.hold)
        defaults.set(motionCommands, forKey: Keys.motion)
        defaults.set(dwellClicks, forKey: Keys.dwell)
        defaults.set(dwellSeconds, forKey: Keys.dwellSeconds)
        defaults.set(dwellPalette, forKey: Keys.dwellPalette)
    }
}

/// Dwell click: once the pointer has travelled `rearm` points, holding it within `radius` for
/// `seconds` clicks once. It then waits for the next move, so a resting pointer never repeats.
struct DwellClicker: Equatable {
    static let radius: CGFloat = 12, rearm: CGFloat = 36
    static let defaultSeconds: TimeInterval = 1.2, secondsRange: ClosedRange<TimeInterval> = 0.6...3
    var seconds: TimeInterval
    private var anchor: CGPoint?
    private var since: TimeInterval = 0
    private var armed = false

    init(seconds: TimeInterval = defaultSeconds) { self.seconds = Self.clamp(seconds) }
    static func clamp(_ seconds: TimeInterval) -> TimeInterval { min(secondsRange.upperBound, max(secondsRange.lowerBound, seconds)) }

    /// True when it should click now. `confirmedAt` is the newest motion sample's time: a click
    /// needs one from during the hold, so a stream that died (which also holds the pointer
    /// still) never clicks.
    mutating func update(_ p: CGPoint, at t: TimeInterval, confirmedAt sample: TimeInterval = .infinity) -> Bool {
        guard let a = anchor else { anchor = p; since = t; return false }
        let distance = hypot(p.x - a.x, p.y - a.y)
        if !armed {
            if distance >= Self.rearm { armed = true; anchor = p; since = t }
            return false
        }
        if distance > Self.radius { anchor = p; since = t; return false }
        guard t - since >= seconds, sample > since else { return false }
        armed = false; anchor = p
        return true
    }
    /// 0…1 while a click is building, nil when not armed (for a progress cue).
    func progress(at t: TimeInterval) -> Double? { armed ? min(1, max(0, (t - since) / seconds)) : nil }
}
