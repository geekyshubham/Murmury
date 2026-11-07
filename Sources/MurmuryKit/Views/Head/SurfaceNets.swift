import simd

/// Meshes a signed distance field (negative inside) with surface nets: one vertex per grid cell the
/// surface crosses, projected onto the surface, with the field's gradient as its normal. Blocks of
/// cells far from the surface are filled from one sample (the field is a distance bound), so only a
/// thin band around the surface is evaluated.
enum SurfaceNets {
    struct Result {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        /// Quads as four vertex indices around a crossed grid edge.
        var quads: [SIMD4<Int32>] = []
    }

    static func gradient(_ p: SIMD3<Float>, _ field: (SIMD3<Float>) -> Float) -> SIMD3<Float> {
        // Tetrahedral differences: four samples instead of six.
        let e: Float = 0.004
        let k0 = SIMD3<Float>(1, -1, -1), k1 = SIMD3<Float>(-1, -1, 1), k2 = SIMD3<Float>(-1, 1, -1), k3 = SIMD3<Float>(1, 1, 1)
        let g = k0 * field(p + k0 * e) + k1 * field(p + k1 * e) + k2 * field(p + k2 * e) + k3 * field(p + k3 * e)
        let length = simd_length(g)
        return length > 1e-12 ? g / length : SIMD3(0, 1, 0)
    }

    static func mesh(lo: SIMD3<Float>, hi: SIMD3<Float>, cell h: Float, field: (SIMD3<Float>) -> Float) -> Result {
        let nx = Int(((hi.x - lo.x) / h).rounded(.up)) + 1
        let ny = Int(((hi.y - lo.y) / h).rounded(.up)) + 1
        let nz = Int(((hi.z - lo.z) / h).rounded(.up)) + 1
        let sx = 1, sy = nx, sz = nx * ny
        var values = [Float](repeating: 1, count: nx * ny * nz)
        func point(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> { lo + SIMD3(Float(i), Float(j), Float(k)) * h }

        let block = 4
        let reach = Float(block) * h * 0.8660254 * 1.5 + h
        for bk in stride(from: 0, to: nz, by: block) {
            for bj in stride(from: 0, to: ny, by: block) {
                for bi in stride(from: 0, to: nx, by: block) {
                    let i1 = min(bi + block, nx), j1 = min(bj + block, ny), k1 = min(bk + block, nz)
                    let centre = lo + SIMD3(Float(bi + i1 - 1), Float(bj + j1 - 1), Float(bk + k1 - 1)) * (h / 2)
                    let d = field(centre)
                    for k in bk..<k1 {
                        for j in bj..<j1 {
                            for i in bi..<i1 {
                                values[k * sz + j * sy + i * sx] = abs(d) > reach ? d : field(point(i, j, k))
                            }
                        }
                    }
                }
            }
        }

        let cx = nx - 1, cy = ny - 1, cz = nz - 1
        var cellVertex = [Int32](repeating: -1, count: cx * cy * cz)
        let cornerOffsets = [0, sx, sy, sx + sy, sz, sz + sx, sz + sy, sz + sy + sx]
        let cornerUnits: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0),
                                            SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 1, 1)]
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        var result = Result()
        for k in 0..<cz {
            for j in 0..<cy {
                for i in 0..<cx {
                    let base = k * sz + j * sy + i * sx
                    var inside = 0
                    for c in 0..<8 where values[base + cornerOffsets[c]] < 0 { inside += 1 }
                    guard inside > 0 && inside < 8 else { continue }
                    var sum = SIMD3<Float>.zero, count: Float = 0
                    for (a, b) in edges {
                        let va = values[base + cornerOffsets[a]], vb = values[base + cornerOffsets[b]]
                        guard (va < 0) != (vb < 0) else { continue }
                        let t = va / (va - vb)
                        sum += cornerUnits[a] + (cornerUnits[b] - cornerUnits[a]) * t
                        count += 1
                    }
                    let start = point(i, j, k) + sum / count * h
                    var p = start
                    var normal = gradient(p, field)
                    for _ in 0..<2 {
                        p -= normal * field(p)
                        normal = gradient(p, field)
                    }
                    // Keep each vertex near its cell, so thin features can't pull vertices across.
                    if simd_distance(p, start) > 1.5 * h { p = start; normal = gradient(p, field) }
                    cellVertex[(k * cy + j) * cx + i] = Int32(result.vertices.count)
                    result.vertices.append(p)
                    result.normals.append(normal)
                }
            }
        }

        func cellIndex(_ i: Int, _ j: Int, _ k: Int) -> Int32 {
            guard i >= 0, j >= 0, k >= 0, i < cx, j < cy, k < cz else { return -1 }
            return cellVertex[(k * cy + j) * cx + i]
        }
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    let v = values[k * sz + j * sy + i * sx]
                    if i + 1 < nx, (v < 0) != (values[k * sz + j * sy + i + 1] < 0) {
                        let q = SIMD4(cellIndex(i, j - 1, k - 1), cellIndex(i, j, k - 1), cellIndex(i, j, k), cellIndex(i, j - 1, k))
                        if q.min() >= 0 { result.quads.append(q) }
                    }
                    if j + 1 < ny, (v < 0) != (values[k * sz + (j + 1) * sy + i] < 0) {
                        let q = SIMD4(cellIndex(i - 1, j, k - 1), cellIndex(i, j, k - 1), cellIndex(i, j, k), cellIndex(i - 1, j, k))
                        if q.min() >= 0 { result.quads.append(q) }
                    }
                    if k + 1 < nz, (v < 0) != (values[(k + 1) * sz + j * sy + i] < 0) {
                        let q = SIMD4(cellIndex(i - 1, j - 1, k), cellIndex(i, j - 1, k), cellIndex(i, j, k), cellIndex(i - 1, j, k))
                        if q.min() >= 0 { result.quads.append(q) }
                    }
                }
            }
        }
        return result
    }
}
