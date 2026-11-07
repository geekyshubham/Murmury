import Foundation
import Observation

/// Cuts the continuous motion stream into movement-sized segments, either while Space is
/// held or automatically when motion energy rises above a calibrated noise floor.
@MainActor @Observable
final class Segmenter {
    static let calibrationSeconds: TimeInterval = 2
    static let prerollSeconds: TimeInterval = 0.3
    static let hangoverSeconds: TimeInterval = 0.35
    static let maxAutoSeconds: TimeInterval = 3
    /// The longest clicked or held take: 6 s by default, longer for people who move slowly
    /// (Settings › Capture).
    static let takeLengthKey = "murmury.takeSeconds"
    static let takeLengths: [TimeInterval] = [6, 10, 15]
    static var maxHoldSeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: takeLengthKey)
        return takeLengths.contains(stored) ? stored : takeLengths[0]
    }

    var autoEnabled = false { didSet { if !autoEnabled, isCapturing, !isManual { finish() } } }
    var triggerRatio: Double = 3

    private(set) var isCapturing = false
    private(set) var isCalibrating = false
    private(set) var energy: Double = 0
    private(set) var noiseFloor: Double?
    var threshold: Double? { noiseFloor.map { $0 * triggerRatio } }

    var onSegment: (([MotionSample]) -> Void)?
    /// Evidence scenarios only: a stillness level as if it had been learned.
    func assumeStillness(_ floor: Double) { noiseFloor = floor }
    /// Called once stillness is learned, so it can be announced.
    var onStillnessLearned: (() -> Void)?

    @ObservationIgnored private var isManual = false
    @ObservationIgnored private var buffer: [MotionSample] = []
    @ObservationIgnored private var preroll: [MotionSample] = []
    @ObservationIgnored private var calibration: [Double] = []
    @ObservationIgnored private var calibrationEnd: TimeInterval?
    @ObservationIgnored private var quietSince: TimeInterval?

    func begin() {
        guard !isCapturing else { return }
        isManual = true
        isCapturing = true
        buffer = preroll
    }

    func end() {
        guard isCapturing, isManual else { return }
        finish()
    }

    func calibrate() {
        calibration = []
        calibrationEnd = nil
        isCalibrating = true
    }

    func ingest(_ s: MotionSample) {
        energy = energy * 0.6 + Features.energy(s) * 0.4

        if isCalibrating {
            let end = calibrationEnd ?? s.t + Self.calibrationSeconds
            calibrationEnd = end
            calibration.append(energy)
            if s.t >= end {
                let sorted = calibration.sorted()
                noiseFloor = max(sorted[sorted.count / 2], 1e-3)
                isCalibrating = false
                onStillnessLearned?()
            }
        }

        preroll.append(s)
        if let k = preroll.firstIndex(where: { $0.t >= s.t - Self.prerollSeconds }), k > 0 { preroll.removeFirst(k) }

        if isCapturing {
            buffer.append(s)
            let duration = s.t - (buffer.first?.t ?? s.t)
            if isManual {
                if duration > Self.maxHoldSeconds { finish() }
            } else if let threshold {
                if energy < threshold * 0.7 {
                    let since = quietSince ?? s.t
                    quietSince = since
                    if s.t - since > Self.hangoverSeconds { finish() }
                } else {
                    quietSince = nil
                }
                if duration > Self.maxAutoSeconds { finish() }
            }
        } else if autoEnabled, !isCalibrating, let threshold, energy > threshold {
            isManual = false
            isCapturing = true
            quietSince = nil
            buffer = preroll
        }
    }

    private func finish() {
        isCapturing = false
        isManual = false
        let segment = buffer
        buffer = []
        quietSince = nil
        if segment.count >= 5 { onSegment?(segment) }
    }
}
