import Foundation
import simd
import Testing
@testable import MurmuryKit

/// A bud mounted at an arbitrary tilt: true head axes expressed in the bud's gyro frame.
private let budUp = simd_normalize(SIMD3<Double>(0.25, -0.35, 0.90))     // head "up" in the bud frame
private let budRight = simd_normalize(simd_cross(simd_cross(budUp, SIMD3(1, 0, 0)), budUp)) * -1

/// Synthetic session: the head turns and nods; the camera sees yaw/pitch (in arbitrary proxy units,
/// sign flipped like an unmirrored image), delayed by `lag`; the bud gyro sees the same rotation.
private func session(lag: Double = 0.12, noise: Double = 0.0, seconds: Double = 12, camScale: Double = 0.6, camJitter: Double? = nil,
                     budInterval: Double = 0.02) -> (bud: [MotionSample], cam: [CameraPose]) {
    var rng = SeededRNG(seed: 7)
    func n() -> Double { noise == 0 ? 0 : Double.random(in: -noise...noise, using: &rng) }
    let yawRate = { (t: Double) in 1.2 * sin(2 * .pi * 0.35 * t) + 0.4 * sin(2 * .pi * 0.9 * t) }   // rad/s, turning right +
    let pitchRate = { (t: Double) in 0.8 * sin(2 * .pi * 0.5 * t + 1) }                              // rad/s, looking up +
    var bud: [MotionSample] = []
    for t in stride(from: 0.0, to: seconds, by: budInterval) {
        // Turning right is a rotation about "down"; looking up, about "right".
        let w = -budUp * yawRate(t) + budRight * pitchRate(t)
        var s = MotionSample(t: t, qw: 1, qx: 0, qy: 0, qz: 0)
        s.hasIMU = true
        (s.gx, s.gy, s.gz) = (w.x + n(), w.y + n(), w.z + n())
        bud.append(s)
    }
    var cam: [CameraPose] = []
    var yaw = 0.0, pitch = 0.0
    let dt = 1.0 / 30
    for t in stride(from: 0.0, to: seconds, by: dt) {
        yaw += yawRate(t - lag) * dt
        pitch += pitchRate(t - lag) * dt
        let j = camJitter.map { c in { Double.random(in: -c...c, using: &rng) } } ?? { n() * 0.01 }
        cam.append(CameraPose(t: t, yaw: -camScale * yaw + j(), pitch: camScale * pitch + j()))
    }
    return (bud, cam)
}

@Suite("Camera calibration fit")
struct CameraCalibrationTests {
    @Test func recoversTheHeadAxesInTheBudFrameAndTheLag() throws {
        let (bud, cam) = session(lag: 0.12)
        let fit = try #require(GyroCameraFit.fit(bud: bud, camera: cam, turnRightAt: 0.2...0.6, lookUpAt: 0.05...0.6))
        #expect(simd_dot(fit.turn, -budUp) > 0.99)       // turning right = +turn
        #expect(simd_dot(fit.nod, budRight) > 0.99)      // looking up = +nod
        #expect(abs(fit.lag - 0.12) < 0.04)
        #expect(fit.quality > 0.92)  // the matched smoothing costs a little on clean data and gains a lot on real webcams
    }

    /// Real webcam landmarks: a small proxy (0.35 units per radian) with ±0.03 jitter every frame at
    /// 30 fps, and buds at 45 Hz whose samples are stamped up to 0.45 s after the camera saw the move
    /// (Bluetooth buffering). The fit must still clear the acceptance bar and point the right way.
    @Test(arguments: [-0.45, -0.25, 0.1]) func realWebcamJitterAndBufferedBuds(lag: Double) throws {
        let (bud, cam) = session(lag: lag, noise: 0.05, seconds: 26, camScale: 0.35, camJitter: 0.03, budInterval: 1.0 / 45)
        let fit = try #require(GyroCameraFit.fit(bud: bud, camera: cam, turnRightAt: 0.2...0.6, lookUpAt: 0.05...0.6))
        #expect(simd_dot(fit.turn, -budUp) > 0.95, "turn \(fit.turn)")
        #expect(simd_dot(fit.nod, budRight) > 0.95, "nod \(fit.nod)")
        #expect(fit.quality >= CameraCalibration.minimumQuality, "quality \(fit.quality) at lag \(fit.lag)")
        #expect(abs(fit.lag - lag) < 0.06, "lag \(fit.lag)")
    }

