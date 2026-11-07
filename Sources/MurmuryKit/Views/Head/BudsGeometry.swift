import AppKit
import SceneKit
import simd

/// Procedural Galaxy Buds3 Pro; all mesh coordinates are millimetres, scaled once at the root.
/// The lead's superellipsoid case and triangular blade remain the construction vocabulary.
enum BudsGeometry {
    static let bodySegments = 144, nozzleSegments = 96, chamferSegments = 12
    static let stemTopWidth = BudsSpec.topWidth, stemBottomWidth = BudsSpec.bottomWidth
    static let stemTopDepth = BudsSpec.topDepth, stemBottomDepth = BudsSpec.bottomDepth
    static let stemLength = BudsSpec.bladeLength
    static let caseDeckY: Float = -0.25
    static var housingLatitude: Float {
        asin(-pow(abs((BudsSpec.collarTop - BudsSpec.housingY) / BudsSpec.housingRadii.y), 1 / BudsSpec.housingVertical))
    }
    static func housingSection(count: Int) -> [SIMD3<Float>] {
        SuperShape.section(radii: BudsSpec.housingRadii, vertical: BudsSpec.housingVertical,
                           horizontal: BudsSpec.housingHorizontal, phi: housingLatitude, count: count)
            .map { $0 + SIMD3(0, BudsSpec.housingY, 0) }
    }
    /// Six real faces: narrow ridge facet, two side faces, rear bevels and a broad flat outer face.
    static func bladeSection(width w: Float, depth d: Float) -> [SIMD2<Float>] {
        let e = BudsSpec.edgeFacet, b = BudsSpec.rearBevel
        return [SIMD2(-w / 2, -d / 3 + b), SIMD2(-w / 2 + b, -d / 3), SIMD2(w / 2 - b, -d / 3),
                SIMD2(w / 2, -d / 3 + b), SIMD2(e / 2, 2 * d / 3), SIMD2(-e / 2, 2 * d / 3)]
    }
    static func bladeData() -> Loft.Mesh {
        let top = bladeSection(width: stemTopWidth, depth: stemTopDepth).map { SIMD3($0.x, BudsSpec.bladeTop, $0.y) }
        let bottom = bladeSection(width: stemBottomWidth, depth: stemBottomDepth).map { SIMD3($0.x, BudsSpec.bladeTop - stemLength, $0.y) }
        return Loft.surface([top, bottom], flat: true, capEnd: true)
    }
    static func bladeMesh() -> SCNGeometry {
        let mesh = bladeData()
        // Give the broad outer face its own polish; preserve real creases without duplicate backfaces.
        let outer = Array(mesh.indices[6..<12]), other = Array(mesh.indices[0..<6]) + Array(mesh.indices[12...])
        return SCNGeometry(sources: [SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) }),
                                     SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) })],
                           elements: [SCNGeometryElement(indices: outer, primitiveType: .triangles), SCNGeometryElement(indices: other, primitiveType: .triangles)])
    }
    static func collarSections() -> [[SIMD3<Float>]] {
        let top = housingSection(count: 48)
        let bottom = Loft.resample(bladeSection(width: stemTopWidth, depth: stemTopDepth), count: 48)
        return (0...256).map { ring in
            let t = Float(ring) / 256, f = t * t * (3 - 2 * t)
            return (0..<48).map { i in
                let a = top[i], b = SIMD3(bottom[i].x, BudsSpec.bladeTop, bottom[i].y)
                return SIMD3(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * f)
            }
        }
    }
    @discardableResult private static func part(_ name: String, _ geometry: SCNGeometry, _ position: SCNVector3,
                                                _ material: SCNMaterial, parent: SCNNode) -> SCNNode {
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry); node.name = name; node.position = position; parent.addChildNode(node)
        return node
    }
    /// The procedural Buds3 Pro used everywhere (hero, head avatar, icon), built in millimetres.
    /// The returned node's own coordinates are millimetres (its `scale` is `BudsSpec.scale`): the
    /// ridge and Blade Light face +z and the ear tip turns toward `side`·x.
    static func make(side: Float) -> SCNNode {
        let model = Buds3Pro.make(side: side); model.name = "budModel"
        model.scale = SCNVector3(Buds3Pro.mm, Buds3Pro.mm, Buds3Pro.mm)
        let bud = SCNNode(); bud.name = "bud"
        bud.addChildNode(model)
        bud.scale = SCNVector3(BudsSpec.scale, BudsSpec.scale, BudsSpec.scale)
        return bud
    }

    /// The previous primitive-built bud, kept for comparison renders.
    static func legacyMake(side: Float) -> SCNNode {
        let bud = SCNNode(); bud.name = "bud"; bud.scale = SCNVector3(BudsSpec.scale, BudsSpec.scale, BudsSpec.scale)
        let silver = StudioMaterials.budsHousing()
        var housing = SuperShape.mesh(radii: BudsSpec.housingRadii, vertical: BudsSpec.housingVertical,
                                      horizontal: BudsSpec.housingHorizontal, latitudes: housingLatitude ... .pi / 2)
        // The ear-contact side is inset around the nozzle. A symmetric pebble would swallow the
        // silicone tip; this keeps the outer dome and millimetre envelope while exposing the tip.
        for i in housing.vertices.indices {
            let p = housing.vertices[i]
            guard side * p.x < 0 else { continue }
            let height = min(1, max(0, (p.y + BudsSpec.housingY - BudsSpec.collarTop) / (16.6 - BudsSpec.collarTop)))
            let contact = sin(Float.pi * height) * exp(-p.z * p.z / 72) * pow(abs(p.x) / BudsSpec.housingRadii.x, 2)
            housing.vertices[i].x *= 1 - BudsSpec.contactInset * contact
        }
        housing.recalculateNormals()
        part("body", housing.geometry(), SCNVector3(0, BudsSpec.housingY, 0), silver, parent: bud)
        part("collar", Loft.surface(collarSections()).geometry(), SCNVector3Zero, silver, parent: bud)
        let stem = bladeMesh(); stem.materials = [StudioMaterials.budsBlade(outer: true), StudioMaterials.budsBlade(outer: false)]
        let blade = SCNNode(geometry: stem); blade.name = "stem"; bud.addChildNode(blade)
        let nozzle = SCNCylinder(radius: CGFloat(BudsSpec.nozzleRadius), height: CGFloat(BudsSpec.nozzleLength)); nozzle.radialSegmentCount = nozzleSegments
        let nozzleNode = part("nozzle", nozzle, SCNVector3(-side * 5.5, 8, 1), silver, parent: bud)
        // Cylinder axis y points inward and 20 degrees forward.
        nozzleNode.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: SIMD3(-side * cos(20 * .pi / 180), 0, sin(20 * .pi / 180)))
        let tip = SCNSphere(radius: 3.5); tip.segmentCount = nozzleSegments
        let tipNode = part("silicone", tip, SCNVector3(-side * 7.5, 8, 1.8), StudioMaterials.surface(RGB(0x4A4652).nsColor, roughness: 0.75), parent: bud)
        tipNode.scale = SCNVector3(0.42, 1, 1)
        let length = stemLength * BudsSpec.bladeLightFraction, mid: Float = 0.50
        let ridge = (2 * stemTopDepth / 3) + (2 * stemBottomDepth / 3 - 2 * stemTopDepth / 3) * mid
        let strip = SCNBox(width: CGFloat(BudsSpec.bladeLightWidth), height: CGFloat(length), length: 0.3, chamferRadius: 0.12)
        strip.chamferSegmentCount = chamferSegments
        let glass = StudioMaterials.surface(RGB(0xE0E4EC).nsColor, roughness: 0.08); glass.transparency = 0.45
        let cover = part("bladeGlass", strip, SCNVector3(0, BudsSpec.bladeTop - stemLength * mid, ridge - BudsSpec.bladeLightInset), glass, parent: blade)
        cover.eulerAngles.x = -CGFloat(atan2(2 * (stemTopDepth - stemBottomDepth) / 3, stemLength))
        let core = SCNBox(width: CGFloat(BudsSpec.bladeCoreWidth), height: CGFloat(length), length: 0.12, chamferRadius: 0.06)
        core.chamferSegmentCount = chamferSegments
        let led = part("bladeLight", core, SCNVector3(0, 0, 0.16), StudioMaterials.bladeLight(), parent: cover)
        let spill = SCNLight(); spill.type = .omni; spill.intensity = 0; spill.attenuationStartDistance = 1; spill.attenuationEndDistance = 12
        let spillNode = SCNNode(); spillNode.name = "ledSpill"; spillNode.light = spill; led.addChildNode(spillNode)
        return bud
    }
    static func chargingCase(hue: Hue, open: Bool = true) -> SCNNode {
        let root = SCNNode(); root.name = "chargingCase"
        root.scale = SCNVector3(BudsSpec.scale, BudsSpec.scale, BudsSpec.scale); root.position.y = CGFloat(caseDeckY)
        let rx = BudsSpec.caseSize.x / 2, rz = BudsSpec.caseSize.z / 2
        let radii = SIMD3(rx, BudsSpec.baseHeight, rz)
        let shell = SuperShape.geometry(radii: radii, vertical: 0.30, horizontal: 0.38, latitudes: -.pi / 2 ... 0)
        part("caseBody", shell, SCNVector3Zero, StudioMaterials.budsCase(), parent: root)
        let deckPath = NSBezierPath()
        for (i, p) in SuperShape.section(radii: SIMD3(rx - 1.1, 1, rz - 1.1), vertical: 0.3, horizontal: 0.38, phi: 0, count: 144).enumerated() {
            let q = CGPoint(x: CGFloat(p.x), y: CGFloat(p.z))
            if i == 0 { deckPath.move(to: q) } else { deckPath.line(to: q) }
        }
        deckPath.close(); deckPath.windingRule = .evenOdd
        for side: Float in [-1, 1] {
            let hole = NSBezierPath(ovalIn: CGRect(x: -7.3, y: -8.7, width: 14.6, height: 17.4))
            var transform = AffineTransform(); transform.translate(x: CGFloat(side * 12), y: 0); transform.rotate(byRadians: CGFloat(side) * 0.22)
            hole.transform(using: transform); deckPath.append(hole)
            let cradle = SuperShape.geometry(radii: SIMD3(7.3, 2.8, 8.7), vertical: 0.4, horizontal: 1,
                                              latitudes: -.pi / 2 ... 0, rings: 20, segments: 96)
            let n = part("cradle", cradle, SCNVector3(side * 12, -0.9, 0), StudioMaterials.surface(RGB(0x2B2832).nsColor, roughness: 0.7), parent: root)
            n.eulerAngles.y = CGFloat(side) * 0.22
        }
        let deck = SCNShape(path: deckPath, extrusionDepth: 0.8)
        let deckNode = part("recessedDeck", deck, SCNVector3(0, -1.3, 0), StudioMaterials.surface(RGB(0x4A4652).nsColor, roughness: 0.55), parent: root)
        deckNode.eulerAngles.x = -.pi / 2
        let seam = caseSeam(rx: rx, rz: rz)
        part("seam", seam, SCNVector3Zero, StudioMaterials.surface(RGB(0x2B2832).nsColor, roughness: 0.6), parent: root)
        let led = SCNBox(width: 3, height: 1, length: 0.3, chamferRadius: 0.5)
        let ledMaterial = StudioMaterials.surface(RGB(0x5FE38A).nsColor, roughness: 0.2)
        ledMaterial.emission.contents = RGB(0x5FE38A).nsColor; ledMaterial.emission.intensity = 1.2
        part("caseLED", led, SCNVector3(0, -7, rz - 0.1), ledMaterial, parent: root)
        let hinge = SCNNode(); hinge.name = "lidHinge"; hinge.position = SCNVector3(0, 0, -rz + BudsSpec.hingeRadius)
        hinge.eulerAngles.x = open ? CGFloat(BudsSpec.lidDegrees) * .pi / 180 : 0; root.addChildNode(hinge)
        let barrel = SCNCylinder(radius: CGFloat(BudsSpec.hingeRadius), height: 18); barrel.radialSegmentCount = 48
        let barrelNode = part("hingeBarrel", barrel, SCNVector3Zero, StudioMaterials.budsCase(), parent: hinge)
        barrelNode.eulerAngles.z = .pi / 2
        let lidRadii = SIMD3(rx, BudsSpec.lidHeight, rz)
        let outer = SuperShape.geometry(radii: lidRadii, vertical: 0.30, horizontal: 0.38, latitudes: 0 ... .pi / 2)
        let lid = part("lid", outer, SCNVector3(0, 0, rz - BudsSpec.hingeRadius), StudioMaterials.budsLid(), parent: hinge); lid.renderingOrder = 30
        let innerRadii = lidRadii - SIMD3<Float>(repeating: BudsSpec.lidWall)
        var inner = SuperShape.mesh(radii: innerRadii, vertical: 0.30, horizontal: 0.38, latitudes: 0 ... .pi / 2)
        inner.normals = inner.normals.map { -$0 }
        for i in stride(from: 0, to: inner.indices.count, by: 3) { inner.indices.swapAt(i + 1, i + 2) }
        let inside = part("lidInner", inner.geometry(), lid.position, StudioMaterials.budsLid(), parent: hinge); inside.renderingOrder = 20
        let outsideRing = SuperShape.section(radii: lidRadii, vertical: 0.30, horizontal: 0.38, phi: 0, count: 144)
        let insideRing = SuperShape.section(radii: innerRadii, vertical: 0.30, horizontal: 0.38, phi: 0, count: 144)
        let rim = part("lidWall", Loft.surface([outsideRing, insideRing]).geometry(), lid.position, StudioMaterials.budsLid(), parent: hinge); rim.renderingOrder = 25
        return root
    }
    private static func caseSeam(rx: Float, rz: Float) -> SCNGeometry {
        let ring = SuperShape.section(radii: SIMD3(rx, 1, rz), vertical: 0.3, horizontal: 0.38, phi: 0, count: 144)
        var mesh = Loft.Mesh()
        for j in ring.indices {
            let tangent = simd_normalize(ring[(j + 1) % ring.count] - ring[(j + ring.count - 1) % ring.count])
            let outward = simd_normalize(simd_cross(tangent, SIMD3(0, 1, 0)))
            for k in 0..<8 {
                let a = 2 * Float.pi * Float(k) / 8
                let n = outward * cos(a) + SIMD3(0, sin(a), 0)
                mesh.vertices.append(ring[j] + n * BudsSpec.seamRadius); mesh.normals.append(n)
            }
        }
        for j in 0..<144 { for k in 0..<8 {
            let a = j * 8 + k, b = ((j + 1) % 144) * 8 + k, c = ((j + 1) % 144) * 8 + (k + 1) % 8, d = j * 8 + (k + 1) % 8
            mesh.triangle(a, b, c); mesh.triangle(a, c, d)
        } }
        return mesh.geometry()
    }

    static func leds(in node: SCNNode) -> [SCNMaterial] {
        var materials: [SCNMaterial] = []
        node.enumerateChildNodes { n, _ in
            if n.name == "bladeLight", let m = n.geometry?.firstMaterial { materials.append(m) }
        }
        return materials
    }
    static func spills(in node: SCNNode) -> [SCNLight] {
        var lights: [SCNLight] = []
        node.enumerateChildNodes { n, _ in if n.name == "ledSpill", let l = n.light { lights.append(l) } }
        return lights
    }

    /// A supplied model's buds, if the asset exists and has both named nodes.
    static func asset(at url: URL?) -> (left: SCNNode, right: SCNNode)? {
        guard let url, FileManager.default.fileExists(atPath: url.path), let scene = try? SCNScene(url: url),
              let left = scene.rootNode.childNode(withName: "budLeft", recursively: true),
              let right = scene.rootNode.childNode(withName: "budRight", recursively: true) else { return nil }
        return (left.clone(), right.clone())
    }
    static var bundledAssetURL: URL? {
        Bundle.main.url(forResource: "buds", withExtension: "scn", subdirectory: "Models")
            ?? Bundle.main.url(forResource: "buds", withExtension: "usdz", subdirectory: "Models")
    }

    /// The hero pair: the supplied model when present, otherwise the procedural buds.
    static func pair(assetURL: URL? = bundledAssetURL) -> (left: SCNNode, right: SCNNode, usesAsset: Bool) {
        if let loaded = asset(at: assetURL) { return (loaded.left, loaded.right, true) }
        return (make(side: -1), make(side: 1), false)
    }
}
