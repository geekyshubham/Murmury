import Foundation

// What the buds can learn about speech, and what they can't.
//
// Open-vocabulary words come from on-device speech recognition (Speech framework), which hears
// every English word you voice or murmur. The buds' motion adds what a microphone can't: how far
// your mouth is open (learned against the camera), and a per-person vocabulary of silently mouthed
// words (learned from words the recogniser timed while you read aloud). Recognising every English
// word from earbud motion alone is beyond published work: the best earable system (MuteIt) reaches
// about 100 command words with a dedicated jaw sensor, and Galaxy Buds stream ~45-50 Hz from the
// ear canal. So the silent vocabulary is measured honestly (leave-one-out against chance, with a
// permutation test) and grows with each calibration.

/// One word the speech recogniser heard, with when it was said (seconds since boot: the clock motion
/// samples and camera frames use).
struct SpokenWord: Codable, Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var duration: TimeInterval

    /// Words from a final recognition result's segments (`timestamp` is seconds from the request's
    /// first audio buffer, which arrived at `requestStart`). Punctuation is dropped; empty ones too.
    static func words(segments: [(text: String, timestamp: TimeInterval, duration: TimeInterval)], requestStart: TimeInterval) -> [SpokenWord] {
        segments.compactMap { s in
            let text = normalized(s.text)
            return text.isEmpty ? nil : SpokenWord(text: text, start: requestStart + s.timestamp, duration: max(0, s.duration))
        }
    }
    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0 == "'" })
    }
}

// MARK: Mouth

/// How far the mouth is open (0 closed … 1 wide), from the buds' motion: ridge regression over a
/// quarter-second of fast gyro and accelerometer features, fitted against the camera's measure of
/// the lips' opening during a calibration.
struct MouthModel: Codable, Equatable, Sendable {
    /// Samples per window: about a quarter of a second at the buds' rate.
    static let window = 12
    var mean: [Double]
    var scale: [Double]
    var weights: [Double]
    var bias: Double
    /// The camera's opening at the session's 5th and 95th percentiles: what 0 and 1 mean.
    var lo: Double
    var hi: Double
    /// How late the buds' samples arrive relative to the camera (seconds).
    var lag: Double
    /// Fit on windows it didn't learn from (`heldOut`), or on the training windows when too few.
    var r2: Double
    var examples: Int
    var heldOut: Bool

    func opening(_ x: [Double]) -> Double {
        guard x.count == weights.count else { return 0 }
        var y = bias
        for i in x.indices { y += weights[i] * (x[i] - mean[i]) / scale[i] }
        return min(1, max(0, y))
    }
}

enum MouthTrainer {
    struct Window { var t0: Double; var t1: Double; var x: [Double] }

    /// Windows of `MouthModel.window` samples, every second sample, from the bud that reported most.
    static func windows(_ samples: [MotionSample]) -> [Window] {
        let bud = Dictionary(grouping: samples, by: \.bud).max { $0.value.count < $1.value.count }?.key
        let s = samples.filter { $0.bud == bud }.sorted { $0.t < $1.t }
        var out: [Window] = []
        var i = 0
        while i + MouthModel.window <= s.count {
            let slice = s[i..<(i + MouthModel.window)]
            if slice.last!.t - slice.first!.t < 0.6, let x = MurmurFeatures.vector(slice) {
                out.append(Window(t0: slice.first!.t, t1: slice.last!.t, x: x))
            }
            i += 2
        }
        return out
    }

