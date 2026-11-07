import Foundation
import simd

/// Which channel groups feed the models. Toggling them is the ablation experiment:
/// does the movement show up in slow orientation change, angular velocity, or its derivative?
struct FeatureSet: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int
    static let orientation = FeatureSet(rawValue: 1 << 0)
    static let velocity = FeatureSet(rawValue: 1 << 1)
    static let acceleration = FeatureSet(rawValue: 1 << 2)
    /// Bud accelerometer + gyroscope, only populated by extended (37-byte) packets.
    static let imu = FeatureSet(rawValue: 1 << 3)
    static let all: FeatureSet = [.orientation, .velocity, .acceleration]

    var channelNames: [String] {
        var n: [String] = []
        if contains(.orientation) { n += ["rot_x", "rot_y", "rot_z"] }
        if contains(.velocity) { n += ["w_x", "w_y", "w_z"] }
        if contains(.acceleration) { n += ["al_x", "al_y", "al_z"] }
        if contains(.imu) { n += ["acc_x", "acc_y", "acc_z", "gyro_x", "gyro_y", "gyro_z"] }
        return n
    }
}

enum Features {
    /// Activity score used for segmentation (rad/s plus a scaled rad/s² term).
    static func energy(_ s: MotionSample) -> Double {
        s.angularSpeed + 0.05 * s.angularAccel
    }

    /// Drops quiet lead-in/lead-out frames so takes align on the movement itself.
    static func trim(_ samples: [MotionSample], padding: Int = 2) -> [MotionSample] {
        guard samples.count > 6 else { return samples }
        let energies = samples.map(energy)
        let sorted = energies.sorted()
        let floor = sorted[sorted.count / 5]
        let peak = sorted[sorted.count - 1]
        guard peak > floor * 1.5 else { return samples }
        let threshold = floor + 0.15 * (peak - floor)
        guard let first = energies.firstIndex(where: { $0 > threshold }),
              let last = energies.lastIndex(where: { $0 > threshold }) else { return samples }
        let lo = max(0, first - padding), hi = min(samples.count - 1, last + padding)
        guard hi - lo + 1 >= 5 else { return samples }
        return Array(samples[lo...hi])
    }

    /// Per-frame feature vectors. Orientation is expressed as the rotation vector from the
    /// segment's first sample, so the result does not depend on where the head was pointing.
    static func frames(_ samples: [MotionSample], set: FeatureSet) -> [[Double]] {
        guard let origin = samples.first?.quaternion else { return [] }
        let inv = origin.inverse
        var frames = samples.map { s -> [Double] in
            var v: [Double] = []
            if set.contains(.orientation) {
                let r = inv * s.quaternion
                var angle = r.angle.isFinite ? r.angle : 0
                if angle > .pi { angle -= 2 * .pi }
                let axis = abs(angle) > 1e-9 ? r.axis : SIMD3<Double>(0, 0, 0)
                v += [axis.x * angle, axis.y * angle, axis.z * angle]
            }
            if set.contains(.velocity) { v += [s.wx, s.wy, s.wz] }
            if set.contains(.acceleration) { v += [s.alx / 20, s.aly / 20, s.alz / 20] }
            if set.contains(.imu) { v += [s.ax, s.ay, s.az, s.gx, s.gy, s.gz] }
            return v
        }
        guard let dims = frames.first?.count, dims > 0 else { return frames }
        for d in 0..<dims {
            let mean = frames.reduce(0) { $0 + $1[d] } / Double(frames.count)
            for i in frames.indices { frames[i][d] -= mean }
        }
        return frames
    }

    /// Linear resample of a frame sequence to exactly `count` frames (time normalization).
    static func resample(_ frames: [[Double]], to count: Int) -> [[Double]] {
        guard let dims = frames.first?.count, count > 0 else { return [] }
        guard frames.count > 1 else { return Array(repeating: frames[0], count: count) }
        return (0..<count).map { i in
            let pos = Double(i) * Double(frames.count - 1) / Double(max(count - 1, 1))
            let lo = Int(pos.rounded(.down)), hi = min(lo + 1, frames.count - 1)
            let f = pos - Double(lo)
            return (0..<dims).map { frames[lo][$0] * (1 - f) + frames[hi][$0] * f }
        }
    }

    /// Per-channel standard deviation across a corpus.
    static func channelScales(_ sequences: [[[Double]]]) -> [Double] {
        guard let dims = sequences.first?.first?.count else { return [] }
        var sum = [Double](repeating: 0, count: dims), sumSq = sum
        var n = 0.0
        for seq in sequences {
            for frame in seq {
                for d in 0..<dims { sum[d] += frame[d]; sumSq[d] += frame[d] * frame[d] }
                n += 1
            }
        }
        guard n > 1 else { return [Double](repeating: 1, count: dims) }
        return (0..<dims).map { d in
            let mean = sum[d] / n
            return max((sumSq[d] / n - mean * mean).squareRoot(), 1e-6)
        }
    }

    static func scaled(_ frames: [[Double]], by scales: [Double]) -> [[Double]] {
        frames.map { zip($0, scales).map { $0 / $1 } }
    }

    // MARK: Augmentation (small user datasets)

    /// Generates jittered copies of a take: time stretch, amplitude scale, small rotation of
    /// the whole sequence, and Gaussian noise. Applied to frames, after feature extraction.
    static func augment(_ frames: [[Double]], copies: Int, rng: inout some RandomNumberGenerator) -> [[[Double]]] {
        guard frames.count > 2, let dims = frames.first?.count else { return [] }
        return (0..<copies).map { _ in
            let stretch = Double.random(in: 0.8...1.2, using: &rng)
            var out = resample(frames, to: max(3, Int(Double(frames.count) * stretch)))
            let gain = Double.random(in: 0.85...1.15, using: &rng)
            // Rotate each xyz triple by the same small random rotation (re-seating the bud).
            let axis = simd_normalize(SIMD3<Double>(Double.random(in: -1...1, using: &rng),
                                                     Double.random(in: -1...1, using: &rng),
                                                     Double.random(in: -1...1, using: &rng)) + 1e-9)
            let rot = simd_quatd(angle: Double.random(in: -0.15...0.15, using: &rng), axis: axis)
            for i in out.indices {
                var f = out[i]
                var g = 0
                while g + 2 < dims {
                    let v = rot.act(SIMD3(f[g], f[g + 1], f[g + 2])) * gain
                    f[g] = v.x; f[g + 1] = v.y; f[g + 2] = v.z
                    g += 3
                }
                for d in 0..<dims { f[d] += gaussian(&rng) * 0.01 }
                out[i] = f
            }
            return out
        }
    }

    private static func gaussian(_ rng: inout some RandomNumberGenerator) -> Double {
        let u1 = Double.random(in: 1e-12..<1, using: &rng), u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
