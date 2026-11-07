import AppKit
import SceneKit
import SwiftUI

/// Shared materials. Only LED materials exceed the bloom threshold.
enum StudioMaterials {
    /// A soft highlight knee instead of a hard clamp: values above 0.86 rise at a third of the rate.
    static let knee = """
    #pragma body
    float3 c = _output.color.rgb;
    _output.color.rgb = select(c, 0.86 + (c - 0.86) * 0.35, c > 0.86);
    """
    static func surface(_ color: NSColor, roughness: CGFloat, metal: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = metal
        m.shaderModifiers = [.fragment: knee]
        return m
    }
    /// Round-1 glossy porcelain, kept for `HeadTreatment.Style.legacy`.
    static func porcelain(_ scheme: ColorScheme, hue: Hue = .control) -> SCNMaterial {
        let m = surface(RGB(scheme == .dark ? 0xECE8F6 : 0xF5F2FB).nsColor, roughness: 0.30)
        m.clearCoat.contents = 0.6; m.clearCoatRoughness.contents = 0.12
        m.shaderModifiers = [.fragment: HeadMesh.rimShader]
        m.setValue(NSNumber(value: 3.4), forKey: "rimPower")
        let strength = scheme == .dark ? 0.45 : 0.25
        m.setValue(NSValue(scnVector3: SCNVector3(hue.aRGB.r * strength, hue.aRGB.g * strength, hue.aRGB.b * strength)), forKey: "rimColor")
        return m
    }
    static func pearlPlastic() -> SCNMaterial {
        let m = surface(RGB(0xF2F0F6).nsColor, roughness: 0.30)
        m.clearCoat.contents = 0.45; m.clearCoatRoughness.contents = 0.18
        return m
    }
    /// Galaxy Buds3 Pro Silver as the reference renders show it: satin metal with broad, soft
    /// highlights, never mirror chrome.
    static func buds3ProSilver() -> SCNMaterial {
        let m = surface(RGB(0x7C8086).nsColor, roughness: 0.6, metal: 0.65)
        m.clearCoat.contents = 0.1; m.clearCoatRoughness.contents = 0.4
        m.shaderModifiers = nil
        return m
    }
    /// The foot cap: paler, finer-polished silver than the housing.
    static func budsCap() -> SCNMaterial {
        let m = surface(RGB(0xD5D8DC).nsColor, roughness: 0.35, metal: 0.6)
        m.shaderModifiers = nil
        return m
    }
    /// The silicone tip: cool charcoal with a faint sheen, so its rounded form reads without going muddy.
    static func budsTip() -> SCNMaterial {
        let m = surface(RGB(0x2C2E34).nsColor, roughness: 0.74)
        m.clearCoat.contents = 0.12; m.clearCoatRoughness.contents = 0.55
        m.shaderModifiers = nil
        return m
    }
    /// Inside the tip's bore: darker than the outside.
    static func budsBore() -> SCNMaterial {
        let m = surface(RGB(0x121315).nsColor, roughness: 0.9)
        m.shaderModifiers = nil
        return m
    }
    /// Perforated acoustic mesh: near-black with a fine hexagonal hole pattern, `tiles` repeats across.
    static func budsGrille(tiles: CGFloat) -> SCNMaterial {
        let m = surface(NSColor.white, roughness: 0.75)
        m.shaderModifiers = nil
        m.diffuse.contents = grilleImage()
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(tiles, tiles, 1)
        return m
    }
    static func grilleImage() -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            RGB(0x2B2D31).nsColor.setFill(); rect.fill()
            RGB(0x08080A).nsColor.setFill()
            let pitch: CGFloat = 16, radius: CGFloat = 5.2
            for row in 0..<10 {
                let y = CGFloat(row) * pitch * 0.866
                for column in -1..<9 {
                    let x = CGFloat(column) * pitch + (row % 2 == 0 ? 0 : pitch / 2)
                    NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)).fill()
                }
            }
            return true
        }
    }
    /// The wear sensor's window: glossy near-black.
    static func budsSensor() -> SCNMaterial {
        let m = surface(RGB(0x141518).nsColor, roughness: 0.15)
        m.clearCoat.contents = 0.8; m.clearCoatRoughness.contents = 0.05
        m.shaderModifiers = nil
        return m
    }
    static func budsHousing() -> SCNMaterial {
        let m = surface(RGB(0xDCDCE2).nsColor, roughness: 0.12, metal: 1)
        m.clearCoat.contents = 0.6; m.clearCoatRoughness.contents = 0.04
        return m
    }
    static func budsBlade(outer: Bool) -> SCNMaterial {
        let m = budsHousing(); m.roughness.contents = outer ? 0.06 : 0.16; return m
    }
    static func budsCase() -> SCNMaterial { surface(RGB(0xE4E3EA).nsColor, roughness: 0.20, metal: 0.85) }
    static func budsLid() -> SCNMaterial {
        let m = surface(RGB(0x2E2B36).nsColor, roughness: 0.03)
        m.transparency = 0.35; m.transparencyMode = .dualLayer; m.fresnelExponent = 2
        m.clearCoat.contents = 1; m.clearCoatRoughness.contents = 0.02
        m.writesToDepthBuffer = false
        return m
    }
    /// The smoked glass lane down the ridge: near-black, a restrained reflection.
    static func bladeGlass() -> SCNMaterial {
        let m = surface(RGB(0x23272D).nsColor, roughness: 0.2)
        m.clearCoat.contents = 0.6; m.clearCoatRoughness.contents = 0.1
        m.shaderModifiers = nil
        return m
    }
    /// The Blade Light's diffuser: frosted pale grey when off; emission is set when the buds are live.
    static func bladeLight() -> SCNMaterial {
        let m = surface(RGB(0xC4C9D2).nsColor, roughness: 0.35)
        m.shaderModifiers = nil
        m.emission.contents = NSColor.black
        return m
    }
}

