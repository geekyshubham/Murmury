import Foundation
import simd

/// What the camera teaches about one person: a linear model from the bud's rotation (relative to
/// straight ahead, in the bud's own frame) to that person's turn, nod and tilt, in degrees.
///
/// It is learned from frames where Apple Vision's on-device face-pose model and the buds watched the
/// same movements, so it captures how this person's buds actually sit: any tilt in the ear, which
/// way each axis runs, and how far the head really moved for a given bud rotation.
struct HeadModel: Codable, Hashable, Sendable {
    /// Row-major 3×3: (yaw, pitch, roll) = matrix · rotation vector (degrees in, degrees out).
    var matrix: [Double]

    init(rows yaw: SIMD3<Double>, _ pitch: SIMD3<Double>, _ roll: SIMD3<Double>) {
        matrix = [yaw.x, yaw.y, yaw.z, pitch.x, pitch.y, pitch.z, roll.x, roll.y, roll.z]
    }
    func row(_ i: Int) -> SIMD3<Double> {
        guard matrix.count == 9 else { return .zero }
        return SIMD3(matrix[3 * i], matrix[3 * i + 1], matrix[3 * i + 2])
    }

    /// The person's head pose for the bud's orientation relative to the recenter pose.
    func pose(relative q: simd_quatd) -> HeadPose {
        let r = Self.rotationVector(q)
        return HeadPose(yaw: simd_dot(row(0), r), pitch: simd_dot(row(1), r), roll: simd_dot(row(2), r))
    }

    /// Rotation vector of a relative orientation, in degrees.
    static func rotationVector(_ q: simd_quatd) -> SIMD3<Double> {
        var q = q
        if q.real < 0 { q = simd_quatd(vector: -q.vector) }
        let angle = q.angle
        guard angle.isFinite, angle > 1e-9 else { return .zero }
        return q.axis * angle * 180 / .pi
    }

    /// The partner bud, mounted as the mirror image: half a turn about the vertical, so its x and z
    /// run the other way.
    var mirrored: HeadModel {
        let flip = SIMD3<Double>(-1, 1, -1)
        return HeadModel(rows: row(0) * flip, row(1) * flip, row(2) * flip)
    }

    /// Pointer axes: +x for turning right (the yaw row), +y for looking down (minus the pitch row).
    var axes: HeadPointer.Axes {
        HeadPointer.Axes(horizontal: AxisMap(vector: row(0)), vertical: AxisMap(vector: -row(1)))
    }
}

/// Learns a `HeadModel` from one guided camera session and measures, frame by frame, how far the
/// on-screen head was from the person's real movement before and after.
enum HeadModelFit {
    /// One camera frame: the person's pose from the camera, what the avatar showed then, and what the
    /// learned model gives for the same moment (all degrees: turn right, look up, tilt right +).
    struct Frame: Equatable, Sendable {
        var t: Double
        var camera: SIMD3<Double>
        var avatar: SIMD3<Double>?
        var learned: SIMD3<Double>
    }
    struct Report: Equatable, Sendable {
        var model: HeadModel
        /// Camera delay behind the buds' timestamps, seconds.
        var lag: Double
        /// R² per axis (turn, nod, tilt) of the learned model against the camera.
        var r2: SIMD3<Double>
        /// RMS error in degrees per axis: the avatar as it was, and the learned model.
        var before: SIMD3<Double>?
        var after: SIMD3<Double>
        /// Whether the tilt row was learned (tilt steps done) or derived from turn and nod.
        var learnedTilt: Bool
        var frames: [Frame]
        /// The worse of turn and nod R²: the bar for accepting the model.
        var quality: Double { min(r2.x, r2.y) }

        /// The frames as CSV, for review.
        var csv: String {
            var out = "t,camera_turn,camera_nod,camera_tilt,avatar_turn,avatar_nod,avatar_tilt,learned_turn,learned_nod,learned_tilt\n"
            let t0 = frames.first?.t ?? 0
            for f in frames {
                let a = f.avatar.map { String(format: "%.2f,%.2f,%.2f", $0.x, $0.y, $0.z) } ?? ",,"
                out += String(format: "%.3f,%.2f,%.2f,%.2f,", f.t - t0, f.camera.x, f.camera.y, f.camera.z) + a
                    + String(format: ",%.2f,%.2f,%.2f\n", f.learned.x, f.learned.y, f.learned.z)
            }
            return out
        }
    }

    static let lags = stride(from: -0.8, through: 0.6, by: 0.02).map { $0 }

