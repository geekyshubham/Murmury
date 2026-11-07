import CoreGraphics
import Foundation
import simd

/// Which rotation drives one screen direction, and which way: either one sensor axis with a sign
/// (two-step calibration), or a full direction in the bud's frame (camera calibration), so a bud
/// that sits tilted in the ear still moves the pointer straight.
struct AxisMap: Codable, Hashable, Sendable {
    var axis: Int  // 0 = x, 1 = y, 2 = z: the dominant component
    var sign: Double
    /// Unit direction in the bud frame; overrides `axis`/`sign` when present.
    var vector: [Double]?

    static let names = ["x", "y", "z"]

    init(axis: Int, sign: Double) {
        self.axis = axis
        self.sign = sign
        vector = nil
    }

    init(vector v: SIMD3<Double>) {
        let u = simd_length(v) > 1e-12 ? simd_normalize(v) : SIMD3(0, 0, 1)
        let a = [abs(u.x), abs(u.y), abs(u.z)]
        axis = a.firstIndex(of: a.max()!)!
        sign = u[axis] < 0 ? -1 : 1
        vector = [u.x, u.y, u.z]
    }

    var direction: SIMD3<Double> {
        if let v = vector, v.count == 3 { return SIMD3(v[0], v[1], v[2]) }
        var u = SIMD3<Double>(0, 0, 0)
        u[axis] = sign
        return u
    }

    /// Signed angular velocity in degrees per second.
    func degreesPerSecond(_ s: MotionSample) -> Double {
        let w = s.turnRate
        return simd_dot(direction, SIMD3(w[0], w[1], w[2])) * 180 / .pi
    }
}

/// Converts head rotation into pointer movement, like an air mouse: angular velocity becomes
/// pointer velocity. Relative control avoids the slow yaw drift of the buds' fused orientation.
struct HeadPointer {
    struct Axes: Codable, Hashable, Sendable {
        var horizontal: AxisMap
        var vertical: AxisMap

        /// The frame measured on a real Buds3 Pro reporting with flag 0 (the left bud): x out of the
        /// ear, y up, z forward, so turning right is negative about y and looking up negative about x.
        /// Calibration replaces it.
        static let standard = Axes(horizontal: AxisMap(axis: 1, sign: -1), vertical: AxisMap(axis: 0, sign: 1))

        /// The partner bud's axes. The two buds are mounted as mirror images, one turned half round
        /// about the vertical: its x and z run the other way, so a turn reads the same on both and a
        /// nod reads opposite.
        var mirrored: Axes { Axes(horizontal: Self.halfTurn(horizontal), vertical: Self.halfTurn(vertical)) }
        private static func halfTurn(_ m: AxisMap) -> AxisMap {
            if let v = m.vector, v.count == 3 { return AxisMap(vector: SIMD3(-v[0], v[1], -v[2])) }
            return AxisMap(axis: m.axis, sign: m.axis == 1 ? m.sign : -m.sign)
        }
    }

    struct Config: Codable, Hashable, Sendable {
        var axes = Axes.standard
        /// Calibrated axes per reporting bud; the two buds sit in mirrored frames.
        var budAxes: [UInt8: Axes] = [:]
        /// Buds whose axes the camera taught. The other routes take the nod's sign from timing alone.
        var cameraBuds: [UInt8]?
        /// Head models the camera taught (turn, nod and tilt from the bud's rotation), per bud.
        var headModels: [UInt8: HeadModel]?
        var invertHorizontal = false
        var invertVertical = false
        /// Points per degree of head rotation at slow speeds.
        var speed = 30.0
        /// Rotation slower than this (°/s) is ignored: tremor, breathing, sensor drift.
        var deadzone = 3.0
        /// Extra gain per 100 °/s, so quick turns cross the screen and slow ones stay precise.
        var acceleration = 2.0
        /// Exponential smoothing of pointer velocity, 0…0.9.
        var smoothing = 0.15
        /// Scroll mode: scroll distance per point of pointer travel.
        var scrollSpeed = 1.0
        /// Points scrolled by one spoken "scroll up/down/left/right".
        var scrollStep = 240.0
        var invertScroll = false