/// One camera, light rig and environment shared by every hero, tuned per subject.
final class Studio {
    enum Preset: CaseIterable { case head, buds, model, icon }

    /// Filmic camera: HDR, a little exposure headroom, bloom only for emissive LEDs, soft contact AO.
    struct CameraSettings: Equatable {
        var exposureDark = -1.0, exposureLight = -1.1
        var whitePoint = 1.4, averageGray = 0.18, contrast = 0.10
        /// Compared before exposure: only emissive LEDs and beads (2.2 and up) bloom.
        var bloomIntensity = 0.6, bloomThreshold = 1.6, bloomBlurRadius = 10.0
        var ssaoIntensity = 2.6, ssaoRadiusFraction = 0.06, ssaoBias = 0.02, ssaoDepthThreshold = 0.15, ssaoNormalThreshold = 0.25
    }
    static let cameraSettings = CameraSettings()
    static func cameraSettings(for preset: Preset) -> CameraSettings {
        var settings = cameraSettings
        if preset == .head { settings.ssaoIntensity = 0.15 }  // soft creases: no dark nostrils or pinched mouth corners
        return settings
    }
    /// Pearl-white products read as white, not grey: they sit a quarter stop brighter than the bust.
    static func exposureBoost(_ preset: Preset, dark: Bool = false) -> Double {
        // Chrome reads by its contrast: only a quarter stop over the bust, so the studio's dark
        // bands stay dark and the strip reflections stay just under clipping.
        switch preset {
        case .buds: dark ? 0.2 : 0.15
        case .icon: dark ? 0 : 0.25
        case .head, .model: dark ? 1.0 : 1.1  // shown at the level they are lit; see `lightScale`
        }
    }
    /// The colour buffer clamps at 1.0 before exposure is applied, so a coloured surface lit above
    /// 1.0 clips to neutral grey and exposure only darkens the grey (the old "grey mannequin").
    /// The bust and the Model core are lit at the level they are shown (their exposure boost cancels
    /// the camera's negative offset) so their hues survive.
    static func lightScale(_ preset: Preset, dark: Bool) -> Double { preset == .head || preset == .model ? (dark ? 0.5 : 0.47) : 1 }
    /// Image-based light: low enough that the key models the face's planes.
    static let environmentDark = 0.38, environmentLight = 0.50
    /// The product set's two near strip softboxes (lumens).
    static let stripIntensity: CGFloat = 5000
    /// Polished metal is only as bright as what it reflects: products get a brighter studio.
    static let productEnvironmentDark = 1.6, productEnvironmentLight = 1.7
    /// A wide penumbra: the key models the face without hard-edged shadows.
    static let keyShadowRadius: CGFloat = 28

