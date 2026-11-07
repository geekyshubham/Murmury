import SceneKit
import simd

/// Taubin smoothing (λ/μ Laplacian passes, no shrinkage): softens a realistic sculpt's fine
/// anatomy (sharp sockets, nostrils, lip creases) into calm sculptural planes, so the bust reads as
/// a designed object rather than a mannequin, while keeping its silhouette.
enum MeshSmoother {
    /// Returns a smoothed copy of `geometry` (positions welded by location first, since converted
    /// meshes store separate vertices per triangle). Elements and their order are preserved.
    /// `weight` (0…1 per original position) limits smoothing to a region; nil smooths everywhere.
    static func taubin(_ geometry: SCNGeometry, iterations: Int, lambda: Float = 0.5, mu: Float = -0.53,
                       weight: ((SIMD3<Float>) -> Float)? = nil) -> SCNGeometry {
        guard let source = geometry.sources(for: .vertex).first, iterations > 0 else { return geometry }
        let positions = read(source)
        // Weld coincident vertices.
        var key: [SIMD3<Int32>: Int32] = [:]
        var weld = [Int32](repeating: 0, count: positions.count)
        var unique: [SIMD3<Float>] = []
        for (i, p) in positions.enumerated() {
            let k = SIMD3<Int32>(Int32((p.x * 1e5).rounded()), Int32((p.y * 1e5).rounded()), Int32((p.z * 1e5).rounded()))
            if let id = key[k] { weld[i] = id } else { key[k] = Int32(unique.count); weld[i] = Int32(unique.count); unique.append(p) }
        }
        // Adjacency from every triangle element.
        var neighbours = [Set<Int32>](repeating: [], count: unique.count)
        for element in geometry.elements where element.primitiveType == .triangles {
            let indices = indexArray(element)
            for t in stride(from: 0, to: indices.count - 2, by: 3) {
                let a = weld[indices[t]], b = weld[indices[t + 1]], c = weld[indices[t + 2]]
                neighbours[Int(a)].formUnion([b, c]); neighbours[Int(b)].formUnion([a, c]); neighbours[Int(c)].formUnion([a, b])
            }
        }
        var p = unique
        let weights = unique.map { weight?($0) ?? 1 }
        for pass in 0..<(iterations * 2) {
            let factor = pass % 2 == 0 ? lambda : mu
            var next = p
            for i in p.indices where !neighbours[i].isEmpty && weights[i] > 0 {
                var mean = SIMD3<Float>(0, 0, 0)
                for n in neighbours[i] { mean += p[Int(n)] }
                mean /= Float(neighbours[i].count)
                next[i] = p[i] + factor * weights[i] * (mean - p[i])
            }
            p = next
        }
        // Smooth normals on the welded mesh.
        var normals = [SIMD3<Float>](repeating: .zero, count: p.count)
        for element in geometry.elements where element.primitiveType == .triangles {
            let indices = indexArray(element)
            for t in stride(from: 0, to: indices.count - 2, by: 3) {
                let a = Int(weld[indices[t]]), b = Int(weld[indices[t + 1]]), c = Int(weld[indices[t + 2]])
                let n = simd_cross(p[b] - p[a], p[c] - p[a])
                normals[a] += n; normals[b] += n; normals[c] += n
            }
        }
        let outPositions = positions.indices.map { i -> SCNVector3 in let q = p[Int(weld[i])]; return SCNVector3(q.x, q.y, q.z) }
        let outNormals = positions.indices.map { i -> SCNVector3 in
            let n = normals[Int(weld[i])]; let u = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
            return SCNVector3(u.x, u.y, u.z)
        }
        var sources = [SCNGeometrySource(vertices: outPositions), SCNGeometrySource(normals: outNormals)]
        sources += geometry.sources.filter { $0.semantic != .vertex && $0.semantic != .normal }
        let result = SCNGeometry(sources: sources, elements: geometry.elements)
        result.materials = geometry.materials
        result.name = geometry.name
        return result
    }

    /// A copy of `geometry` with every (welded) position moved by `f` and smooth normals recomputed.
    static func deformed(_ geometry: SCNGeometry, by f: (SIMD3<Float>) -> SIMD3<Float>) -> SCNGeometry {
        guard let source = geometry.sources(for: .vertex).first else { return geometry }
        let positions = read(source).map(f)
        var key: [SIMD3<Int32>: Int32] = [:]
        var weld = [Int32](repeating: 0, count: positions.count)
        var unique: [SIMD3<Float>] = []
        for (i, p) in positions.enumerated() {
            let k = SIMD3<Int32>(Int32((p.x * 1e5).rounded()), Int32((p.y * 1e5).rounded()), Int32((p.z * 1e5).rounded()))
            if let id = key[k] { weld[i] = id } else { key[k] = Int32(unique.count); weld[i] = Int32(unique.count); unique.append(p) }
        }
        var normals = [SIMD3<Float>](repeating: .zero, count: unique.count)
        for element in geometry.elements where element.primitiveType == .triangles {
            let indices = indexArray(element)
            for t in stride(from: 0, to: indices.count - 2, by: 3) {
                let a = Int(weld[indices[t]]), b = Int(weld[indices[t + 1]]), c = Int(weld[indices[t + 2]])
                let n = simd_cross(unique[b] - unique[a], unique[c] - unique[a])
                normals[a] += n; normals[b] += n; normals[c] += n
            }
        }
        let outNormals = positions.indices.map { i -> SCNVector3 in
            let n = normals[Int(weld[i])]; let u = simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0)
            return SCNVector3(u.x, u.y, u.z)
        }
        var sources = [SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) }), SCNGeometrySource(normals: outNormals)]
        sources += geometry.sources.filter { $0.semantic != .vertex && $0.semantic != .normal }
        let result = SCNGeometry(sources: sources, elements: geometry.elements)
        result.materials = geometry.materials
        result.name = geometry.name
        return result
    }

    static func read(_ source: SCNGeometrySource) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(source.vectorCount)
        source.data.withUnsafeBytes { raw in
            for i in 0..<source.vectorCount {
                let base = i * source.dataStride + source.dataOffset
                if source.bytesPerComponent == 4 {
                    out.append(SIMD3(raw.load(fromByteOffset: base, as: Float.self), raw.load(fromByteOffset: base + 4, as: Float.self),
                                     raw.load(fromByteOffset: base + 8, as: Float.self)))
                } else {
                    out.append(SIMD3(Float(raw.load(fromByteOffset: base, as: Double.self)), Float(raw.load(fromByteOffset: base + 8, as: Double.self)),
                                     Float(raw.load(fromByteOffset: base + 16, as: Double.self))))
                }
            }
        }
        return out
    }

    static func indexArray(_ element: SCNGeometryElement) -> [Int] {
        var out: [Int] = []
        let count = element.primitiveCount * 3
        out.reserveCapacity(count)
        element.data.withUnsafeBytes { raw in
            for i in 0..<count {
                switch element.bytesPerIndex {
                case 1: out.append(Int(raw.load(fromByteOffset: i, as: UInt8.self)))
                case 2: out.append(Int(raw.load(fromByteOffset: i * 2, as: UInt16.self)))
                default: out.append(Int(raw.load(fromByteOffset: i * 4, as: UInt32.self)))
                }
            }
        }
        return out
    }
}
