// Adapted from Subvox (https://github.com/joeblau/subvox), MIT License, Copyright (c) 2026 Joe Blau.
import AVFoundation
import Observation
import Speech

/// Continuous speech-to-text from the microphone. Used as the reference ("ground truth")
/// next to the motion decoder, and to test whether whispering is enough for input.
@MainActor @Observable
final class MicTranscriber {
    private(set) var isRunning = false
    private(set) var text = ""
    private(set) var isOnDevice = false
    private(set) var error: String?

    /// Called on every transcript change, including partial results and clears.
    @ObservationIgnored var onText: ((String) -> Void)?
    /// Each final result's words, with when they were said (seconds since boot): the labels a
    /// speech calibration lines the buds' motion up with.
    @ObservationIgnored var onWords: (([SpokenWord]) -> Void)?
    /// Phrases to bias recognition towards.
    @ObservationIgnored var vocabulary: [String] = []
    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    @ObservationIgnored private let box = RequestBox()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var sinkID: UUID?
    @ObservationIgnored private weak var sink: AudioSink?
    @ObservationIgnored private var state = TranscriptState()

    func start(sink: AudioSink) async {
        guard !isRunning else { return }
        error = nil

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            error = "Speech recognition not authorized."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognizer unavailable."
            return
        }

        self.sink = sink
        sinkID = sink.add { [box] buffer, time in box.append(buffer, at: time) }
        isRunning = true
        startTask()
    }

    func stop() {
        isRunning = false
        _ = state.newTask()  // nothing from the stopped task may speak again
        if let sinkID { sink?.remove(sinkID) }
        sinkID = nil
        box.set(nil)
        task?.cancel()
        task = nil
    }

    /// Closes the current recognition and starts a fresh one. Results still pending from the old
    /// request are dropped (their generation no longer matches), however late they would arrive;
    /// text already delivered is kept, so the transcript doesn't shrink under the command parser.
    func restartRecognition() {
        guard isRunning else { return }
        state.carryOver()
        startTask()
    }

    func clear() {
        state.clear()
        text = ""
        onText?(text)
    }

    private func startTask() {
        guard isRunning, let recognizer else { return }
        let generation = state.newTask()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = vocabulary
        isOnDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = isOnDevice
        let clock = RequestClock()
        box.set(request, clock: clock)

        task?.cancel()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(owner: self, generation: generation, clock: clock))
    }

    private func handle(generation: Int, partial: String?, isFinal: Bool, failed: Bool, words: [SpokenWord] = []) {
        guard isRunning, let ended = state.receive(generation: generation, partial: partial, isFinal: isFinal, failed: failed) else { return }
        text = state.text
        onText?(text)
        if !words.isEmpty { onWords?(words) }
        if ended {
            // Recognition tasks end on silence/timeout; keep listening with a fresh one, unless a
            // newer task has started meanwhile (a restart at a boundary): an old timer never
            // cancels newer recognition.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(failed ? 500 : 50))
                guard let self, self.state.isCurrent(generation) else { return }
                self.startTask()
            }
        }
    }

    nonisolated private static func resultHandler(owner: MicTranscriber, generation: Int, clock: RequestClock)
        -> (SFSpeechRecognitionResult?, Error?) -> Void
    {
        { [weak owner] result, error in
            let partial = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            // Word timings only from final results: partial ones are still being revised.
            var words: [SpokenWord] = []
            if isFinal, let result, let start = clock.start {
                words = SpokenWord.words(segments: result.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.duration) },
                                         requestStart: start)
            }
            Task { @MainActor in
                owner?.handle(generation: generation, partial: partial, isFinal: isFinal, failed: failed, words: words)
            }
        }
    }
}

/// The current recognition request, appended to from the audio thread.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    private var clock: RequestClock?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?, clock: RequestClock? = nil) {
        lock.withLock {
            self.request?.endAudio()
            self.request = request
            self.clock = clock
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.withLock {
            guard let request else { return }
            request.append(buffer)
            // The request's clock: when its first audio arrived, on the host clock (seconds since
            // boot), so the recogniser's word timestamps can be placed beside motion samples.
            if time.isHostTimeValid { clock?.mark(AVAudioTime.seconds(forHostTime: time.hostTime)) }
        }
    }
}

/// When one recognition request's first audio buffer arrived.
private final class RequestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var first: TimeInterval?
    func mark(_ t: TimeInterval) { lock.withLock { if first == nil { first = t } } }
    var start: TimeInterval? { lock.withLock { first } }
}

/// The transcript across recognition tasks, and which task may still speak. Each task gets a
/// generation; results and restart timers from older generations are ignored, however late.
struct TranscriptState: Equatable {
    private(set) var finalized = ""
    private(set) var text = ""
    private(set) var generation = 0

    /// Starts a new task; from now on only its results count.
    mutating func newTask() -> Int { generation += 1; return generation }
    func isCurrent(_ g: Int) -> Bool { g == generation }
    /// Folds the delivered text in, so a new task never shrinks the transcript under the parser.
    mutating func carryOver() { finalized = text.isEmpty ? "" : text + " " }
    mutating func clear() { finalized = ""; text = "" }

    /// A result from task `g`. Nil when it belongs to an older task (dropped); otherwise whether
    /// the task ended (final or failed), so a fresh one should follow.
    mutating func receive(generation g: Int, partial: String?, isFinal: Bool, failed: Bool) -> Bool? {
        guard g == generation else { return nil }
        if let partial { text = finalized + partial }
        if isFinal || failed {
            if let partial, !partial.isEmpty { finalized += partial + " " }
            // A task that fails with nothing new keeps what it already delivered, so the transcript
            // never shrinks and the command parser never waits for words it already acted on.
            else if failed, text.count > finalized.count { finalized = text + " " }
            text = finalized
        }
        return isFinal || failed
    }
}
