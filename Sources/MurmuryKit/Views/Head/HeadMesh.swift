import SceneKit
import simd

/// One continuous sculpted head: a sphere deformed into cranium, jaw, chin, nose and brow, so it
/// reads as a calm porcelain bust rather than stacked primitives.
enum HeadMesh {
    static func geometry(rings: Int = 120, segments: Int = 160) -> SCNGeometry {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity((rings + 1) * (segments + 1))
        for i in 0...rings {
            let theta = Float.pi * Float(i) / Float(rings)  // 0 = top
            for j in 0...segments {
                let phi = 2 * Float.pi * Float(j) / Float(segments)
                let d = SIMD3<Float>(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi))  // +z faces the viewer
                positions.append(shape(d))
            }
        }
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var indices: [UInt32] = []
        let w = segments + 1
        for i in 0..<rings {
            for j in 0..<segments {
                let a = UInt32(i * w + j), b = UInt32((i + 1) * w + j), c = UInt32((i + 1) * w + j + 1), d = UInt32(i * w + j + 1)
                indices += [a, b, c, a, c, d]
                for (p, q, r) in [(a, b, c), (a, c, d)] {
                    let n = simd_cross(positions[Int(q)] - positions[Int(p)], positions[Int(r)] - positions[Int(p)])
                    normals[Int(p)] += n; normals[Int(q)] += n; normals[Int(r)] += n
                }
            }
        }
        // Weld the seam and the poles so lighting has no visible stitch.
        for i in 0...rings {
            let s = normals[i * w] + normals[i * w + segments]
            normals[i * w] = s; normals[i * w + segments] = s
        }
        for row in [0, rings] {
            let sum = (0...segments).reduce(SIMD3<Float>.zero) { $0 + normals[row * w + $1] }
            for j in 0...segments { normals[row * w + j] = sum }
        }
        normals = normals.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }

        let vs = SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) })
        let ns = SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vs, ns], elements: [element])
    }

    /// Unit-sphere direction → head surface point. Units: the head is ~2 tall.
    static func shape(_ d: SIMD3<Float>) -> SIMD3<Float> {
        var p = d * SIMD3(0.80, 1.02, 0.92)
        let x = d.x, y = d.y, z = d.z
        // Jaw tapers toward the chin; the face is slightly flatter than the back of the skull.
        if y < 0 {
            let t = powf(-y, 1.6)
            p.x *= 1 - 0.38 * t
            p.z *= 1 - 0.12 * t * (z < 0 ? 1.6 : 0.6)
            p.y *= 1 + 0.06 * t
        }
        if z < 0, y > -0.2 { p.z *= 1.08 }  // occipital curve
        if z > 0 { p.z *= 1 - 0.05 * z * max(0, y) }
        let front = max(0, z)
        // Chin.
        p += SIMD3(0, -0.02, 0.10) * bump(x, y + 0.82, 0.22, 0.14) * front
        // Brow ridge.
        p.z += 0.02 * bump(x, y - 0.28, 0.5, 0.12) * front
        // Eye sockets.
        for ex: Float in [-0.30, 0.30] { p.z -= 0.03 * bump(x - ex, y - 0.12, 0.16, 0.11) * front }
        // Nose: bridge and tip.
        p.z += 0.07 * bump(x, y - 0.05, 0.06, 0.16) * front
        p.z += 0.13 * bump(x, y + 0.14, 0.09, 0.08) * front
        // Lips, a hint.
        p.z += 0.03 * bump(x, y + 0.42, 0.16, 0.035) * front
        // Ears.
        let side = abs(x)
        p += SIMD3(x > 0 ? 0.07 : -0.07, 0, 0) * bump(side - 0.98, y + 0.02, 0.12, 0.22) * (1 - abs(z))
        return p
    }

    private static func bump(_ dx: Float, _ dy: Float, _ sx: Float, _ sy: Float) -> Float {
        exp(-(dx * dx) / (sx * sx) - (dy * dy) / (sy * sy))
    }

    /// Fresnel rim light: the glossy edge glow that makes the bust sit in the lit field.
    static let rimShader = """
    #pragma arguments
    float3 rimColor;
    float rimPower;
    #pragma body
    float facing = max(dot(normalize(_surface.normal), normalize(_surface.view)), 0.0);
    float rim = pow(1.0 - facing, rimPower);
    _output.color.rgb = min(_output.color.rgb + rimColor * rim, float3(1.0));
    """
}
