import Foundation
import simd

/// Deterministic synthetic head motion for `--demo`: an 8 s loop of rest, nod, rest, shake, in the
/// measured Buds3 Pro frame (`HeadPointer.Axes.standard`: x out of the ear, y up, z forward), so a
/// nod turns about x and a shake about y. Lets the app be explored (and screenshotted) without buds.
enum DemoMotion {
    static let period: TimeInterval = 8

    static func phase(at t: TimeInterval) -> String {
        switch t.truncatingRemainder(dividingBy: period) {
        case 2..<3.6: "nod"
        case 5..<6.6: "shake"
        default: "rest"
        }
    }

    static func sample(at t: TimeInterval) -> HeadSample {
        let u = t.truncatingRemainder(dividingBy: period)
        let breathe = 0.01 * sin(2 * .pi * 0.25 * t)
        var q = simd_quatd(angle: 0.2, axis: [0, 0, 1]) * simd_quatd(angle: breathe, axis: [1, 0, 0])
        func gesture(_ start: Double) -> Double {
            let x = (u - start) / 1.6
            return (0...1).contains(x) ? 0.25 * sin(.pi * x) * sin(2 * .pi * 3 * x) : 0
        }
        switch phase(at: t) {
        case "nod": q = q * simd_quatd(angle: gesture(2), axis: [1, 0, 0])
        case "shake": q = q * simd_quatd(angle: gesture(5), axis: [0, 1, 0])
        default: break
        }
        return HeadSample(q: Quat(w: q.real, x: q.imag.x, y: q.imag.y, z: q.imag.z), bud: 0)
    }

    /// Evidence only (`MURMURY_STEP_PROBE=<file>`): still, then a 20° turn to the right held for a
    /// second, then back, repeating, so a screen probe can time each step from the arrival of its
    /// first sample to the first displayed frame that shows it.
    static func stepTurnedRight(at t: TimeInterval) -> Bool { t >= 2 && Int(t) % 2 == 1 }
    static func stepSample(at t: TimeInterval) -> HeadSample {
        let q = simd_quatd(angle: stepTurnedRight(at: t) ? -20 * .pi / 180 : 0, axis: [0, 1, 0])
        return HeadSample(q: Quat(w: q.real, x: q.imag.x, y: q.imag.y, z: q.imag.z), bud: 0)
    }
}
