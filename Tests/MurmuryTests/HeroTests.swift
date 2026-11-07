import AppKit
import SceneKit
import Testing
@testable import MurmuryKit

@MainActor @Suite("Studio heroes")
struct HeroTests {
    @Test func bladeStatesFollowHardwareAndDemoNeverLights() {
        for (state, expected) in [(BudsService.State.disconnected, BudsPresentation.BladeState.off),
                                  (.connecting, .connecting), (.searching, .connecting), (.connected, .connected),
                                  (.streaming, .streaming), (.failed("No"), .off)] {
            let p = BudsPresentation(state: state, isDemo: false, sampleRate: 50, batteryLeft: nil, batteryRight: nil,
                                     placementLeft: .unknown, placementRight: .unknown, sensorSupported: nil)
            #expect(p.bladeState == expected)
            let demo = BudsPresentation(state: state, isDemo: true, sampleRate: 50, batteryLeft: nil, batteryRight: nil,
                                        placementLeft: .unknown, placementRight: .unknown, sensorSupported: nil)
            #expect(demo.bladeState == .off)
        }
        #expect(BudsPresentation.BladeState.connecting.intensity(at: 0, reduceMotion: true) ==
                BudsPresentation.BladeState.connecting.intensity(at: 1.2, reduceMotion: true))
        #expect(BudsPresentation.BladeState.off.intensity(at: 1, reduceMotion: false) == 0)
    }
    @Test func modelAnimationStopsUnderReducedMotion() {
        #expect(ModelHeroState.training.rotationRate(reduceMotion: false) == 0.8)
        for state in [ModelHeroState.untrained, .training, .ready, .failed] {
            #expect(state.rotationRate(reduceMotion: true) == 0)
        }
        #expect(ModelHeroState.training.beadIntensity(index: 0, time: 0, reduceMotion: true) == 1)
        #expect(ModelHeroState.failed.beadIntensity(index: 0, time: 0, reduceMotion: false) == 0.2)
    }
    @Test func recordingHaloAndPorcelainRefreshOnAppearanceChange() throws {
        // Round 2: the halo plane is gone (the backdrop glow carries recording); materials still refresh.
        let rig = HeadRig(assetURL: nil)
        var input = HeadRig.Inputs()
        input.reduceMotion = true; input.recording = true; input.budsLit = true
        rig.apply(input, time: 0)
        #expect(rig.scene.rootNode.childNode(withName: "recording", recursively: false) == nil)
        let skinNode = try #require(rig.scene.rootNode.childNode(withName: "skin", recursively: true))
        let dark = try #require(skinNode.geometry?.firstMaterial)
        input.scheme = .light
        rig.apply(input, time: 0)
        let light = try #require(skinNode.geometry?.firstMaterial)
        #expect(dark !== light)
        let expected = HeadTreatment.finish(HeadTreatment.style, dark: false).albedo
        #expect(light.diffuse.contents as? NSColor == expected.nsColor)
        let recording = HeroBackdrop.layers(hue: .control, dark: false, recording: true)[0].color
        #expect(recording != HeroBackdrop.layers(hue: .control, dark: false, recording: false)[0].color)
    }
    @Test func avatarLimitsDoNotChangeSourcePose() {
        let raw = HeadPose(yaw: 120, pitch: -80, roll: 90)
        let shown = HeadRig.displayPose(raw)
        #expect(shown == HeadPose(yaw: 70, pitch: -35, roll: 30))
        #expect(raw.yaw == 120)
        #expect(HeadRig.displayPose(HeadPose(yaw: .nan, pitch: .infinity)).yaw == 0)
    }
    @Test func missingAssetHasAnchorsAndGeometry() {
        let rig = HeadRig(assetURL: URL(fileURLWithPath: ".build/missing-head.scn"))
        #expect(!rig.usesSculptedAsset)
        for name in ["earLeft", "earRight", "noseTip", "skin"] {
            #expect(rig.scene.rootNode.childNode(withName: name, recursively: true) != nil)
        }
    }
    @Test func suppliedAssetLoadsAndBudsUseAnchors() {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Models/head.scn")
        let rig = HeadRig(assetURL: url)
        #expect(rig.usesSculptedAsset)
        for name in ["earLeft", "earRight"] {
            let anchor = rig.scene.rootNode.childNode(withName: name, recursively: true)
            #expect(anchor?.childNode(withName: "budMount", recursively: false)?.childNode(withName: "bud", recursively: false) != nil)
        }
        #expect(rig.scene.rootNode.childNode(withName: "noseTip", recursively: true)?.childNode(withName: "gaze", recursively: false) != nil)
    }
    @Test func reducedMotionIsSteadyButLivePoseMoves() {
        let rig = HeadRig(assetURL: URL(fileURLWithPath: ".build/missing.scn"))
        var input = HeadRig.Inputs()
        input.reduceMotion = true; input.budsLit = true; input.recording = true
        rig.apply(input, time: 1)
        let blade = rig.scene.rootNode.childNode(withName: "bladeLight", recursively: true)?.geometry?.firstMaterial
        let first = blade?.emission.intensity
        rig.apply(input, time: 2)
        #expect(first == blade?.emission.intensity)
        #expect(rig.displayedPose == HeadPose())
        input.pose = HeadPose(yaw: 30)
        rig.apply(input, time: 3)
        #expect(rig.displayedPose.yaw > 0)
    }
    @Test func budsHaveBladeAndSiliconeAndOnlyLEDEmits() {
        let bud = BudsGeometry.make(side: -1)
        for name in ["body", "nozzle", "silicone", "bladeLight"] {
            #expect(bud.childNode(withName: name, recursively: true)?.geometry != nil)
        }
        #expect((bud.childNode(withName: "body", recursively: true)?.geometry?.firstMaterial?.emission.contents as? NSColor) != NSColor.white)
    }

    @Test func studioPresetsAndCamera() {
        let c = Studio.cameraSettings
        #expect(c.whitePoint == 1.4 && c.averageGray == 0.18 && c.contrast == 0.10)
        #expect(c.bloomIntensity == 0.6 && c.bloomThreshold == 1.6 && c.bloomBlurRadius == 10)
        #expect(c.ssaoRadiusFraction == 0.06 && c.ssaoBias == 0.02 && c.ssaoDepthThreshold == 0.15 && c.ssaoNormalThreshold == 0.25)
        #expect(c.exposureDark == -1.0 && c.exposureLight == -1.1)
        #expect(Studio.framing(.head).fieldOfView == 20.5, "the head fills its hero: crown near the title line, shoulders into the fade")
        #expect(Set(Studio.lights.map(\.name)) == ["key", "fill", "kicker", "rimLeft", "rimRight", "bounce", "ambient"])
        #expect(Studio.lights.first { $0.name == "bounce" }?.intensityLight == 0)
        #expect(Studio.lights.first { $0.name == "key" }?.temperature == 5200)
        for preset in Studio.Preset.allCases {
            // Builds without a GPU: no renderer is needed to make the scene.
            let studio = Studio(preset: preset)
            studio.update(hue: .control, scheme: .dark)
            let cam = studio.camera.camera
            #expect(cam?.wantsHDR == true && cam?.wantsExposureAdaptation == false)
            #expect(abs((cam?.screenSpaceAmbientOcclusionRadius ?? 0) - 0.06 * Studio.framing(preset).subjectHeight) < 1e-6)
            let key = studio.scene.rootNode.childNode(withName: "key", recursively: false)?.light
            // Products sit on the backdrop's floor pool: only the bust and the model take the key's shadow.
            #expect(key?.castsShadow == (preset != .buds) && key?.shadowSampleCount == 8 && key?.shadowMapSize == CGSize(width: 2048, height: 2048))
            // Rims carry the section's hue, except on the silver product, which keeps dim white rims.
            let rim = studio.scene.rootNode.childNode(withName: "rimLeft", recursively: false)?.light?.color as? NSColor
            #expect(rim == (preset == .buds ? NSColor(white: 0.4, alpha: 1) : Hue.control.aRGB.nsColor))
        }
    }
    @Test func treatmentConstantsPerAppearance() {
        #expect(HeadTreatment.finish(.satin, dark: true) == .init(albedo: RGB(0xCEC8DE), roughness: 0.55, rimStrength: 0.85, rimPower: 2.2))
        #expect(HeadTreatment.finish(.satin, dark: false) == .init(albedo: RGB(0xBEB6D4), roughness: 0.60, rimStrength: 0.38))
        #expect(HeadTreatment.finish(.graphite, dark: true).albedo == RGB(0x8F88A6))
        #expect(HeadTreatment.finish(.graphite, dark: false).albedo == RGB(0xA79FC0))
        for style in [HeadTreatment.Style.satin, .graphite] {
            let f = HeadTreatment.finish(style, dark: true)
            #expect(f.clearCoat == 0.10 && f.clearCoatRoughness == 0.40 && f.rimPower == 2.2)
            #expect(HeadTreatment.finish(style, dark: false).rimPower == 2.6)
        }
        #expect(HeadTreatment.style != .legacy)
        let m = HeadTreatment.materials(style: .graphite, eyes: .iris, scheme: .dark, hue: .control, anatomy: nil, debugEyes: false)
        #expect(m.skin.lightingModel == .physicallyBased && m.skin.metalness.contents as? Double == 0)
        #expect(m.skin.shaderModifiers?[.geometry]?.contains("out.objPos = _geometry.position.xyz") == true)
        #expect(m.eye !== m.skin)
    }
    @Test func eyesAreSymmetricInsideTheSkinAndInFrontOfTheEars() throws {
        let rig = HeadRig(assetURL: HeroTests.assetURL)
        let skin = try #require(rig.scene.rootNode.childNode(withName: "skin", recursively: true))
        let a = try #require(HeadTreatment.anatomy(of: skin, noseTip: rig.scene.rootNode.childNode(withName: "noseTip", recursively: true)))
        #expect(a.eyes.count == 2)
        let (l, r) = (a.eyes[0], a.eyes[1])
        #expect(abs(l.x + r.x) < 1e-4 && abs(l.y - r.y) < 1e-4 && abs(l.z - r.z) < 1e-4)
        for e in a.eyes {
            #expect(e.x > a.bounds.min.x && e.x < a.bounds.max.x && e.y > a.bounds.min.y && e.y < a.bounds.max.y && e.z < a.bounds.max.z)
            for ear in ["earLeft", "earRight"] {
                let anchor = try #require(rig.scene.rootNode.childNode(withName: ear, recursively: true))
                #expect(Float(skin.convertPosition(anchor.position, from: anchor.parent).z) < e.z)
            }
        }
        #expect(a.chinY < a.eyes[0].y)
    }
    @Test func backdropLayersFadeSoftlyToZero() {
        for hue in Hue.all { for dark in [true, false] { for recording in [true, false] {
            for layer in HeroBackdrop.layers(hue: hue, dark: dark, recording: recording) {
                #expect(layer.alpha(atRadius: 0.98) < 0.005, "\(layer.name)")
                #expect(layer.alpha(atRadius: 1) == 0)
                for (a, b) in zip(layer.stops, layer.stops.dropFirst()) {
                    #expect(b.alpha <= a.alpha && a.alpha - b.alpha <= 0.2 + 1e-9, "\(layer.name) \(a) \(b)")
                }
            }
        } } }
        #expect(HeroBackdrop.scale == 1.3)
        // The mask fades the shoulders out completely before the frame ends.
        #expect(HeroMask.alpha(atY: 0.5) == 1 && HeroMask.alpha(atY: 0.92) == 0 && HeroMask.alpha(x: 0.5, y: 0.4) == 1)
    }
    @Test func bustReachesTheFadeAtExtremePitch() {
        for pitch in [-35.0, 35.0] {
            let rig = HeadRig(assetURL: HeroTests.assetURL)
            var input = HeadRig.Inputs(); input.pose = HeadPose(pitch: pitch); input.idle = false; input.reduceMotion = true
            for step in 0..<40 { rig.apply(input, time: Double(step)) }
            #expect(HeroFraming.projectedBottom(rig: rig, aspect: 1 / PageLayout.visualAspect) >= 0.93, "pitch \(pitch)")
        }
    }
    @Test func chargingCaseStandsOpenWithASmokedLid() {
        let c = BudsGeometry.chargingCase(hue: .buds)
        let hinge = c.childNode(withName: "lidHinge", recursively: false)
        #expect(hinge.map { $0.eulerAngles.x < -1.5 } == true, "lid open past vertical")
        let lid = c.childNode(withName: "lid", recursively: true)?.geometry?.firstMaterial
        #expect(lid.map { $0.transparency < 0.6 && $0.transparencyMode == .dualLayer } == true)
        #expect(c.childNode(withName: "caseBody", recursively: false) != nil)
    }

    @Test func budsAreSmoothAndOnlyLEDsEmit() {
        let bud = BudsGeometry.make(side: 1)
        // A dense, smooth housing (head, nozzle and stem in one surface), not a faceted primitive.
        let body = bud.childNode(withName: "body", recursively: true)?.geometry
        #expect((body?.sources(for: .vertex).first?.vectorCount ?? 0) > 5000)
        #expect((bud.childNode(withName: "nozzle", recursively: true)?.geometry as? SCNCylinder)?.radialSegmentCount == 96)
        // The ridge, head and Blade Light are checked in BudsSpecTests; the light's outline is fine.
        #expect(((bud.childNode(withName: "bladeLight", recursively: true)?.geometry as? SCNShape)?.path?.flatness ?? 1) <= 0.01)
        var emitters: [String] = []
        bud.enumerateChildNodes { node, _ in
            if let c = node.geometry?.firstMaterial?.emission.contents as? NSColor, c.usingColorSpace(.sRGB)?.brightnessComponent ?? 0 > 0 { emitters.append(node.name ?? "") }
        }
        #expect(emitters.isEmpty, "unlit buds emit nothing")
        #expect(BudsGeometry.leds(in: bud).count == 1 && BudsGeometry.spills(in: bud).count == 1)
        let still = ProductSceneView.Coordinator.turntable(time: 3, reduceMotion: true)
        #expect(still.yaw == 0 && still.bob == 0, "Reduce Motion holds the symmetric front shot")
        #expect(ProductSceneView.Coordinator.turntable(time: 1, reduceMotion: false).yaw != ProductSceneView.Coordinator.turntable(time: 3, reduceMotion: false).yaw)
        // Sways ±16° about the front shot over 18 s: peak at t = 4.5 s.
        #expect(abs(ProductSceneView.Coordinator.turntable(time: 4.5, reduceMotion: false).yaw - 16 * .pi / 180) < 1e-9)
        #expect(BudsPresentation.BladeState.connected.intensity(at: 0, reduceMotion: false) > Studio.cameraSettings.bloomThreshold)
    }
    @Test func suppliedBudsModelReplacesTheProceduralOne() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/test-data/buds-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scene = SCNScene()
        for name in ["budLeft", "budRight"] {
            let node = SCNNode(geometry: SCNSphere(radius: 0.4)); node.name = name; scene.rootNode.addChildNode(node)
        }
        let url = directory.appendingPathComponent("buds.scn")
        #expect(scene.write(to: url, options: nil, delegate: nil, progressHandler: nil))
        let loaded = BudsGeometry.pair(assetURL: url)
        #expect(loaded.usesAsset && loaded.left.name == "budLeft" && loaded.right.name == "budRight")
        let fallback = BudsGeometry.pair(assetURL: directory.appendingPathComponent("missing.scn"))
        #expect(!fallback.usesAsset && fallback.left.name == "bud")
    }
    @Test func modelMaterialsSeparateCoreRingsAndBeads() throws {
        // Phase 7: silver ribbon bands and texture comets replace the atom's beads; round 8: a glossy
        // hue core, a clearly different material from the bands.
        let rig = ModelRig(labelCount: 5)
        rig.apply(state: .ready, scheme: .dark, time: 0, dt: 0, reduceMotion: true)
        let core = try #require(rig.root.childNode(withName: "core", recursively: true)?.geometry?.firstMaterial)
        #expect(core.roughness.contents as? Double == ModelRig.coreRoughness && core.transparency == 1, "glossy, opaque candy core")
        #expect((rig.root.childNode(withName: "core", recursively: true)?.geometry as? SCNSphere)?.radius == 0.42)
        let ribbon = try #require(rig.root.childNode(withName: "ribbon", recursively: true)?.geometry?.firstMaterial)
        #expect(ribbon.metalness.contents as? Double == ModelRig.ribbonMetal && ribbon.roughness.contents as? Double == ModelRig.ribbonRoughness)
        #expect(rig.cometIntensities.allSatisfy { $0 > Studio.cameraSettings.bloomThreshold })
        let old = ModelRig(kind: .atom)
        #expect(old.root.childNode(withName: "bead", recursively: true) != nil)
    }
    static let assetURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Models/head.scn")
}