    /// Learns the model from bud samples and the camera's mouth opening over the same session.
    static func train(samples: [MotionSample], mouth: [(t: Double, value: Double)]) -> MouthModel? {
        let wins = windows(samples)
        let frames = mouth.sorted { $0.t < $1.t }
        guard wins.count >= 80, frames.count >= 40 else { return nil }
        let values = frames.map(\.value).sorted()
        let lo = values[Int(Double(values.count - 1) * 0.05)], hi = values[Int(Double(values.count - 1) * 0.95)]
        guard hi - lo > 1e-6 else { return nil }
        let times = frames.map(\.t)
        /// The camera's mean normalised opening over a bud window, shifted by `lag`.
        func target(_ w: Window, _ lag: Double) -> Double? {
            let a = lowerBound(times, w.t0 - lag), b = lowerBound(times, w.t1 - lag + 1e-9)
            guard b > a else { return nil }
            let m = frames[a..<b].reduce(0) { $0 + $1.value } / Double(b - a)
            return min(1, max(0, (m - lo) / (hi - lo)))
        }
        // One temporal split: the last quarter is held out, a second's gap either side of the cut.
        let cut = wins[Int(Double(wins.count) * 0.75)].t0
        let train = wins.filter { $0.t1 < cut - 0.5 }, test = wins.filter { $0.t0 >= cut + 0.5 }
        func pairs(_ ws: [Window], _ lag: Double) -> [(x: [Double], y: Double)] { ws.compactMap { w in target(w, lag).map { (w.x, $0) } } }
        // The camera-to-buds delay that best explains the training side.
        var bestLag = 0.0, bestR2 = -Double.infinity
        for lag in stride(from: -0.3, through: 0.6, by: 0.04) {
            let p = pairs(train, lag)
            guard p.count >= 60, let fit = Ridge.fit(p) else { continue }
            let r2 = Ridge.r2(fit, p)
            if r2 > bestR2 { bestR2 = r2; bestLag = lag }
        }
        guard bestR2.isFinite else { return nil }
        let held = pairs(test, bestLag), fitted = pairs(train, bestLag)
        let fair = held.count >= 20 && Set(held.map { ($0.y * 10).rounded() }).count > 1
        guard let probe = Ridge.fit(fitted) else { return nil }
        let r2 = fair ? Ridge.r2(probe, held) : Ridge.r2(probe, fitted)
        let everything = pairs(wins, bestLag)
        guard let final = Ridge.fit(everything) else { return nil }
        return MouthModel(mean: final.mean, scale: final.scale, weights: final.weights, bias: final.bias, lo: lo, hi: hi,
                          lag: bestLag, r2: r2, examples: everything.count, heldOut: fair)
    }

    private static func lowerBound(_ a: [Double], _ v: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] < v { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}

/// Closed-form ridge regression on standardised features.
enum Ridge {
    struct Fit { var mean: [Double]; var scale: [Double]; var weights: [Double]; var bias: Double }
    static func fit(_ data: [(x: [Double], y: Double)], lambda: Double = 1.0) -> Fit? {
        guard let d = data.first?.x.count, data.count > d else { return nil }
        let n = Double(data.count)
        var mean = [Double](repeating: 0, count: d), scale = [Double](repeating: 0, count: d)
        for p in data { for i in 0..<d { mean[i] += p.x[i] / n } }
        for p in data { for i in 0..<d { scale[i] += pow(p.x[i] - mean[i], 2) / n } }
        scale = scale.map { max(1e-6, $0.squareRoot()) }
        let ym = data.reduce(0) { $0 + $1.y } / n
        // Normal equations (XᵀX + λI) w = Xᵀy on standardised x and centred y.
        var a = [[Double]](repeating: [Double](repeating: 0, count: d + 1), count: d)
        for p in data {
            let z = (0..<d).map { (p.x[$0] - mean[$0]) / scale[$0] }
            for i in 0..<d {
                for j in 0..<d { a[i][j] += z[i] * z[j] }
                a[i][d] += z[i] * (p.y - ym)
            }
        }
        for i in 0..<d { a[i][i] += lambda }
        guard let w = solve(a) else { return nil }
        return Fit(mean: mean, scale: scale, weights: w, bias: ym)
    }
    static func predict(_ f: Fit, _ x: [Double]) -> Double {
        var y = f.bias
        for i in x.indices { y += f.weights[i] * (x[i] - f.mean[i]) / f.scale[i] }
        return y
    }
    /// Coefficient of determination of `f` on `data` (1 perfect, 0 no better than the mean).
    static func r2(_ f: Fit, _ data: [(x: [Double], y: Double)]) -> Double {
        guard !data.isEmpty else { return -.infinity }
        let ym = data.reduce(0) { $0 + $1.y } / Double(data.count)
        let ssTot = data.reduce(0) { $0 + pow($1.y - ym, 2) }
        let ssRes = data.reduce(0) { $0 + pow($1.y - predict(f, $1.x), 2) }
        return ssTot > 0 ? 1 - ssRes / ssTot : -.infinity
    }
    /// Gauss-Jordan elimination with partial pivoting on an augmented matrix.
    private static func solve(_ m: [[Double]]) -> [Double]? {
        var a = m
        let n = a.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p)
            let pivot = a[c][c]
            for j in c...n { a[c][j] /= pivot }
            for r in 0..<n where r != c {
                let f = a[r][c]
                guard f != 0 else { continue }
                for j in c...n { a[r][j] -= f * a[c][j] }
            }
        }
        return a.map { $0[n] }
    }
}

