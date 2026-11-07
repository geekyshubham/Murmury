import AppKit
import SceneKit
import simd

/// Closed toroidal Lissajous bands: harmonics modulate a simple winding, so planar crossings do
/// not turn into mesh intersections. Nested radial lanes retain clearance in every model state.
enum MotionRibbons {
    /// Flat bands, three and a half times wider than they are thick, so they read as ribbons rather
    /// than wire tubing, within the lanes' clearance (2.5 widths) and the 1.4 envelope.
    static let width = 0.072, thickness = 0.02, laneSpacing: Float = 0.2
    static let frequencies = [(1, 2), (2, 1), (3, 2), (3, 1), (1, 3)]
    static let samples = 256
    /// A smooth rounded band (a superellipse, 24 points): readable thickness and clean contours at
    /// display size, so the metal catches continuous highlights instead of faceted glints.
    /// Superellipse exponent: softly rounded faces, so reflections roll across the band.
    static let roundness: Float = 0.8
    static let profile: [SIMD2<Float>] = (0..<24).map { i in
        let a = 2 * Float.pi * Float(i) / 24, c = cos(a), s = sin(a)
        let e = roundness
        return SIMD2(Float(width / 2) * copysign(pow(abs(c), e), c), Float(thickness / 2) * copysign(pow(abs(s), e), s))
    }
    /// One gesture's shape around its band: (turn, nod) per point, each within -1…1, periodic.
    typealias Signature = [SIMD2<Float>]
    /// Each band carries its gesture three times; turn bends the band in and out, nod lifts it.
    static let repeats = 3
    static let wobble: Float = 0.05, lift: Float = 0.11
    static func curves(labelCount: Int, signatures: [Signature] = []) -> [[SIMD3<Float>]] {
        (0..<min(5, max(3, labelCount))).map { index in
            let (a, b) = frequencies[index]
            let signature = index < signatures.count ? signatures[index] : []
            var curve = (0..<samples).map { i -> SIMD3<Float> in
                let t = 2 * Float.pi * Float(i) / Float(samples)
                let s = sample(signature, at: Float(i * repeats % samples) / Float(samples))
                let r = 0.54 + Float(index) * laneSpacing + 0.01 * cos(Float(a) * t) + wobble * s.x
                return SIMD3(r * cos(t), 0.03 * sin(Float(b) * t) + lift * s.y, r * sin(t))
            }
            curve.append(curve[0]); return curve
        }
    }
    /// Linear interpolation around a periodic signature (its last point equals its first).
    static func sample(_ signature: Signature, at u: Float) -> SIMD2<Float> {
        guard signature.count > 1 else { return .zero }
        let x = u * Float(signature.count - 1), i = min(Int(x), signature.count - 2), f = x - Float(i)
        return signature[i] + (signature[i + 1] - signature[i]) * f
    }
    static func mesh(_ curve: [SIMD3<Float>]) -> Loft.Mesh {
        var mesh = Loft.Mesh()
        let count = curve.count - 1, profileCount = profile.count
        for i in 0...count {
            let k = i % count
            let tangent = simd_normalize(curve[(k + 1) % count] - curve[(k + count - 1) % count])
            let radial = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), tangent))
            let up = simd_normalize(simd_cross(tangent, radial))
            for p in profile {
                mesh.vertices.append(curve[k] + radial * p.x + up * p.y)
                // Superellipse normal: the gradient of |x/a|^(2/e) + |y/b|^(2/e).
                let a = Float(width / 2), b = Float(thickness / 2)
                let k = 2 / roundness - 1
                let nx = copysign(pow(abs(p.x / a), k) / a, p.x), ny = copysign(pow(abs(p.y / b), k) / b, p.y)
                let n = radial * nx + up * ny
                mesh.normals.append(simd_length(n) > 1e-6 ? simd_normalize(n) : radial)
            }
        }
        for i in 0..<count { for j in 0..<profileCount {
            let a = i * profileCount + j, b = (i + 1) * profileCount + j
            let c = (i + 1) * profileCount + (j + 1) % profileCount, d = i * profileCount + (j + 1) % profileCount
            mesh.triangle(a, b, c); mesh.triangle(a, c, d)
        } }
        return mesh
    }
    static func geometry(_ curve: [SIMD3<Float>]) -> SCNGeometry {
        let base = mesh(curve).geometry()
        let uv = curve.indices.flatMap { i in profile.indices.map { j in CGPoint(x: Double(i) / Double(curve.count - 1), y: Double(j) / Double(profile.count)) } }
        return SCNGeometry(sources: base.sources + [SCNGeometrySource(textureCoordinates: uv)], elements: base.elements)
    }
    static func cometTexture(color: RGB) -> CGImage? {
        let size = 256
        guard let c = CGContext(data: nil, width: size, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = c.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<4 { for x in 0..<size {
            let d = min(Double(x), Double(size - x)) / Double(size)
            let light = exp(-pow(d / 0.045, 2))
            let p = y * c.bytesPerRow + x * 4
            data[p] = UInt8(color.r * light * 255); data[p + 1] = UInt8(color.g * light * 255)
            data[p + 2] = UInt8(color.b * light * 255); data[p + 3] = 255
        } }
        return c.makeImage()
    }
}

/// The user's gestures as band shapes: each label's takes averaged into one turn/nod trace.
enum GestureSignature {
    static let points = 49
    /// Below about 1.5° nothing reads as a gesture, so every band stays a plain ring.
    static let minimumSpan = 0.026

    /// One signature per label, in `labels` order. Angles are relative to each take's start,
    /// resampled over the take, closed (start and end at zero) and scaled together so the
    /// largest gesture spans ±1 and stillness stays flat.
    static func make(takes: [Take], labels: [String]) -> [MotionRibbons.Signature] {
        let traces: [[SIMD2<Double>]] = labels.map { label in
            let resampled = takes.filter { $0.label == label }.compactMap(resample)
            guard !resampled.isEmpty else { return [] }
            return (0..<points).map { k in resampled.reduce(SIMD2<Double>.zero) { $0 + $1[k] } / Double(resampled.count) }
        }
        let span = traces.flatMap { $0 }.map { max(abs($0.x), abs($0.y)) }.max() ?? 0
        guard span >= minimumSpan else { return labels.map { _ in [] } }
        return traces.map { trace in trace.map { SIMD2<Float>(Float($0.x / span), Float($0.y / span)) } }
    }

    private static func resample(_ take: Take) -> [SIMD2<Double>]? {
        let s = take.samples
        guard s.count >= 2 else { return nil }
        func wrapped(_ a: Double) -> Double { atan2(sin(a), cos(a)) }
        let raw = s.map { SIMD2(wrapped($0.yaw - s[0].yaw), wrapped($0.pitch - s[0].pitch)) }
        var trace = (0..<points).map { k -> SIMD2<Double> in
            let x = Double(k) / Double(points - 1) * Double(raw.count - 1)
            let i = min(Int(x), raw.count - 2), f = x - Double(i)
            return raw[i] + (raw[i + 1] - raw[i]) * f
        }
        // Close the loop: remove the drift from start to end so the band joins without a step.
        let end = trace[points - 1]
        for k in trace.indices { trace[k] -= end * (Double(k) / Double(points - 1)) }
        return trace
    }
}
