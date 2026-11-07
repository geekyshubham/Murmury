import Foundation
import Testing
@testable import MurmuryKit

/// A simulated reading session at 45 Hz. Speaking adds the jaw's small, quick shake to the bud's gyro
/// and accelerometer; quiet steps are still; the turn-quietly step swings the head slowly with no
/// shake. The buds' timestamps run `late` seconds behind the microphone's clock, as over Bluetooth.
private func readingSession(late: Double = 0.3) -> (samples: [(step: Int, s: MotionSample)], levels: [(t: Double, level: Float, step: Int)]) {
    var rng = SeededRNG(seed: 5)
    func noise(_ a: Double) -> Double { Double.random(in: -a...a, using: &rng) }
    let prompts = MurmurEnrollment.standard
    var samples: [(step: Int, s: MotionSample)] = [], levels: [(t: Double, level: Float, step: Int)] = []
    var t = 0.0
    for (step, prompt) in prompts.enumerated() {
        let length = prompt.seconds ?? 9
        let start = t
        while t < start + length {
            let u = t - start
            // Reading: speech in bursts of 1.4 s with 0.5 s breaths between them.
            let speaking = !prompt.isTimed && u.truncatingRemainder(dividingBy: 1.9) < 1.4
            let turning: Double = { if case .turnQuietly = prompt { return 1.2 * sin(2 * .pi * 0.4 * u) } else { return 0 } }()
            let jaw = speaking ? 0.12 : 0.0
            var s = MotionSample(t: t + late, qw: 1, qx: 0, qy: 0, qz: 0)
            s.hasIMU = true
            let shake = jaw * sin(2 * .pi * 7 * t + noise(1))
            (s.gx, s.gy, s.gz) = (shake + noise(0.01), turning + 0.6 * shake + noise(0.01), 0.4 * shake + noise(0.01))
            (s.ax, s.ay, s.az) = (0.5 * shake + noise(0.005), 9.8 + 0.3 * shake + noise(0.005), noise(0.005))
            samples.append((step, s))
            if Int((t * 45).rounded()) % 1 == 0 {
                levels.append((t, speaking ? 0.55 + Float(noise(0.05)) : 0.2 + Float(noise(0.03)), step))
            }
            t += 1.0 / 45
        }
    }
    return (samples, levels)
}

@Suite("Murmur model")
struct MurmurModelTests {
    @Test func learnsToFeelSpeechAndIgnoresAQuietHeadTurn() throws {
        let session = readingSession()
        let examples = MurmurEnrollment.examples(samples: session.samples, levels: session.levels, prompts: MurmurEnrollment.standard)
        #expect(examples.filter(\.speaking).count > 100 && examples.filter { !$0.speaking }.count > 100)
        let model = try #require(MurmurTrainer.train(examples))
        #expect(model.recall > 0.9, "recall \(model.recall)")
        #expect(model.falseAlarms < 0.1, "false alarms \(model.falseAlarms)")
        // Live: the detector feels the reading and stays quiet through the head turn.
        var detector = MurmurDetector(model: model)
        var duringTurn = 0, turnSamples = 0, duringSpeech = 0, speechSamples = 0, stepStart: [Int: Double] = [:]
        for (step, s) in session.samples {
            let murmuring = detector.ingest(s)
            let start = stepStart[step] ?? s.t; stepStart[step] = start
            // After its first second: the half-second window and hold still cover the last words read.
            if case .turnQuietly = MurmurEnrollment.standard[step], s.t - start > 1 { turnSamples += 1; if murmuring { duringTurn += 1 } }
            if case .read = MurmurEnrollment.standard[step] { speechSamples += 1; if murmuring { duringSpeech += 1 } }
        }
        #expect(Double(duringTurn) / Double(turnSamples) < 0.1, "turn flagged \(duringTurn)/\(turnSamples)")
        #expect(Double(duringSpeech) / Double(speechSamples) > 0.6, "reading felt \(duringSpeech)/\(speechSamples)")
    }

