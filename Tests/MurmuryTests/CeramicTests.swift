import SceneKit
import simd
import Testing
@testable import MurmuryKit

@MainActor @Suite("Hue-dyed ceramic")
struct CeramicTests {
    /// Regression: shader `float3` arguments bound as `NSValue(scnVector3:)` (64-bit CGFloats on
    /// macOS) arrived in Metal as zeros, silently disabling the dye, rims, eye positions and tint.
    @Test func float3ShaderArgumentsArePackedAsMetalLaysThemOut() {
        let data = HeadTreatment.float3(SIMD3(0.25, -1.5, 3))
        #expect(data.length == 16)
        var values = [Float](repeating: 0, count: 4)
        data.getBytes(&values, length: 16)
        #expect(values == [0.25, -1.5, 3, 0])
    }

    /// The supplied sculpt is stylised by Taubin smoothing: fine anatomy softens (lower local
    /// curvature) while the silhouette keeps its size (no shrinkage).
    @Test func stylisingSoftensDetailWithoutShrinkingTheHead() throws {
        let url = HeroTests.assetURL
        let scene = try SCNScene(url: url)
        let skin = try #require(scene.rootNode.childNode(withName: "skin", recursively: true)?.geometry)
        let smooth = MeshSmoother.taubin(skin, iterations: 30)
        let a = MeshSmoother.read(skin.sources(for: .vertex).first!), b = MeshSmoother.read(smooth.sources(for: .vertex).first!)
        #expect(a.count == b.count)
        func extent(_ p: [SIMD3<Float>]) -> SIMD3<Float> {
            p.reduce(SIMD3(repeating: -.infinity), { simd_max($0, $1) }) - p.reduce(SIMD3(repeating: .infinity), { simd_min($0, $1) })
        }
        let ea = extent(a), eb = extent(b)
        for i in 0..<3 { #expect(abs(eb[i] / ea[i] - 1) < 0.03, "axis \(i) keeps its size") }
        let moved = zip(a, b).map { simd_distance($0, $1) }
        #expect(moved.max()! > 0.002 * ea.y, "fine detail actually softened")
    }

    @Test func finishAndAlbedoBoundsAcrossAllHues() {
        // Round 34: soft eyes, a large iris in a deeper tone of the head's colour (no grey marble stare).
        #expect(HeadTreatment.style == .ceramic && HeadTreatment.eyes == .soft)
        let (_, eye) = HeadTreatment.materials(style: .ceramic, eyes: .soft, scheme: .dark, hue: .control, anatomy: nil, debugEyes: false)
        let irisCos = HeadTreatment.pack(eye, "headB")!.x
        #expect(abs(irisCos - Float((1 - 0.56 * 0.56).squareRoot())) < 1e-4, "the iris meets the lids")
        let iris = HeadTreatment.pack(eye, "irisColor")!
        #expect(iris.z > iris.x && iris.z > iris.y, "the iris is a deeper violet tone, not grey")
        for hue in Hue.all { for dark in [true, false] {
            let f = HeadTreatment.finish(.ceramic, dark: dark, hue: hue)
            #expect(f.roughness == (dark ? 0.58 : 0.62))
            #expect(f.clearCoat == 0.12 && f.clearCoatRoughness == 0.42 && f.rimPower == 2.6, "matte-satin bisque, not a wet coat")
            #expect(f.rimStrength == (dark ? 0.38 : 0.2))
            for t in [0.0, 0.25, 0.5, 0.75, 1] {
                let color = HeadTreatment.ceramicAlbedo(hue: hue, dark: dark, height: t)
                #expect((0.22...0.75001).contains(color.luminance))
                #expect(color.saturation >= 0.40, "visibly hue-coloured, not grey")
            }
        } }
    }
    @Test func shaderHasHueShadowLiftAndSculptedEyesHaveNoIris() throws {
        for dark in [true, false] {
            let pair = HeadTreatment.materials(style: .ceramic, eyes: .sculpted, scheme: dark ? .dark : .light, hue: .control, anatomy: nil, debugEyes: false)
            let shader = try #require(pair.skin.shaderModifiers?[.fragment])
            #expect(shader.contains("shadowTint") && shader.contains("shadowLift"))
            #expect(HeadTreatment.pack(pair.skin, "rimA")?.w == Float(dark ? 0.22 : 0.16))
            #expect(pair.eye.roughness.contents as? Double == 0.14 && pair.eye.clearCoat.contents as? Double == 1.0)
            #expect(HeadTreatment.pack(pair.eye, "headB")?.x == 2)
            let gem = HeadTreatment.materials(style: .ceramic, eyes: .gem, scheme: .dark, hue: .buds, anatomy: nil, debugEyes: false).eye
            #expect(gem.clearCoat.contents as? Double == 1)
        }
    }
    @Test func lightingOverridesApplyToHeadOnly() throws {
        for preset in Studio.Preset.allCases {
            let studio = Studio(preset: preset); studio.update(hue: .control, scheme: .dark)
            let key = try #require(studio.scene.rootNode.childNode(withName: "key", recursively: false))
            let fill = try #require(studio.scene.rootNode.childNode(withName: "fill", recursively: false)?.light)
            #expect(abs((studio.camera.camera?.screenSpaceAmbientOcclusionIntensity ?? 0) - (preset == .head ? 0.15 : 2.6)) < 1e-6)
            #expect(key.light?.shadowRadius == (preset == .head ? 44 : 28))
            // Round 4: high-key head, ~2:1. The bust is lit at display level (scaled, with its exposure
            // boost cancelling the camera's offset) so the clamped colour buffer keeps the dye's hue.
            #expect(abs(fill.intensity - (preset == .head ? 520 : 170) * Studio.lightScale(preset, dark: true)) < 1e-6)
            if preset == .head {
                #expect(abs(key.position.x + 2.4) < 1e-6 && abs(key.position.y - 2.9) < 1e-6 && abs(key.position.z - 4.4) < 1e-6)
                studio.update(hue: .control, scheme: .light)
                #expect(abs(fill.intensity - 480 * Studio.lightScale(.head, dark: false)) < 1e-6)
                #expect(abs((studio.camera.camera?.exposureOffset ?? 1) - (Studio.cameraSettings.exposureLight + Studio.exposureBoost(.head, dark: false))) < 1e-6)
                #expect(abs(studio.camera.camera?.exposureOffset ?? 1) < 1e-6, "the bust is shown at the level it is lit")
            }
        }
    }
}