    struct Framing: Equatable {
        var fieldOfView: Double
        var position: SCNVector3
        var target: SCNVector3
        /// The subject's height in scene units (scales the AO radius).
        var subjectHeight: Double
        static func == (a: Framing, b: Framing) -> Bool {
            a.fieldOfView == b.fieldOfView && SCNVector3EqualToVector3(a.position, b.position)
                && SCNVector3EqualToVector3(a.target, b.target) && a.subjectHeight == b.subjectHeight
        }
    }
    static func framing(_ preset: Preset) -> Framing {
        switch preset {
        case .head: Framing(fieldOfView: 20.5, position: SCNVector3(0, 0.0, 8.2), target: SCNVector3(0, -0.10, 0), subjectHeight: 2.67)
        // The floating pair (≈ 1.3 tall): close and about 15° above, like Samsung's product shot.
        case .buds: Framing(fieldOfView: 24, position: SCNVector3(0, 1.35, 7.1), target: SCNVector3(0, -0.6, 0), subjectHeight: 1.5)
        case .model: Framing(fieldOfView: 26, position: SCNVector3(0, 0.1, 8.6), target: SCNVector3(0, -0.05, 0), subjectHeight: 2.8)
        case .icon: Framing(fieldOfView: 20, position: SCNVector3(0, 0.3, 7.6), target: SCNVector3(0, -0.2, 0), subjectHeight: 1.6)
        }
    }

    struct LightSpec: Equatable {
        enum Kind: Equatable { case spot(inner: Double, outer: Double), directional, ambient }
        var name: String
        var kind: Kind
        var position: SCNVector3
        var intensityDark: Double
        var intensityLight: Double
        var temperature: Double?
        static func == (a: LightSpec, b: LightSpec) -> Bool {
            a.name == b.name && a.kind == b.kind && SCNVector3EqualToVector3(a.position, b.position)
                && a.intensityDark == b.intensityDark && a.intensityLight == b.intensityLight && a.temperature == b.temperature
        }
    }
    static let lights: [LightSpec] = [
        LightSpec(name: "key", kind: .spot(inner: 30, outer: 70), position: SCNVector3(-3.4, 3.4, 3.2), intensityDark: 1000, intensityLight: 1000, temperature: 5200),
        LightSpec(name: "fill", kind: .directional, position: SCNVector3(3.0, 0.2, 3.2), intensityDark: 170, intensityLight: 170, temperature: 7500),
        LightSpec(name: "kicker", kind: .spot(inner: 30, outer: 70), position: SCNVector3(0, 4.2, -3.2), intensityDark: 420, intensityLight: 420, temperature: nil),
        LightSpec(name: "rimLeft", kind: .spot(inner: 20, outer: 60), position: SCNVector3(-3.0, 1.0, -2.2), intensityDark: 650, intensityLight: 380, temperature: nil),
        LightSpec(name: "rimRight", kind: .spot(inner: 20, outer: 60), position: SCNVector3(3.0, 1.0, -2.2), intensityDark: 650, intensityLight: 380, temperature: nil),
        // A soft, hue-tinted bounce from below and in front: in dark, the bust glows against the field.
        LightSpec(name: "bounce", kind: .directional, position: SCNVector3(0, -3.0, 2.6), intensityDark: 150, intensityLight: 0, temperature: nil),
        LightSpec(name: "ambient", kind: .ambient, position: SCNVector3Zero, intensityDark: 25, intensityLight: 40, temperature: nil),
    ]

