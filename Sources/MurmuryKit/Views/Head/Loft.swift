import SceneKit
import simd

/// Small CPU mesh builder for closed section lofts. No renderer or model import is involved.
enum Loft {
    struct Mesh {
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        func geometry() -> SCNGeometry {
            SCNGeometry(sources: [SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) }),
                                  SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })],
                        elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        }
        mutating func recalculateNormals() {
            let previous = normals
            normals = Array(repeating: .zero, count: vertices.count)
            for i in stride(from: 0, to: indices.count, by: 3) {
                let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
                let n = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
                normals[a] += n; normals[b] += n; normals[c] += n
            }
            for i in normals.indices {
                normals[i] = simd_length(normals[i]) > 1e-8 ? simd_normalize(normals[i]) : previous[i]
            }
        }
        mutating func triangle(_ a: Int, _ b: Int, _ c: Int) {
            let cross = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
            guard simd_length(cross) > 1e-8 else { return }
            let n = normals[a] + normals[b] + normals[c]
            indices += simd_dot(cross, n) >= 0 ? [UInt32(a), UInt32(b), UInt32(c)] : [UInt32(a), UInt32(c), UInt32(b)]
        }
    }
    static func resample(_ points: [SIMD2<Float>], count: Int) -> [SIMD2<Float>] {
        guard points.count >= 3, count >= 3 else { return [] }
        var cumulative: [Float] = [0]
        for i in points.indices { cumulative.append(cumulative.last! + simd_distance(points[i], points[(i + 1) % points.count])) }
        let length = cumulative.last!
        guard length > 0 else { return Array(repeating: points[0], count: count) }
        var edge = 0
        return (0..<count).map { index in
            let distance = length * Float(index) / Float(count)
            while edge + 1 < points.count && cumulative[edge + 1] < distance { edge += 1 }
            let t = (distance - cumulative[edge]) / max(1e-8, cumulative[edge + 1] - cumulative[edge])
            return points[edge] + (points[(edge + 1) % points.count] - points[edge]) * t
        }
    }
    static func surface(_ sections: [[SIMD3<Float>]], flat: Bool = false, capEnd: Bool = false) -> Mesh {
        guard let first = sections.first, first.count >= 3, sections.count >= 2 else { return Mesh() }
        let count = first.count
        precondition(sections.allSatisfy { $0.count == count })
        var mesh = Mesh()
        if flat {
            for ring in 0..<(sections.count - 1) { for j in 0..<count {
                let next = (j + 1) % count
                let points = [sections[ring][j], sections[ring + 1][j], sections[ring + 1][next], sections[ring][next]]
                var n = simd_normalize(simd_cross(points[1] - points[0], points[3] - points[0]))
                let centre = points.reduce(.zero, +) / 4
                if simd_dot(n, SIMD3(centre.x, 0, centre.z)) < 0 { n = -n }
                let base = mesh.vertices.count
                mesh.vertices += points; mesh.normals += Array(repeating: n, count: 4)
                mesh.triangle(base, base + 1, base + 2); mesh.triangle(base, base + 2, base + 3)
            } }
        } else {
            mesh.vertices = sections.flatMap { $0 }
            for ring in sections.indices { for j in 0..<count {
                let tangent = sections[ring][(j + 1) % count] - sections[ring][(j + count - 1) % count]
                let along = sections[min(sections.count - 1, ring + 1)][j] - sections[max(0, ring - 1)][j]
                var n = simd_cross(tangent, along)
                let p = sections[ring][j]
                if simd_dot(n, SIMD3(p.x, 0, p.z)) < 0 { n = -n }
                if simd_length(n) < 1e-8 { n = SIMD3(0, p.y < 0 ? -1 : 1, 0) }
                mesh.normals.append(simd_normalize(n))
            } }
            for ring in 0..<(sections.count - 1) { for j in 0..<count {
                let a = ring * count + j, b = (ring + 1) * count + j
                let c = (ring + 1) * count + (j + 1) % count, d = ring * count + (j + 1) % count
                mesh.triangle(a, b, c); mesh.triangle(a, c, d)
            } }
        }
        if capEnd, let last = sections.last {
            let base = mesh.vertices.count
            let centre = last.reduce(.zero, +) / Float(count)
            let n = SIMD3<Float>(0, last[0].y < first[0].y ? -1 : 1, 0)
            mesh.vertices += [centre] + last; mesh.normals += Array(repeating: n, count: count + 1)
            for j in 0..<count { mesh.triangle(base, base + 1 + j, base + 1 + (j + 1) % count) }
        }
        return mesh
    }
}
