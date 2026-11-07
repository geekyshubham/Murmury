import Foundation

/// One labelled recording: the user performed `label` (a word, a gesture, "nothing"...).
struct Take: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var label: String
    var samples: [MotionSample]
    var createdAt = Date()

    var duration: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.t - first.t
    }
}

struct RankedLabel: Identifiable, Hashable, Sendable {
    var label: String
    /// Higher is better: probability for the neural model, 1/(1+distance) for DTW.
    var score: Double
    var id: String { label }
}

struct Prediction: Hashable, Sendable {
    var ranked: [RankedLabel]
    var confidence: Double
    var accepted: Bool
    var source: String
    var best: RankedLabel? { ranked.first }
}
