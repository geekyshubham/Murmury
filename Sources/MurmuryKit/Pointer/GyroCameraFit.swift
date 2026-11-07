import Foundation
import simd

/// Head orientation seen by the webcam, in any consistent unit (Vision angles or a landmark proxy).
struct CameraPose: Equatable, Sendable {
    var t: TimeInterval  // seconds since boot, the clock motion samples use
    var yaw: Double
    var pitch: Double
    /// Apple Vision's face pose (yaw, pitch, roll) in radians, when it reports all three.
    var angles: SIMD3<Double>? = nil
    /// How far the lips are open, in inter-eye distances (`CameraMouth.opening`).
    var mouth: Double? = nil
}

/// The lips' opening from Vision's face landmarks: the inner lips' height (their outline's vertical
/// extent) in inter-eye distances, so it doesn't change with distance from the camera. Without an
/// inner-lip outline, the outer lips' height less a closed mouth's typical outer height.
enum CameraMouth {
    static func opening(innerLips: [CGPoint]?, outerLips: [CGPoint]?, eyeSpan: Double) -> Double? {
        guard eyeSpan > 1e-4 else { return nil }
        func height(_ p: [CGPoint]) -> Double { Double((p.map(\.y).max() ?? 0) - (p.map(\.y).min() ?? 0)) }
        if let inner = innerLips, inner.count >= 3 { return height(inner) / eyeSpan }
        if let outer = outerLips, outer.count >= 3 { return max(0, height(outer) / eyeSpan - 0.35) }
        return nil
    }
}

/// One-time webcam calibration: finds which directions in the bud's gyro frame are the user's real
/// head turn and nod, by fitting the camera's head-rotation rates against the gyro.
///
/// The camera only teaches; afterwards the buds work alone. Least squares over all three gyro axes
/// gives full directions, so a bud tilted in the ear still drives the pointer straight. The camera
/// is slower than the buds, so the lag between them is searched too.
enum GyroCameraFit {
    struct Result: Equatable {
        /// Unit direction in the bud frame whose positive rotation is turning right.
        var turn: SIMD3<Double>
        /// Unit direction in the bud frame whose positive rotation is looking up.
        var nod: SIMD3<Double>
        /// Camera delay behind the buds, seconds.
        var lag: Double
        /// Fit quality: the worse of the two R² values, 0…1.
        var quality: Double

        /// Pointer axes: +x for turning right, +y (down the screen) for looking down.
        var axes: HeadPointer.Axes {
            HeadPointer.Axes(horizontal: AxisMap(vector: turn), vertical: AxisMap(vector: -nod))
        }
    }

    static let gridRate = 30.0
    /// Camera delay behind the buds' timestamps. Negative when the buds' samples are stamped late:
    /// Buds3 Pro can hold samples back by up to about half a second over Bluetooth.
    static let lags = stride(from: -0.8, through: 0.6, by: 0.01).map { $0 }
    /// Both signals pass the same centred moving average (± this, seconds) before their rates are
    /// compared: differencing raw webcam landmarks multiplies their frame-to-frame jitter, which
    /// swamped real head movement, while head turns are slow enough to keep through the filter.
    static let smoothing = 0.1

    /// `turnRightAt` / `lookUpAt` (and their opposites, when the routine asked for them): when the
    /// guided routine asked for those movements (outward phase), which fixes the signs whatever the
    /// camera's convention. Either of a pair is enough; a skipped step is simply missing.
    static func fit(bud: [MotionSample], camera: [CameraPose],
                    turnRightAt: ClosedRange<Double>?, lookUpAt: ClosedRange<Double>?,
                    turnLeftAt: ClosedRange<Double>? = nil, lookDownAt: ClosedRange<Double>? = nil) -> Result? {
        guard turnRightAt != nil || turnLeftAt != nil, lookUpAt != nil || lookDownAt != nil else { return nil }
        // Only the bud that reported most: the two buds' frames are mirror images, so mixing them
        // when the reporting bud changes would cancel the fit.
        let counts = Dictionary(grouping: bud, by: \.bud).mapValues(\.count)
        let reporting = counts.max { $0.value < $1.value }?.key
        // The bud's own gyro when its packets carry it (Buds3 Pro always do), else the rate derived
        // from the orientation, so calibration never depends on the extended packet format.
        let gyro = bud.filter { $0.bud == reporting }.map { s in let w = s.turnRate; return (t: s.t, w: SIMD3(w[0], w[1], w[2])) }
        guard gyro.count >= 100, camera.count >= 60 else { return nil }
        let energy = gyro.reduce(0.0) { $0 + simd_length_squared($1.w) } / Double(gyro.count)
        guard energy.squareRoot() > 0.1 else { return nil }  // rad/s: the head has to actually move

        let rates = cameraRates(camera)
        guard let first = rates.first?.t, let last = rates.last?.t, last - first > 2 else { return nil }
        let grid = stride(from: first + 0.3, to: last - 0.3, by: 1 / gridRate).map { $0 }

        var best: (score: Double, lag: Double, turn: SIMD3<Double>, nod: SIMD3<Double>, rYaw: Double, rPitch: Double)?
        for lag in lags {
            var rows: [(g: SIMD3<Double>, yaw: Double, pitch: Double)] = []
            for t in grid {
                guard let g = smoothed(gyro, at: t - lag), let c = interpolateRates(rates, at: t) else { continue }
                rows.append((g, c.yaw, c.pitch))
            }
            guard rows.count >= 40,
                  let (a, rYaw) = solve(rows.map { ($0.g, $0.yaw) }),
                  let (b, rPitch) = solve(rows.map { ($0.g, $0.pitch) }) else { continue }
            let score = rYaw + rPitch
            if score > (best?.score ?? -.infinity) { best = (score, lag, a, b, rYaw, rPitch) }
        }
        guard let best, simd_length(best.turn) > 0, simd_length(best.nod) > 0 else { return nil }

        var turn = simd_normalize(best.turn), nod = simd_normalize(best.nod)
        func signed(_ d: SIMD3<Double>, toward: ClosedRange<Double>?, away: ClosedRange<Double>?) -> Double {
            (toward.map { projected(gyro, onto: d, during: $0) } ?? 0) - (away.map { projected(gyro, onto: d, during: $0) } ?? 0)
        }
        if signed(turn, toward: turnRightAt, away: turnLeftAt) < 0 { turn = -turn }
        if signed(nod, toward: lookUpAt, away: lookDownAt) < 0 { nod = -nod }
        return Result(turn: turn, nod: nod, lag: best.lag, quality: max(0, min(best.rYaw, best.rPitch)))
    }

