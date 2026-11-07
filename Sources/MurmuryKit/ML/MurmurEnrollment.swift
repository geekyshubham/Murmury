import Foundation
import Observation

/// Teaches the murmur model, the way a voice is enrolled: the person reads a few short passages
/// aloud while their buds stream and the microphone listens. The microphone only labels when they
/// were speaking; the model learns to feel that from the buds alone.
@MainActor @Observable
final class MurmurEnrollment {
    enum Prompt: Equatable, Sendable {
        case read(String, why: String)
        case quiet(seconds: Double)
        case turnQuietly(seconds: Double)

        var isTimed: Bool { if case .read = self { return false } else { return true } }
        var seconds: Double? {
            switch self {
            case .read: nil
            case .quiet(let s), .turnQuietly(let s): s
            }
        }
    }
    enum Phase: Equatable {
        case idle, running, training
        /// Trained. `accepted` is false for a weak result that waits for the person's decision.
        case done(MurmurModel, accepted: Bool)
        case failed(String, micDenied: Bool = false)
        /// Reading or learning: spoken commands must not act (the passages contain them).
        var isActive: Bool { self == .running || self == .training }
    }
    /// Below these a model isn't installed without the person choosing to.
    nonisolated static let minimumRecall = 0.6, maximumFalseAlarms = 0.25

    /// Each passage teaches something different, and the quiet steps teach what isn't speech:
    /// stillness, and a head turning with the mouth closed.
    static let standard: [Prompt] = [
        .quiet(seconds: 3),
        .read("Click. Right click. Double click. Scroll down, then scroll up. Mouse off, and mouse on.",
              why: "The words you'll say to Murmury"),
        .quiet(seconds: 3),
        .read("Click. Scroll. Down. Up. Left. Right. Yes. No. Click. Scroll. Down. Up. Left. Right. Yes. No. Click. Scroll. Down. Up. Left. Right. Yes. No.",
              why: "One word at a time, with a pause: so your buds learn each word's own movement"),
        .quiet(seconds: 3),
        .read("A large, calm owl on a high bough sang a slow, low song about the autumn harvest, and the farmer's old dog yawned.",
              why: "Open vowels: the jaw drops wide"),
        .turnQuietly(seconds: 5),
        .read("Peter's busy bee buzzed by the bamboo, humming, mumbling and beeping by the big blue bin.",
              why: "Closed sounds: lips press, the jaw barely moves"),
        .quiet(seconds: 3),
        .read("Now murmur this, as quietly as you would at your desk: click, scroll down, right click, mouse off, mouse on.",
              why: "Your real murmur, under your breath"),
        .quiet(seconds: 3),
    ]

    let prompts = MurmurEnrollment.standard
    private(set) var phase: Phase = .idle {
        didSet { if oldValue == .running, phase != .running { readingEndedAt = clock(); onReadingEnded?() } }
    }
    /// When reading last stopped (cancel, microphone loss or the last passage).
    @ObservationIgnored private var readingEndedAt: TimeInterval?
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Called the moment reading stops, however it stopped: the app closes the recognition session
    /// there, so words read aloud can never arrive later as commands.
    @ObservationIgnored var onReadingEnded: (() -> Void)?
    /// Recognition lags speech: results for words read during the session can arrive just after it.
    nonisolated static let commandGrace: TimeInterval = 1.5
    /// Whether spoken and gesture commands must not act: while reading or learning, and for a
    /// moment after reading stops, so a late result for words read aloud never becomes an action.
    var suppressesCommands: Bool {
        phase.isActive || readingEndedAt.map { clock() - $0 < Self.commandGrace } ?? false
    }
    private(set) var index = 0
    private(set) var level: Float = 0
    /// The microphone hears the person now (for the live cue while reading).
    private(set) var hearing = false
    private(set) var remaining: Double?
    var prompt: Prompt? { phase == .running && prompts.indices.contains(index) ? prompts[index] : nil }
    var readingNumber: Int { prompts.prefix(index + 1).filter { !$0.isTimed }.count }
    var readingCount: Int { prompts.filter { !$0.isTimed }.count }
    var progress: Double { Double(index) / Double(prompts.count) }

