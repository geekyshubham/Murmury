import AppKit
import AVFoundation
import Foundation
import Observation
import simd
import Speech

/// Central state: Buds link → kinematics → segmenter → (train | decode), plus recording.
@MainActor @Observable
final class AppModel {
    enum Screen: String, CaseIterable, Identifiable {
        case mouse = "Mouse", device = "Device", sensors = "Sensors", train = "Train", model = "Model", live = "Live"
        var id: String { rawValue }
        /// What the sidebar and window call it.
        var title: String {
            switch self {
            case .mouse: "Control"
            case .device: "Buds"
            case .sensors: "Motion"
            case .train: "Teach"
            case .model: "Model"
            case .live: "Detect"
            }
        }
        var symbol: String {
            switch self {
            case .mouse: "cursorarrow.motionlines"
            case .device: "earbuds"
            case .sensors: "gyroscope"
            case .train: "record.circle"
            case .model: "brain"
            case .live: "text.bubble"
            }
        }
        var hue: Hue {
            switch self {
            case .mouse: .control
            case .device: .buds
            case .sensors: .motion
            case .train: .teach
            case .model: .model
            case .live: .detect
            }
        }
    }

    struct LiveEvent: Identifiable, Hashable {
        let id = UUID()
        let time: Date
        let label: String
        let confidence: Double
        let source: String
        let accepted: Bool
    }

    static let historySeconds: TimeInterval = 10

