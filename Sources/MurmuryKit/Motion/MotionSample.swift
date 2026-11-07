import Foundation
import simd

/// One head-motion reading from the Buds3 Pro, enriched with derived kinematics.
///
/// Every packet carries a fused orientation quaternion (GRV). The 37-byte extended packet also
/// carries the bud's own accelerometer and (probably) gyroscope; when present they're stored in
/// `ax…gz` and `hasIMU` is true. Angular velocity/acceleration are always derived by
/// differentiating consecutive quaternions, so every take has them.
///
/// `t` is seconds since boot (`ProcessInfo.systemUptime`), the clock AVAudio uses.
struct MotionSample: Codable, Hashable, Sendable {
    var t: TimeInterval
    var bud: UInt8 = 0
    // Orientation quaternion (scalar first), normalized.
    var qw: Double, qx: Double, qy: Double, qz: Double
    // Body-frame angular velocity (rad/s): the bud gyro when present, else differentiated
    // quaternions. Angular acceleration (rad/s²) is its derivative.
    var wx = 0.0, wy = 0.0, wz = 0.0
    var alx = 0.0, aly = 0.0, alz = 0.0
    // Euler angles (rad) of the raw orientation.
    var pitch = 0.0, roll = 0.0, yaw = 0.0
    // Bud IMU from extended packets: accelerometer (vecB) and gyroscope (vecA).
    var hasIMU = false
    var ax = 0.0, ay = 0.0, az = 0.0
    var gx = 0.0, gy = 0.0, gz = 0.0

    static let csvHeader = "t,bud,qw,qx,qy,qz,wx,wy,wz,alx,aly,alz,pitch,roll,yaw,has_imu,ax,ay,az,gx,gy,gz"

    var quaternion: simd_quatd { simd_quatd(ix: qx, iy: qy, iz: qz, r: qw) }
    var angularSpeed: Double { (wx * wx + wy * wy + wz * wz).squareRoot() }
    /// Body-frame turn rate (rad/s): the bud's own gyro when the packet carries it (cleaner, no
    /// differentiation lag), otherwise the quaternion-derived velocity. Verified on hardware: the
    /// gyro shares the quaternion's axes and signs.
    var turnRate: [Double] { hasIMU ? [gx, gy, gz] : [wx, wy, wz] }
    var angularAccel: Double { (alx * alx + aly * aly + alz * alz).squareRoot() }

    func csvRow(relativeTo t0: TimeInterval) -> String {
        let values = [t - t0, Double(bud), qw, qx, qy, qz, wx, wy, wz, alx, aly, alz, pitch, roll, yaw,
                      hasIMU ? 1 : 0, ax, ay, az, gx, gy, gz]
        return values.map { String(format: "%.6f", $0) }.joined(separator: ",")
    }
}

/// Turns head-tracking samples into `MotionSample`s with angular velocity/acceleration.
struct Kinematics {
    private var previous: MotionSample?
    /// Exponential smoothing on the derivatives; quaternions are int16/10000 so raw finite
    /// differences are noisy.
    var smoothing = 0.5
    /// Gaps longer than this restart differentiation instead of producing a spike.
    static let maxGap: TimeInterval = 0.5
    static let minStep: TimeInterval = 0.01

    mutating func reset() { previous = nil }

    mutating func ingest(_ h: HeadSample, t: TimeInterval) -> MotionSample {
        var q = simd_quatd(ix: h.q.x, iy: h.q.y, iz: h.q.z, r: h.q.w)
        q = simd_length(q.vector) > 1e-9 ? simd_normalize(q) : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        if let p = previous, simd_dot(q.vector, p.quaternion.vector) < 0 {
            q = simd_quatd(vector: -q.vector) // same rotation; keep one hemisphere
        }
        let (pitch, roll, yaw) = Self.euler(q)
        var s = MotionSample(t: t, bud: h.bud, qw: q.real, qx: q.imag.x, qy: q.imag.y, qz: q.imag.z,
                             pitch: pitch, roll: roll, yaw: yaw)
        if let g = h.gyro, let a = h.accel, g.count == 3, a.count == 3 {
            s.hasIMU = true
            (s.gx, s.gy, s.gz) = (g[0], g[1], g[2])
            (s.ax, s.ay, s.az) = (a[0], a[1], a[2])
        }

        // A bud role switch changes the sensor frame (different mounting), so the jump between
        // buds is not head motion.
        if let p = previous, p.bud == h.bud, t > p.t, t - p.t < Self.maxGap {
            // Timestamps of clumped packets can sit 1 ms apart; never differentiate over less
            // than a sensor period.
            let dt = max(t - p.t, Self.minStep)
            var omega: SIMD3<Double>
            if s.hasIMU {
                omega = SIMD3(s.gx, s.gy, s.gz)  // measured, same axes as the quaternion
            } else {
                let dq = p.quaternion.inverse * q
                var angle = dq.angle.isFinite ? dq.angle : 0
                if angle > .pi { angle -= 2 * .pi }
                let axis = abs(angle) > 1e-12 ? dq.axis : SIMD3<Double>(0, 0, 0)
                omega = axis * (angle / dt)
            }
            let k = s.hasIMU ? 0 : smoothing
            s.wx = k * p.wx + (1 - k) * omega.x
            s.wy = k * p.wy + (1 - k) * omega.y
            s.wz = k * p.wz + (1 - k) * omega.z
            s.alx = k * p.alx + (1 - k) * (s.wx - p.wx) / dt
            s.aly = k * p.aly + (1 - k) * (s.wy - p.wy) / dt
            s.alz = k * p.alz + (1 - k) * (s.wz - p.wz) / dt
        }
        previous = s
        return s
    }

