import Foundation
import simd
import Testing
@testable import MurmuryKit

/// A bud sitting tilted in the ear: the head's axes expressed in the bud's frame.
private let up = simd_normalize(SIMD3<Double>(0.2, 0.9, -0.3))
private let right = simd_normalize(simd_cross(simd_cross(up, SIMD3(1, 0, 0.2)), up)) * -1
private let forward = simd_cross(up, right)

/// The bud's orientation for a head pose in degrees (turn right, look up, tilt right +).
private func budQuaternion(yaw: Double, pitch: Double, roll: Double) -> simd_quatd {
    let r = (-up * yaw + right * pitch + forward * roll) * .pi / 180
    let angle = simd_length(r)
    return angle < 1e-12 ? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) : simd_quatd(angle: angle, axis: r / angle)
}

/// A guided session: centre, then turn, nod and tilt each way, then free movement. The camera
/// reports Vision-style radians with its own signs, a small scale error and jitter; the buds'
/// timestamps run `budLate` seconds behind what the camera saw.
private func session(budLate: Double = 0.3) -> (bud: [MotionSample], camera: [(t: Double, angles: SIMD3<Double>)],
                                                avatar: [(t: Double, pose: HeadPose)],
                                                windows: [CalibrationScript.Kind: ClosedRange<Double>]) {
    let kinds: [CalibrationScript.Kind] = [.turnRight, .turnLeft, .lookUp, .lookDown, .tiltRight, .tiltLeft]
    func pose(_ t: Double) -> SIMD3<Double> {
        if t < 2.5 { return .zero }
        let k = Int((t - 2.5) / 3), u = (t - 2.5) - Double(k) * 3
        if k < kinds.count {
            let bump = u < 2.4 ? sin(.pi * u / 2.4) : 0
            switch kinds[k] {
            case .turnRight: return SIMD3(28 * bump, 0, 0)
            case .turnLeft: return SIMD3(-28 * bump, 0, 0)
            case .lookUp: return SIMD3(0, 18 * bump, 0)
            case .lookDown: return SIMD3(0, -18 * bump, 0)
            case .tiltRight: return SIMD3(0, 0, 14 * bump)
            default: return SIMD3(0, 0, -14 * bump)
            }
        }
        return SIMD3(20 * sin(1.1 * t), 12 * sin(1.7 * t + 1), 8 * sin(0.9 * t + 2))
    }
    var windows: [CalibrationScript.Kind: ClosedRange<Double>] = [:]
    for (k, kind) in kinds.enumerated() { let s = 2.5 + Double(k) * 3; windows[kind] = s...(s + 1.2) }
    var rng = SeededRNG(seed: 11)
    var bud: [MotionSample] = []
    for t in stride(from: 0.0, to: 30, by: 1.0 / 45) {
        let p = pose(t - budLate)
        let q = budQuaternion(yaw: p.x, pitch: p.y, roll: p.z)
        var s = MotionSample(t: t, qw: q.real, qx: q.imag.x, qy: q.imag.y, qz: q.imag.z)
        s.bud = 0
        bud.append(s)
    }
    var camera: [(t: Double, angles: SIMD3<Double>)] = []
    var avatar: [(t: Double, pose: HeadPose)] = []
    for t in stride(from: 0.0, to: 30, by: 1.0 / 30) {
        let p = pose(t), jitter = SIMD3(Double.random(in: -0.6...0.6, using: &rng), Double.random(in: -0.6...0.6, using: &rng),
                                        Double.random(in: -0.6...0.6, using: &rng))
        // Vision's own conventions: turn and tilt run the other way; 5% scale error.
        camera.append((t, (SIMD3(-p.x, p.y, -p.z) * 0.95 + jitter) * .pi / 180))
        // The head as it was: half the turn, the nod upside down, tilt mixed with turn.
        avatar.append((t, HeadPose(yaw: 0.5 * p.x, pitch: -p.y, roll: 0.3 * p.x)))
    }
    return (bud, camera, avatar, windows)
}

