import Foundation

/// Few-shot recognizer: nearest-neighbour DTW against the user's takes. Works from ~3 takes
/// per label, before there is enough data to train the neural model.
struct TemplateClassifier: Sendable {
    let featureSet: FeatureSet
    private let entries: [(label: String, frames: [[Double]])]
    private let scales: [Double]

    var labels: [String] { Array(Set(entries.map(\.label))).sorted() }

    init?(takes: [Take], featureSet: FeatureSet) {
        guard !featureSet.isEmpty, Set(takes.map(\.label)).count >= 2 else { return nil }
        let raw = takes.map { Features.frames(Features.trim($0.samples), set: featureSet) }
        let scales = Features.channelScales(raw)
        self.featureSet = featureSet
        self.scales = scales
        self.entries = zip(takes, raw).map { ($0.label, Features.scaled($1, by: scales)) }
    }

    func predict(_ samples: [MotionSample], maxDistance: Double, minConfidence: Double) -> Prediction {
        let query = Features.scaled(Features.frames(Features.trim(samples), set: featureSet), by: scales)
        var best: [String: Double] = [:]
        for entry in entries {
            best[entry.label] = min(best[entry.label] ?? .infinity, DTW.distance(query, entry.frames))
        }
        let sorted = best.sorted { $0.value < $1.value }
        let margin = sorted.count >= 2 && sorted[1].value > 0 ? max(0, 1 - sorted[0].value / sorted[1].value) : 0
        let accepted = (sorted.first?.value ?? .infinity) <= maxDistance && margin >= minConfidence
        return Prediction(ranked: sorted.map { RankedLabel(label: $0.key, score: 1 / (1 + $0.value)) },
                          confidence: margin, accepted: accepted, source: "DTW")
    }
}

/// Leave-one-out DTW accuracy plus a label-permutation test: the honest answer to
/// "does the motion stream distinguish these labels better than chance?"
struct Evaluation: Sendable {
    var labels: [String]
    var confusion: [[Int]] // [actual][predicted]
    var accuracy: Double
    var chance: Double
    var permutationP95: Double
    var pValue: Double
    var takeCount: Int

    static func run(takes: [Take], featureSet: FeatureSet, permutations: Int = 300) -> Evaluation? {
        let labels = Array(Set(takes.map(\.label))).sorted()
        let counts = Dictionary(grouping: takes, by: \.label).mapValues(\.count)
        guard labels.count >= 2, counts.values.allSatisfy({ $0 >= 2 }), !featureSet.isEmpty else { return nil }

        let raw = takes.map { Features.frames(Features.trim($0.samples), set: featureSet) }
        let scales = Features.channelScales(raw)
        let seqs = raw.map { Features.scaled($0, by: scales) }
        let n = seqs.count
        var flat = [Double](repeating: 0, count: n * n)
        flat.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { i in
                // Each iteration writes only its own row.
                for j in 0..<n where j != i { base[i * n + j] = DTW.distance(seqs[i], seqs[j]) }
            }
        }
        let dist = (0..<n).map { Array(flat[($0 * n)..<($0 * n + n)]) }

        let index = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ($1, $0) })
        let truth = takes.map { index[$0.label]! }
        func loo(_ assign: [Int]) -> [Int] {
            (0..<n).map { i in
                var best = [Double](repeating: .infinity, count: labels.count)
                for j in 0..<n where j != i { best[assign[j]] = min(best[assign[j]], dist[i][j]) }
                return best.indices.min { best[$0] < best[$1] }!
            }
        }
        func acc(_ p: [Int], _ a: [Int]) -> Double { Double(zip(p, a).filter { $0 == $1 }.count) / Double(n) }

        let predicted = loo(truth)
        var confusion = [[Int]](repeating: [Int](repeating: 0, count: labels.count), count: labels.count)
        for (p, a) in zip(predicted, truth) { confusion[a][p] += 1 }
        let observed = acc(predicted, truth)
        var nulls: [Double] = []
        for _ in 0..<permutations {
            let s = truth.shuffled()
            nulls.append(acc(loo(s), s))
        }
        nulls.sort()
        return Evaluation(labels: labels, confusion: confusion, accuracy: observed,
                          chance: Double(counts.values.max()!) / Double(n),
                          permutationP95: nulls.isEmpty ? 0 : nulls[Int(Double(nulls.count - 1) * 0.95)],
                          pValue: Double(nulls.filter { $0 >= observed }.count + 1) / Double(permutations + 1),
                          takeCount: n)
    }
}
