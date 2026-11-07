import Foundation

/// Murmur detection from the buds alone. Speaking, even under your breath, moves the jaw and the
/// skin around the ear canal, which shakes the buds in small, quick ways that a still or turning head
/// doesn't. The model learns one person's pattern from a short reading session (`MurmurEnrollment`),
/// with the microphone telling it when they were speaking.
enum MurmurFeatures {
    /// About half a second of samples at the buds' 45–50 Hz.
    static let window = 22
    static let names = ["gyro_x", "gyro_y", "gyro_z", "jitter_gx", "jitter_gy", "jitter_gz",
                        "acc_x", "acc_y", "acc_z", "jitter_ax", "jitter_ay", "jitter_az", "head_speed"]

    /// Features over one window: the fast part of the gyro and accelerometer (each window's mean
    /// removed, so slow head turns drop out), their sample-to-sample jitter, and the head's overall
    /// turning speed (so a quick turn isn't mistaken for speech). Log-scaled: these span decades.
    static func vector(_ s: ArraySlice<MotionSample>) -> [Double]? {
        guard s.count >= window / 2 else { return nil }
        let n = Double(s.count)
        let g = s.map { $0.turnRate }, a = s.map { [$0.ax, $0.ay, $0.az] }
        func spread(_ v: [[Double]], _ k: Int) -> Double {
            let m = v.reduce(0) { $0 + $1[k] } / n
            return (v.reduce(0) { $0 + ($1[k] - m) * ($1[k] - m) } / n).squareRoot()
        }
        func jitter(_ v: [[Double]], _ k: Int) -> Double {
            zip(v, v.dropFirst()).reduce(0) { $0 + abs($1.1[k] - $1.0[k]) } / max(1, n - 1)
        }
        var out: [Double] = []
        for k in 0..<3 { out.append(spread(g, k)) }
        for k in 0..<3 { out.append(jitter(g, k)) }
        for k in 0..<3 { out.append(spread(a, k)) }
        for k in 0..<3 { out.append(jitter(a, k)) }
        out.append(g.reduce(0) { $0 + ($1[0] * $1[0] + $1[1] * $1[1] + $1[2] * $1[2]).squareRoot() } / n)
        return out.map { log(1e-5 + $0) }
    }
}

/// A per-person logistic model over `MurmurFeatures`.
struct MurmurModel: Codable, Equatable, Sendable {
    var mean: [Double]
    var scale: [Double]
    var weights: [Double]
    var bias: Double
    /// Probability above which a window counts as murmuring.
    var threshold: Double
    /// Results from training: share of speaking windows felt, and of quiet windows flagged.
    var recall: Double
    var falseAlarms: Double
    var examples: Int
    /// True when those results come from reading held out of training; false when no fair hold-out
    /// was possible and they describe the training data itself.
    var heldOut: Bool? = nil

    func probability(_ x: [Double]) -> Double {
        guard x.count == weights.count else { return 0 }
        var z = bias
        for i in x.indices { z += weights[i] * (x[i] - mean[i]) / scale[i] }
        return 1 / (1 + exp(-z))
    }
}

enum MurmurTrainer {
    struct Example: Sendable {
        var features: [Double]; var speaking: Bool; var t: Double
        /// Which side of the session's one temporal split the example falls on; `auto` lets the
        /// trainer split by time itself.
        var split: Split = .auto
    }
    enum Split: Sendable { case auto, train, gap, test }

    /// Class-balanced, L2-regularised logistic regression. The last quarter of the session (in
    /// time) is held out to report how well it generalises, with a one-second gap so no window
    /// overlaps both sides; the final model trains on everything. Without enough of both classes
    /// in the hold-out, the figures describe the training data and `heldOut` says so.
    static func train(_ examples: [Example]) -> MurmurModel? {
        let speaking = examples.filter(\.speaking).count, quiet = examples.count - speaking
        guard speaking >= 40, quiet >= 40, let dims = examples.first?.features.count else { return nil }
        let sorted = examples.sorted { $0.t < $1.t }
        let fitted: [Example], held: [Example]
        if sorted.contains(where: { $0.split != .auto }) {
            // The split the labelling already used for its own fitting: one boundary throughout.
            fitted = sorted.filter { $0.split == .train }; held = sorted.filter { $0.split == .test }
        } else {
            let cutTime = sorted[Int(Double(sorted.count) * 0.75)].t
            fitted = sorted.filter { $0.t < cutTime }; held = sorted.filter { $0.t >= cutTime + 1.0 }
        }
        let fair = fitted.filter(\.speaking).count >= 20 && fitted.filter { !$0.speaking }.count >= 20
            && held.filter(\.speaking).count >= 10 && held.filter { !$0.speaking }.count >= 10
        guard let probe = fit(fair ? fitted : sorted, dims: dims) else { return nil }
        let (recall, falseAlarms) = rates(probe, fair ? held : sorted, threshold: 0.5)
        guard var model = fit(sorted, dims: dims) else { return nil }
        model.recall = recall; model.falseAlarms = falseAlarms; model.examples = examples.count; model.heldOut = fair
        return model
    }