    /// Tait–Bryan angles: pitch about x, roll about y, yaw about z.
    static func euler(_ q: simd_quatd) -> (Double, Double, Double) {
        let w = q.real, x = q.imag.x, y = q.imag.y, z = q.imag.z
        let pitch = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
        let roll = asin(max(-1, min(1, 2 * (w * y - z * x))))
        let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        return (pitch, roll, yaw)
    }
}

/// GRV packets carry no timestamps, and the buds deliver them in clumps (several frames within
/// a few ms, then 50–100 ms of nothing) even though the sensor samples steadily at ~42 Hz.
/// Timestamps therefore follow the sensor: consecutive samples are spaced by the measured
/// sensor interval, anchored to arrival time so they never drift far from the radio.
struct SampleClock {
    static let nominalInterval: TimeInterval = 0.02
    /// Falling further behind arrival than this means samples were lost: restart at arrival.
    /// In buffered mode the bud holds samples back by up to ~0.5 s, which is not loss.
    static let maxLag: TimeInterval = 0.6
    /// Running further ahead than this means the interval estimate is too long: compress.
    static let maxLead: TimeInterval = 0.1
    /// Rate is measured over this much recent arrival history.
    static let rateWindow: TimeInterval = 2
    /// A silence longer than this is a stall, not clumping; it doesn't count toward the rate.
    static let stall: TimeInterval = 0.3
    static let minInterval: TimeInterval = 1.0 / 60
    static let maxInterval: TimeInterval = 1.0 / 40

    private(set) var interval = nominalInterval
    private var last: TimeInterval?
    private var history: [(arrival: TimeInterval, count: Int)] = []

    mutating func timestamps(count: Int, arrival: TimeInterval) -> [TimeInterval] {
        guard count > 0 else { return [] }
        updateInterval(count: count, arrival: arrival)
        guard let last else {
            let ts = (0..<count).map { arrival - Double(count - 1 - $0) * interval }
            self.last = ts.last
            return ts
        }
        var ts = (1...count).map { last + Double($0) * interval }
        if ts[count - 1] < arrival - Self.maxLag {
            ts = (0..<count).map { max(arrival - Double(count - 1 - $0) * interval, last + Double($0 + 1) * 1e-3) }
        } else if ts[count - 1] > arrival + Self.maxLead {
            let end = max(arrival + Self.maxLead, last + Double(count) * 1e-3)
            ts = (1...count).map { last + (end - last) * Double($0) / Double(count) }
        }
        self.last = ts.last
        return ts
    }

    private mutating func updateInterval(count: Int, arrival: TimeInterval) {
        if let previous = history.last?.arrival, arrival - previous > Self.stall { history = [] }
        history.append((arrival, count))
        if let k = history.firstIndex(where: { $0.arrival >= arrival - Self.rateWindow }), k > 0 { history.removeFirst(k) }
        guard history.count >= 2, let first = history.first else { return }
        let samples = history.dropFirst().reduce(0) { $0 + $1.count }
        let span = arrival - first.arrival
        // The sensor runs at ~50 Hz. Arrival rates outside 40–60 Hz are the radio (idle trickle
        // at ~1 Hz, buffered phases at ~19 Hz, catch-up bursts), not the sensor.
        if span > 0.5 { interval = min(max(span / Double(samples), Self.minInterval), Self.maxInterval) }
    }
}

/// Packet → sample stream with a bounded history, a measured sample rate and a recentering
/// reference. Plain class so it can be tested without the UI.
final class MotionPipeline {
    let historySeconds: TimeInterval
    private(set) var history: [MotionSample] = []
    private(set) var latest: MotionSample?
    private(set) var sampleRate: Double = 0
    var onSample: ((MotionSample) -> Void)?

    private var kinematics = Kinematics()
    private var clock = SampleClock()
    private var rateWindow: [TimeInterval] = []
    private var reference: simd_quatd?

    init(historySeconds: TimeInterval = 10) { self.historySeconds = historySeconds }

    func ingest(_ samples: [HeadSample], arrival: TimeInterval) {
        for (h, t) in zip(samples, clock.timestamps(count: samples.count, arrival: arrival)) {
            let s = kinematics.ingest(h, t: t)
            latest = s
            if reference == nil { reference = s.quaternion }
            history.append(s)
            if let k = history.firstIndex(where: { $0.t >= s.t - historySeconds }), k > 0 { history.removeFirst(k) }
            rateWindow.append(s.t)
            if let k = rateWindow.firstIndex(where: { $0 >= s.t - 1 }), k > 0 { rateWindow.removeFirst(k) }
            if let first = rateWindow.first, s.t > first { sampleRate = Double(rateWindow.count - 1) / (s.t - first) }
            onSample?(s)
        }
    }

    func recenter() { reference = latest?.quaternion }

    /// Orientation relative to the recenter reference.
    var relativeQuaternion: simd_quatd? {
        guard let s = latest, let r = reference else { return nil }
        return r.inverse * s.quaternion
    }

    /// Orientation relative to the recenter reference, in degrees.
    var relativeAngles: (pitch: Double, roll: Double, yaw: Double)? {
        guard let s = latest, let r = reference else { return nil }
        let (p, ro, y) = Kinematics.euler(r.inverse * s.quaternion)
        return (p * 180 / .pi, ro * 180 / .pi, y * 180 / .pi)
    }

    func reset() {
        history = []; latest = nil; sampleRate = 0; rateWindow = []
        kinematics.reset(); clock = SampleClock()
    }
}