    static func lightSpecs(for preset: Preset) -> [LightSpec] {
        lights.map { spec in
            var result = spec
            if preset == .head {
                if spec.name == "key" { result.position = SCNVector3(-2.4, 2.9, 4.4) }
                // High-key, like CleanMyMac's hero objects: ~2:1 key-to-fill so the shadow side stays ceramic, not grey.
                if spec.name == "fill" { result.intensityDark = 520; result.intensityLight = 480 }
                if spec.name == "ambient" { result.intensityDark = 60; result.intensityLight = 70 }
                // A soft fill from below and in front lifts nostril and mouth-corner cavities, so the
                // face reads sculpted rather than carved.
                if spec.name == "bounce" { result.intensityDark = 220; result.intensityLight = 140 }
                // A faint kicker: enough to separate the crown from the field, never a white band on it.
                if spec.name == "kicker" { result.intensityDark = 60; result.intensityLight = 50 }
            }
            if preset == .buds {
                // Satin metal under big soft sources, as in the reference renders: spot lights only
                // shape the form; the environment and the strip softboxes carry the reflections.
                if spec.name == "key" { result.intensityDark = 320; result.intensityLight = 320 }
                if spec.name == "kicker" { result.intensityDark = 60; result.intensityLight = 60 }
                if spec.name == "rimLeft" || spec.name == "rimRight" { result.intensityDark = 250; result.intensityLight = 180 }
            }
            return result
        }
    }

    let scene = SCNScene()
    let camera = SCNNode()
    let preset: Preset
    private var lightNodes: [String: SCNNode] = [:]
    private var lastHue: Hue?
    private var lastScheme: ColorScheme?

    init(preset: Preset = .head) {
        #if DEBUG
        BodyCounters.record("SceneBuild")
        #endif
        self.preset = preset
        scene.background.contents = NSColor.clear
        let cam = SCNCamera()
        let s = Self.cameraSettings(for: preset), f = Self.framing(preset)
        cam.fieldOfView = f.fieldOfView
        cam.wantsHDR = true; cam.wantsExposureAdaptation = false
        cam.whitePoint = s.whitePoint; cam.averageGray = s.averageGray; cam.contrast = s.contrast
        cam.bloomIntensity = s.bloomIntensity; cam.bloomThreshold = s.bloomThreshold; cam.bloomBlurRadius = s.bloomBlurRadius
        cam.screenSpaceAmbientOcclusionIntensity = s.ssaoIntensity
        cam.screenSpaceAmbientOcclusionRadius = s.ssaoRadiusFraction * f.subjectHeight
        cam.screenSpaceAmbientOcclusionBias = s.ssaoBias
        cam.screenSpaceAmbientOcclusionDepthThreshold = s.ssaoDepthThreshold
        cam.screenSpaceAmbientOcclusionNormalThreshold = s.ssaoNormalThreshold
        camera.camera = cam
        camera.position = f.position
        camera.look(at: f.target)
        scene.rootNode.addChildNode(camera)
        for spec in Self.lightSpecs(for: preset) {
            let light = SCNLight()
            let node = SCNNode(); node.name = spec.name; node.light = light; node.position = spec.position
            switch spec.kind {
            case .spot(let inner, let outer):
                light.type = .spot; light.spotInnerAngle = inner; light.spotOuterAngle = outer
                node.look(at: SCNVector3(0, -0.1, 0))
            case .directional:
                light.type = .directional; node.look(at: SCNVector3Zero)
            case .ambient:
                light.type = .ambient
            }
            if let k = spec.temperature { light.temperature = k }
            if spec.name == "key" {
                light.castsShadow = true
                light.shadowMode = .forward
                light.shadowSampleCount = 8  // The plan's first GPU step-down (16 cost ~20% over the Phase 0 baseline)
                light.shadowRadius = preset == .head ? 44 : Self.keyShadowRadius
                light.shadowMapSize = CGSize(width: 2048, height: 2048)
                light.shadowColor = NSColor(white: 0, alpha: 0.5)
            }
            scene.rootNode.addChildNode(node)
            lightNodes[spec.name] = node
        }
        if preset == .buds {
            // Products sit on the backdrop's soft floor pool: a shadow map at this scale only aliases.
            lightNodes["key"]?.light?.castsShadow = false
            // Two tall strip softboxes close to the set: a near light (unlike the environment, which is
            // at infinity) lays a bright stripe down a flat polished face, as in product photography.
            for (name, x) in [("stripLeft", -1.5), ("stripRight", 1.7)] {
                let light = SCNLight(); light.type = .area; light.areaType = .rectangle
                light.areaExtents = simd_float3(0.22, 2.2, 0); light.drawsArea = false
                light.intensity = Self.stripIntensity; light.color = NSColor(white: 1, alpha: 1)
                let node = SCNNode(); node.name = name; node.light = light
                node.position = SCNVector3(x, 0.4, 2.4); node.look(at: SCNVector3(0, 0.1, 0))
                scene.rootNode.addChildNode(node)
                lightNodes[name] = node
            }
        }
    }