    /// `camera` angles are Vision's (yaw, pitch, roll) in radians; their signs are found from the
    /// guided steps, so the camera's conventions never matter. `windows` are the steps' outward
    /// phases; `centre` is the look-straight step. `avatar` is what the 3D head showed, sampled by
    /// its renderer, for the before measurement.
    static func fit(bud: [MotionSample], camera: [(t: Double, angles: SIMD3<Double>)], avatar: [(t: Double, pose: HeadPose)],
                    windows: [CalibrationScript.Kind: ClosedRange<Double>], centre: ClosedRange<Double>) -> Report? {
        // One bud: the two buds' frames are mirror images.
        let counts = Dictionary(grouping: bud, by: \.bud).mapValues(\.count)
        guard let reporting = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let samples = bud.filter { $0.bud == reporting }.sorted { $0.t < $1.t }
        guard samples.count >= 100, camera.count >= 60 else { return nil }

        // Camera in degrees, lightly de-jittered (3-frame median), signed in the person's terms.
        let raw = camera.sorted { $0.t < $1.t }
        var cam = raw.indices.map { i -> (t: Double, a: SIMD3<Double>) in
            let lo = max(0, i - 1), hi = min(raw.count - 1, i + 1)
            var m = SIMD3<Double>()
            for k in 0..<3 {
                let v = (lo...hi).map { raw[$0].angles[k] }.sorted()
                m[k] = v[v.count / 2] * 180 / .pi
            }
            return (raw[i].t, m)
        }
        func mean(_ range: ClosedRange<Double>?) -> SIMD3<Double>? {
            guard let range else { return nil }
            let v = cam.filter { range.contains($0.t) }.map(\.a)
            return v.isEmpty ? nil : v.reduce(.zero, +) / Double(v.count)
        }
        let rest = mean(centre) ?? cam.prefix(30).map(\.a).reduce(.zero, +) / Double(min(30, cam.count))
        // Each axis's sign from its pair of steps: the move toward the positive side minus the other.
        let pairs: [(CalibrationScript.Kind, CalibrationScript.Kind)] = [(.turnRight, .turnLeft), (.lookUp, .lookDown), (.tiltRight, .tiltLeft)]
        var sign = SIMD3<Double>(1, 1, 1), known = [false, false, false]
        for (k, pair) in pairs.enumerated() {
            let pos = mean(windows[pair.0]).map { $0[k] - rest[k] }, neg = mean(windows[pair.1]).map { $0[k] - rest[k] }
            let d = (pos ?? 0) - (neg ?? 0)
            if pos != nil || neg != nil, abs(d) > 0.5 { sign[k] = d < 0 ? -1 : 1; known[k] = true }
        }
        guard known[0], known[1] else { return nil }
        cam = cam.map { ($0.t, ($0.a - rest) * sign) }

        // Bud rotation vectors relative to the centre step's end.
        let refSample = samples.last(where: { $0.t <= centre.upperBound }) ?? samples[0]
        let ref = refSample.quaternion.inverse
        let rot = samples.map { (t: $0.t, r: HeadModel.rotationVector(ref * $0.quaternion)) }
        func budAt(_ t: Double) -> SIMD3<Double>? {
            var lo = 0, hi = rot.count
            while lo < hi { let mid = (lo + hi) / 2; if rot[mid].t < t { lo = mid + 1 } else { hi = mid } }
            guard lo > 0, lo < rot.count, rot[lo].t - rot[lo - 1].t < 0.25 else { return nil }
            let k = (t - rot[lo - 1].t) / (rot[lo].t - rot[lo - 1].t)
            return rot[lo - 1].r + (rot[lo].r - rot[lo - 1].r) * k
        }

        // Search the delay; fit each output row with an intercept (ridge least squares).
        var best: (score: Double, lag: Double, rows: [SIMD4<Double>], r2: SIMD3<Double>)?
        for lag in lags {
            var x: [SIMD4<Double>] = [], y: [SIMD3<Double>] = []
            for c in cam { if let r = budAt(c.t - lag) { x.append(SIMD4(r, 1)); y.append(c.a) } }
            guard x.count >= 40 else { continue }
            var rows: [SIMD4<Double>] = [], r2 = SIMD3<Double>()
            for k in 0..<3 {
                guard let (w, q) = solve(x, y.map { $0[k] }) else { rows = []; break }
                rows.append(w); r2[k] = q
            }
            guard rows.count == 3 else { continue }
            let score = r2.x + r2.y + (known[2] ? r2.z : 0)
            if score > (best?.score ?? -.infinity) { best = (score, lag, rows, r2) }
        }
        guard let best else { return nil }
        let yaw = SIMD3(best.rows[0].x, best.rows[0].y, best.rows[0].z)
        let pitch = SIMD3(best.rows[1].x, best.rows[1].y, best.rows[1].z)
        var roll = SIMD3(best.rows[2].x, best.rows[2].y, best.rows[2].z)
        let learnedTilt = known[2] && best.r2.z >= 0.3
        if !learnedTilt {
            // Without tilt steps, tilt is the turn and nod axes' cross product (unit gain).
            let up = -simd_normalize(yaw), right = simd_normalize(pitch)
            roll = simd_normalize(simd_cross(up, right))
        }
        let model = HeadModel(rows: yaw, pitch, roll)

        // Frame by frame: camera, avatar then, learned model (offset to the camera's rest).
        let offsets = SIMD3(best.rows[0].w, best.rows[1].w, best.rows[2].w)
        let avatarSorted = avatar.sorted { $0.t < $1.t }
        func avatarAt(_ t: Double) -> SIMD3<Double>? {
            var lo = 0, hi = avatarSorted.count
            while lo < hi { let mid = (lo + hi) / 2; if avatarSorted[mid].t < t { lo = mid + 1 } else { hi = mid } }
            let candidates = [lo - 1, lo].filter { avatarSorted.indices.contains($0) }
            guard let i = candidates.min(by: { abs(avatarSorted[$0].t - t) < abs(avatarSorted[$1].t - t) }),
                  abs(avatarSorted[i].t - t) < 0.05 else { return nil }
            let p = avatarSorted[i].pose
            return SIMD3(p.yaw, p.pitch, p.roll)
        }
        var frames: [Frame] = []
        for c in cam {
            guard let r = budAt(c.t - best.lag) else { continue }
            let learned = SIMD3(simd_dot(yaw, r), simd_dot(pitch, r), simd_dot(roll, r)) + (learnedTilt ? offsets : SIMD3(offsets.x, offsets.y, 0))
            frames.append(Frame(t: c.t, camera: c.a, avatar: avatarAt(c.t), learned: learned))
        }
        let after = rms(frames.map { $0.learned - $0.camera }, removeMean: false)
        // The avatar trails the buds (display and smoothing); compare it at its own best delay so
        // the before figure measures direction and scale, as the after figure does.
        var before: SIMD3<Double>?
        for shift in stride(from: 0.0, through: 0.4, by: 0.02) {
            let pairs = frames.compactMap { f in avatarAt(f.t + shift).map { $0 - f.camera } }
            guard pairs.count >= 30 else { continue }
            let e = rms(pairs, removeMean: true)
            if before.map({ e.x + e.y < $0.x + $0.y }) ?? true { before = e }
        }
        return Report(model: model, lag: best.lag, r2: best.r2, before: before, after: after, learnedTilt: learnedTilt, frames: frames)
    }

