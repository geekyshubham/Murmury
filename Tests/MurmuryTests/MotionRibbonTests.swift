import SceneKit
import simd
import Testing
@testable import MurmuryKit

@MainActor @Suite("Motion ribbons")
struct MotionRibbonTests {
    @Test func labelCountClampsAndCurvesClose() {
        for count in [-1, 0, 2, 3, 4, 5, 20] {
            let ribbons = MotionRibbons.curves(labelCount: count)
            #expect(ribbons.count == min(5, max(3, count)))
            for curve in ribbons {
                #expect(simd_distance(curve[0], curve.last!) < 1e-4)
                #expect(curve.allSatisfy { simd_length($0) + Float(MotionRibbons.width / 2) <= 1.4 })
                for i in 1..<(curve.count - 1) {
                    let a = curve[i] - curve[i - 1], b = curve[i + 1] - curve[i]
                    let cross = simd_length(simd_cross(a, b))
                    let radius = simd_length(a) * simd_length(b) * simd_length(a + b) / max(1e-10, 2 * cross)
                    #expect(radius > 3 * Float(MotionRibbons.width))
                }
            }
        }
    }
    @Test func ribbonCentrelinesHaveClearance() {
        let curves = MotionRibbons.curves(labelCount: 5)
        for a in curves.indices { for b in curves.indices where b > a {
            var minimum = Float.infinity
            for p in curves[a] { for q in curves[b] { minimum = min(minimum, simd_distance(p, q)) } }
            #expect(minimum >= 2.5 * Float(MotionRibbons.width), "\(a) / \(b): \(minimum)")
        } }
    }
    @Test func statesAndReducedMotionDriveCometTextureOnly() throws {
        let rig = ModelRig(labelCount: 5)
        for state in [ModelHeroState.untrained, .training, .ready, .failed] {
            rig.apply(state: state, scheme: .dark, time: 0, dt: 0, reduceMotion: true)
            let first = rig.cometTransforms
            rig.apply(state: state, scheme: .dark, time: 20, dt: 0.1, reduceMotion: true)
            #expect(first == rig.cometTransforms)
            #expect(rig.cometIntensities.filter { $0 > 0 }.count == (state == .untrained ? 0 : (state == .failed ? 1 : 5)))
        }
        rig.apply(state: .training, scheme: .dark, time: 0, dt: 0, reduceMotion: false)
        let start = rig.cometTransforms
        rig.apply(state: .training, scheme: .dark, time: 0.5, dt: 0.1, reduceMotion: false)
        #expect(start != rig.cometTransforms)
        let material = try #require(rig.root.childNode(withName: "ribbon", recursively: true)?.geometry?.firstMaterial)
        #expect(abs(Double(material.emission.contentsTransform.m41) + 0.4) < 1e-6)
        let texture = try #require(material.emission.contents)
        #expect(CFGetTypeID(texture as CFTypeRef) == CGImage.typeID)
        #expect(material.emission.wrapS == .repeat)
        #expect(ModelHeroState.training.rotationRate(reduceMotion: false) == 0.8)
        #expect(ModelHeroState.ready.rotationRate(reduceMotion: false) == 0.12)
        rig.setLabelCount(4)
        #expect(rig.root.childNodes.filter { $0.name == "ribbon" }.count == 4)
        rig.setLabelCount(0)
        #expect(rig.root.childNodes.filter { $0.name == "ribbon" }.count == 3)
        let old = ModelRig(kind: .atom)
        #expect(old.root.childNode(withName: "ring", recursively: true) != nil)
    }
    @Test func posedRibbonsStaySeparateAndInsideTheEnvelope() {
        let rig = ModelRig(labelCount: 5)
        let curves = MotionRibbons.curves(labelCount: 5)
        for state in [ModelHeroState.untrained, .training, .ready, .failed] {
            rig.apply(state: state, scheme: .dark, time: 0, dt: 0, reduceMotion: true)
            let nodes = rig.root.childNodes.filter { $0.name == "ribbon" }
            let world = curves.enumerated().map { i, curve in curve.map { p -> SIMD3<Float> in
                nodes[i].simdConvertPosition(p, to: rig.root)
            } }
            for curve in world { #expect(curve.allSatisfy { simd_length($0) + 0.03 <= 1.4 }) }
            for a in world.indices { for b in world.indices where b > a {
                var minimum = Float.infinity
                for p in world[a] { for q in world[b] { minimum = min(minimum, simd_distance(p, q)) } }
                #expect(minimum >= 0.15)
            } }
        }
    }
    @Test func ribbonMeshHasClosedUvSeamsAndFlatRoundedProfile() throws {
        let curve = MotionRibbons.curves(labelCount: 3)[0]
        let mesh = MotionRibbons.mesh(curve)
        let count = MotionRibbons.profile.count
        for i in 0..<count {
            #expect(simd_distance(mesh.vertices[i], mesh.vertices[mesh.vertices.count - count + i]) < 1e-4)
            #expect(simd_distance(mesh.normals[i], mesh.normals[mesh.normals.count - count + i]) < 1e-4)
        }
        #expect(MotionRibbons.width == 0.072 && MotionRibbons.thickness == 0.02 && MotionRibbons.profile.count == 24)
        #expect(mesh.normals.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }
}
