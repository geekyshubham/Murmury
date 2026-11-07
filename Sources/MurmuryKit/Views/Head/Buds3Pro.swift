import AppKit
import SceneKit
import simd

/// Galaxy Buds3 Pro, rebuilt from reference renders of the product (our own geometry, nothing copied).
///
/// The bud is three forms fused with soft fillets: a rounded ovoid head whose long axis runs from a
/// high outer crown down toward the ear, a short nozzle on its flattened ear end that carries the
/// silicone tip, and a straight blade stem. The stem's narrow front ridge carries the Blade Light and
/// stays proud of the head up to its top; its broad back face carries the printed letter. A pale cap
/// with the side colour (blue L, orange R) closes the foot.
///
/// Built in millimetres in a design frame for the left bud: `a` runs from the ridge toward the back
/// face, `b` toward the ear (the side the tip turns to), `y` up. `map` places that frame in the node:
/// the ridge faces +z (the viewer in the hero), the tip turns toward `side`·x, and the right bud is
/// the mirror image. The housing is one signed distance field meshed with surface nets.
enum Buds3Pro {
    /// Model units per millimetre.
    static let mm: Float = 1
    static let bottom: Float = -24.4, height: Float = 33.2
    static var top: Float { bottom + height }

    // MARK: Stem

    /// The stem's section skeleton in plan (a, b), grown by `stemRound`: a narrow facet at a = 0 for
    /// the Blade Light, two flanks, and a broad back face 6.5 mm across.
    static let stemSkeleton: [SIMD2<Float>] = [SIMD2(0.45, -0.45), SIMD2(4.15, -2.8), SIMD2(4.15, 2.8), SIMD2(0.45, 0.45)]
    static let stemRound: Float = 0.45
    static var stemDepth: Float { 4.15 + stemRound }
    static let capHeight: Float = 1.3
    static var capTop: Float { bottom + capHeight }
    /// Where the ridge runs into the head (28.2 mm above the foot); the stem's top rises toward the
    /// back, inside the head.
    static let ridgeTop: Float = 3.4, roofRise: Float = 0.1
    /// Blade Light: a dark glass lane down the ridge, lit over its upper half (about 14 mm).
    static let glassTop: Float = 1.8, lightBottom: Float = -12.0
    static var glassBottom: Float { capTop + 0.35 }

    // MARK: Head, nozzle and tip

    static let headCentre = SIMD3<Float>(10.2, 0.9, 2.0)
    /// From the outer crown toward the ear: turned toward the back and tipped about 14° down.
    static let headAxis = simd_normalize(SIMD3<Float>(0.15, -0.55, 1))
    /// Semi-axes along `headAxis`, `headUp` and `headAcross`.
    static let headRadii = SIMD3<Float>(9.4, 7.3, 6.9)
    /// The ear end is a little narrower than the crown.
    static let headTaper: Float = 0.12
    /// The ear end is flattened this far along the axis from the centre.
    static let earFace: Float = 6.9
    static var headUp: SIMD3<Float> { simd_normalize(SIMD3(0, 1, 0) - headAxis * headAxis.y) }
    static var headAcross: SIMD3<Float> { simd_normalize(simd_cross(headAxis, headUp)) }
    /// The nozzle and tip aim into the ear canal, about 15° down.
    static let tipAxis = simd_normalize(SIMD3<Float>(0.3, -0.27, 0.92))
    static var tipBase: SIMD3<Float> { headCentre + headAxis * (earFace - 1.1) - headUp * 0.7 }
    static let nozzleRadius: Float = 2.35, nozzleLength: Float = 1.8
    /// The tip's face, along its own axis from `tipBase`.
    static let tipFace: Float = 5.9
    static let boreRadius: Float = 1.8, meshDepth: Float = 1.3

    // MARK: Distance field