    // MARK: Pieces

    /// The gyro averaged over the same window the camera angles are smoothed over.
    private static func smoothed(_ s: [(t: Double, w: SIMD3<Double>)], at t: Double) -> SIMD3<Double>? {
        var sum = SIMD3<Double>(0, 0, 0)
        let taps = 9
        for k in 0..<taps {
            guard let w = interpolate(s, at: t - smoothing + 2 * smoothing * Double(k) / Double(taps - 1)) else { return nil }
            sum += w
        }
        return sum / Double(taps)
    }

    /// Camera angles → angular rates, after a centred moving average over ± `smoothing`.
    private static func cameraRates(_ c: [CameraPose]) -> [(t: Double, yaw: Double, pitch: Double)] {
        guard c.count >= 5 else { return [] }
        var lo = 0, hi = 0
        var sumYaw = 0.0, sumPitch = 0.0
        let smooth = c.indices.map { i -> CameraPose in
            while hi < c.count && c[hi].t <= c[i].t + smoothing { sumYaw += c[hi].yaw; sumPitch += c[hi].pitch; hi += 1 }
            while c[lo].t < c[i].t - smoothing { sumYaw -= c[lo].yaw; sumPitch -= c[lo].pitch; lo += 1 }
            let n = Double(hi - lo)
            return CameraPose(t: c[i].t, yaw: sumYaw / n, pitch: sumPitch / n)
        }
        return (1..<smooth.count - 1).compactMap { i in
            let dt = smooth[i + 1].t - smooth[i - 1].t
            guard dt > 0 else { return nil }
            return (smooth[i].t, (smooth[i + 1].yaw - smooth[i - 1].yaw) / dt, (smooth[i + 1].pitch - smooth[i - 1].pitch) / dt)
        }
    }

    /// Ridge least squares y ≈ x·g over the three gyro axes; returns x and R².
    private static func solve(_ rows: [(SIMD3<Double>, Double)]) -> (SIMD3<Double>, Double)? {
        var a = simd_double3x3(0), b = SIMD3<Double>(0, 0, 0), mean = 0.0
        for (g, y) in rows {
            a += simd_double3x3(columns: (g * g.x, g * g.y, g * g.z))
            b += g * y
            mean += y
        }
        // Ridge: a session of turns and nods never excites roll, which leaves the normal matrix
        // singular in that direction. A small ridge takes the minimum-norm answer there.
        let trace = a[0][0] + a[1][1] + a[2][2]
        guard trace > 1e-9 else { return nil }
        let ridge = trace / 3 * 1e-3
        a += simd_double3x3(diagonal: SIMD3(repeating: ridge))
        let x = a.inverse * b
        mean /= Double(rows.count)
        var res = 0.0, tot = 0.0
        for (g, y) in rows {
            res += pow(y - simd_dot(x, g), 2)
            tot += pow(y - mean, 2)
        }
        guard tot > 0 else { return nil }
        return (x, 1 - res / tot)
    }

    private static func projected(_ gyro: [(t: Double, w: SIMD3<Double>)], onto d: SIMD3<Double>,
                                  during window: ClosedRange<Double>) -> Double {
        gyro.filter { window.contains($0.t) }.reduce(0) { $0 + simd_dot($1.w, d) }
    }

    private static func interpolate(_ s: [(t: Double, w: SIMD3<Double>)], at t: Double) -> SIMD3<Double>? {
        guard let i = upperIndex(s.count, { s[$0].t }, t), i > 0 else { return nil }
        let (a, b) = (s[i - 1], s[i])
        guard b.t - a.t < 0.25 else { return nil }
        let k = (t - a.t) / (b.t - a.t)
        return a.w + (b.w - a.w) * k
    }

    private static func interpolateRates(_ s: [(t: Double, yaw: Double, pitch: Double)], at t: Double) -> (yaw: Double, pitch: Double)? {
        guard let i = upperIndex(s.count, { s[$0].t }, t), i > 0 else { return nil }
        let (a, b) = (s[i - 1], s[i])
        guard b.t - a.t < 0.25 else { return nil }
        let k = (t - a.t) / (b.t - a.t)
        return (a.yaw + (b.yaw - a.yaw) * k, a.pitch + (b.pitch - a.pitch) * k)
    }

    /// First index whose time is ≥ t, or nil when t is past the end.
    private static func upperIndex(_ count: Int, _ time: (Int) -> Double, _ t: Double) -> Int? {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if time(mid) < t { lo = mid + 1 } else { hi = mid }
        }
        return lo < count ? lo : nil
    }
}
