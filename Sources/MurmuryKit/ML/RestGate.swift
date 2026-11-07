import Foundation

/// Decides "nothing" from motion energy before the network is asked.
///
/// Stillness is near-zero input, where a small network answers mostly from its biases: on
/// synthetic data it collapsed every "nothing" take into "nod" in about one training in four, and
/// a real user sitting still would trigger gestures. The gate is learned from the user's own
/// takes and only exists when their rest class is clearly quieter than every gesture.
struct RestGate: Codable, Equatable, Sendable {
    var restLabel: String
    /// RMS angular speed (rad/s) below which a segment is rest.
    var threshold: Double

    static let restNames: Set<String> = ["nothing", "still", "rest", "idle", "none"]

    /// RMS angular speed over the take, in rad/s.
    static func energy(_ samples: [MotionSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + $1.angularSpeed * $1.angularSpeed }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// Learns the threshold between the rest class's 90th-percentile energy and the gestures'
    /// 10th percentile (geometric midpoint). Nil when there is no rest class or they overlap.
    static func learn(takes: [Take]) -> RestGate? {
        guard let rest = Set(takes.map(\.label)).first(where: { restNames.contains($0.lowercased()) }) else { return nil }
        let still = takes.filter { $0.label == rest }.map { energy($0.samples) }.sorted()
        let moving = takes.filter { $0.label != rest }.map { energy($0.samples) }.sorted()
        guard !still.isEmpty, !moving.isEmpty else { return nil }
        let high = percentile(still, 0.9), low = percentile(moving, 0.1)
        guard high > 0, low > high * 1.5 else { return nil }
        return RestGate(restLabel: rest, threshold: (high * low).squareRoot())
    }

    func isRest(_ samples: [MotionSample]) -> Bool { Self.energy(samples) < threshold }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))]
    }
}