    private static func rms(_ v: [SIMD3<Double>], removeMean: Bool) -> SIMD3<Double> {
        guard !v.isEmpty else { return .zero }
        let m = removeMean ? v.reduce(.zero, +) / Double(v.count) : .zero
        let s = v.reduce(SIMD3<Double>()) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)
        return SIMD3(s.x.squareRoot(), s.y.squareRoot(), s.z.squareRoot())
    }

    /// Ridge least squares y ≈ w·x over (rotation vector, 1); returns w and R².
    private static func solve(_ x: [SIMD4<Double>], _ y: [Double]) -> (SIMD4<Double>, Double)? {
        var a = simd_double4x4(0), b = SIMD4<Double>(), mean = 0.0
        for (xi, yi) in zip(x, y) {
            a += simd_double4x4(columns: (xi * xi.x, xi * xi.y, xi * xi.z, xi * xi.w))
            b += xi * yi; mean += yi
        }
        let trace = a[0][0] + a[1][1] + a[2][2]
        guard trace > 1e-9 else { return nil }
        let ridge = trace / 3 * 1e-4
        a += simd_double4x4(diagonal: SIMD4(ridge, ridge, ridge, 0))
        guard abs(a.determinant) > 1e-12 else { return nil }
        let w = a.inverse * b
        mean /= Double(y.count)
        var res = 0.0, tot = 0.0
        for (xi, yi) in zip(x, y) { res += pow(yi - simd_dot(w, xi), 2); tot += pow(yi - mean, 2) }
        guard tot > 0 else { return nil }
        return (w, 1 - res / tot)
    }
}

/// The 3D head's displayed pose, sampled by its renderer while a camera session records, so what the
/// avatar showed can be compared frame by frame with what the camera saw.
final class AvatarPoseTap: @unchecked Sendable {
    static let shared = AvatarPoseTap()
    private let lock = NSLock()
    private var recording = false
    private var samples: [(t: Double, pose: HeadPose)] = []
    func start() { lock.withLock { recording = true; samples = [] } }
    func record(time: Double, pose: HeadPose) {
        lock.withLock { if recording { samples.append((time, pose)) } }
    }
    func stop() -> [(t: Double, pose: HeadPose)] {
        lock.withLock { recording = false; defer { samples = [] }; return samples }
    }
}