    static func rates(_ m: MurmurModel, _ examples: [Example], threshold: Double) -> (recall: Double, falseAlarms: Double) {
        let s = examples.filter(\.speaking), q = examples.filter { !$0.speaking }
        let hit = s.filter { m.probability($0.features) >= threshold }.count
        let fa = q.filter { m.probability($0.features) >= threshold }.count
        return (Double(hit) / Double(max(1, s.count)), Double(fa) / Double(max(1, q.count)))
    }

    private static func fit(_ ex: [Example], dims: Int) -> MurmurModel? {
        let n = Double(ex.count)
        var mean = [Double](repeating: 0, count: dims), scale = [Double](repeating: 0, count: dims)
        for e in ex { for i in 0..<dims { mean[i] += e.features[i] / n } }
        for e in ex { for i in 0..<dims { scale[i] += pow(e.features[i] - mean[i], 2) / n } }
        scale = scale.map { max(1e-6, $0.squareRoot()) }
        let x = ex.map { e in (0..<dims).map { (e.features[$0] - mean[$0]) / scale[$0] } }
        let y = ex.map { $0.speaking ? 1.0 : 0.0 }
        let pos = y.reduce(0, +), neg = n - pos
        guard pos > 0, neg > 0 else { return nil }
        let weightOf = [n / (2 * neg), n / (2 * pos)]  // balance the classes
        var w = [Double](repeating: 0, count: dims), b = 0.0
        let rate = 0.5, l2 = 1e-3
        for _ in 0..<400 {
            var gw = [Double](repeating: 0, count: dims), gb = 0.0
            for (xi, yi) in zip(x, y) {
                var z = b
                for i in 0..<dims { z += w[i] * xi[i] }
                let err = (1 / (1 + exp(-z)) - yi) * weightOf[Int(yi)]
                for i in 0..<dims { gw[i] += err * xi[i] }
                gb += err
            }
            for i in 0..<dims { w[i] -= rate * (gw[i] / n + l2 * w[i]) }
            b -= rate * gb / n
        }
        return MurmurModel(mean: mean, scale: scale, weights: w, bias: b, threshold: 0.5, recall: 0, falseAlarms: 0, examples: ex.count)
    }
}

/// Runs a trained `MurmurModel` on the live stream: is the wearer murmuring right now?
struct MurmurDetector {
    var model: MurmurModel
    private var recent: [MotionSample] = []
    private var smoothed = 0.0
    private(set) var lastFelt: TimeInterval?
    /// How long a felt murmur keeps counting (bridges the gaps between words).
    static let hangover: TimeInterval = 0.5

    init(model: MurmurModel) { self.model = model }

    /// Feeds one sample; returns whether the wearer is murmuring at its time.
    mutating func ingest(_ s: MotionSample) -> Bool {
        if let last = recent.last, last.bud != s.bud || s.t - last.t > 0.25 { recent.removeAll() }
        recent.append(s)
        if recent.count > MurmurFeatures.window { recent.removeFirst(recent.count - MurmurFeatures.window) }
        guard recent.count == MurmurFeatures.window, let x = MurmurFeatures.vector(recent[...]) else { return isMurmuring(at: s.t) }
        smoothed = 0.6 * smoothed + 0.4 * model.probability(x)
        if smoothed >= model.threshold { lastFelt = s.t }
        return isMurmuring(at: s.t)
    }

    func isMurmuring(at t: TimeInterval) -> Bool {
        guard let lastFelt else { return false }
        return t >= lastFelt && t - lastFelt <= Self.hangover
    }

    /// Whether the buds felt the wearer speaking within `window` seconds before `t`.
    func felt(within window: TimeInterval, of t: TimeInterval) -> Bool {
        guard let lastFelt else { return false }
        return t - lastFelt <= window
    }
}
