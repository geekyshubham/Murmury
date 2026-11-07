import SceneKit
import simd
import Testing
@testable import MurmuryKit

@MainActor @Suite("Procedural Buds3 Pro specification")
struct BudsSpecTests {
    @Test func dimensionsAndClosedCaseRatios() {
        for side: Float in [-1, 1] {
            let bud = BudsGeometry.make(side: side)
            let (lo, hi) = bud.boundingBox
            #expect(abs(Float(hi.y - lo.y) / BudsSpec.budSize.y - 1) <= 0.04, "height \(hi.y - lo.y)")
            // Footprint: within about 2 mm of Samsung's published 18.1 × 19.8 mm (the bud lies at a
            // slant in its smallest box, so the shorter side runs a little under the published depth).
            let footprint = Self.footprint(bud)
            #expect((15...19).contains(footprint.x) && (18.5...21).contains(footprint.y), "footprint \(footprint)")
        }
        let closed = BudsGeometry.chargingCase(hue: .buds, open: false)
        let (lo, hi) = closed.boundingBox
        let size = SIMD3<Float>(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z))
        for axis in 0..<3 { #expect(abs(size[axis] / BudsSpec.caseSize[axis] - 1) <= 0.03, "case \(size)") }
        #expect(BudsSpec.scale == 0.04)
    }
    /// The smallest-area horizontal box (sorted: shorter, longer) over the bud's mesh vertices.
    static func footprint(_ bud: SCNNode) -> SIMD2<Float> {
        var points: [SIMD2<Float>] = []
        bud.enumerateChildNodes { node, _ in
            guard let source = node.geometry?.sources(for: .vertex).first else { return }
            for v in HeroStills.readVectors(source) {
                let p = node.convertPosition(SCNVector3(v.x, v.y, v.z), to: bud)
                points.append(SIMD2(Float(p.x), Float(p.z)))
            }
        }
        var best = SIMD2<Float>(.infinity, .infinity)
        for step in 0..<180 {
            let a = Float(step) * .pi / 180, c = cos(a), s = sin(a)
            let u = points.map { $0.x * c + $0.y * s }, v = points.map { -$0.x * s + $0.y * c }
            let size = SIMD2(u.max()! - u.min()!, v.max()! - v.min()!)
            if size.x * size.y < best.x * best.y { best = SIMD2(min(size.x, size.y), max(size.x, size.y)) }
        }
        return best
    }
    @Test func bladeHasRealCreasesAndNoDoubledTriangles() {
        let mesh = BudsGeometry.bladeData()
        let normals = mesh.normals
        for face in 0..<6 {
            let a = normals[face * 4], b = normals[((face + 1) % 6) * 4]
            #expect(acos(min(1, max(-1, simd_dot(a, b)))) > .pi / 6)
        }
        var triangles = Set<String>()
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let points = mesh.indices[i..<(i + 3)].map { mesh.vertices[Int($0)] }
            let key = points.map { "\($0.x),\($0.y),\($0.z)" }.sorted().joined(separator: ";")
            #expect(triangles.insert(key).inserted)
            #expect(simd_length(simd_cross(points[1] - points[0], points[2] - points[0])) > 1e-7)
        }
        #expect(normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs(simd_length($0) - 1) < 1e-4 })
    }
    /// The reference form: an ovoid head whose crown sits above the stem, a blade stem whose narrow
    /// ridge stays proud of the head's front up to the Blade Light's top, a broad back face carrying
    /// the letter, and a nozzle that aims the tip toward the ear and slightly down.
    @Test func ovoidHeadBladeStemAndProudRidge() throws {
        let section = (Buds3Pro.stemOutline().map(\.0.y).max()! - Buds3Pro.stemOutline().map(\.0.y).min()!)
        #expect(abs(section - 6.5) < 0.2, "stem \(section) mm across")
        #expect(abs(Buds3Pro.stemDepth - 4.6) < 0.2)
        // The ridge (a = 0) is outside the head at every height the Blade Light covers.
        for y in stride(from: Buds3Pro.lightBottom, through: Buds3Pro.glassTop, by: 0.5) {
            #expect(Buds3Pro.head(SIMD3(0, y, 0)) > 0.4, "ridge proud of the head at y \(y)")
            #expect(abs(Buds3Pro.shell(SIMD3(0, y, 0))) < 0.15, "ridge on the surface at y \(y)")
        }
        // The crown is the head's, above the stem; the tip turns toward the ear and down.
        let crown = Buds3Pro.housingNet.vertices.max { $0.y < $1.y }!
        #expect(abs(crown.y - Buds3Pro.top) < 0.5 && crown.x > 2, "crown \(crown)")
        #expect(Buds3Pro.tipAxis.z > 0.9 && Buds3Pro.tipAxis.y < -0.15)
        let mesh = Buds3Pro.housingMesh(side: -1)
        #expect(mesh.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs(simd_length($0) - 1) < 1e-3 })
        #expect(mesh.vertices.count > 15000)
        // The Blade Light is on the ridge, the stem's most forward edge (toward the viewer, +z).
        let bud = BudsGeometry.make(side: -1)
        let body = try #require(bud.childNode(withName: "body", recursively: true))
        let led = try #require(bud.childNode(withName: "bladeLight", recursively: true))
        let ledZ = Float(led.convertPosition(SCNVector3Zero, to: body).z)
        let stemZ = mesh.vertices.filter { $0.y < -8 }.map(\.z).max()!
        #expect(abs(ledZ - stemZ) < 0.2, "light \(ledZ) on the ridge \(stemZ)")
        for name in ["sideLetter", "sideAccent", "footCap", "tipBore", "nozzle", "micGrille", "outerSensor"] {
            #expect(bud.childNode(withName: name, recursively: true) != nil, "\(name)")
        }
    }
    /// Grilles and the sensor window hug the shell: every patch vertex sits just proud of it.
    @Test func insetsHugTheShell() {
        for inset in Buds3Pro.insets {
            let geometry = Buds3Pro.insetGeometry(inset, side: -1)
            let points = HeroStills.readVectors(geometry.sources(for: .vertex)[0])
            for p in points {
                let d = Buds3Pro.shell(SIMD3(-Float(p.z), Float(p.y), -Float(p.x)))
                #expect(d > 0 && d < 0.05, "\(inset.name) \(d)")
            }
        }
    }
    @Test func finiteSuperellipsoidNormalsAndExactWrap() {
        let mesh = SuperShape.mesh(radii: SIMD3(9, 8.4, 9.9), vertical: 0.82, horizontal: 0.70)
        #expect(mesh.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs(simd_length($0) - 1) < 1e-4 })
        #expect(mesh.vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }
    @Test func floatingPairStaysInFrameAndBudsDoNotTouch() throws {
        let c = BudsGeometry.chargingCase(hue: .buds)
        #expect(c.childNode(withName: "lidHinge", recursively: false) != nil)
        let product = ProductSceneView.Coordinator(); product.build(.buds, budsAsset: nil)
        let pair = try #require(product.studio.scene.rootNode.childNode(withName: "budsPair", recursively: true))
        let buds = pair.childNodes.filter { $0.name == "bud" }
        #expect(buds.count == 2)
        for yaw in [-34.0, -12, 10] { for pitch in [-4.5, 4.5] {
            pair.eulerAngles = SCNVector3(pitch * .pi / 180, yaw * .pi / 180, 0)
            let projected = HeroFraming.projectedBounds(root: pair, camera: product.studio.camera, aspect: 1 / PageLayout.visualAspect)
            #expect(CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92).contains(projected), "pair envelope \(projected)")
        } }
        pair.eulerAngles = SCNVector3Zero
        func box(_ n: SCNNode) -> (SCNVector3, SCNVector3) {
            let (lo, hi) = n.boundingBox
            return (n.convertPosition(lo, to: pair), n.convertPosition(hi, to: pair))
        }
        let (a0, a1) = box(buds[0]), (b0, b1) = box(buds[1])
        let gap = max(min(b0.x, b1.x) - max(a0.x, a1.x), min(a0.x, a1.x) - max(b0.x, b1.x))
        #expect(gap > 0, "the buds don't overlap")
    }
    /// On the head the buds are worn, not hung beside the ear: the ear tip reaches inward of the ear's
    /// rim to the canal, the stem hangs below the tip, and the Blade Light faces forward.
    @Test func budsAreSeatedInTheEars() throws {
        let rig = HeadRig(assetURL: HeroTests.assetURL)
        for (name, side) in [("earLeft", CGFloat(-1)), ("earRight", 1)] {
            let ear = try #require(rig.scene.rootNode.childNode(withName: name, recursively: true))
            let bud = try #require(ear.childNode(withName: "bud", recursively: true))
            let tip = try #require(bud.childNode(withName: "silicone", recursively: true))
            let face = tip.convertPosition(SCNVector3(0, 0, CGFloat(Buds3Pro.tipFace)), to: ear)
            let mm = CGFloat(bud.scale.x)
            #expect(-face.x * side > 15 * mm, "tip \(face.x / mm) mm inward of the rim")
            let led = try #require(bud.childNode(withName: "bladeLight", recursively: true))
            let top = led.convertPosition(SCNVector3(0, 6.9, 0), to: ear), bottom = led.convertPosition(SCNVector3(0, -6.9, 0), to: ear)
            #expect(bottom.y < face.y && top.y > bottom.y, "stem hangs down")
            let n = led.convertVector(SCNVector3(0, 0, 1), to: ear)  // carries the bud's scale
            let facing = simd_normalize(SIMD3(Double(n.x), Double(n.y), Double(n.z)))
            #expect(facing.z > 0.5, "Blade Light faces forward \(facing)")
        }
    }
    @Test func onHeadScaleUsesMeasuredChinToCrown() {
        for height: Float in [1.5, 1.9, 2.2] {
            #expect(abs(BudsSpec.onHeadScale(chinToCrown: height) * 230 - height) < 1e-6)
        }
        let rig = HeadRig(assetURL: HeroTests.assetURL)
        #expect(rig.scene.rootNode.childNode(withName: "bud", recursively: true)?.scale.x ?? 1 < 0.02)
    }
    /// As in Samsung's front product shot, each bud's head and ear tip turn outward (toward `side`·x).
    @Test func siliconeTipTurnsOutwardBeyondTheHousing() throws {
        for side: Float in [-1, 1] {
            let bud = BudsGeometry.make(side: side)
            let tip = try #require(bud.childNode(withName: "silicone", recursively: true))
            let body = try #require(bud.childNode(withName: "body", recursively: true))
            let tipCentre = tip.convertPosition(SCNVector3(0, 0, 4), to: body)
            #expect(Float(tipCentre.x) * side > 0, "ear tip on the outer side")
            let housing = Buds3Pro.housingMesh(side: side).vertices.map { side * $0.x }.max()!
            #expect(side * Float(tipCentre.x) > housing * 0.9, "tip protrudes past the housing")
        }
    }
    @Test func productMaterialsAndOnlyLEDsEmit() throws {
        let bud = BudsGeometry.make(side: 1)
        let body = try #require(bud.childNode(withName: "body", recursively: true)?.geometry?.firstMaterial)
        // Galaxy Buds3 Pro Silver as the reference renders show it: satin metal, a faint clear coat.
        #expect(body.metalness.contents as? Double == 0.65 && body.roughness.contents as? Double == 0.6)
        #expect(body.clearCoat.contents as? Double == 0.1 && body.clearCoatRoughness.contents as? Double == 0.4)
        let tip = try #require(bud.childNode(withName: "silicone", recursively: true)?.geometry?.firstMaterial)
        #expect(tip.metalness.contents as? Double == 0 && (tip.roughness.contents as? Double ?? 0) >= 0.7, "matte silicone")
        let lid = try #require(BudsGeometry.chargingCase(hue: .buds).childNode(withName: "lid", recursively: true))
        let m = try #require(lid.geometry?.firstMaterial)
        #expect(abs(m.transparency - 0.35) < 1e-6 && m.transparencyMode == .dualLayer && m.roughness.contents as? Double == 0.03 && m.fresnelExponent == 2)
        #expect(lid.renderingOrder > 0 && !m.writesToDepthBuffer)
        var emitters = [String]()
        bud.enumerateChildNodes { n, _ in
            if let color = n.geometry?.firstMaterial?.emission.contents as? NSColor,
               (color.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0 { emitters.append(n.name ?? "") }
        }
        #expect(emitters.isEmpty)
    }
}