@Suite("Head model learned from the camera")
struct HeadModelTests {
    @Test func learnsTurnNodAndTiltFromTheCamera() throws {
        let s = session()
        let report = try #require(HeadModelFit.fit(bud: s.bud, camera: s.camera, avatar: s.avatar, windows: s.windows, centre: 0...2.5))
        #expect(report.quality > 0.95, "r2 \(report.r2)")
        #expect(report.learnedTilt)
        #expect(abs(report.lag + 0.3) < 0.05, "lag \(report.lag)")
        // The learned model reads the head the way the person moved, in degrees.
        for (yaw, pitch, roll) in [(20.0, 0.0, 0.0), (0, -15, 0), (0, 0, 10), (-12, 8, -5)] {
            let p = report.model.pose(relative: budQuaternion(yaw: yaw, pitch: pitch, roll: roll))
            #expect(abs(p.yaw - yaw * 0.95) < 1.5 && abs(p.pitch - pitch * 0.95) < 1.5 && abs(p.roll - roll * 0.95) < 1.5, "\(p)")
        }
        // Frame by frame, the learned head is far closer to the person than the head was.
        let before = try #require(report.before)
        for k in 0..<3 { #expect(report.after[k] < 1.5 && before[k] > 3 * report.after[k], "axis \(k): \(before[k]) → \(report.after[k])") }
        #expect(report.csv.split(separator: "\n").count == report.frames.count + 1)
    }

    @Test func withoutTiltStepsTiltIsDerived() throws {
        let s = session()
        var windows = s.windows; windows[.tiltRight] = nil; windows[.tiltLeft] = nil
        let report = try #require(HeadModelFit.fit(bud: s.bud, camera: s.camera, avatar: s.avatar, windows: windows, centre: 0...2.5))
        #expect(!report.learnedTilt)
        let p = report.model.pose(relative: budQuaternion(yaw: 0, pitch: 0, roll: 10))
        #expect(abs(abs(p.roll) - 10) < 1.5, "\(p)")
    }

    /// The partner bud is mounted as the mirror image; its mirrored model reads the same head pose.
    @Test func mirroredModelServesThePartnerBud() throws {
        let s = session()
        let report = try #require(HeadModelFit.fit(bud: s.bud, camera: s.camera, avatar: s.avatar, windows: s.windows, centre: 0...2.5))
        let halfTurn = simd_quatd(angle: .pi, axis: [0, 1, 0])
        let left = budQuaternion(yaw: 15, pitch: -10, roll: 6)
        let a = report.model.pose(relative: left)
        let b = report.model.mirrored.pose(relative: halfTurn * left * halfTurn.inverse)
        #expect(abs(a.yaw - b.yaw) < 0.01 && abs(a.pitch - b.pitch) < 0.01 && abs(a.roll - b.roll) < 0.01, "\(a) vs \(b)")
        var config = HeadPointer.Config()
        config.learn(report.model.axes, bud: 0, fromCamera: true, model: report.model)
        #expect(config.headModel(for: 0) == report.model && config.headModel(for: 1) == report.model.mirrored)
        config.learn(.standard, bud: 1, fromCamera: false)
        #expect(config.headModel(for: 0) == nil && config.headModel(for: 1) == nil, "a step calibration replaces the camera's model")
    }

    @Test func refusesWithoutATurnAndANod() {
        let s = session()
        var windows = s.windows; windows[.turnRight] = nil; windows[.turnLeft] = nil
        #expect(HeadModelFit.fit(bud: s.bud, camera: s.camera, avatar: s.avatar, windows: windows, centre: 0...2.5) == nil)
        #expect(CameraCalibration.reason(turn: 0.8, nod: 0.3).contains("nods didn't"))
        #expect(CameraCalibration.reason(turn: 0.3, nod: 0.8).contains("turns didn't"))
    }
}
