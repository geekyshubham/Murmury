import Foundation
import simd
import Testing
@testable import MurmuryKit

@Suite("Head pose for the avatar")
struct HeadPoseTests {
    let rad = Double.pi / 180

    /// The measured left-bud frame: x out of the ear, y up, z forward. Turning right is negative
    /// about y, looking up negative about x.
    @Test func standardFrameTurnLookTilt() {
        let axes = HeadPointer.Axes.standard
        let turn = HeadPose(relative: simd_quatd(angle: -20 * rad, axis: [0, 1, 0]), axes: axes)
        #expect(abs(turn.yaw - 20) < 0.01 && abs(turn.pitch) < 0.01 && abs(turn.roll) < 0.01)
        let up = HeadPose(relative: simd_quatd(angle: -15 * rad, axis: [1, 0, 0]), axes: axes)
        #expect(abs(up.pitch - 15) < 0.01 && abs(up.yaw) < 0.01)
        let tilt = HeadPose(relative: simd_quatd(angle: 10 * rad, axis: [0, 0, 1]), axes: axes)
        #expect(abs(tilt.roll - 10) < 0.01)
    }

    /// The right bud is the left one turned half round about the vertical: its x and z point the
    /// other way. One real head movement must read the same on the avatar whichever bud reports,
    /// including when only the left bud was ever calibrated (the reversed-nod bug).
    @Test func bothBudsAgreeAfterCalibratingOne() {
        var config = HeadPointer.Config()
        config.learn(.standard, bud: 0, fromCamera: false)
        let halfTurn = simd_quatd(angle: .pi, axis: [0, 1, 0])
        for (angle, axis) in [(-15.0, SIMD3<Double>(1, 0, 0)), (-20, SIMD3(0, 1, 0))] {
            let left = simd_quatd(angle: angle * rad, axis: axis)
            let right = halfTurn.inverse * left * halfTurn  // the same rotation in the right bud's frame
            let a = HeadPose(relative: left, axes: config.axes(for: 0)), b = HeadPose(relative: right, axes: config.axes(for: 1))
            #expect(abs(a.pitch - b.pitch) < 0.01 && abs(a.yaw - b.yaw) < 0.01, "\(a) vs \(b)")
        }
        let up = HeadPose(relative: halfTurn.inverse * simd_quatd(angle: -15 * rad, axis: [1, 0, 0]) * halfTurn, axes: config.axes(for: 1))
        #expect(up.pitch > 14, "looking up reads up on the right bud")
    }

    /// The pose follows calibration, so the avatar agrees with the pointer whatever the bud frame.
    @Test func calibratedFrameIsHonoured() {
        // This bud reports turning right as negative y, looking up as positive x.
        let axes = HeadPointer.Axes(horizontal: AxisMap(axis: 1, sign: -1), vertical: AxisMap(axis: 0, sign: -1))
        let turn = HeadPose(relative: simd_quatd(angle: -25 * rad, axis: [0, 1, 0]), axes: axes)
        #expect(abs(turn.yaw - 25) < 0.01)
        let up = HeadPose(relative: simd_quatd(angle: 12 * rad, axis: [1, 0, 0]), axes: axes)
        #expect(abs(up.pitch - 12) < 0.01)
    }

    @Test func restIsZero() {
        let p = HeadPose(relative: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), axes: .standard)
        #expect(p.yaw == 0 && p.pitch == 0 && p.roll == 0)
    }
}