    var screen: Screen = .mouse {
        willSet { if newValue != screen { capture.cancelForNavigation() } }
    }
    var evidenceSurface: String?
    var settingsTab = SettingsTab.pointer
    var detailSheet: DetailDestination?
    /// One readiness rule everywhere: two gestures with at least two takes each (what training needs).
    var canTrain: Bool { labels.count >= 2 && labels.allSatisfy { count(for: $0) >= 2 } }
    var canEvaluate: Bool { canTrain }
    /// One spelling per gesture: trimmed, single-spaced, lower-case ("Nod " and "nod" are one).
    static func gestureName(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    /// Why Train is unavailable, naming the gesture that holds it back.
    /// What the next take buys for a gesture with `n` takes, or what training still needs once it
    /// has its 2: one wording for the Teach screen and its spoken confirmation.
    func takeNote(count n: Int) -> String { n >= 2 ? (trainBlocker ?? TakeProgress.next(for: n)) : TakeProgress.next(for: n) }
    /// Spoken after a take is saved: this gesture's count and what it, or training, needs next
    /// (never a fixed "of 15", which reads as fifteen required).
    func savedTakeAnnouncement(label: String) -> String {
        let n = count(for: label)
        return "Saved. \(n == 1 ? "1 take" : "\(n) takes") of \(Self.gestureName(label)). \(takeNote(count: n))."
    }
    var trainBlocker: String? {
        guard !canTrain else { return nil }
        if labels.count < 2 { return labels.isEmpty ? "2 gestures, 2 takes each" : "Teach 1 more gesture" }
        if let short = labels.first(where: { count(for: $0) < 2 }) { return "“\(short)” needs 1 more take" }
        return "2 gestures, 2 takes each"
    }
    var modelHeroState: ModelHeroState {
        isTraining ? .training : (trainingLog.contains("Failed:") ? .failed : (neural == nil ? .untrained : .ready))
    }
    let buds = BudsService()
    let segmenter = Segmenter()
    let audio = AudioService()
    let transcriber = MicTranscriber()
    let headMouse: HeadMouse
    let cameraCalibration = CameraCalibration()
    /// Closes the speech recognition session at a boundary (replaceable in tests, which have no recogniser).
    @ObservationIgnored lazy var restartRecognition: () -> Void = { [weak self] in self?.transcriber.restartRecognition() }
    /// Reading session that teaches the murmur model (`MurmurEnrollment`).
    let murmurEnrollment = MurmurEnrollment()
    /// The wearer's murmur model: felt from the buds alone, it holds the pointer while they speak
    /// and can require that a spoken command came from them.
    var murmurModel: MurmurModel? {
        didSet {
            murmurDetector = murmurModel.map(MurmurDetector.init)
            Self.save(murmurModel, to: store.directory.appendingPathComponent("murmur.json"))
        }
    }
    @ObservationIgnored private(set) var murmurDetector: MurmurDetector?

    // MARK: Speech: the mouth and silent words

    /// What a speech calibration taught (`SpeechModels`): the mouth from the buds, and silent words.
    var speechModels: SpeechModels? {
        didSet {
            mouthDetector = speechModels?.mouth.map(MouthDetector.init)
            silentWords = speechModels?.words.flatMap(SilentWordRecognizer.init)
            let url = store.directory.appendingPathComponent(SpeechModels.fileName)
            if let speechModels { speechModels.save(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }
    }
    @ObservationIgnored private var mouthDetector: MouthDetector?
    @ObservationIgnored private var silentWords: SilentWordRecognizer?
    @ObservationIgnored private var audioMouth = AudioMouth()
    /// How far the head's mouth is open (0…1): from the buds once a mouth model is learned,
    /// otherwise from the microphone while you speak.
    private(set) var mouthOpen = 0.0
    private func show(mouth: Double) { if abs(mouth - mouthOpen) > 0.01 || (mouth == 0 && mouthOpen != 0) { mouthOpen = mouth } }
    /// Act on commands mouthed silently (felt by the buds, unheard by the microphone).
    var silentCommands = UserDefaults.standard.bool(forKey: "murmury.silentCommands") {
        didSet { UserDefaults.standard.set(silentCommands, forKey: "murmury.silentCommands") }
    }
    /// The camera that watches the lips while teaching (separate from calibration's).
    let speechCamera = CameraHeadTracker()
    @ObservationIgnored private var silentSegment: [MotionSample] = []
    @ObservationIgnored private var feltSilently = false

    /// Silent words that act, when silent commands are on: one word each, said on its own.
    nonisolated static func silentCommand(for word: String) -> MouseCommand? {
        switch word {
        case "click": .leftClick
        case "down": .scrollDown
        case "up": .scrollUp
        case "left": .scrollLeft
        case "right": .scrollRight
        default: nil
        }
    }

    /// Follows one sample for the silent-word path: while the buds feel speech the microphone
    /// doesn't hear, its motion is one utterance; when that ends, it's matched against the words
    /// the person taught.
    private func followSilentSpeech(_ s: MotionSample, felt: Bool) {
        guard silentWords != nil else { return }
        if felt && !headMouse.micHearsSpeech {
            silentSegment.append(s); feltSilently = true
            if silentSegment.count > 150 { silentSegment.removeAll() }  // three seconds: talk, not a word
        } else if feltSilently {
            feltSilently = false
            let segment = silentSegment; silentSegment = []
            guard segment.count >= 8, let r = silentWords?.recognize(segment) else { return }
            events.insert(LiveEvent(time: Date(), label: r.word, confidence: r.confidence, source: "Silent word", accepted: r.accepted), at: 0)
            if events.count > 200 { events.removeLast() }
            guard r.accepted else { return }
            transcript += (transcript.isEmpty ? "" : " ") + r.word
            if silentCommands, !murmurEnrollment.suppressesCommands, let command = Self.silentCommand(for: r.word) {
                headMouse.perform(command, source: .gesture)
            }
        }
    }

    /// Starts the teaching camera when the camera is allowed; its lip measure goes to the session.
    func startSpeechCamera() async {
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied, AVCaptureDevice.default(for: .video) != nil else { return }
        speechCamera.onPose = { [weak self] pose in
            guard let self, let mouth = pose.mouth else { return }
            self.murmurEnrollment.see(mouth: mouth, at: pose.t)
        }
        await speechCamera.start()
    }
    func stopSpeechCamera() { speechCamera.stop() }
    /// Act on a spoken command only when the buds felt the wearer speak it (voices nearby can't click).
    var ownVoiceOnly = UserDefaults.standard.bool(forKey: "murmury.ownVoiceOnly") {
        didSet { UserDefaults.standard.set(ownVoiceOnly, forKey: "murmury.ownVoiceOnly") }
    }
    private static func save(_ model: MurmurModel?, to url: URL) {
        if let model, let data = try? JSONEncoder().encode(model) { try? data.write(to: url) } else if model == nil { try? FileManager.default.removeItem(at: url) }
    }
    @ObservationIgnored let recorder = SessionRecorder()

    // Stream
    @ObservationIgnored let pipeline = MotionPipeline(historySeconds: AppModel.historySeconds)
    private(set) var history: [MotionSample] = []
    private(set) var latest: MotionSample?
    private(set) var sampleRate: Double = 0
    private(set) var rawAccel: [[Double]] = []
    @ObservationIgnored let store: DatasetStore

    // Dataset
    private(set) var takes: [Take] = [] {
        didSet {
            gestureSignatures = GestureSignature.make(takes: takes, labels: labels)
            // New takes answer a failed training; its banner shouldn't outlive them.
            if takes.count > oldValue.count, trainingLog.contains("Failed:") { trainingLog = "" }
        }
    }
    /// The Model hero's band shapes, recomputed only when takes change.
    private(set) var gestureSignatures: [MotionRibbons.Signature] = []
    var currentLabel = "nothing"
    var featureSet: FeatureSet = .all { didSet { rebuildTemplates() } }
    var lastTake: Take?

    // Models
    private(set) var templates: TemplateClassifier?
    private(set) var neural: MotionModelRunner?
    private(set) var evaluation: Evaluation?
    private(set) var isEvaluating = false
    private(set) var isTraining = false
    private(set) var trainingLog = ""
    var useNeural = true
    var minConfidence = 0.6
    var maxDTWDistance = 2.5
    var minDTWMargin = 0.1

    // Live
    private(set) var events: [LiveEvent] = []
    private(set) var transcript = ""
    var appendNothing = false

    // Recording
    private(set) var recordingURL: URL?
    var recordingCondition = "free"

    @ObservationIgnored lazy var capture: CaptureController = {
        let c = CaptureController(segmenter: segmenter, label: { [weak self] in self?.currentLabel ?? "" },
                                  hasMotion: { [weak self] in self?.hasMotion ?? false })
        c.onSegment = { [weak self] samples, label in self?.handleSegment(samples, label: label) }
        c.onFinish = { [weak self, weak c] reason, saved in
            guard let self else { return }
            if reason == .timeLimit { announce("Stopped at \(Int(Segmenter.maxHoldSeconds)) second limit") }
            else if saved, screen == .train, let label = c?.recordingLabel, !label.isEmpty { announce(savedTakeAnnouncement(label: label)) }
        }
        return c
    }()
    var trainWindow = Double(MotionModelTrainer.defaultWindow)
    var trainAugment = 12.0
    var trainIterations = 40.0
    private(set) var lastAnnouncement: String?

    init(store: DatasetStore = .standard, headMouse injected: HeadMouse? = nil) {
        self.store = store
        self.headMouse = injected ?? HeadMouse(driver: SystemPointer())
        // Older datasets may spell one gesture two ways ("Nod", "nod"): one name from here on.
        takes = store.load().map { var take = $0; take.label = Self.gestureName(take.label); return take }
        tuneNodDetectors()
        // VoiceOver hears every calibration step and its result.
        headMouse.onCalibrationStep = { [weak self] step in
            guard let self else { return }
            switch step {
            case .turnRight: announce("Calibrating. Turn your head right about 20 degrees, then back to center.")
            case .lookUp: announce("Now look up about 20 degrees, then back to center.")
            case nil:
                switch headMouse.lastCalibrationOutcome {
                case .failed: announce(headMouse.calibrationMessage ?? "Calibration didn't finish.")
                case .cancelled: announce("Calibration cancelled. Your previous setup is kept.")
                case .succeeded, nil: announce("Calibrated. The pointer follows your head.")
                }
            }
        }
        // VoiceOver hears what a command did (plain dwell left clicks excepted: the click itself speaks).
        cameraCalibration.onAnnounce = { [weak self] message in self?.announce(message) }
        murmurEnrollment.onAnnounce = { [weak self] message in self?.announce(message) }
        cameraCalibration.onPrompt = { [weak self] message in self?.announce(message, urgent: true) }
        murmurEnrollment.onPrompt = { [weak self] message in self?.announce(message, urgent: true) }
        murmurEnrollment.onTrained = { [weak self] model in self?.murmurModel = model }
        murmurEnrollment.onSpeechTrained = { [weak self] speech in self?.speechModels = speech }
        murmurEnrollment.onReadingEnded = { [weak self] in self?.restartRecognition(); self?.stopSpeechCamera() }
        speechModels = SpeechModels.load(from: store.directory.appendingPathComponent(SpeechModels.fileName))
        if let data = try? Data(contentsOf: store.directory.appendingPathComponent("murmur.json")),
           let model = try? JSONDecoder().decode(MurmurModel.self, from: data) {
            murmurModel = model
        }
        headMouse.commandsAllowed = { [weak self] in !(self?.murmurEnrollment.suppressesCommands ?? false) }
        headMouse.ownVoiceGate = { [weak self] in
            guard let self, self.ownVoiceOnly, let detector = self.murmurDetector else { return true }
            // Bud timestamps can trail the clock by up to half a second; allow for it.
            return detector.felt(within: 2.0, of: ProcessInfo.processInfo.systemUptime)
        }
        segmenter.onStillnessLearned = { [weak self] in self?.announce("Stillness learned.") }
        FieldJournal.shared?.state = { [weak self] in
            guard let self else { return [:] }
            return ["pointer": !headMouse.isEnabled ? "off" : headMouse.isPaused ? "paused" : "\(headMouse.mode)",
                    "buds_state": buds.state.label, "left": "\(buds.placementLeft)", "right": "\(buds.placementRight)",
                    "buds_lost": motionLost, "own_voice_only": ownVoiceOnly, "murmur_model": murmurModel != nil, "voice": voiceFailure.map { "\($0)" } ?? (voiceIsRunning() ? "running" : "off")]
        }
        headMouse.onResumeRefused = { [weak self] in self?.announce("Buds still disconnected. Pointer stays paused.") }
        headMouse.onCommand = { [weak self] command, source in
            FieldJournal.shared?.event("command", ["command": command.title, "source": "\(source)"])
            guard let self, let words = Self.spoken(command, source: source, dwell: headMouse.dwellClicks,
                                                    voice: voiceIsRunning() && headMouse.voiceClicks) else { return }
            announce(words)
        }
        buds.onMotion = { [weak self] samples, t in self?.receiveDeviceMotion(samples, arrival: t) }
        buds.onRawAccel = { [weak self] xyz in
            guard let self else { return }
            rawAccel = Array((rawAccel + xyz).suffix(500))
        }
        pipeline.onSample = { [weak self] s in
            guard let self else { return }
            if recorder.isRecording { recorder.write(s) }
            capture.ingest(s)
            headMouse.ingest(s)
            cameraCalibration.ingest(s)
            murmurEnrollment.ingest(s)
            if var detector = murmurDetector {
                let murmuring = detector.ingest(s)
                murmurDetector = detector
                headMouse.feel(murmur: murmuring, at: s.t)
                followSilentSpeech(s, felt: murmuring)
            }
            if var mouth = mouthDetector, !isDemo {
                show(mouth: mouth.ingest(s))
                mouthDetector = mouth
            }
            if let pitch = pipeline.relativeAngles?.pitch { receiveRecoveryPitch(pitch, at: s.t) }
        }
        transcriber.vocabulary = VoiceCommandParser.vocabulary
        transcriber.onWords = { [weak self] words in self?.murmurEnrollment.hear(words: words) }
        transcriber.onText = { [weak self] text in
            guard let self else { return }
            // Decided before the stop phrase can end the session: a transcript that arrives while
            // teaching never acts, even the passage words that come with "stop teaching".
            let teaching = self.murmurEnrollment.suppressesCommands
            self.murmurEnrollment.hear(text: text)  // the spoken way out while teaching
            guard self.handsFreeMode == .voice else { return }
            self.headMouse.hear(text: text, actionsAllowed: !teaching)
        }
        audio.onLevel = { [weak self] level in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            headMouse.hear(level: level, at: now)
            murmurEnrollment.hear(level: level, at: now)
            // Before a mouth model is learned, the mouth follows your voice.
            if mouthDetector == nil { show(mouth: audioMouth.update(level: level)) }
        }
        _ = capture
        capture.onToggledStart = { [weak self] in self?.announce("Recording. Click anywhere to save.") }
        rebuildTemplates()
        neural = try? MotionModelRunner(store: store)
        startVoice = { [weak self] in await self?.startVoiceServices() ?? .recognizerUnavailable }
        voiceIsRunning = { [weak self] in self?.transcriber.isRunning ?? false }
        watchVoice()
    }

    var labels: [String] { Array(Set(takes.map(\.label))).sorted() }
    /// Counts by the normalised name, so what you type ("Nod ") and what was saved ("nod") agree.
    func count(for label: String) -> Int {
        let name = Self.gestureName(label)
        return takes.filter { Self.gestureName($0.label) == name }.count
    }

    // MARK: Stream

    /// When the latest motion arrived (seconds since boot), for the head's latency evidence.
    private(set) var latestArrival: TimeInterval?
    private func ingest(_ samples: [HeadSample], arrival: TimeInterval) {
        latestArrival = arrival
        let recenterNewSource = latest == nil
        pipeline.ingest(samples, arrival: arrival)
        if recenterNewSource { pipeline.recenter() }
        history = pipeline.history
        latest = pipeline.latest
        sampleRate = pipeline.sampleRate
    }

    var relativeAngles: (pitch: Double, roll: Double, yaw: Double)? { hasMotion ? pipeline.relativeAngles : nil }
    func recenter() { pipeline.recenter() }

    /// Head pose for the avatar, in the same calibrated frame the pointer uses.
    var headPose: HeadPose? {
        guard hasMotion, let latest, let q = pipeline.relativeQuaternion else { return nil }
        // The model the camera taught, when there is one: it knows turn, nod and tilt for this wearer.
        if let model = headMouse.config.headModel(for: latest.bud) { return model.pose(relative: q) }
        return HeadPose(relative: q, axes: headMouse.config.axes(for: latest.bud))
    }

    // MARK: Demo (synthetic motion, no buds needed)

    enum MotionSource { case none, demo, device }
    private(set) var activeSource: MotionSource = .none
    var isDemo: Bool { activeSource == .demo }
    var hasMotion: Bool { activeSource == .demo || (activeSource == .device && buds.state == .streaming) }
    private(set) var deviceHasSamples = false

    var sourcePresentation: BudsPresentation {
        BudsPresentation(state: buds.state, isDemo: isDemo, sampleRate: sampleRate,
                         batteryLeft: buds.batteryLeft, batteryRight: buds.batteryRight,
                         placementLeft: buds.placementLeft, placementRight: buds.placementRight, sensorSupported: buds.sensorSupported)
    }

    /// What VoiceOver says after a command, or nil when the action announces itself.
    static func spoken(_ command: MouseCommand, source: HeadMouse.CommandSource, dwell: Bool = false, voice: Bool = false) -> String? {
        // Mode changes are always spoken, whatever caused them, with the way back that exists.
        if command == .scrollMode {
            return "Scroll mode. Turn to scroll" + (dwell ? ", then hold still to point again." : (voice ? ". Say pointer mode to point again." : "."))
        }
        if command == .pointerMode { return "Pointer mode." }
        return switch source {
        case .dwell: command == .leftClick ? nil : command.title
        case .voice: "Heard \(command.title.lowercased())"
        case .gesture: command.title
        case .other: nil
        }
    }

    /// Urgent messages (voice loss, failures, stop, and a guided step's instruction, which makes the
    /// previous one stale) interrupt VoiceOver; routine feedback (a saved
    /// take, a heard command, a detection) waits its turn, so continuous use stays listenable.
    func announce(_ message: String, urgent: Bool = false) {
        lastAnnouncement = message
        FieldJournal.shared?.event("said", ["text": message, "urgent": urgent])
        onAnnouncement?(message)
        guard let app = NSApp else { return }
        let priority: NSAccessibilityPriorityLevel = urgent ? .high : .medium
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: priority.rawValue])
    }

    private func clearMotion() {
        capture.cancelForNavigation()
        pipeline.reset(); history = []; latest = nil; sampleRate = 0; rawAccel = []
        deviceHasSamples = false
    }

    func connectMotionSource() {
        if isDemo { stopDemo(); announce("Demo stopped.") }
        clearMotion(); activeSource = .device
        buds.streamOnConnect = true; buds.connect()
    }
    func disconnectMotionSource() { buds.disconnect(); clearMotion(); activeSource = .none }
    func startMotionStream() {
        if isDemo { stopDemo(); announce("Demo stopped.") }
        clearMotion(); activeSource = .device; buds.startSensor()
    }
    func stopMotionStream() { buds.stopSensor(); clearMotion(); activeSource = .none }
    func reconcileMotionSource(state: BudsService.State? = nil) {
        let state = state ?? buds.state
        if isDemo, state == .connected || state == .streaming {
            stopDemo(); announce("Demo stopped."); activeSource = .device
        }
        if !isDemo, state != .streaming, state != .connecting, state != .searching {
            // The buds stopped streaming under a running head mouse: never a silently frozen pointer.
            if headMouse.isEnabled, deviceHasSamples, !motionLost { beginMotionLoss() }
            clearMotion(); activeSource = state == .connected ? .device : .none
        }
    }

    // MARK: Buds lost mid-session

    /// The head mouse is on but its buds stopped streaming: paused, said out loud, reconnecting.
    private(set) var motionLost = false
    private(set) var motionRetryAt: Date?
    /// Reconnect attempts so far in this loss: after a few, the notice says more and offers Bluetooth.
    private(set) var motionRetries = 0
    static let motionEscalateAfter = 4
    @ObservationIgnored private var motionRetryTask: Task<Void, Never>?
    static let motionRetryDelays: [Double] = [2, 5, 15, 30]
    /// The backoff in use (shortened in tests).
    @ObservationIgnored var motionRetryDelays = AppModel.motionRetryDelays
    // MARK: Pause ownership

    /// Why the pointer is held: each failure adds its cause and removing it never undoes another
    /// cause or the user's own pause. The pointer resumes only when the last cause clears and the
    /// user hadn't paused before the first one arrived.
    enum PauseCause: Hashable { case voice, buds }
    @ObservationIgnored private(set) var pauseCauses: Set<PauseCause> = []
    @ObservationIgnored private var userPausedUnderCauses = false
    private func addPauseCause(_ cause: PauseCause) {
        if pauseCauses.isEmpty { userPausedUnderCauses = headMouse.isPaused }
        pauseCauses.insert(cause)
        if !headMouse.isPaused { headMouse.perform(.pause) }
    }
    /// True when this resumed the pointer.
    @discardableResult private func removePauseCause(_ cause: PauseCause) -> Bool {
        guard pauseCauses.remove(cause) != nil else { return false }
        guard pauseCauses.isEmpty, !userPausedUnderCauses, headMouse.isEnabled, headMouse.isPaused else { return false }
        headMouse.perform(.resume)
        return !headMouse.isPaused
    }
    private func clearPauseCauses() { pauseCauses = []; userPausedUnderCauses = false; headMouse.holdPaused = false }

    private func beginMotionLoss() {
        FieldJournal.shared?.event("buds-lost")
        motionLost = true; motionRetries = 0
        // Quiet when the pointer was already held (the user's break, or voice loss).
        let alreadyPaused = headMouse.isPaused
        addPauseCause(.buds)
        headMouse.holdPaused = true  // no resume (button, menu, "mouse on") until the buds are back
        if alreadyPaused {
            announce("Buds disconnected. Reconnecting.")
        } else {
            play(.voiceLost)
            announce("Buds disconnected. Pointer paused. Reconnecting.", urgent: true)
        }
        motionRetryTask?.cancel()
        motionRetryTask = Task { [weak self] in
            var attempt = 0
            while let self, self.motionLost, self.headMouse.isEnabled, !Task.isCancelled {
                let delay = self.motionRetryDelays[min(attempt, self.motionRetryDelays.count - 1)]
                self.motionRetryAt = Date().addingTimeInterval(delay)
                try? await Task.sleep(for: .seconds(delay))
                guard self.motionLost, !Task.isCancelled else { return }
                self.motionRetryAt = nil
                if !self.buds.isBusy { self.reconnectMotion() }
                attempt += 1
                self.motionRetries = attempt
                // Said once, for someone working in another app: the outage needs them now.
                if attempt == Self.motionEscalateAfter {
                    self.announce("Still can't reach the buds. Check they're out of the case and charged.", urgent: true)
                }
            }
        }
    }
    /// "Reconnect now" from the notice or the menu bar.
    func reconnectNow() {
        guard motionLost else { return }
        motionRetryAt = nil
        if !buds.isBusy { reconnectMotion() }
    }
    /// How a lost source reconnects (the real buds in the app; injected in tests).
    @ObservationIgnored lazy var reconnectMotion: () -> Void = { [weak self] in self?.connectMotionSource() }
    private func endMotionLoss() {
        guard motionLost else { return }
        FieldJournal.shared?.event("buds-back")
        motionLost = false; motionRetryAt = nil
        motionRetryTask?.cancel(); motionRetryTask = nil
        headMouse.holdPaused = false
        if removePauseCause(.buds) {
            play(.resumed)
            announce("Buds are back. Pointer resumed.", urgent: true)
        } else if pauseCauses.contains(.voice) {
            announce("Buds are back. Pointer stays paused until voice is back.")
        } else {
            announce("Buds are back. Pointer still paused.")
        }
    }
    func receiveDeviceMotion(_ samples: [HeadSample], arrival: TimeInterval) {
        guard !samples.isEmpty else { return }
        FieldJournal.shared?.samples(samples.count, at: arrival, bud: samples.last?.bud)
        if isDemo { stopDemo(); announce("Demo stopped.") }
        if activeSource != .device { clearMotion(); activeSource = .device }
        let first = !deviceHasSamples
        ingest(samples, arrival: arrival)
        deviceHasSamples = true
        if first { recenter() }
        if first, motionLost { endMotionLoss() } else if first { announce("Buds connected. Head tracking is live.") }
        // Hands-free start: with the option on, the head mouse starts as soon as real buds stream.
        if first, startWhenBudsConnect, !headMouse.isEnabled, headMouse.isTrusted {
            Task { await setHeadMouse(true, unattended: true) }
        }
    }
    @ObservationIgnored private var demoTimer: Timer?
    /// Starts the head mouse when real buds begin streaming (off by default: the pointer never
    /// starts by surprise). For people who can't press Start themselves.
    /// Nodding (Settings › Pointer): depth in degrees and a slowness factor, and whether a double
    /// nod pauses in voiceless modes (it always retries voice after voice loss).
    static let nodDepthRange = 6.0...20.0, nodSlownessRange = 1.0...2.0
    var nodDepth = (UserDefaults.standard.object(forKey: "murmury.nodDepth") as? Double).map { min(20, max(6, $0)) } ?? 10 {
        didSet { UserDefaults.standard.set(nodDepth, forKey: "murmury.nodDepth"); tuneNodDetectors() }
    }
    var nodSlowness = (UserDefaults.standard.object(forKey: "murmury.nodSlowness") as? Double).map { min(2, max(1, $0)) } ?? 1 {
        didSet { UserDefaults.standard.set(nodSlowness, forKey: "murmury.nodSlowness"); tuneNodDetectors() }
    }
    var nodToPause = UserDefaults.standard.object(forKey: "murmury.nodToPause") as? Bool ?? true {
        didSet { UserDefaults.standard.set(nodToPause, forKey: "murmury.nodToPause") }
    }
    private func tuneNodDetectors() {
        nodDetector.depth = nodDepth; nodDetector.slowness = nodSlowness
        pauseNodDetector.depth = nodDepth; pauseNodDetector.slowness = nodSlowness
    }

    var startWhenBudsConnect = UserDefaults.standard.bool(forKey: "murmury.startWhenBudsConnect") {
        didSet { UserDefaults.standard.set(startWhenBudsConnect, forKey: "murmury.startWhenBudsConnect") }
    }

    /// Sounds for changes that happen while another app is in front (pause, voice lost, voice back).
    enum Chime: Equatable {
        case paused, resumed, voiceLost
        var soundName: String { switch self { case .paused: "Pop"; case .resumed: "Tink"; case .voiceLost: "Basso" } }
    }
    var soundsEnabled = UserDefaults.standard.object(forKey: "murmury.sounds") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "murmury.sounds") }
    }
    /// Plays a chime; the app installs the system player, tests record calls.
    @ObservationIgnored var chime: (Chime) -> Void = { _ in }
    private func play(_ c: Chime) { if soundsEnabled { chime(c) } }

    func startDemo() {
        guard demoTimer == nil else { return }
        if buds.state != .disconnected { buds.disconnect() }
        clearMotion(); activeSource = .demo
        let start = ProcessInfo.processInfo.systemUptime
        let probe = ProcessInfo.processInfo.environment["MURMURY_STEP_PROBE"].map { FileManager.default.createFile(atPath: $0, contents: nil); return FileHandle(forWritingAtPath: $0) } ?? nil
        var turned = false
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                guard let probe else { self?.ingest([DemoMotion.sample(at: now - start)], arrival: now); return }
                // Evidence only: log each step's first sample (arrival on the uptime clock), then deliver it.
                let right = DemoMotion.stepTurnedRight(at: now - start)
                if right != turned { turned = right; probe.write(Data(String(format: "step %.6f %@\n", now, right ? "right" : "centre").utf8)) }
                self?.ingest([DemoMotion.stepSample(at: now - start)], arrival: now)
            }
        }
    }

    func stopDemo() {
        demoTimer?.invalidate(); demoTimer = nil
        if activeSource == .demo { clearMotion(); activeSource = .none }
    }

    /// Launch arguments: `--demo` feeds synthetic motion, `--stream` connects to the buds and
    /// starts streaming, `--screen=<name>` opens a screen.
    /// (A bare `--screen train` would make AppKit treat "train" as a document to open.)
    func applyLaunchArguments(_ args: [String]) {
        PointerSignal.shared.setOverride(Self.launchOptions(from: args).pointerAt)
        if args.contains("--demo") { startDemo() }
        if args.contains("--stream"), Self.launchOptions(from: args).scenario == nil {
            connectMotionSource()
        }
        if let screen = Self.screen(fromLaunchArguments: args) { self.screen = screen }
        if let scenario = Self.launchOptions(from: args).scenario { applyScenario(scenario) }
        // `--stage=<calibration|murmur>-<state>`: puts a sheet's model in a state before the sheet is
        // opened the normal way (the accessibility probe opens it from the More menu).
        if let value = args.first(where: { $0.hasPrefix("--stage=") }) {
            let name = String(value.dropFirst("--stage=".count))
            let state = name.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            if name.hasPrefix("murmur") { murmurEnrollment.stage(state) } else if name.hasPrefix("calibration") { cameraCalibration.stage(state) }
        }
        if let value = args.first(where: { $0.hasPrefix("--evidence-surface=") }) {
            let name = String(value.dropFirst("--evidence-surface=".count))
            evidenceSurface = name
            if name.hasPrefix("settings-"), let tab = SettingsTab.allCases.first(where: { $0.rawValue.lowercased() == name.dropFirst(9) }) { settingsTab = tab }
        }
    }

    struct LaunchOptions {
        var screen: Screen?
        var appearance: NSAppearance.Name?
        var windowSize: NSSize?
        var scenario: Scenario?
        var axDumpPath: String?
        var pointerAt: CGPoint?
    }

    /// Evidence states for screenshots, selected only by `--scenario=`. They change presentation
    /// state this model owns; they never move the pointer, open the camera or touch saved data.
    enum Scenario: String, CaseIterable {
        case controlVoiceDenied = "control-voice-denied", controlVoiceLost = "control-voice-lost"
        case controlPointerOnly = "control-pointer-only", controlVoiceOff = "control-voice-off"
        case controlVoiceRetrying = "control-voice-retrying", controlVoiceRecoveryFailed = "control-voice-recovery-failed"
        case controlRunning = "control-running", controlCalibrationFailed = "control-calibration-failed"
        case controlCalibrating = "control-calibrating", teachRecording = "teach-recording"
        case modelFailed = "model-failed", detectFeedback = "detect-feedback", modelGestures = "model-gestures"
        case controlBudsLost = "control-buds-lost", controlBudsEscalated = "control-buds-escalated"
        var screen: Screen {
            switch self {
            case .teachRecording: .train
            case .modelFailed, .modelGestures: .model
            case .detectFeedback: .live
            default: .mouse
            }
        }
    }
    private(set) var scenario: Scenario?

    /// Scenario and staged launches use a throwaway dataset so evidence never reads or writes the user's takes.
    static func store(for args: [String]) -> DatasetStore {
        guard launchOptions(from: args).scenario != nil || args.contains(where: { $0.hasPrefix("--stage=") }) else { return .standard }
        return DatasetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("murmury-scenario-\(UUID().uuidString)"))
    }

    // Presentation inputs: the live state, or a scenario's stand-in that never drives the real pointer.
    var showsMouseOn: Bool { headMouse.isEnabled || [.controlBudsLost, .controlBudsEscalated, .controlRunning, .controlVoiceLost, .controlPointerOnly, .controlVoiceOff, .controlVoiceRetrying, .controlVoiceRecoveryFailed].contains(scenario) }
    var showsMousePaused: Bool { headMouse.isPaused || [.controlVoiceLost, .controlVoiceRetrying, .controlVoiceRecoveryFailed, .controlBudsLost, .controlBudsEscalated].contains(scenario) }
    var showsCalibrationStep: HeadMouse.CalibrationStep? { headMouse.calibration ?? (scenario == .controlCalibrating ? .turnRight : nil) }
    var showsCalibrationFailed: Bool { headMouse.lastCalibrationFailed || scenario == .controlCalibrationFailed }
    var showsCalibrationMessage: String? {
        scenario == .controlCalibrationFailed ? "No movement seen. Choose Try again, then move when asked." : headMouse.calibrationMessage
    }

    func applyScenario(_ scenario: Scenario) {
        self.scenario = scenario
        screen = scenario.screen
        switch scenario {
        case .controlVoiceDenied:
            voiceFailure = .micDenied
        case .controlBudsEscalated: motionRetries = Self.motionEscalateAfter
        case .controlPointerOnly: handsFreeMode = .pointerOnly
        case .controlVoiceOff: handsFreeMode = .voiceOff
        case .controlVoiceLost, .controlVoiceRetrying, .controlVoiceRecoveryFailed:
            voiceFailure = .stopped
            handsFreeMode = .voice
        case .controlRunning:
            handsFreeMode = .voice
        case .teachRecording:
            currentLabel = "nod"
            capture.toggle()
        case .modelFailed:
            trainingLog = "Training on 4 takes…\nFailed: Each gesture needs at least two takes.\n"
        case .detectFeedback:
            segmenter.assumeStillness(0.02)  // the scenario is mid-session: stillness already learned
            let now = Date()
            events = [LiveEvent(time: now, label: "nod", confidence: 0.91, source: "Your trained model", accepted: true),
                      LiveEvent(time: now.addingTimeInterval(-2), label: "shake", confidence: 0.42, source: "Templates", accepted: false),
                      LiveEvent(time: now.addingTimeInterval(-4), label: "nod", confidence: 0.88, source: "Your trained model", accepted: true)]
            transcript = "nod shake nod"
            // Detections need taught gestures: stand-in takes so the screen is in its listening state.
            takes = ["nod", "nod", "shake", "shake"].map { Take(label: $0, samples: []) }
        case .modelGestures:
            takes = Self.sampleGestureTakes()
        default:
            break
        }
    }

    /// Evidence only: two takes each of a nod, a shake and stillness, shaped like real ones.
    static func sampleGestureTakes() -> [Take] {
        func take(_ label: String, _ shape: (Double) -> (yaw: Double, pitch: Double)) -> Take {
            Take(label: label, samples: (0..<60).map { i in
                let u = Double(i) / 59, a = shape(u)
                return MotionSample(t: Double(i) / 50, qw: 1, qx: 0, qy: 0, qz: 0, pitch: a.pitch, yaw: a.yaw)
            })
        }
        let nod = take("nod") { u in (0.02 * sin(2 * .pi * u), -0.32 * sin(.pi * u) * sin(.pi * u)) }
        let shake = take("shake") { u in (0.34 * sin(2 * .pi * 2 * u) * sin(.pi * u), 0.03 * sin(2 * .pi * u)) }
        let still = take("nothing") { u in (0.004 * sin(9 * u), 0.003 * cos(7 * u)) }
        return [nod, nod, shake, shake, still, still]
    }

    static func launchOptions(from args: [String]) -> LaunchOptions {
        let appearance: NSAppearance.Name?
        switch args.first(where: { $0.hasPrefix("--appearance=") }) {
        case "--appearance=light": appearance = .aqua
        case "--appearance=dark": appearance = .darkAqua
        default: appearance = nil
        }
        let size: NSSize?
        switch args.first(where: { $0.hasPrefix("--window-size=") }) {
        case "--window-size=1120x740": size = NSSize(width: 1120, height: 740)
        case "--window-size=1600x1000": size = NSSize(width: 1600, height: 1000)
        default: size = nil
        }
        let scenario = args.first(where: { $0.hasPrefix("--scenario=") }).flatMap { Scenario(rawValue: String($0.dropFirst("--scenario=".count))) }
        let dump = args.first(where: { $0.hasPrefix("--dump-ax=") }).map { String($0.dropFirst("--dump-ax=".count)) }
        let pointer = args.first(where: { $0.hasPrefix("--pointer-at=") }).flatMap { arg -> CGPoint? in
            let parts = arg.dropFirst("--pointer-at=".count).split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]),
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
            return CGPoint(x: x, y: y)
        }
        return LaunchOptions(screen: screen(fromLaunchArguments: args), appearance: appearance, windowSize: size,
                             scenario: scenario, axDumpPath: dump?.isEmpty == false ? dump : nil, pointerAt: pointer)
    }

    static func screen(fromLaunchArguments args: [String]) -> Screen? {
        guard let arg = args.first(where: { $0.hasPrefix("--screen=") }) else { return nil }
        let name = arg.dropFirst("--screen=".count).lowercased()
        return Screen.allCases.first { $0.rawValue.lowercased() == name || $0.title.lowercased() == name }
    }

    // MARK: Segments

    private func handleSegment(_ segment: [MotionSample], label: String) {
        switch screen {
        case .train:
            let take = Take(label: Self.gestureName(label), samples: segment)
            guard !take.label.isEmpty else { return }
            takes.append(take)
            lastTake = take
            store.save(takes)
            rebuildTemplates()
            if recorder.isRecording, let a = segment.first, let b = segment.last {
                recorder.event(start: a.t, end: b.t, kind: "take", label: take.label, confidence: 1)
            }
        default:
            classify(segment)
        }
    }

    private func classify(_ segment: [MotionSample]) {
        var prediction: Prediction?
        if useNeural, let neural {
            prediction = try? neural.predict(segment, minConfidence: minConfidence)
        }
        if prediction == nil, let templates {
            prediction = templates.predict(segment, maxDistance: maxDTWDistance, minConfidence: minDTWMargin)
        }
        guard let prediction, let best = prediction.best else { return }
        events.insert(LiveEvent(time: Date(), label: best.label, confidence: prediction.confidence,
                                source: prediction.source, accepted: prediction.accepted), at: 0)
        if events.count > 200 { events.removeLast() }
        if prediction.accepted {
            headMouse.perform(label: best.label)
            if best.label != "nothing" { announce("Detected \(best.label)") }
        }
        if prediction.accepted, appendNothing || best.label != "nothing" {
            transcript += (transcript.isEmpty ? "" : " ") + best.label
        }
        if recorder.isRecording, let a = segment.first, let b = segment.last {
            recorder.event(start: a.t, end: b.t, kind: "prediction", label: best.label, confidence: prediction.confidence)
        }
    }

    func clearTranscript() { transcript = ""; events = [] }

    // MARK: Dataset

    func delete(_ take: Take) {
        takes.removeAll { $0.id == take.id }
        if lastTake?.id == take.id { lastTake = nil }
        store.save(takes); rebuildTemplates()
    }

    func deleteLabel(_ label: String) {
        takes.removeAll { $0.label == label }
        if lastTake?.label == label { lastTake = nil }
        store.save(takes); rebuildTemplates()
    }

    func undoLastTake() { if let lastTake { delete(lastTake) } }

    /// The takes the models learn from. With raw IMU channels on, a take without raw IMU (recorded
    /// from demo motion or older packets) would feed zeros, so it is left out until IMU is off again.
    var learningTakes: [Take] { featureSet.contains(.imu) ? takes.filter { $0.samples.first?.hasIMU == true } : takes }
    /// Takes left out by the raw-IMU setting, for the note beside it.
    var takesWithoutIMU: Int { takes.filter { $0.samples.first?.hasIMU != true }.count }

    private func rebuildTemplates() {
        templates = TemplateClassifier(takes: learningTakes, featureSet: featureSet)
        evaluation = nil
    }

    // MARK: Models

    func evaluate() {
        guard !isEvaluating else { return }
        isEvaluating = true
        let takes = learningTakes, set = featureSet
        Task.detached(priority: .userInitiated) {
            let result = Evaluation.run(takes: takes, featureSet: set)
            await MainActor.run { self.evaluation = result; self.isEvaluating = false }
        }
    }

    func train(window: Int, augment: Int, iterations: Int) {
        guard !isTraining else { return }
        isTraining = true
        trainingLog = "Training on \(learningTakes.count) takes…\n"
        let takes = learningTakes, set = featureSet, store = store
        Task.detached(priority: .userInitiated) {
            do {
                let report = try MotionModelTrainer.train(takes: takes, featureSet: set, store: store, window: window,
                                                          augmentCopies: augment, iterations: iterations)
                let runner = try MotionModelRunner(store: store)
                await MainActor.run {
                    self.trainingLog += report.log + "Saved to \(store.modelURL.path)\n"
                    self.neural = runner
                    self.isTraining = false
                    let accuracy = runner.meta.validationAccuracy.map { " Accuracy on new takes: \(Int(($0 * 100).rounded())) percent." } ?? ""
                    self.announce("Training finished." + accuracy)
                }
            } catch {
                await MainActor.run {
                    // Plain words on screen: our own errors read well; anything else gets a generic line.
                    let reason = (error as? MotionModelError)?.errorDescription ?? "The model couldn't be trained from these takes."
                    self.trainingLog += "Failed: \(reason)\n"
                    self.isTraining = false
                    self.announce("Training failed. Record more takes in Teach, then train again.", urgent: true)
                }
            }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop(); recordingURL = nil
        } else {
            recordingURL = try? recorder.start(condition: recordingCondition)
        }
    }

    // MARK: Head mouse

    /// Why spoken click and pause are unavailable, if they are.
    private(set) var voiceFailure: VoiceFailure? {
        didSet {
            if oldValue == nil, let voiceFailure { FieldJournal.shared?.event("voice-lost", ["why": "\(voiceFailure)"]) }
            if oldValue != nil, voiceFailure == nil { FieldJournal.shared?.event("voice-back") }
        }
    }
    /// How the running pointer is controlled; nil while it is off.
    private(set) var handsFreeMode: HandsFreeMode?
    private(set) var voiceRecovery = VoiceRecoveryPolicy()
    var nextVoiceAttemptAt: Date? { voiceRecovery.nextAttemptAt }
    @ObservationIgnored var voiceRecoverySleep: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    @ObservationIgnored var recoveryNow: () -> Date = Date.init
    @ObservationIgnored var onAnnouncement: ((String) -> Void)?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryID: UUID?
    @ObservationIgnored private var voiceEpoch = UUID()
    @ObservationIgnored private var voiceRequestID: UUID?
    @ObservationIgnored private var nodDetector = DoubleNodDetector()
    /// Without voice (pointer only, or voice turned off), a double nod pauses and resumes the
    /// pointer, so every running state has a hands-free stop.
    @ObservationIgnored private var pauseNodDetector = DoubleNodDetector()
    @ObservationIgnored private var pauseNodQuietUntil = -Double.infinity
    /// Observed: the voice-lost row says which nod pair comes next.
    private var lastNodRetry: Double?

    /// Clicking still works without voice: trained gesture clicks or dwell.
    var canClickWithoutVoice: Bool { hasMotionClickCommands || headMouse.dwellClicks }
    var hasMotionClickCommands: Bool {
        let usableLabels = (templates?.labels ?? []) + (useNeural ? (neural?.meta.labels ?? []) : [])
        return headMouse.motionCommands && usableLabels.contains {
            [.leftClick, .rightClick, .doubleClick].contains(VoiceCommandParser.command(forLabel: $0))
        }
    }

    var controlCopy: ControlCopy {
        var budsHold: String?
        let state: ControlCopy.State
        if showsCalibrationStep != nil { state = .calibrating }
        else if !showsMouseOn { state = .off }
        // Paused while running without voice is the user's own pause (nod twice), not a voice error.
        else if motionLost || scenario == .controlBudsLost || scenario == .controlBudsEscalated {
            let seconds = motionRetryAt.map { Int(max(0, $0.timeIntervalSinceNow).rounded(.up)) } ?? (scenario == .controlBudsLost ? 5 : nil)
            state = .budsLost(seconds)
            budsHold = userPausedUnderCauses ? "Paused by you; reconnecting the buds" : (pauseCauses.contains(.voice) ? "Waiting for the buds and for voice" : nil)
        }
        else if showsMousePaused, handsFreeMode == .pointerOnly || handsFreeMode == .voiceOff { state = .userPaused }
        else if showsMousePaused, voiceFailure == .micDenied || voiceFailure == .speechDenied { state = .voiceDenied }
        else if showsMousePaused, voiceFailure != nil {
            let recovery: ControlCopy.Recovery
            if scenario == .controlVoiceRecoveryFailed { recovery = .failed }
            else if let next = nextVoiceAttemptAt { recovery = .waiting(Int(max(0, next.timeIntervalSince(recoveryNow())).rounded(.up))) }
            else if voiceRecovery.phase == .restarting { recovery = .restarting }
            else if scenario == .controlVoiceRetrying { recovery = .restarting }
            else if scenario == .controlVoiceLost { recovery = .waiting(2) }
            else { recovery = .failed }
            state = .voiceLost(recovery)
        } else if showsMousePaused { state = .userPaused }
        // Scrolling is shown in every mode, voiceless ones included: that is where its hands-free
        // exit (hold still) matters most.
        else if headMouse.mode == .scroll { state = .scrolling }
        else if handsFreeMode == .pointerOnly { state = .pointerOnly }
        else if handsFreeMode == .voiceOff || (!headMouse.voiceClicks && scenario == nil) { state = .voiceOff }
        else if headMouse.isHoldingForSpeech { state = .speakingHold }
        else { state = headMouse.mode == .scroll ? .scrolling : .pointing }
        let voiceAvailable = scenario == .controlRunning || (voiceIsRunning() && headMouse.voiceClicks && handsFreeMode != .pointerOnly && handsFreeMode != .voiceOff)
        return ControlCopy.make(state: state, voiceRunning: voiceAvailable, motionCommands: hasMotionClickCommands,
                                voiceEnabled: headMouse.voiceClicks, dwell: headMouse.dwellClicks,
                                heard: headMouse.lastVoiceCommand.map { $0.title.lowercased() }, retried: lastNodRetry != nil,
                                nodToPause: nodToPause, budsHold: budsHold)
    }

    private func cancelVoiceRecovery() {
        recoveryID = nil; recoveryTask?.cancel(); recoveryTask = nil
        voiceRecovery = VoiceRecoveryPolicy()
    }
    private var canRecoverVoice: Bool {
        scenario == nil && headMouse.isEnabled && headMouse.voiceClicks && handsFreeMode == .voice
    }
    private func finishVoiceRecovery() {
        let wasLost = voiceFailure != nil || handsFreeMode != .voice
        cancelVoiceRecovery(); voiceFailure = nil; lastNodRetry = nil
        if headMouse.isEnabled, headMouse.voiceClicks {
            handsFreeMode = .voice
            if wasLost {
                removePauseCause(.voice)
                play(.resumed)
                // Say what the pointer is actually doing now.
                announce(!headMouse.isPaused ? "Voice is back. Pointer resumed."
                         : (pauseCauses.contains(.buds) ? "Voice is back. Pointer stays paused until the buds are back." : "Voice is back. Pointer remains paused."))
            }
        } else {
            removePauseCause(.voice)
        }
    }
    private func beginVoiceRecovery() {
        guard recoveryTask == nil, canRecoverVoice else { return }
        let id = UUID(); recoveryID = id
        recoveryTask = Task { @MainActor [weak self] in
            while let self, self.recoveryID == id, self.canRecoverVoice {
                let delay = self.voiceRecovery.schedule(at: self.recoveryNow())
                if self.voiceRecovery.shouldAnnounce {
                    self.announce("Voice stopped. Pointer paused. Retrying voice in \(Int(delay)) seconds. Nod twice to retry now.", urgent: true)
                }
                do { try await self.voiceRecoverySleep(delay) } catch { return }
                guard self.recoveryID == id, self.canRecoverVoice, !Task.isCancelled else { return }
                if self.voiceIsRunning() { self.finishVoiceRecovery(); return }
                let auth = self.voiceAuthorization()
                if auth.mic != .authorized || auth.speech != .authorized {
                    self.voiceFailure = auth.mic != .authorized ? .micDenied : .speechDenied
                    self.cancelVoiceRecovery(); return
                }
                self.voiceRecovery.restarting()
                await self.restartVoice()
                guard self.recoveryID == id, self.canRecoverVoice else { return }
            }
        }
    }

    /// Called from the common motion-sample hook, independent of window focus or device type.
    func receiveRecoveryPitch(_ pitch: Double, at time: Double) {
        let calibrating = headMouse.calibration != nil || cameraCalibration.phase == .running || cameraCalibration.phase == .starting
        let armed = DoubleNodDetector.isArmed(stopped: voiceFailure == .stopped, enabled: headMouse.isEnabled,
                                             paused: headMouse.isPaused, calibrating: calibrating, demo: isDemo)
        // Voiceless modes pause by nodding even with a voice failure on record (continuing without
        // voice keeps it, so the notice can still offer Retry voice).
        let voiceless = headMouse.isEnabled && (handsFreeMode == .pointerOnly || handsFreeMode == .voiceOff)
            && !calibrating && !isDemo
        // Just after continuing without voice, a habitual extra nod must not pause the pointer.
        if pauseNodDetector.ingest(pitch: pitch, time: time, armed: voiceless && nodToPause && time >= pauseNodQuietUntil) {
            headMouse.perform(headMouse.isPaused ? .resume : .pause)
            play(headMouse.isPaused ? .paused : .resumed)
            announce(headMouse.isPaused ? "Pointer paused. Nod twice to resume." : "Pointer on.")
            return
        }
        guard nodDetector.ingest(pitch: pitch, time: time, armed: armed), voiceRequestID == nil else { return }
        if DoubleNodDetector.offersPointerOnly(lastRetry: lastNodRetry, now: time) {
            lastNodRetry = nil
            pauseNodQuietUntil = time + 3
            Task { await setHeadMouse(true, pointerOnly: true) }
        } else {
            lastNodRetry = time
            announce("Retrying voice. Nod twice again to continue without it.")
            Task { await restartVoice() }
        }
    }

    /// Starts microphone and speech; returns why they failed. Injected in tests.
    @ObservationIgnored var startVoice: () async -> VoiceFailure? = { nil }
    @ObservationIgnored var voiceIsRunning: () -> Bool = { false }
    @ObservationIgnored var voiceAuthorization: () -> (mic: VoiceAuthorization, speech: VoiceAuthorization) = {
        let mic: VoiceAuthorization = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
        let speech: VoiceAuthorization = switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
        return (mic, speech)
    }

    /// Turns the head mouse on or off. Voice starts first; the pointer is enabled only when spoken
    /// click and pause work, voice commands are off in Settings, or the user confirmed pointer-only.
    /// `unattended`: started by "Start when buds connect", with nobody at the keyboard. If voice
    /// can't start then, the head mouse starts pointer-only (with dwell clicking) rather than not at
    /// all: refusing would leave a hands-free user with no pointer and no way to retry.
    func setHeadMouse(_ on: Bool, pointerOnly: Bool = false, unattended: Bool = false, announcing: Bool = true) async {
        guard scenario == nil else { return }
        guard on else {
            voiceEpoch = UUID(); cancelVoiceRecovery(); nodDetector = DoubleNodDetector(); tuneNodDetectors(); lastNodRetry = nil
            clearPauseCauses()
            motionLost = false; motionRetryAt = nil; motionRetryTask?.cancel(); motionRetryTask = nil
            headMouse.isEnabled = false
            handsFreeMode = nil
            if voiceFailure == .stopped { voiceFailure = nil }
            return
        }
        let wantsVoice = headMouse.voiceClicks
        if pointerOnly || !wantsVoice {
            voiceEpoch = UUID(); cancelVoiceRecovery()
        }
        let epoch = voiceEpoch
        var failure: VoiceFailure?
        if wantsVoice, !pointerOnly, !voiceIsRunning() { failure = await startVoice() }
        guard epoch == voiceEpoch else { return }
        switch HandsFreeGate.decide(wantsVoice: wantsVoice, pointerOnlyConfirmed: pointerOnly, voiceRunning: voiceIsRunning(), failure: failure) {
        case .enable(let mode):
            voiceFailure = mode == .pointerOnly ? (failure ?? voiceFailure) : nil
            handsFreeMode = mode
            headMouse.isEnabled = true
            if mode != .voice {
                // Going on without voice ends voice's hold on the pointer; never the user's or the buds'.
                if pauseCauses.contains(.voice) { removePauseCause(.voice) }
                else if pauseCauses.isEmpty, headMouse.isPaused, !pointerOnly { headMouse.perform(.resume) }
            }
            if mode == .pointerOnly {
                // Pointer-only with no way to click is a dead end: dwell clicking comes on with it.
                let dwellAdded = !canClickWithoutVoice
                if dwellAdded { headMouse.dwellClicks = true }
                if announcing { announce("Head mouse on, pointer only." + (dwellAdded ? " Dwell clicking is on: hold the pointer still to click." : "") + (nodToPause ? " Nodding twice now pauses." : "")
                         + " Stop it with Shift Command M or the menu bar.") }
            }
        case .block(let reason):
            if unattended {
                await setHeadMouse(true, pointerOnly: true, announcing: false)
                voiceFailure = reason
                // One announcement, naming only the ways to click that are actually on.
                let clicks = headMouse.dwellClicks ? " Hold the pointer still to click." : (hasMotionClickCommands ? " Your gestures click." : "")
                announce("Voice didn't start, so the head mouse started without voice." + clicks + (nodToPause ? " Nod twice to pause." : ""), urgent: true)
                return
            }
            voiceFailure = reason
            handsFreeMode = nil
            headMouse.isEnabled = false
            announce("Head mouse not started: voice commands unavailable. Choose \(reason.recovery.primary.orbTitle), or Start without voice.", urgent: true)
        }
    }

    /// After returning from System Settings: clears a permission failure that is now fixed. It never
    /// starts the pointer.
    func recheckVoice() {
        // Evidence scenarios stand in for permission states this Mac doesn't have; keep them.
        guard scenario == nil, let failure = voiceFailure else { return }
        let auth = voiceAuthorization()
        switch failure {
        case .micDenied where auth.mic != .denied: voiceFailure = auth.speech == .denied ? .speechDenied : nil
        case .speechDenied where auth.speech != .denied: voiceFailure = auth.mic == .denied ? .micDenied : nil
        default: break
        }
    }

    /// Repeated notifications share one task; returning voice resumes only a voice-loss pause.
    func checkVoiceHealth() {
        guard scenario == nil else { return }
        if headMouse.isEnabled {
            if !headMouse.voiceClicks {
                if handsFreeMode != .voiceOff { voiceEpoch = UUID() }
                cancelVoiceRecovery(); handsFreeMode = .voiceOff; voiceFailure = nil
                if removePauseCause(.voice) {
                    announce("Voice commands are off. Pointer resumed without voice. Stop with Shift Command M or the menu bar.")
                }
                return
            }
            if handsFreeMode == .voiceOff { handsFreeMode = .voice }
        }
        guard canRecoverVoice else {
            cancelVoiceRecovery()
            if headMouse.isEnabled, !headMouse.voiceClicks { handsFreeMode = .voiceOff }
            return
        }
        if voiceIsRunning() {
            if voiceFailure != nil { finishVoiceRecovery() }
            return
        }
        if voiceFailure == .micDenied || voiceFailure == .speechDenied { cancelVoiceRecovery(); return }
        if voiceFailure != .stopped {
            addPauseCause(.voice); voiceFailure = .stopped
            play(.voiceLost)
        }
        beginVoiceRecovery()
    }

    /// The voice-off row's "Turn on": the same path as the Settings toggle.
    func turnOnVoice() {
        headMouse.voiceClicks = true
        checkVoiceHealth()
    }

    /// One voice request at a time; session epochs discard completion after Stop or a mode change.
    func restartVoice() async {
        guard scenario == nil, voiceRequestID == nil else { return }
        let auth = voiceAuthorization()
        if !voiceIsRunning(), auth.mic == .denied || auth.speech == .denied {
            voiceFailure = auth.mic == .denied ? .micDenied : .speechDenied
            cancelVoiceRecovery(); return
        }
        let id = UUID(), epoch = voiceEpoch
        voiceRequestID = id
        defer { if voiceRequestID == id { voiceRequestID = nil } }
        voiceRecovery.restarting()
        var failure: VoiceFailure?
        if !voiceIsRunning() { failure = await startVoice() }
        guard epoch == voiceEpoch else { return }
        guard voiceIsRunning() else {
            if failure == .micDenied || failure == .speechDenied {
                voiceFailure = failure; cancelVoiceRecovery()
            } else {
                voiceRecovery.phase = .failed
                voiceFailure = canRecoverVoice ? .stopped : (failure ?? .recognizerUnavailable)
            }
            return
        }
        if headMouse.isEnabled, headMouse.voiceClicks {
            finishVoiceRecovery()
        } else { voiceFailure = nil; cancelVoiceRecovery() }
    }

    private func startVoiceServices() async -> VoiceFailure? {
        if !transcriber.isRunning {
            await audio.start()
            if audio.isRunning { await transcriber.start(sink: audio.sink) }
            if !transcriber.isRunning, audio.isRunning { audio.stop() }
        }
        if transcriber.isRunning { return nil }
        let auth = voiceAuthorization()
        return VoiceFailure.classify(micAuth: auth.mic, speechAuth: auth.speech, audioError: audio.error, speechError: transcriber.error)
            ?? .recognizerUnavailable
    }

    /// Read-only watch of the voice services.
    private func watchVoice() {
        withObservationTracking {
            _ = transcriber.isRunning
            _ = audio.isRunning
            _ = headMouse.voiceClicks
            _ = headMouse.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkVoiceHealth()
                self?.watchVoice()
            }
        }
    }

    /// One-time webcam calibration of the head axes; the camera is off again afterwards.
    func calibrateWithCamera() async {
        await cameraCalibration.start { [weak self] axes, model, bud in
            self?.headMouse.applyCalibration(axes, bud: bud, message: "Calibrated with the camera. The buds now know your head's turn, nod and tilt.", model: model)
        }
    }

    // MARK: Mic

    func toggleMic() async {
        if transcriber.isRunning {
            transcriber.stop(); audio.stop()
        } else {
            await audio.start()
            if audio.isRunning { await transcriber.start(sink: audio.sink) }
        }
    }
}
