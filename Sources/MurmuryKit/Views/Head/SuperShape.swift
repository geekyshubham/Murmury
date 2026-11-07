import SceneKit
import simd

/// Rounded superellipsoids. Exact cardinal samples and one indexed wrap avoid pole/seam slivers.
enum SuperShape {
    static func power(_ value: Float, _ exponent: Float) -> Float {
        abs(value) < 1e-6 ? 0 : (value < 0 ? -1 : 1) * pow(abs(value), exponent)
    }
    static func section(radii: SIMD3<Float>, vertical: Float, horizontal: Float, phi: Float, count: Int) -> [SIMD3<Float>] {
        let outline = (0..<576).map { j -> SIMD2<Float> in
            let theta = -Float.pi + 2 * .pi * Float(j) / 576
            return SIMD2(radii.x * power(cos(theta), horizontal), radii.z * power(sin(theta), horizontal))
        }
        let ring = Loft.resample(outline, count: count)
        let factor = power(cos(phi), vertical), y = radii.y * power(sin(phi), vertical)
        return ring.map { SIMD3($0.x * factor, y, $0.y * factor) }
    }
    static func mesh(radii: SIMD3<Float>, vertical: Float, horizontal: Float,
                     latitudes: ClosedRange<Float> = -.pi / 2 ... .pi / 2,
                     rings: Int = 72, segments: Int = 144) -> Loft.Mesh {
        let outline = section(radii: radii, vertical: vertical, horizontal: horizontal, phi: 0, count: segments)
        let sections = (0...rings).map { i -> [SIMD3<Float>] in
            let phi = latitudes.lowerBound + (latitudes.upperBound - latitudes.lowerBound) * Float(i) / Float(rings)
            let factor = power(cos(phi), vertical), y = radii.y * power(sin(phi), vertical)
            return outline.map { SIMD3($0.x * factor, y, $0.z * factor) }
        }
        var mesh = Loft.surface(sections)
        mesh.normals = mesh.vertices.map { p in
            let q = simd_abs(p / radii)
            if q.x + q.z < 1e-7 { return SIMD3(0, p.y < 0 ? -1 : 1, 0) }
            let ex = 2 / horizontal, ey = 2 / vertical
            let xz = pow(max(1e-12, pow(q.x, ex) + pow(q.z, ex)), horizontal / vertical - 1)
            let n = SIMD3<Float>(xz * pow(q.x, ex - 1) / radii.x * (p.x < 0 ? -1 : 1),
                                 pow(q.y, ey - 1) / radii.y * (p.y < 0 ? -1 : 1),
                                 xz * pow(q.z, ex - 1) / radii.z * (p.z < 0 ? -1 : 1))
            return simd_normalize(n)
        }
        return mesh
    }
    static func geometry(radii: SIMD3<Float>, vertical: Float, horizontal: Float,
                         latitudes: ClosedRange<Float> = -.pi / 2 ... .pi / 2,
                         rings: Int = 72, segments: Int = 144) -> SCNGeometry {
        mesh(radii: radii, vertical: vertical, horizontal: horizontal, latitudes: latitudes, rings: rings, segments: segments).geometry()
    }
}