    @Test func toleratesSensorNoise() throws {
        let (bud, cam) = session(lag: 0.05, noise: 0.15)
        let fit = try #require(GyroCameraFit.fit(bud: bud, camera: cam, turnRightAt: 0.2...0.6, lookUpAt: 0.05...0.6))
        #expect(simd_dot(fit.turn, -budUp) > 0.97)
        #expect(simd_dot(fit.nod, budRight) > 0.97)
    }

    @Test func refusesWhenThereIsTooLittleMovementOrData() {
        let still = (0..<300).map { i -> MotionSample in
            var s = MotionSample(t: Double(i) * 0.02, qw: 1, qx: 0, qy: 0, qz: 0); s.hasIMU = true; return s
        }
        let cam = (0..<180).map { CameraPose(t: Double($0) / 30, yaw: 0, pitch: 0) }
        #expect(GyroCameraFit.fit(bud: still, camera: cam, turnRightAt: 0...1, lookUpAt: 1...2) == nil)
        #expect(GyroCameraFit.fit(bud: [], camera: [], turnRightAt: 0...1, lookUpAt: 1...2) == nil)
    }

    @Test func fittedAxesDriveThePointerStraight() throws {
        let (bud, cam) = session()
        let fit = try #require(GyroCameraFit.fit(bud: bud, camera: cam, turnRightAt: 0.2...0.6, lookUpAt: 0.05...0.6))
        let axes = fit.axes
        // A pure turn to the right in the tilted bud frame: all horizontal, no vertical.
        var s = MotionSample(t: 0, qw: 1, qx: 0, qy: 0, qz: 0)
        s.hasIMU = true
        let w = -budUp * 0.5
        (s.gx, s.gy, s.gz) = (w.x, w.y, w.z)
        #expect(axes.horizontal.degreesPerSecond(s) > 28)
        #expect(abs(axes.vertical.degreesPerSecond(s)) < 1)
        // And the avatar agrees.
        let pose = HeadPose(relative: simd_quatd(angle: 0.3, axis: -budUp), axes: axes)
        #expect(abs(pose.yaw - 0.3 * 180 / .pi) < 0.5)
        #expect(abs(pose.pitch) < 0.5)
    }

    @Test func axisVectorsSurviveEncoding() throws {
        let map = AxisMap(vector: SIMD3(0.6, 0.0, -0.8))
        let decoded = try JSONDecoder().decode(AxisMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)
        #expect(simd_length(decoded.direction - SIMD3(0.6, 0, -0.8)) < 1e-9)
        // Single-axis maps keep working and encode as before.
        #expect(AxisMap(axis: 2, sign: -1).direction == SIMD3(0, 0, -1))
    }
}

@Suite("Camera calibration routine")
struct CalibrationScriptTests {
    @Test func walksThroughTheGuidedStepsInOrder() {
        let s = CalibrationScript.standard
        #expect(s.step(at: 0)?.kind == .centre)
        #expect(s.step(at: s.start(of: .turnRight) + 0.1)?.kind == .turnRight)
        #expect(s.step(at: s.start(of: .lookUp) + 0.1)?.kind == .lookUp)
        #expect(s.step(at: s.duration + 0.1) == nil)
        #expect(s.progress(at: s.duration / 2) > 0.45 && s.progress(at: s.duration / 2) < 0.55)
    }

    @Test func signWindowsCoverTheOutwardHalfOfEachMove() {
        let s = CalibrationScript.standard
        let right = s.outwardWindow(of: .turnRight, startingAt: 100)
        #expect(right.lowerBound == 100 + s.start(of: .turnRight))
        #expect(abs((right.upperBound - right.lowerBound) - s.length(of: .turnRight) / 2) < 1e-9)
    }
}