    @Test func refusesWithoutEnoughSpeech() {
        let session = readingSession()
        let quietOnly = session.levels.map { ($0.t, Float(0.2), $0.step) }
        let examples = MurmurEnrollment.examples(samples: session.samples, levels: quietOnly, prompts: MurmurEnrollment.standard)
        #expect(MurmurTrainer.train(examples) == nil)
    }

    @Test func passagesCoverTheCommandsAndTeachWhatIsntSpeech() {
        let text = MurmurEnrollment.standard.compactMap { if case .read(let t, _) = $0 { return t.lowercased() } else { return nil } }.joined(separator: " ")
        for word in ["click", "right click", "double click", "scroll down", "scroll up", "mouse off", "mouse on"] {
            #expect(text.contains(word), "\(word)")
        }
        #expect(MurmurEnrollment.standard.contains { if case .turnQuietly = $0 { return true } else { return false } })
        #expect(MurmurEnrollment.standard.first?.isTimed == true, "starts with quiet, for the room's level")
    }

    @MainActor @Test func onlyMyVoiceBlocksCommandsTheBudsDidNotFeel() {
        let pointer = FakePointer()
        let mouse = HeadMouse(driver: pointer, defaults: nil, ticks: false)
        mouse.isEnabled = true
        var felt = false
        mouse.ownVoiceGate = { felt }
        mouse.hear(text: "click")
        #expect(pointer.clicks.isEmpty, "someone else's click is ignored")
        felt = true
        mouse.hear(text: "click click")
        #expect(pointer.clicks.count == 1, "the wearer's own click acts")
    }