    func update(hue: Hue, scheme: ColorScheme) {
        guard hue != lastHue || scheme != lastScheme else { return }
        lastHue = hue; lastScheme = scheme
        let dark = scheme == .dark
        camera.camera?.exposureOffset = (dark ? Self.cameraSettings.exposureDark : Self.cameraSettings.exposureLight) + Self.exposureBoost(preset, dark: dark)
        let scale = Self.lightScale(preset, dark: dark)
        for spec in Self.lightSpecs(for: preset) { lightNodes[spec.name]?.light?.intensity = (dark ? spec.intensityDark : spec.intensityLight) * scale }
        // Products keep white rims (coloured edges read as a render, not a photograph of silver).
        let neutralRims = preset == .buds
        lightNodes["rimLeft"]?.light?.color = neutralRims ? NSColor(white: 0.4, alpha: 1) : hue.aRGB.nsColor
        lightNodes["rimRight"]?.light?.color = neutralRims ? NSColor(white: 0.4, alpha: 1) : hue.bRGB.nsColor
        lightNodes["bounce"]?.light?.color = hue.bRGB.mixed(with: RGB(0xFFFFFF), fraction: 0.5).nsColor
        lightNodes["ambient"]?.light?.color = hue.bRGB.mixed(with: (dark ? Palette.dark : Palette.light).night, fraction: 0.6).nsColor
        let product = preset == .buds || preset == .icon
        scene.lightingEnvironment.contents = Self.environment(hue: hue, dark: dark, productStrips: product)
        scene.lightingEnvironment.intensity = product ? (dark ? Self.productEnvironmentDark : Self.productEnvironmentLight)
                                                      : (dark ? Self.environmentDark : Self.environmentLight) * scale
    }