/// Runs a trained `MouthModel` on the live stream: how far the mouth is open now.
struct MouthDetector {
    var model: MouthModel
    private var recent: [MotionSample] = []
    private(set) var opening = 0.0
    init(model: MouthModel) { self.model = model }

    /// Feeds one sample; returns the smoothed opening (opens fast, closes a little slower).
    mutating func ingest(_ s: MotionSample) -> Double {
        if let last = recent.last, last.bud != s.bud || s.t - last.t > 0.25 { recent.removeAll() }
        recent.append(s)
        if recent.count > MouthModel.window { recent.removeFirst(recent.count - MouthModel.window) }
        guard recent.count == MouthModel.window, let x = MurmurFeatures.vector(recent[...]) else { return opening }
        let target = model.opening(x)
        opening += (target - opening) * (target > opening ? 0.5 : 0.2)
        return opening
    }
}

/// Before a mouth model is learned: the mouth opens with the voice's loudness above the room's
/// quiet (the microphone's level, 0…1), so the head speaks along while you do.
struct AudioMouth {
    private var floor: Float?
    private(set) var opening = 0.0
    mutating func update(level: Float) -> Double {
        let f = floor ?? level
        floor = level < f ? level : f + (level - f) * 0.002
        let target = Double(min(1, max(0, (level - f - 0.08) / 0.3)))
        opening += (target - opening) * (target > opening ? 0.6 : 0.25)
        if opening < 0.01 { opening = 0 }
        return opening
    }
}

// MARK: Words

/// A per-person vocabulary of words, each with motion templates the speech recogniser labelled
/// while the person read aloud: the Subvox idea (DTW templates, leave-one-out against chance), with
/// the labelling done by the recogniser's word timings instead of one held key per word.
struct WordModel: Codable, Sendable {
    var takes: [Take]
    var vocabulary: [String]
    var featureSet: FeatureSet
    var accuracy: Double?
    var chance: Double?
    var pValue: Double?
}

enum WordTrainer {
    /// Occurrences a word needs before it joins the vocabulary.
    static let minimumTakes = 3
    /// Lead-in before the recogniser's start, and tail after its end (seconds).
    static let lead = 0.1, tail = 0.15