@Suite("Calm expression")
struct HeadExpressionTests {
    /// Smoothing reaches the brow above each eye and (lightly) the mouth corners; never the eyes,
    /// the back of the head or the crown.
    @Test func weightsCoverBrowAndCornersOnly() {
        let a = HeadTreatment.Anatomy(bounds: (SIMD3(-9, 0, -6), SIMD3(9, 24, 10)),
                                      eyes: [SIMD3(-2.5, 15.6, 6.7), SIMD3(2.5, 15.6, 6.7)], eyeRadius: 1.25, chinY: 9.6)
        let w = HeadExpression.weight(anatomy: a, noseY: 13.1)
        #expect(w(SIMD3(-2.5, 15.6 + 1.6, 7)) > 0.5)        // brow above the left eye
        #expect(w(SIMD3(-2.5, 15.6, 6.9)) == 0)             // the eye itself
        #expect(w(SIMD3(0, 22, 4)) == 0)                     // crown
        #expect(w(SIMD3(-2.5, 15.6, -4)) == 0)               // back of the head
        let corner = w(SIMD3(-0.42 * 5, 13.1 + (9.6 - 13.1) * 0.42, 8))
        #expect(corner > 0 && corner <= 0.3)                 // mouth corners, lightly
    }
}

@Suite("Head follow timing")
struct HeadFollowTests {
    /// The same settle per unit time at 30, 60 and 120 Hz; 0.35 per frame at 60 Hz.
    @MainActor @Test func followIsFrameRateIndependent() {
        #expect(abs(HeadRig.follow(dt: 1.0 / 60) - 0.35) < 0.005)
        let at30 = 1 - HeadRig.follow(dt: 1.0 / 30), at120 = pow(1 - HeadRig.follow(dt: 1.0 / 120), 4)
        #expect(abs(at30 - at120) < 1e-9)

    }
}