    /// Reading the passages must not act: their command words would click, scroll and pause.
    @MainActor @Test func readingThePassagesNeverActs() {
        let pointer = FakePointer()
        let model = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: ".build/murmur-\(UUID())")),
                             headMouse: HeadMouse(driver: pointer, defaults: nil, ticks: false))
        model.headMouse.isEnabled = true
        model.headMouse.motionCommands = true
        var now = 100.0
        model.murmurEnrollment.clock = { now }
        model.murmurEnrollment.start(micRunning: { true })
        #expect(model.murmurEnrollment.phase == .running)
        // Every passage, as one growing transcript, the way the recogniser delivers it.
        var transcript = ""
        for case .read(let text, _) in MurmurEnrollment.standard {
            transcript += " " + text
            model.headMouse.hear(text: transcript)
        }
        model.headMouse.perform(label: "click")  // a trained gesture is held too
        #expect(pointer.clicks.isEmpty && pointer.scrolls.isEmpty && !model.headMouse.isPaused)
        // The spoken way out ends the session, with the head mouse still running.
        model.murmurEnrollment.hear(text: transcript + " stop teaching")
        #expect(model.murmurEnrollment.phase == .idle && model.headMouse.isEnabled)
        now += MurmurEnrollment.commandGrace + 0.1  // past the grace for late recognition results
        model.headMouse.hear(text: transcript + " stop teaching click")
        #expect(pointer.clicks.count == 1, "after teaching, a new command acts; the read ones never fire late")
    }

    /// Without a running microphone the session doesn't start, and denied access says how to fix it.
    @MainActor @Test func refusesToStartWithoutTheMicrophone() {
        let e = MurmurEnrollment()
        e.start(micRunning: { false }, micError: "Microphone access denied. Enable it in System Settings › Privacy & Security.")
        guard case .failed(_, let denied) = e.phase else { Issue.record("expected failure, got \(e.phase)"); return }
        #expect(denied)
        e.start(micRunning: { false }, micError: nil)
        guard case .failed(_, let denied2) = e.phase else { Issue.record("expected failure"); return }
        #expect(!denied2)
    }

    /// Through the app's real transcript path: the update that carries "stop teaching" never acts,
    /// even for passage words recognised alongside it; only a later command does.
    @MainActor @Test func theCancellingTranscriptNeverActs() {
        let pointer = FakePointer()
        let model = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: ".build/murmur-\(UUID())")),
                             headMouse: HeadMouse(driver: pointer, defaults: nil, ticks: false))
        model.applyScenario(.controlRunning)
        model.headMouse.isEnabled = true
        var now = 100.0
        model.murmurEnrollment.clock = { now }
        model.murmurEnrollment.start(micRunning: { true })
        model.transcriber.onText?("Click.")
        model.transcriber.onText?("Click. Right click. Stop teaching.")
        #expect(model.murmurEnrollment.phase == .idle)
        #expect(pointer.clicks.isEmpty, "the right click that arrived with the stop phrase is consumed, not performed")
        now += MurmurEnrollment.commandGrace + 0.1
        model.transcriber.onText?("Click. Right click. Stop teaching. Click.")
        #expect(pointer.clicks.count == 1, "the next command acts")
    }

    /// Recognition lags speech: a result for words read during the session that arrives just after
    /// it ends (cancel, microphone loss or the last passage) is consumed, never performed.
    @MainActor @Test func lateResultsAfterTeachingNeverAct() {
        // Ended by Esc, by a silent microphone, and by the last passage: each the same way.
        for end in 0..<3 {
            let pointer = FakePointer()
            let model = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: ".build/murmur-\(UUID())")),
                                 headMouse: HeadMouse(driver: pointer, defaults: nil, ticks: false))
            model.applyScenario(.controlRunning)
            model.headMouse.isEnabled = true
            var now = 100.0
            model.murmurEnrollment.clock = { now }
            model.murmurEnrollment.start(micRunning: { true })
            model.transcriber.onText?("Click. \(end)")
            switch end {
            case 0: model.murmurEnrollment.cancel()
            case 1: model.murmurEnrollment.tick(at: now + MurmurEnrollment.micSilence + 5)
            default: while model.murmurEnrollment.phase == .running { model.murmurEnrollment.next() }
            }
            model.transcriber.onText?("Click. \(end) Right click. Scroll down.")  // late result for words read aloud
            #expect(pointer.clicks.isEmpty && pointer.scrolls.isEmpty, "ending \(end)")
            now += MurmurEnrollment.commandGrace + 0.1
            model.murmurEnrollment.cancel()  // leaves training, if the last case started it
            model.transcriber.onText?("Click. \(end) Right click. Scroll down. Click.")
            #expect(pointer.clicks.count == 1, "ending \(end): a command after the grace acts")
        }
    }

    /// The recognition session closes at the boundary, not on a timer: every way reading stops
    /// reports it once, and the app restarts recognition there.
    @MainActor @Test func readingEndCloseTheRecognitionSession() {
        for end in 0..<3 {
            let e = MurmurEnrollment()
            var now = 50.0
            e.clock = { now }
            var ended = 0
            e.onReadingEnded = { ended += 1 }
            e.start(micRunning: { true })
            switch end {
            case 0: e.cancel()
            case 1: e.tick(at: now + MurmurEnrollment.micSilence + 1)
            default: while e.phase == .running { e.next() }
            }
            #expect(ended == 1, "ending \(end)")
            e.cancel(); now += 5
            #expect(ended == 1, "leaving training doesn't report again")
        }
        let model = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: ".build/murmur-\(UUID())")),
                             headMouse: HeadMouse(driver: FakePointer(), defaults: nil, ticks: false))
        #expect(model.murmurEnrollment.onReadingEnded != nil, "the app closes recognition when reading ends")
    }

    /// The app's boundary end to end, with a stand-in recogniser built on the real TranscriptState:
    /// however reading stops, results still pending from the reading task never reach the app, even
    /// long after the grace, and the next intentional command acts exactly once.
    @MainActor @Test func theAppClosesRecognitionAtEveryEnding() {
        for end in 0..<3 {
            let pointer = FakePointer()
            let model = AppModel(store: DatasetStore(directory: URL(fileURLWithPath: ".build/murmur-\(UUID())")),
                                 headMouse: HeadMouse(driver: pointer, defaults: nil, ticks: false))
            model.applyScenario(.controlRunning)
            model.headMouse.isEnabled = true
            var now = 10.0
            model.murmurEnrollment.clock = { now }
            var state = TranscriptState(), task = state.newTask()
            func deliver(_ g: Int, _ partial: String, final: Bool = false) {
                if state.receive(generation: g, partial: partial, isFinal: final, failed: false) != nil { model.transcriber.onText?(state.text) }
            }
            model.restartRecognition = { state.carryOver(); task = state.newTask() }
            model.murmurEnrollment.start(micRunning: { true })
            let reading = task
            deliver(reading, "Click.")
            switch end {
            case 0: model.murmurEnrollment.cancel()
            case 1: model.murmurEnrollment.tick(at: now + MurmurEnrollment.micSilence + 1)
            default: while model.murmurEnrollment.phase == .running { model.murmurEnrollment.next() }
            }
            #expect(task != reading, "ending \(end): the recognition session was restarted")
            now += 60  // far past the grace
            deliver(reading, "Click. Right click. Scroll down. Mouse off.", final: true)  // the old task's late result
            #expect(pointer.clicks.isEmpty && pointer.scrolls.isEmpty && !model.headMouse.isPaused, "ending \(end)")
            model.murmurEnrollment.cancel()
            deliver(task, "click")
            #expect(pointer.clicks.count == 1, "ending \(end): the next command acts once")
            deliver(task, "click mouse off")
            #expect(pointer.clicks.count == 1 && model.headMouse.isPaused)
        }
    }

    /// A stop phrase already in the recogniser's history can't end a retry; a new one can, and a
    /// recogniser reset (a shorter transcript) starts the count afresh.
    @MainActor @Test func spokenStopIsScopedToTheSession() {
        let e = MurmurEnrollment()
        e.hear(text: "earlier I said stop teaching")
        e.start(micRunning: { true })
        e.hear(text: "earlier I said stop teaching. A large, calm owl")
        #expect(e.phase == .running, "the old phrase doesn't cancel the retry")
        e.hear(text: "earlier I said stop teaching. A large, calm owl. Stop teaching")
        #expect(e.phase == .idle, "a new one does")
        e.start(micRunning: { true })
        e.hear(text: "Peter's busy bee")  // the recogniser restarted: a fresh, shorter transcript
        #expect(e.phase == .running)
        e.hear(text: "Peter's busy bee. Stop teaching")
        #expect(e.phase == .idle)
    }

    /// One temporal split: changing only the held-out reading can't change what was fitted.
    @Test func heldOutReadingDoesNotShapeTheFit() throws {
        let session = readingSession()
        let base = MurmurEnrollment.examples(samples: session.samples, levels: session.levels, prompts: MurmurEnrollment.standard)
        // The cut sits 1 s before the first held-out window. Silence the microphone from there on:
        // the held-out labels change; the fitted side, its noise floor and its alignment must not.
        let cut = try #require(base.filter { $0.split == .test }.map(\.t).min()) - 1
        let altered = session.levels.map { $0.t >= cut ? ($0.t, Float(0.2), $0.step) : $0 }
        let other = MurmurEnrollment.examples(samples: session.samples, levels: altered, prompts: MurmurEnrollment.standard)
        let a = base.filter { $0.split == .train }, b = other.filter { $0.split == .train }
        #expect(a.count == b.count && zip(a, b).allSatisfy { $0.speaking == $1.speaking && $0.t == $1.t })
        let heldA = base.filter { $0.split == .test }, heldB = other.filter { $0.split == .test }
        #expect(heldA.filter(\.speaking).count != heldB.filter(\.speaking).count, "the alteration did reach the held-out side")
    }

    /// A microphone that stops delivering sound ends the session, even while its service still says
    /// it is running.
    @MainActor @Test func silentMicrophoneEndsTheSession() {
        let e = MurmurEnrollment()
        e.start(micRunning: { true })
        e.hear(level: 0.2, at: 100)
        e.tick(at: 100.5)
        #expect(e.phase == .running)
        e.tick(at: 100 + MurmurEnrollment.micSilence + 0.2)
        guard case .failed(let why, _) = e.phase else { Issue.record("expected failure, got \(e.phase)"); return }
        #expect(why.contains("microphone stopped"))
    }

    /// The reported figures say whether they come from held-out reading.
    @Test func validationIsHonestAboutItsHoldOut() throws {
        let session = readingSession()
        let examples = MurmurEnrollment.examples(samples: session.samples, levels: session.levels, prompts: MurmurEnrollment.standard)
        let model = try #require(MurmurTrainer.train(examples))
        #expect(model.heldOut == true)
        // Only quiet near the end: no fair hold-out, so the figures are marked as training figures.
        let lastSpeech = examples.filter(\.speaking).map(\.t).max()!
        let early = examples.filter { $0.t <= lastSpeech } + examples.filter { $0.t > lastSpeech }.map { var e = $0; e.speaking = false; return e }
        let squeezed = early.filter { !$0.speaking || $0.t < lastSpeech - 30 }
        if let m = MurmurTrainer.train(squeezed) { #expect(m.heldOut == false) }
    }

    @MainActor @Test func feltMurmurHoldsThePointer() {
        let mouse = HeadMouse(driver: FakePointer(), defaults: nil, ticks: false)
        mouse.isEnabled = true
        mouse.feel(murmur: true, at: 10)
        var s = MotionSample(t: 10.1, qw: 1, qx: 0, qy: 0, qz: 0)
        s.hasIMU = true; s.gy = 1
        mouse.ingest(s)
        #expect(mouse.isSpeaking, "the felt murmur holds the pointer like heard speech")
    }
}