    /// Cuts each spoken word's motion out of the session (bud time = speech time + `lag`).
    static func takes(samples: [MotionSample], words: [SpokenWord], lag: Double) -> [Take] {
        let bud = Dictionary(grouping: samples, by: \.bud).max { $0.value.count < $1.value.count }?.key
        let s = samples.filter { $0.bud == bud }.sorted { $0.t < $1.t }
        let times = s.map(\.t)
        func index(_ v: Double) -> Int {
            var lo = 0, hi = times.count
            while lo < hi { let mid = (lo + hi) / 2; if times[mid] < v { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        return words.compactMap { w in
            let a = index(w.start - lead + lag), b = index(w.start + w.duration + tail + lag)
            guard b - a >= 6 else { return nil }
            return Take(label: w.text, samples: Array(s[a..<b]))
        }
    }

    /// The jaw shows in the buds' own gyro and accelerometer more than in their fused orientation,
    /// so words use the raw sensors whenever the buds send them.
    static func featureSet(for samples: [MotionSample]) -> FeatureSet {
        samples.contains(where: \.hasIMU) ? [.velocity, .imu] : [.velocity, .acceleration]
    }

    static func build(samples: [MotionSample], words: [SpokenWord], lag: Double, featureSet: FeatureSet? = nil) -> WordModel? {
        let featureSet = featureSet ?? Self.featureSet(for: samples)
        let all = takes(samples: samples, words: words, lag: lag)
        let counts = Dictionary(grouping: all, by: \.label).mapValues(\.count)
        let vocabulary = counts.filter { $0.value >= minimumTakes }.keys.sorted()
        guard vocabulary.count >= 2 else { return nil }
        let kept = all.filter { vocabulary.contains($0.label) }
        let eval = Evaluation.run(takes: kept, featureSet: featureSet, permutations: 200)
        return WordModel(takes: kept, vocabulary: vocabulary, featureSet: featureSet,
                         accuracy: eval?.accuracy, chance: eval?.chance, pValue: eval?.pValue)
    }
}

/// Recognises a silently mouthed word from its motion, against the learned vocabulary.
struct SilentWordRecognizer: Sendable {
    /// The same acceptance as gestures: close enough to a template, and clearly closer than the next word.
    static let maxDistance = 2.5, minMargin = 0.15
    private let classifier: TemplateClassifier
    init?(model: WordModel) {
        guard let c = TemplateClassifier(takes: model.takes, featureSet: model.featureSet) else { return nil }
        classifier = c
    }
    func recognize(_ samples: [MotionSample]) -> (word: String, confidence: Double, accepted: Bool)? {
        let p = classifier.predict(samples, maxDistance: Self.maxDistance, minConfidence: Self.minMargin)
        guard let best = p.best else { return nil }
        return (best.label, p.confidence, p.accepted)
    }
}

// MARK: Together

/// Everything a speech calibration learned, saved as `speech.json` beside the dataset.
struct SpeechModels: Codable, Sendable {
    var mouth: MouthModel?
    var words: WordModel?
    static let fileName = "speech.json"

    /// One line per model, for the sheet and Settings.
    var report: [String] {
        var lines: [String] = []
        if let m = mouth {
            lines.append(String(format: "Mouth: follows yours, fit %.0f%%%@", max(0, m.r2) * 100, m.heldOut ? "" : " (on its own training)"))
        }
        if let w = words {
            let acc = w.accuracy.map { String(format: ", %.0f%% right vs %.0f%% by chance", $0 * 100, (w.chance ?? 0) * 100) } ?? ""
            lines.append("Silent words: \(w.vocabulary.count) learned\(acc)")
        }
        return lines
    }

    static func load(from url: URL) -> SpeechModels? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeechModels.self, from: data)
    }
    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Trains both from one session: bud samples, the camera's mouth opening, and the recogniser's
    /// timed words. The mouth model's delay also lines the words up with the buds.
    static func train(samples: [MotionSample], mouth: [(t: Double, value: Double)], words: [SpokenWord]) -> SpeechModels {
        let mouthModel = mouth.isEmpty ? nil : MouthTrainer.train(samples: samples, mouth: mouth)
        let wordModel = WordTrainer.build(samples: samples, words: words, lag: mouthModel?.lag ?? 0.15)
        return SpeechModels(mouth: mouthModel, words: wordModel)
    }
}
