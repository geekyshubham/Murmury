import Foundation
import simd

/// Head orientation in the user's own terms, in degrees: turn right +, look up +, tilt right +.
///
/// Built from the orientation relative to the recenter pose and the calibrated axes, so the avatar
/// always moves the way the pointer does, whichever way the bud's sensor frame sits.
struct HeadPose: Equatable, Sendable {
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0

    init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    init(relative q: simd_quatd, axes: HeadPointer.Axes) {
        var q = q
        if q.real < 0 { q = simd_quatd(vector: -q.vector) }
        let angle = q.angle
        guard angle.isFinite, angle > 1e-9 else { return }
        let rotation = q.axis * angle * 180 / .pi  // rotation vector in the bud frame, degrees

        // Turning right is a positive rotation about `down`; looking up, about `right`.
        let up = simd_normalize(-axes.horizontal.direction)
        var right = -axes.vertical.direction
        right = simd_normalize(right - simd_dot(right, up) * up)  // calibrated axes needn't be exactly orthogonal
        let forward = simd_cross(up, right)
        yaw = simd_dot(rotation, -up)
        pitch = simd_dot(rotation, right)
        roll = simd_dot(rotation, forward)
    }
}