    @ObservationIgnored private var samples: [(step: Int, s: MotionSample)] = []
    @ObservationIgnored private var levels: [(t: Double, level: Float, step: Int)] = []
    @ObservationIgnored private var stepStarted = 0.0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var live = VoiceActivity()
    @ObservationIgnored var onTrained: ((MurmurModel) -> Void)?
    @ObservationIgnored var onAnnounce: ((String) -> Void)?
    /// Step instructions are time-bound: each one replaces any instruction still being spoken, so a
    /// queued prompt never arrives after its step has ended. Falls back to `onAnnounce`.
    @ObservationIgnored var onPrompt: ((String) -> Void)?
    private func prompt(_ message: String) { (onPrompt ?? onAnnounce)?(message) }
    /// Whether the microphone is still running; checked every tick so a lost microphone stops the
    /// session instead of implying speech is still being heard.
    @ObservationIgnored private var micRunning: () -> Bool = { true }
    @ObservationIgnored private var heardSeconds = 0.0
    @ObservationIgnored private var lastHeard: Double?
    @ObservationIgnored private var lastLevelAt: Double?

    /// Starts only with a running microphone; otherwise says why, so the person can fix it.
    func start(micRunning: @escaping () -> Bool, micError: String? = nil) {
        guard micRunning() else {
            let denied = micError?.lowercased().contains("denied") == true
            phase = .failed(denied ? "Murmury can't hear you: microphone access is off. Allow it in System Settings, then try again."
                                   : "The microphone didn't start\(micError.map { ": " + $0 } ?? ".") Check your input device, then try again.", micDenied: denied)
            onAnnounce?("Murmur teaching couldn't start: the microphone isn't on.")
            return
        }
        self.micRunning = micRunning
        samples = []; levels = []; index = 0; live = VoiceActivity(); stopsHeard = stopsInTranscript
        mouthFrames = []; spokenWords = []; speech = nil
        phase = .running
        beginStep()
        lastLevelAt = clock()  // the first buffer gets the same grace as any gap
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(at: ProcessInfo.processInfo.systemUptime) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops a session in progress and says so, whichever way it was stopped (Esc, Cancel, the
    /// spoken stop or the sheet closing), so a VoiceOver user always hears the outcome.
    func cancel() {
        timer?.invalidate(); timer = nil
        guard phase.isActive else { return }
        phase = .idle
        onAnnounce?("Murmur teaching stopped. Nothing was learned.")
    }
    /// Evidence only (`--evidence-surface=murmur-<reading|done|weak|denied>`): shows a state without
    /// buds or microphone, so each can be captured at the sheet's real size.
    func stage(_ name: String) {
        let model = MurmurModel(mean: [], scale: [], weights: [], bias: 0, threshold: 0.5, recall: 0.92, falseAlarms: 0.04, examples: 1800, heldOut: true)
        switch name {
        case "reading": phase = .running; index = 3; hearing = true
        case "done":
            phase = .done(model, accepted: true)
            speech = SpeechModels(mouth: MouthModel(mean: [], scale: [], weights: [], bias: 0, lo: 0, hi: 1, lag: 0.2, r2: 0.68, examples: 900, heldOut: true),
                                  words: WordModel(takes: [], vocabulary: ["click", "down", "left", "no", "right", "scroll", "up", "yes"],
                                                   featureSet: [.velocity, .imu], accuracy: 0.71, chance: 0.125, pValue: 0.002))
        case "weak": var weak = model; weak.recall = 0.48; weak.falseAlarms = 0.31; phase = .done(weak, accepted: false)
        case "denied": start(micRunning: { false }, micError: "Microphone access denied.")
        default: break
        }
    }

    /// The spoken escape while reading: commands are off, but "stop teaching" (in no passage) ends it.
    nonisolated static let stopPhrase = "stop teaching"
    @ObservationIgnored private var stopsHeard = 0
    /// Stop phrases in the latest transcript, whatever the phase: a new session starts from it, so a
    /// "stop teaching" already in the recogniser's history can't end a retry.
    @ObservationIgnored private var stopsInTranscript = 0
    /// Feeds the live transcript; ends the session when the stop phrase is newly said.
    func hear(text: String) {
        let count = text.lowercased().components(separatedBy: Self.stopPhrase).count - 1
        stopsInTranscript = count
        // A recogniser reset or revision can shorten the transcript: count from where it now is.
        if count < stopsHeard { stopsHeard = count }
        guard phase.isActive else { stopsHeard = count; return }
        if count > stopsHeard {
            stopsHeard = count
            cancel()
        }
    }

    /// Installs a weak result the person chose to keep.
    func accept() {
        guard case .done(let model, false) = phase else { return }
        phase = .done(model, accepted: true)
        onTrained?(model)
        onAnnounce?("Murmur model in use.")
    }

    // MARK: Camera and words (speech calibration)

    @ObservationIgnored private var mouthFrames: [(t: Double, value: Double)] = []
    @ObservationIgnored private var spokenWords: [SpokenWord] = []
    /// What the session's camera and words taught, once trained (nil without a camera or words).
    private(set) var speech: SpeechModels?
    @ObservationIgnored var onSpeechTrained: ((SpeechModels) -> Void)?
    /// The camera saw the lips this many times this session (for the sheet's cue).
    var mouthFramesSeen: Int { mouthFrames.count }
    /// The camera's measure of the lips' opening at `t` (seconds since boot), while reading.
    func see(mouth: Double, at t: Double) {
        guard phase == .running else { return }
        mouthFrames.append((t, mouth))
    }
    /// Words the recogniser timed. Final results lag speech, so they count until training starts.
    func hear(words: [SpokenWord]) {
        guard phase == .running else { return }
        spokenWords += words
    }

    /// Done reading this passage.
    func next() {
        guard phase == .running else { return }
        index += 1
        if index >= prompts.count { finish() } else { beginStep() }
    }

    func ingest(_ s: MotionSample) {
        guard phase == .running else { return }
        samples.append((index, s))
    }

    func hear(level: Float, at t: TimeInterval) {
        guard phase == .running else { return }
        self.level = level
        levels.append((t, level, index))
        let speaking = live.update(level: level, at: t)
        if speaking != hearing { hearing = speaking }
        if speaking, !prompts[index].isTimed {
            heardSeconds += min(0.1, t - (lastLevelAt ?? t)); lastHeard = t
        }
        lastLevelAt = t
    }

    private func beginStep() {
        stepStarted = ProcessInfo.processInfo.systemUptime
        remaining = prompts[index].seconds
        heardSeconds = 0; lastHeard = nil
        switch prompts[index] {
        case .read(let text, _): prompt("Read aloud: " + text)
        case .quiet(let s): prompt("Stay quiet for \(Int(s)) seconds.")
        case .turnQuietly(let s): prompt("Stay quiet and turn your head slowly left and right for \(Int(s)) seconds.")
        }
    }

    /// The longest gap between microphone buffers before the capture counts as stopped (they
    /// normally arrive about 40 times a second).
    nonisolated static let micSilence: TimeInterval = 1.0

    func tick(at now: TimeInterval) {
        guard phase == .running else { return }
        // Healthy capture is buffers arriving, not a flag: an engine interruption or a device that
        // stops delivering leaves the service "running" while nothing is heard.
        guard micRunning(), now - (lastLevelAt ?? now) <= Self.micSilence else {
            timer?.invalidate(); timer = nil
            phase = .failed("The microphone stopped, so Murmury could no longer hear you. Nothing was learned. Check your input device, then try again.")
            onAnnounce?("Murmur teaching stopped: the microphone went off.")
            return
        }
        if case .read(let text, _) = prompts[index] {
            // Hands-free: the passage is done once most of it was heard and the reader has paused.
            let expected = Double(text.split(separator: " ").count) * 0.3
            if heardSeconds >= 0.6 * expected, let lastHeard, now - lastHeard >= 1.6 { next() }
            return
        }
        guard let seconds = prompts[index].seconds else { return }
        let left = seconds - (now - stepStarted)
        remaining = max(0, left)
        if left <= 0 { next() }
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        phase = .training
        let samples = samples, levels = levels, prompts = prompts, mouth = mouthFrames, words = spokenWords
        Task.detached(priority: .userInitiated) {
            let examples = Self.examples(samples: samples, levels: levels, prompts: prompts)
            let model = MurmurTrainer.train(examples)
            // The same session teaches the mouth (against the camera) and silent words (from the
            // recogniser's word timings), when there was a camera and words to learn from.
            let speech = SpeechModels.train(samples: samples.map(\.s), mouth: mouth, words: words)
            await MainActor.run {
                guard self.phase == .training else { return }
                if speech.mouth != nil || speech.words != nil { self.speech = speech; self.onSpeechTrained?(speech) }
                if let model {
                    let good = model.recall >= Self.minimumRecall && model.falseAlarms <= Self.maximumFalseAlarms
                    self.phase = .done(model, accepted: good)
                    if good { self.onTrained?(model) }
                    self.onAnnounce?(good ? String(format: "Learned. Your buds felt %.0f percent of your speech.", model.recall * 100)
                                          : "The result is weak. Try again, or choose whether to use it.")
                } else {
                    let why = samples.isEmpty
                        ? "No motion arrived from your buds. Connect them and start streaming, then try again."
                        : "Not enough speech was heard to learn from. Read each passage aloud, close to your Mac, then try again."
                    self.phase = .failed(why, micDenied: false)
                    self.onAnnounce?("Murmur teaching didn't finish. " + why)
                }
            }
        }
    }

    // MARK: Labelling

    /// Training examples: one window of bud samples every second sample, labelled speaking or quiet.
    /// Quiet steps are quiet whatever the room does. In reading steps the microphone decides, after
    /// the buds' timestamps are lined up with it (Bluetooth can deliver them up to half a second
    /// late), and windows near a start or end of speech are left out as ambiguous.
    nonisolated static func examples(samples: [(step: Int, s: MotionSample)], levels: [(t: Double, level: Float, step: Int)],
                                     prompts: [Prompt], margin: Float = 0.15) -> [MurmurTrainer.Example] {
        let quietSteps = Set(prompts.indices.filter { prompts[$0].isTimed })
        // Windows and their gyro jitter, per bud stream.
        struct Window { var step: Int; var t: Double; var x: [Double] }
        var windows: [Window] = []
        let bySteps = Dictionary(grouping: samples, by: \.step)
        for (step, group) in bySteps {
            let s = group.map(\.s).sorted { $0.t < $1.t }
            var i = 0
            while i + MurmurFeatures.window <= s.count {
                let slice = s[i..<(i + MurmurFeatures.window)]
                if slice.last!.t - slice.first!.t < 1.0, let x = MurmurFeatures.vector(slice) {
                    windows.append(Window(step: step, t: slice[slice.startIndex + MurmurFeatures.window / 2].t, x: x))
                }
                i += 2
            }
        }
        windows.sort { $0.t < $1.t }  // deterministic order, whatever the grouping's
        // One temporal split for everything learned: the cut comes from the buds' window times; the
        // training side ends 0.6 s before it, so no training label looks at microphone data past the
        // cut (a label reads up to about half a second ahead); the held-out side starts 1 s after it.
        let times = windows.map(\.t).sorted()
        guard !times.isEmpty else { return [] }
        let cut = times[Int(Double(times.count) * 0.75)], trainEnd = cut - 0.6
        // The room's level and the speech labels, from the training side's microphone data only.
        let quietLevels = levels.filter { quietSteps.contains($0.step) && $0.t < trainEnd }.map(\.level).sorted()
        guard !quietLevels.isEmpty else { return [] }
        let floor = quietLevels[quietLevels.count / 2]
        let loud = levels.filter { !quietSteps.contains($0.step) && $0.level > floor + margin }.map(\.t)
        func speaking(_ t: Double) -> Bool {
            var lo = 0, hi = loud.count
            while lo < hi { let mid = (lo + hi) / 2; if loud[mid] < t - 0.2 { lo = mid + 1 } else { hi = mid } }
            return lo < loud.count && loud[lo] <= t + 0.2
        }
        // The delay that best lines the buds' jitter up with the microphone's speech, training side only.
        let reading = windows.filter { !quietSteps.contains($0.step) && $0.t < trainEnd }
        var bestLag = 0.0, bestScore = -Double.infinity
        for lag in stride(from: -0.2, through: 0.8, by: 0.04) {
            let pairs = reading.map { (j: $0.x[3] + $0.x[4] + $0.x[5], y: speaking($0.t - lag) ? 1.0 : 0.0) }
            let ones = pairs.filter { $0.y == 1 }, zeros = pairs.filter { $0.y == 0 }
            guard !ones.isEmpty, !zeros.isEmpty else { continue }
            let score = ones.reduce(0) { $0 + $1.j } / Double(ones.count) - zeros.reduce(0) { $0 + $1.j } / Double(zeros.count)
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        // The same boundary for the trainer: fitted before the cut, a one-second gap, held out after.
        func split(_ t: Double) -> MurmurTrainer.Split { t < trainEnd ? .train : (t >= cut + 1 ? .test : .gap) }
        return windows.compactMap { w in
            if quietSteps.contains(w.step) { return MurmurTrainer.Example(features: w.x, speaking: false, t: w.t, split: split(w.t)) }
            let t = w.t - bestLag, now = speaking(t)
            guard speaking(t - 0.15) == now, speaking(t + 0.15) == now else { return nil }
            return MurmurTrainer.Example(features: w.x, speaking: now, t: w.t, split: split(w.t))
        }
    }
}