        /// The reporting bud's own calibration; else its partner's, mirrored (borrowing it unmirrored
        /// turned every nod upside down when the other bud took over the stream); else the default,
        /// which describes an even flag.
        func axes(for bud: UInt8) -> Axes {
            if let own = budAxes[bud] { return own }
            if let partner = budAxes[bud ^ 1] { return partner.mirrored }
            return bud & 1 == 0 ? axes : axes.mirrored
        }
        /// Whether the camera taught this bud's axes, directly or through its partner.
        func cameraTaught(_ bud: UInt8) -> Bool {
            let taught = cameraBuds ?? []
            return taught.contains(bud) || (budAxes[bud] == nil && taught.contains(bud ^ 1))
        }
        /// Records axes learned for `bud`. A camera result also replaces the partner's guessed axes,
        /// so both buds follow what the camera saw.
        mutating func learn(_ learned: Axes, bud: UInt8, fromCamera: Bool, model: HeadModel? = nil) {
            budAxes[bud] = learned
            axes = bud & 1 == 0 ? learned : learned.mirrored
            var taught = Set(cameraBuds ?? [])
            var models = headModels ?? [:]
            if fromCamera {
                taught.insert(bud)
                if !taught.contains(bud ^ 1) { budAxes[bud ^ 1] = nil; models[bud ^ 1] = nil }
                models[bud] = model
            } else {
                // A step calibration replaces what the camera taught for this bud and its partner.
                taught.remove(bud)
                models[bud] = nil; models[bud ^ 1] = nil
            }
            cameraBuds = taught.sorted()
            headModels = models.isEmpty ? nil : models
        }
        /// The reporting bud's learned head model, else its partner's mirrored.
        func headModel(for bud: UInt8) -> HeadModel? {
            if let own = headModels?[bud] { return own }
            if budAxes[bud] == nil, let partner = headModels?[bud ^ 1] { return partner.mirrored }
            return nil
        }
    }

    var config: Config
    /// A longer pause between samples means the stream stalled; don't turn it into a jump.
    static let maxGap: TimeInterval = 0.25

    private var last: TimeInterval?
    private var velocity = CGVector.zero

    init(config: Config = Config()) { self.config = config }

    mutating func reset() {
        last = nil
        velocity = .zero
    }

    /// Pointer movement in points since the previous sample. Screen y grows downwards.
    mutating func delta(for s: MotionSample) -> CGVector {
        let dt = last.map { s.t - $0 } ?? 0
        let v = velocity(for: s)
        return CGVector(dx: v.dx * dt, dy: v.dy * dt)
    }

    /// Smoothed pointer velocity in points per second; zero after a gap in the stream.
    mutating func velocity(for s: MotionSample) -> CGVector {
        defer { last = s.t }
        guard let last, s.t > last, s.t - last <= Self.maxGap else {
            velocity = .zero
            return .zero
        }
        let axes = config.axes(for: s.bud)
        let vx = pointsPerSecond(axes.horizontal.degreesPerSecond(s)) * (config.invertHorizontal ? -1 : 1)
        let vy = pointsPerSecond(axes.vertical.degreesPerSecond(s)) * (config.invertVertical ? -1 : 1)
        let k = min(max(config.smoothing, 0), 0.9)
        velocity = CGVector(dx: k * velocity.dx + (1 - k) * vx, dy: k * velocity.dy + (1 - k) * vy)
        return velocity
    }

    private func pointsPerSecond(_ degreesPerSecond: Double) -> Double {
        let m = max(abs(degreesPerSecond) - config.deadzone, 0)
        guard m > 0 else { return 0 }
        return (degreesPerSecond < 0 ? -1 : 1) * m * config.speed * (1 + config.acceleration * m / 100)
    }
}

/// Learns the bud's axes from two deliberate movements, because the sensor frame depends on
/// how the bud sits in the ear and which bud reports.
enum AxisCalibrator {
    /// The axis (and direction) with the largest excursion during "move out and back".
    static func detect(_ samples: [MotionSample], excluding: Int? = nil, minDegrees: Double = 8) -> AxisMap? {
        var angle = [0.0, 0.0, 0.0], peak = [0.0, 0.0, 0.0]
        for (a, b) in zip(samples, samples.dropFirst()) where a.bud == b.bud {
            let dt = b.t - a.t
            guard dt > 0, dt <= HeadPointer.maxGap else { continue }
            let w = b.turnRate
            for i in 0..<3 {
                angle[i] += w[i] * dt * 180 / .pi
                if abs(angle[i]) > abs(peak[i]) { peak[i] = angle[i] }
            }
        }
        let candidates = (0..<3).filter { $0 != excluding }
        guard let best = candidates.max(by: { abs(peak[$0]) < abs(peak[$1]) }), abs(peak[best]) >= minDegrees else {
            return nil
        }
        return AxisMap(axis: best, sign: peak[best] > 0 ? 1 : -1)
    }
}