    /// 512x256 equirectangular studio: a dim gradient, one feathered softbox, two soft hue strips.
    static func environment(hue: Hue, dark: Bool, productStrips: Bool = false) -> NSImage {
        #if DEBUG
        BodyCounters.record("EnvironmentBuild")
        #endif
        return NSImage(size: NSSize(width: 512, height: 256), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            // Products reflect a neutral studio, so silver stays silver whatever the section's hue.
            // Product photography: a bright studio above, a darker floor below, so polished silver
            // reads light with crisp contrast rather than mid-grey.
            if productStrips {
                // A soft product set, as in the reference renders: one smooth sweep from a light
                // ceiling to a mid-grey floor, with no horizon band, so satin metal shades evenly.
                let stops: [(RGB, CGFloat)] = [(RGB(0xBEBEC3), 0), (RGB(0xA3A3A9), 0.35), (RGB(0x86868D), 0.55), (RGB(0x66666D), 1)]
                if let g = CGGradient(colorsSpace: space, colors: stops.map { $0.0.nsColor.cgColor } as CFArray, locations: stops.map(\.1)) {
                    cg.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: 0), options: [])
                }
            } else {
                let top = dark ? hue.worldTopRGB.mixed(with: RGB(0xFFFFFF), fraction: 0.10) : RGB(0x8C86A0)
                let bottom = dark ? hue.worldBottomRGB.mixed(with: RGB(0xFFFFFF), fraction: 0.10) : RGB(0x5E5872)
                if let g = CGGradient(colorsSpace: space, colors: [top.nsColor.cgColor, bottom.nsColor.cgColor] as CFArray, locations: [0, 1]) {
                    cg.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: 0), options: [])
                }
            }
            func soft(_ color: NSColor, alpha: CGFloat, centre: CGPoint, radii: CGSize, feather: CGFloat) {
                cg.saveGState()
                cg.translateBy(x: centre.x, y: centre.y)
                cg.scaleBy(x: 1, y: radii.height / radii.width)
                let inner = max(0, radii.width - feather)
                if let g = CGGradient(colorsSpace: space, colors: [color.withAlphaComponent(alpha).cgColor, color.withAlphaComponent(alpha).cgColor,
                                                                   color.withAlphaComponent(0).cgColor] as CFArray,
                                      locations: [0, inner / radii.width, 1]) {
                    cg.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radii.width, options: [])
                }
                cg.restoreGState()
            }
            soft(NSColor(white: 0.75, alpha: 1), alpha: productStrips ? 0.7 : 1, centre: CGPoint(x: 255, y: 205), radii: CGSize(width: 110, height: 40), feather: 40)
            soft(productStrips ? NSColor(white: 0.9, alpha: 1) : hue.aRGB.nsColor, alpha: productStrips ? 0.5 : 0.30,
                 centre: CGPoint(x: 52, y: 137), radii: CGSize(width: 38, height: 88), feather: 20)
            soft(productStrips ? NSColor(white: 0.9, alpha: 1) : hue.bRGB.nsColor, alpha: productStrips ? 0.5 : 0.30,
                 centre: CGPoint(x: 462, y: 137), radii: CGSize(width: 38, height: 88), feather: 20)
            if productStrips {
                // Two broad softboxes either side of the camera and a wide one overhead: long,
                // continuous highlights down the stem's faces and one broad sheen across each head.
                for (x, alpha) in [(CGFloat(190), CGFloat(0.45)), (330, 0.4)] {
                    soft(NSColor(white: 1, alpha: 1), alpha: alpha, centre: CGPoint(x: x, y: 150), radii: CGSize(width: 58, height: 112), feather: 54)
                }
                soft(NSColor(white: 1, alpha: 1), alpha: 0.5, centre: CGPoint(x: 256, y: 232), radii: CGSize(width: 200, height: 26), feather: 24)
            }
            return true
        }
    }

    /// A picture, not a control: it never takes keyboard focus, so a sheet or window that holds a
    /// head opens with focus on its content (and VoiceOver doesn't land on a label that changes
    /// with every head movement).
    final class PictureView: SCNView {
        override var acceptsFirstResponder: Bool { false }
    }

    static func view(scene: SCNScene, camera: SCNNode) -> SCNView {
        let view = PictureView(frame: .zero)
        view.scene = scene; view.pointOfView = camera; view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X; view.rendersContinuously = true
        // The display's own rate (120 Hz on ProMotion), so a head turn shows a new pose every refresh.
        view.preferredFramesPerSecond = max(60, NSScreen.main?.maximumFramesPerSecond ?? 60); view.allowsCameraControl = false
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image)
        return view
    }
}