    static func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k / 4
    }
    static func smax(_ a: Float, _ b: Float, _ k: Float) -> Float { -smin(-a, -b, k) }

    /// Each long face bows out this far at its middle, as on the polished part, so a face carries a
    /// gradient of the studio instead of one flat tone.
    static let faceBow: Float = 0.22
    /// Signed distance to the stem's section in plan.
    static func stemSection(_ q: SIMD2<Float>) -> Float {
        let pts = stemSkeleton
        var nearest = Float.infinity, plane = -Float.infinity
        for i in pts.indices {
            let p0 = pts[i], e = pts[(i + 1) % pts.count] - p0, w = q - p0
            let t = min(1, max(0, simd_dot(w, e) / simd_dot(e, e)))
            let bow = simd_length(e) > 2 ? faceBow * (1 - (2 * t - 1) * (2 * t - 1)) : 0
            nearest = min(nearest, simd_length(w - e * t) - bow)
            plane = max(plane, simd_dot(w, simd_normalize(SIMD2(e.y, -e.x))) - bow)
        }
        return (plane > 0 ? nearest : plane) - stemRound
    }
    static func stem(_ p: SIMD3<Float>) -> Float {
        let roof = (p.y - (ridgeTop + roofRise * p.x)) / (1 + roofRise * roofRise).squareRoot()
        return smax(smax(stemSection(SIMD2(p.x, p.z)), roof, 2.6), capTop - p.y, 0.3)
    }
    static func head(_ p: SIMD3<Float>) -> Float {
        let q = p - headCentre
        let s = simd_dot(q, headAxis), t = simd_dot(q, headUp), w = simd_dot(q, headAcross)
        let g = 1 - headTaper * min(1, max(-1, s / headRadii.x))
        let r = SIMD3(headRadii.x, headRadii.y * g, headRadii.z * g)
        let local = SIMD3(s, t, w)
        let k0 = simd_length(local / r), k1 = simd_length(local / (r * r))
        return smax(k0 * (k0 - 1) / max(k1, 1e-6), s - earFace, 2.4)
    }
    static func nozzle(_ p: SIMD3<Float>) -> Float {
        let q = p - tipBase, z = simd_dot(q, tipAxis), r = simd_length(q - tipAxis * z)
        let round: Float = 0.35, back: Float = 3
        let dr = r - (nozzleRadius - round), dz = abs(z - (nozzleLength - back) / 2) - ((nozzleLength + back) / 2 - round)
        return min(max(dr, dz), 0) + simd_length(SIMD2(max(dr, 0), max(dz, 0))) - round
    }
    /// The stem's faces sweep up into the head through a broad concave fillet, broader still under
    /// the head and on the flanks. The head sits far enough behind the ridge that the fillet never
    /// reaches the Blade Light's facet.
    static func shoulder(_ p: SIMD3<Float>) -> Float {
        func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float { let t = min(1, max(0, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t) }
        return 3.0 + 1.8 * smooth(headCentre.y - 1.5, headCentre.y - 6.0, p.y) * smooth(0.3, 2.2, p.x)
    }
    static func shell(_ p: SIMD3<Float>) -> Float { smin(smin(head(p), stem(p), shoulder(p)), nozzle(p), 0.8) }

    /// A flush inset on the shell: a microphone grille or the wear sensor's window. `half` is the
    /// outline's half-size along `x` and across it; `squareness` is its superellipse exponent.
    struct Inset {
        let name: String, centre: SIMD3<Float>, normal: SIMD3<Float>, x: SIMD3<Float>
        let half: SIMD2<Float>, squareness: Float, grille: Bool
        var y: SIMD3<Float> { simd_cross(normal, x) }
    }
    /// Where a ray from the head's centre leaves the shell, with the outward normal there.
    static func surfacePoint(toward direction: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let d = simd_normalize(direction)
        var lo: Float = 0, hi: Float = 14
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if shell(headCentre + d * mid) < 0 { lo = mid } else { hi = mid }
        }
        let p = headCentre + d * lo
        return (p, SurfaceNets.gradient(p, shell))
    }
    static func inset(_ name: String, toward direction: SIMD3<Float>, along: SIMD3<Float>, half: SIMD2<Float>,
                      squareness: Float, grille: Bool) -> Inset {
        let (p, n) = surfacePoint(toward: direction)
        let x = simd_normalize(along - n * simd_dot(along, n))
        return Inset(name: name, centre: p, normal: n, x: x, half: half, squareness: squareness, grille: grille)
    }
    static let front = SIMD3<Float>(-1, 0, 0)
    static let insets: [Inset] = [
        // The microphone grille on the upper outer shoulder, beside the ridge.
        inset("micGrille", toward: headUp * 0.6 - headAxis * 0.75 + front * 0.75, along: headAxis,
              half: SIMD2(1.6, 0.9), squareness: 3.6, grille: true),
        // The slot on the crown.
        inset("crownSlot", toward: headUp - front * 0.55 - headAxis * 0.05, along: headAxis,
              half: SIMD2(1.3, 0.45), squareness: 3.2, grille: true),
        // The round wear sensor on the outer back of the head.
        inset("outerSensor", toward: -headAxis * 0.9 + headUp * 0.08 - front * 0.5, along: headUp,
              half: SIMD2(1.8, 1.8), squareness: 2, grille: false),
        // The lower outer grille.
        inset("lowerGrille", toward: -headAxis * 0.62 - headUp * 0.42 + front * 0.35, along: headAxis + headUp * 0.3,
              half: SIMD2(1.9, 0.8), squareness: 3.2, grille: true)
    ]
    static func housing(_ p: SIMD3<Float>) -> Float { shell(p) }

    /// An inset as a thin patch hugging the shell 0.02 mm proud of it, with texture coordinates in
    /// half-millimetres (so the grille's holes keep one pitch on every inset).
    static func insetGeometry(_ inset: Inset, side: Float) -> SCNGeometry {
        let around = 72, rings = 10
        var vertices: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
        func add(_ u: Float, _ v: Float) {
            var p = inset.centre + inset.x * u + inset.y * v
            var g = inset.normal
            for _ in 0..<4 { g = SurfaceNets.gradient(p, shell); p -= g * shell(p) }
            vertices.append(map(p + g * 0.02, side: side)); normals.append(map(g, side: side))
            uvs.append(SIMD2(u, v) / 2)
        }
        add(0, 0)
        for r in 1...rings {
            let t = Float(r) / Float(rings)
            for i in 0..<around {
                let angle = 2 * Float.pi * Float(i) / Float(around), c = cos(angle), s = sin(angle)
                let e = 2 / inset.squareness
                add(t * inset.half.x * (c < 0 ? -1 : 1) * pow(abs(c), e), t * inset.half.y * (s < 0 ? -1 : 1) * pow(abs(s), e))
            }
        }
        var mesh = Loft.Mesh(); mesh.vertices = vertices; mesh.normals = normals
        for i in 0..<around { mesh.triangle(0, 1 + i, 1 + (i + 1) % around) }
        for r in 0..<(rings - 1) {
            for i in 0..<around {
                let a = 1 + r * around + i, b = 1 + r * around + (i + 1) % around
                mesh.triangle(a, a + around, b + around); mesh.triangle(a, b + around, b)
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) }),
                                     SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }),
                                     SCNGeometrySource(textureCoordinates: uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })],
                           elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
    }

    /// The housing meshed once in the design frame (about 0.2 mm cells).
    static let housingNet: SurfaceNets.Result = SurfaceNets.mesh(lo: SIMD3(-1.5, capTop - 0.6, -10.5),
                                                                  hi: SIMD3(21.5, top + 1.2, 15), cell: 0.2, field: housing)

    // MARK: Meshes

    /// Design (a, y, b) to node coordinates.
    static func map(_ p: SIMD3<Float>, side: Float) -> SIMD3<Float> { SIMD3(side * p.z, p.y, -p.x) }

    /// Appends rows × columns (design-frame positions and outward normals), mapped to the node;
    /// `wrap` closes the columns into a ring.
    static func grid(_ mesh: inout Loft.Mesh, _ rows: [[(SIMD3<Float>, SIMD3<Float>)]], wrap: Bool, side: Float) {
        guard let columns = rows.first?.count, columns > 1 else { return }
        let base = mesh.vertices.count
        for row in rows { for (p, n) in row { mesh.vertices.append(map(p, side: side)); mesh.normals.append(simd_normalize(map(n, side: side))) } }
        for r in 0..<(rows.count - 1) {
            for c in 0..<(wrap ? columns : columns - 1) {
                let c1 = (c + 1) % columns
                let a = base + r * columns + c, b = base + (r + 1) * columns + c
                let d = base + (r + 1) * columns + c1, e = base + r * columns + c1
                mesh.triangle(a, b, d); mesh.triangle(a, d, e)
            }
        }
    }

    /// Flat-shaded fan from `centre` over a closed outline (each triangle its own normal).
    static func cap(_ mesh: inout Loft.Mesh, centre: SIMD3<Float>, outline: [SIMD3<Float>], outward: SIMD3<Float>, side: Float) {
        for i in 0..<outline.count {
            let p = outline[i], q = outline[(i + 1) % outline.count]
            var n = simd_cross(p - centre, q - centre)
            guard simd_length(n) > 1e-6 else { continue }
            n = simd_normalize(n); if simd_dot(n, outward) < 0 { n = -n }
            let base = mesh.vertices.count
            for v in [centre, p, q] { mesh.vertices.append(map(v, side: side)); mesh.normals.append(simd_normalize(map(n, side: side))) }
            mesh.triangle(base, base + 1, base + 2)
        }
    }

    /// The stem's outline in plan with outward normals: the skeleton grown by `stemRound`.
    static func stemOutline(grow: Float = 0) -> [(SIMD2<Float>, SIMD2<Float>)] {
        let pts = stemSkeleton, r = stemRound + grow
        var out: [(SIMD2<Float>, SIMD2<Float>)] = []
        func normal(_ e: SIMD2<Float>) -> SIMD2<Float> { simd_normalize(SIMD2(e.y, -e.x)) }
        for i in pts.indices {
            let prev = pts[(i + pts.count - 1) % pts.count], p = pts[i], next = pts[(i + 1) % pts.count]
            let n0 = normal(p - prev), n1 = normal(next - p)
            let a0 = atan2(n0.y, n0.x)
            var a1 = atan2(n1.y, n1.x)
            while a1 < a0 { a1 += 2 * .pi }
            for k in 0...8 {
                let angle = a0 + (a1 - a0) * Float(k) / 8, n = SIMD2(cos(angle), sin(angle))
                out.append((p + n * r, n))
            }
        }
        return out
    }

    /// The housing in node coordinates for one side.
    static func housingMesh(side: Float = -1) -> Loft.Mesh {
        let net = housingNet
        var mesh = Loft.Mesh()
        mesh.vertices = net.vertices.map { map($0, side: side) }
        mesh.normals = net.normals.map { map($0, side: side) }
        for q in net.quads {
            let a = Int(q.x), b = Int(q.y), c = Int(q.z), d = Int(q.w)
            if simd_distance_squared(mesh.vertices[a], mesh.vertices[c]) < simd_distance_squared(mesh.vertices[b], mesh.vertices[d]) {
                mesh.triangle(a, b, c); mesh.triangle(a, c, d)
            } else {
                mesh.triangle(a, b, d); mesh.triangle(b, c, d)
            }
        }
        return mesh
    }

    /// The pale foot cap: the stem's section, chamfered at the bottom.
    static func capMesh(side: Float) -> Loft.Mesh {
        var mesh = Loft.Mesh()
        let outline = stemOutline()
        let wall = outline.map { (SIMD3($0.0.x, capTop, $0.0.y), SIMD3($0.1.x, 0, $0.1.y)) }
        let shoulder = outline.map { (SIMD3($0.0.x, bottom + 0.35, $0.0.y), SIMD3($0.1.x, 0, $0.1.y)) }
        let bevel = outline.map { (SIMD3($0.0.x, bottom + 0.35, $0.0.y), simd_normalize(SIMD3($0.1.x, -1, $0.1.y))) }
        let inner = stemOutline(grow: -0.3)
        let foot = zip(inner, outline).map { (SIMD3($0.0.x, bottom, $0.0.y), simd_normalize(SIMD3($1.1.x, -1, $1.1.y))) }
        grid(&mesh, [wall, shoulder], wrap: true, side: side)
        grid(&mesh, [bevel, foot], wrap: true, side: side)
        let centroid = stemSkeleton.reduce(.zero, +) / Float(stemSkeleton.count)
        cap(&mesh, centre: SIMD3(centroid.x, bottom, centroid.y), outline: foot.map(\.0), outward: SIMD3(0, -1, 0), side: side)
        cap(&mesh, centre: SIMD3(centroid.x, capTop, centroid.y), outline: wall.map(\.0), outward: SIMD3(0, 1, 0), side: side)
        return mesh
    }

    /// The silicone ear tip along +z from its seat: a narrow skirt, a broad rounded shoulder, a
    /// softly domed face and a 3.6 mm bore. Returns the outer surface and the bore separately.
    static func tipMeshes() -> (outer: Loft.Mesh, bore: Loft.Mesh) {
        let outer: [SIMD2<Float>] = [  // (radius, z)
            SIMD2(2.45, -0.3), SIMD2(2.6, 0.1), SIMD2(3.6, 0.3), SIMD2(4.4, 0.5), SIMD2(5.0, 0.85), SIMD2(5.45, 1.35),
            SIMD2(5.7, 2.0), SIMD2(5.78, 2.8), SIMD2(5.7, 3.6), SIMD2(5.42, 4.35), SIMD2(4.95, 4.98), SIMD2(4.3, 5.45),
            SIMD2(3.55, 5.75), SIMD2(2.85, 5.9), SIMD2(2.35, 5.86)
        ]
        let bore: [SIMD2<Float>] = [
            SIMD2(2.35, 5.86), SIMD2(2.02, 5.7), SIMD2(1.84, 5.4), SIMD2(boreRadius, 5.0), SIMD2(boreRadius, tipFace - meshDepth - 0.4)
        ]
        func lathe(_ profile: [SIMD2<Float>]) -> Loft.Mesh {
            var mesh = Loft.Mesh()
            let count = 96
            for (i, p) in profile.enumerated() {
                let prev = profile[max(0, i - 1)], next = profile[min(profile.count - 1, i + 1)]
                let t = next - prev
                let n2 = simd_normalize(SIMD2(t.y, -t.x))  // (radial, z)
                for j in 0..<count {
                    let angle = 2 * Float.pi * Float(j) / Float(count), c = cos(angle), s = sin(angle)
                    mesh.vertices.append(SIMD3(p.x * c, p.x * s, p.y))
                    mesh.normals.append(simd_normalize(SIMD3(n2.x * c, n2.x * s, n2.y)))
                }
            }
            for r in 0..<(profile.count - 1) {
                for j in 0..<count {
                    let j1 = (j + 1) % count
                    let a = r * count + j, b = (r + 1) * count + j, c = (r + 1) * count + j1, d = r * count + j1
                    mesh.triangle(a, b, c); mesh.triangle(a, c, d)
                }
            }
            return mesh
        }
        return (lathe(outer), lathe(bore))
    }

    // MARK: Node

    static func orient(_ node: SCNNode, z direction: SIMD3<Float>, x along: SIMD3<Float>? = nil, side: Float) {
        let z = simd_normalize(map(direction, side: side))
        guard let along else { node.simdOrientation = simd_quatf(from: SIMD3(0, 0, 1), to: z); return }
        var x = map(along, side: side); x = simd_normalize(x - z * simd_dot(x, z))
        node.simdOrientation = simd_quatf(simd_float3x3(columns: (x, simd_cross(z, x), z)))
    }
    /// A flat label facing `normal` (design frame) with its x axis reading left to right from outside.
    static func faceOrientation(normal: SIMD3<Float>, side: Float) -> simd_quatf {
        let z = simd_normalize(map(normal, side: side)), y = SIMD3<Float>(0, 1, 0)
        let x = simd_normalize(simd_cross(y, z))
        return simd_quatf(simd_float3x3(columns: (x, simd_cross(z, x), z)))
    }
    /// A thin flat plate with a rounded-rectangle outline, centred on its node, facing +z.
    static func plate(width: Float, height: Float, corner: Float, depth: Float) -> SCNShape {
        let path = NSBezierPath(roundedRect: NSRect(x: CGFloat(-width / 2), y: CGFloat(-height / 2), width: CGFloat(width), height: CGFloat(height)),
                                xRadius: CGFloat(corner), yRadius: CGFloat(corner))
        path.flatness = 0.004
        return SCNShape(path: path, extrusionDepth: CGFloat(depth))
    }

    static func make(side: Float) -> SCNNode {
        let bud = SCNNode(); bud.name = "bud"
        let content = SCNNode(); content.name = "budContent"
        bud.addChildNode(content)
        let housing = housingMesh(side: side).geometry()
        housing.materials = [StudioMaterials.buds3ProSilver()]
        let body = SCNNode(geometry: housing); body.name = "body"
        content.addChildNode(body)
        let capGeometry = capMesh(side: side).geometry()
        capGeometry.materials = [StudioMaterials.budsCap()]
        let capNode = SCNNode(geometry: capGeometry); capNode.name = "footCap"
        content.addChildNode(capNode)

        // Silicone tip over the nozzle, its bore, and the acoustic mesh 1.3 mm inside the opening.
        let (outer, bore) = tipMeshes()
        let silicone = outer.geometry(); silicone.materials = [StudioMaterials.budsTip()]
        let tip = SCNNode(geometry: silicone); tip.name = "silicone"
        tip.simdPosition = map(tipBase, side: side)
        tip.simdScale = SIMD3(1.18, 1.18, 1.08)  // a medium tip, 13.6 mm across
        orient(tip, z: tipAxis, side: side)
        content.addChildNode(tip)
        let boreGeometry = bore.geometry(); boreGeometry.materials = [StudioMaterials.budsBore()]
        let boreNode = SCNNode(geometry: boreGeometry); boreNode.name = "tipBore"
        tip.addChildNode(boreNode)
        let meshDisc = SCNCylinder(radius: CGFloat(boreRadius + 0.02), height: 0.05); meshDisc.radialSegmentCount = 96
        meshDisc.materials = [StudioMaterials.budsGrille(tiles: 1.8)]
        let nozzleMesh = SCNNode(geometry: meshDisc); nozzleMesh.name = "nozzle"
        nozzleMesh.position = SCNVector3(0, 0, CGFloat(tipFace - meshDepth))
        nozzleMesh.eulerAngles.x = .pi / 2
        tip.addChildNode(nozzleMesh)

        // Grilles and the sensor window, flush with the shell.
        for inset in insets {
            let node = SCNNode(geometry: insetGeometry(inset, side: side)); node.name = inset.name
            node.geometry?.materials = [inset.grille ? StudioMaterials.budsGrille(tiles: 1) : StudioMaterials.budsSensor()]
            content.addChildNode(node)
        }

        // Blade Light: smoked glass down the ridge facet, lit over its upper half.
        let facetNormal = SIMD3<Float>(-1, 0, 0)
        let glass = SCNNode(geometry: plate(width: 0.8, height: glassTop - glassBottom, corner: 0.38, depth: 0.06))
        glass.geometry?.materials = [StudioMaterials.bladeGlass()]
        glass.name = "bladeGlass"
        glass.simdPosition = map(SIMD3(-0.04, (glassTop + glassBottom) / 2, 0), side: side)
        glass.simdOrientation = faceOrientation(normal: facetNormal, side: side)
        content.addChildNode(glass)
        let led = SCNNode(geometry: plate(width: 0.62, height: glassTop - 0.15 - lightBottom, corner: 0.3, depth: 0.04))
        led.geometry?.materials = [StudioMaterials.bladeLight()]
        led.name = "bladeLight"
        led.simdPosition = map(SIMD3(-0.08, (glassTop - 0.15 + lightBottom) / 2, 0), side: side)
        led.simdOrientation = faceOrientation(normal: facetNormal, side: side)
        let spill = SCNLight(); spill.type = .omni; spill.intensity = 0; spill.attenuationStartDistance = 1; spill.attenuationEndDistance = 12
        let spillNode = SCNNode(); spillNode.name = "ledSpill"; spillNode.light = spill; spillNode.position = SCNVector3(0, 0, 5)
        led.addChildNode(spillNode)
        content.addChildNode(led)

        // The printed letter low on the broad back face, and the side colour on the cap.
        let backNormal = SIMD3<Float>(1, 0, 0)
        let labelOrientation = faceOrientation(normal: backNormal, side: side)
        let accent = SCNNode(geometry: plate(width: 1.4, height: 1.0, corner: 0.14, depth: 0.04))
        accent.geometry?.materials = [StudioMaterials.surface((side < 0 ? RGB(0x587DB0) : RGB(0xE96937)).nsColor, roughness: 0.4)]
        accent.name = "sideAccent"
        accent.simdPosition = map(SIMD3(stemDepth + 0.005, bottom + capHeight / 2 + 0.1, 0), side: side)
        accent.simdOrientation = labelOrientation
        content.addChildNode(accent)
        let text = SCNText(string: side < 0 ? "L" : "R", extrusionDepth: 0.2)
        text.font = NSFont.systemFont(ofSize: 32, weight: .light); text.flatness = 0.05
        text.materials = [StudioMaterials.surface(RGB(0x3A3D42).nsColor, roughness: 0.6)]
        let letter = SCNNode(geometry: text); letter.name = "sideLetter"
        let (lo, hi) = text.boundingBox
        letter.position = SCNVector3(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, 0)  // centred, in points
        let glyphs = SCNNode(); glyphs.scale = SCNVector3(0.1, 0.1, 0.1)  // 32 pt to 2.3 mm capitals
        glyphs.addChildNode(letter)
        let labelNode = SCNNode(); labelNode.name = "sideLabel"
        labelNode.simdPosition = map(SIMD3(stemDepth + 0.03, bottom + 4.3, 0), side: side)
        labelNode.simdOrientation = labelOrientation
        labelNode.addChildNode(glyphs)
        content.addChildNode(labelNode)

        // Centre the bud's footprint on its node so it turns about its own middle.
        let (blo, bhi) = content.boundingBox
        content.position = SCNVector3(-(blo.x + bhi.x) / 2, 0, -(blo.z + bhi.z) / 2)
        return bud
    }
}