@Suite("Calibration response window")
struct CalibrationResponseWindowTests {
    /// A slow responder starts turning 2.5 s into the step: the fit window follows them.
    @Test func windowFollowsTheMovementNotTheClock() {
        let s = CalibrationScript.standard
        let start = s.start(of: .turnRight)
        let samples = stride(from: 0.0, to: s.duration, by: 0.02).map { t -> MotionSample in
            var m = MotionSample(t: t, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0)
            if t >= start + 2.5 && t < start + 3.5 { m.wy = 1.0 }  // ~57°/s
            return m
        }
        let w = s.responseWindow(of: .turnRight, startingAt: 0, samples: samples)
        #expect(abs(w.lowerBound - (start + 2.4)) < 0.03)
        #expect(w.upperBound <= start + s.length(of: .turnRight) + 1e-9)
        // No movement: the old first-half window.
        let still = samples.map { var m = $0; m.wy = 0; return m }
        #expect(s.responseWindow(of: .turnRight, startingAt: 0, samples: still) == s.outwardWindow(of: .turnRight, startingAt: 0))
    }
}

@Suite("Calibration pacing")
struct CalibrationPacerTests {
    /// A simulated person: answers each instruction `delay` seconds late with a slow move out
    /// (`speed` rad/s for 1.5 s), a pause, and a slow move back. The camera sees the same motion.
    private func pacedSession(delay: Double, speed: Double) -> (pacer: CalibrationPacer, bud: [MotionSample], cam: [CameraPose]) {
        var pacer = CalibrationPacer(start: 0)
        var bud: [MotionSample] = [], cam: [CameraPose] = []
        var yaw = 0.0, pitch = 0.0, kind: CalibrationScript.Kind?, kindStart = 0.0
        var t = 0.0
        while !pacer.finished && t < 200 {
            if pacer.step?.kind != kind { kind = pacer.step?.kind; kindStart = t }
            let u = t - kindStart - delay
            let profile = u < 0 ? 0 : (u < 1.5 ? speed : (u < 1.8 ? 0 : (u < 3.3 ? -speed : 0)))
            var yawRate = 0.0, pitchRate = 0.0, rollRate = 0.0
            switch kind {
            case .tiltRight: rollRate = profile
            case .tiltLeft: rollRate = -profile
            case .turnRight: yawRate = profile
            case .turnLeft: yawRate = -profile
            case .lookUp: pitchRate = profile
            case .lookDown: pitchRate = -profile
            case .free: yawRate = 0.9 * sin(2 * .pi * 0.4 * t); pitchRate = 0.6 * sin(2 * .pi * 0.55 * t + 1)
            default: break
            }
            let w = -budUp * yawRate + budRight * pitchRate + simd_cross(budUp, budRight) * rollRate
            var s = MotionSample(t: t, qw: 1, qx: 0, qy: 0, qz: 0)
            s.hasIMU = true; (s.gx, s.gy, s.gz) = (w.x, w.y, w.z)
            bud.append(s)
            yaw += yawRate * 0.02; pitch += pitchRate * 0.02
            if Int((t * 50).rounded()) % 2 == 0 { cam.append(CameraPose(t: t + 0.1, yaw: -0.6 * yaw, pitch: 0.6 * pitch)) }
            pacer.ingest(s)
            _ = pacer.advance(to: t)
            t += 0.02
        }
        return (pacer, bud, cam)
    }
    /// A late (6 s), slow (12°/s) responder: every step waits for the whole out-and-back move, and
    /// the fitted axes point the right way.
    @Test func lateSlowResponsesFitTheRightDirections() throws {
        let (pacer, bud, cam) = pacedSession(delay: 6, speed: 12 * .pi / 180)
        #expect(pacer.finished)
        let right = try #require(pacer.windows[.turnRight]), up = try #require(pacer.windows[.lookUp])
        // The windows are the outward halves: they start near the late onset and end near the turnaround.
        #expect(right.upperBound - right.lowerBound > 1.0 && right.upperBound - right.lowerBound < 2.0)
        let fit = try #require(GyroCameraFit.fit(bud: bud, camera: cam, turnRightAt: right, lookUpAt: up))
        #expect(simd_dot(fit.turn, -budUp) > 0.95)
        #expect(simd_dot(fit.nod, budRight) > 0.95)
    }
    /// No movement: the step stalls at the longest wait instead of moving on silently. Repeat starts
    /// it again; Skip moves on and leaves it out of the fit.
    @Test func noResponseStallsUntilRepeatOrSkip() {
        var pacer = CalibrationPacer(start: 0)
        var t = 0.0
        func run(until end: Double) {
            while t < end { pacer.ingest(MotionSample(t: t, qw: 1, qx: 0, qy: 0, qz: 0)); _ = pacer.advance(to: t); t += 0.02 }
        }
        run(until: 30)
        #expect(pacer.stalled && pacer.step?.kind == .turnRight && !pacer.finished)
        // A full out-and-back move while stalled is ignored: the step still waits for Repeat or Skip.
        let moveStart = t
        while t < moveStart + 4 {
            var s = MotionSample(t: t, qw: 1, qx: 0, qy: 0, qz: 0)
            let u = t - moveStart
            s.wy = u < 1.5 ? 0.3 : (u < 1.8 ? 0 : (u < 3.3 ? -0.3 : 0))
            pacer.ingest(s); _ = pacer.advance(to: t); t += 0.02
        }
        #expect(pacer.stalled && pacer.step?.kind == .turnRight)
        pacer.retry(at: t)
        // After Repeat, a move completes the step instead of stalling again.
        let again = t
        while t < again + 5 {
            var s = MotionSample(t: t, qw: 1, qx: 0, qy: 0, qz: 0)
            let u = t - again - 0.5
            s.wy = u < 0 ? 0 : (u < 1.5 ? 0.3 : (u < 1.8 ? 0 : (u < 3.3 ? -0.3 : 0)))
            pacer.ingest(s); _ = pacer.advance(to: t); t += 0.02
        }
        #expect(!pacer.stalled && pacer.step?.kind == .turnLeft && pacer.windows[.turnRight] != nil)
        // The next step stalls without movement; Repeat and Skip still work there.
        run(until: t + 13)
        #expect(pacer.stalled && pacer.step?.kind == .turnLeft)
        pacer.retry(at: t)
        #expect(!pacer.stalled && pacer.step?.kind == .turnLeft)
        run(until: t + 13)
        #expect(pacer.stalled)
        pacer.skip(at: t)
        #expect(!pacer.stalled && pacer.step?.kind == .lookUp && pacer.windows[.turnLeft] == nil)
    }
    /// Either direction of a pair fixes the sign, so a skipped "turn right" or "look up" still fits;
    /// with neither direction of a pair there is nothing to fit.
    @Test func eitherDirectionOfAPairFixesTheSign() throws {
        let (pacer, bud, cam) = pacedSession(delay: 1, speed: 30 * .pi / 180)
        let left = try #require(pacer.windows[.turnLeft]), down = try #require(pacer.windows[.lookDown])
        let fit = try #require(GyroCameraFit.fit(bud: bud, camera: cam, turnRightAt: nil, lookUpAt: nil, turnLeftAt: left, lookDownAt: down))
        #expect(simd_dot(fit.turn, -budUp) > 0.95)
        #expect(simd_dot(fit.nod, budRight) > 0.95)
        #expect(GyroCameraFit.fit(bud: bud, camera: cam, turnRightAt: nil, lookUpAt: nil) == nil)
    }
    /// Progress never goes back, including when a move starts just before the longest wait ends.
    @Test func progressNeverGoesBackwards() {
        var pacer = CalibrationPacer(start: 0)
        var last = 0.0, t = 0.0, ok = true, kind: CalibrationScript.Kind?, kindStart = 0.0
        while !pacer.finished && t < 200 {
            if pacer.step?.kind != kind { kind = pacer.step?.kind; kindStart = t }
            var s = MotionSample(t: t, qw: 1, qx: 0, qy: 0, qz: 0)
            let u = t - kindStart - 11.5   // starts at 11.5 s of a 12 s wait
            if CalibrationPacer.movements.contains(kind ?? .free), u >= 0 { s.wy = u < 1.5 ? 0.3 : (u < 1.8 ? 0 : (u < 3.3 ? -0.3 : 0)) }
            pacer.ingest(s); _ = pacer.advance(to: t)
            let p = pacer.progress(at: t)
            if p + 1e-9 < last { ok = false }
            last = p; t += 0.02
        }
        #expect(ok && last == 1)
    }
}