/// What a VoiceOver user hears at each turn of the sheets, checked against the models that speak.
@Suite("Sheet announcements")
@MainActor
struct SheetAnnouncementTests {
    @Test func everyWayOutOfTeachingIsSpokenOnce() {
        let e = MurmurEnrollment()
        var heard: [String] = []
        e.onAnnounce = { heard.append($0) }
        e.start(micRunning: { true })
        heard = []
        e.cancel()  // Esc or Cancel
        #expect(heard == ["Murmur teaching stopped. Nothing was learned."])
        e.cancel()  // closing the sheet afterwards says nothing more
        #expect(heard.count == 1)
        e.start(micRunning: { true })
        heard = []
        e.hear(text: "stop teaching")  // the spoken stop
        #expect(heard == ["Murmur teaching stopped. Nothing was learned."])
    }

    @Test func keepingAWeakResultIsConfirmed() {
        let e = MurmurEnrollment()
        var heard: [String] = [], installed = false
        e.onAnnounce = { heard.append($0) }
        e.onTrained = { _ in installed = true }
        e.stage("weak")
        e.accept()
        #expect(installed && heard == ["Murmur model in use."])
    }

    @Test func skippingAStalledStepSaysWhatComesNext() {
        let cal = CameraCalibration()
        var heard: [String] = []
        var prompts: [String] = []
        cal.onAnnounce = { heard.append($0) }
        cal.onPrompt = { prompts.append($0) }
        cal.stage("stalled")
        #expect(cal.stalled && cal.step == cal.script.steps[3])
        cal.skipStep()
        #expect(!cal.stalled && cal.step == cal.script.steps[4])
        #expect(prompts == ["Step skipped. " + cal.script.steps[4].kind.instruction + "."])
        cal.stage("stalled")
        prompts = []
        cal.retryStep()
        #expect(!cal.stalled && prompts == [cal.script.steps[3].kind.instruction + "."])
        #expect(heard.isEmpty, "instructions replace each other; outcomes queue")
    }

    @Test func eachTeachingPromptReplacesTheLastButOutcomesQueue() {
        let e = MurmurEnrollment()
        var prompts: [String] = [], heard: [String] = []
        e.onPrompt = { prompts.append($0) }
        e.onAnnounce = { heard.append($0) }
        e.start(micRunning: { true })
        e.next()
        #expect(prompts.count == 2 && prompts.allSatisfy { $0.hasPrefix("Read aloud") || $0.hasPrefix("Stay quiet") })
        e.cancel()
        #expect(heard == ["Murmur teaching stopped. Nothing was learned."])
    }
}
