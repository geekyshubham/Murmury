import SceneKit
import SwiftUI

enum ModelHeroState: String {
    case untrained, training, ready, failed
    func rotationRate(reduceMotion: Bool) -> Double {
        if reduceMotion { return 0 }
        switch self { case .training: return 0.8; case .ready: return 0.12; default: return 0 }
    }
    /// Beads glow (above the bloom threshold) once the model is ready.
    func beadIntensity(index: Int, time: Double, reduceMotion: Bool) -> CGFloat {
        switch self {
        case .untrained: return 0.25
        case .failed: return 0.2
        case .ready: return 2.2
        case .training: return reduceMotion ? 1 : (Int(time * 4) % 8 == index ? 2.2 : 0.25)
        }
    }
    /// The core's own light: faint until trained, pulsing while training.
    func coreEmission(time: Double, reduceMotion: Bool) -> CGFloat {
        switch self {
        case .untrained, .failed: return 0.1
        case .ready: return 0.2
        case .training: return reduceMotion ? 0.15 : 0.15 + 0.08 * sin(time * 2 * .pi / 1.4)
        }
    }
}
enum ModelHeroKind { case ribbons, atom }
struct ModelAvatar: View {
    var state: ModelHeroState
    var labelCount = 3
    /// The user's gestures, one band each (see `GestureSignature`); empty bands stay plain rings.
    var signatures: [MotionRibbons.Signature] = []
    var gestureNames: [String] = []
    var kind = ModelHeroKind.ribbons
    /// What VoiceOver hears: the state, then which gesture each band is (innermost first).
    var spokenLabel: String {
        let bands = gestureNames.prefix(5)
        return "Model, " + state.rawValue + (bands.isEmpty ? ", no gestures yet" : ". Bands, innermost first: " + bands.joined(separator: ", "))
    }
    var body: some View {
        if ProcessInfo.processInfo.environment["MURMURY_OFFLINE"] == "1" { Color.clear.accessibilityLabel("Model: unavailable offline") } else { ProductSceneView(kind: .model, modelState: state, modelLabels: labelCount, modelSignatures: signatures, modelKind: kind, label: spokenLabel)
        .mask(HeroMask.ProductShape()).heroBackdrop(hue: .model) } }
}
final class AtomRig {
    enum Part { case core, rings }
    /// Ring material: light satin metal in both appearances (a darker light-mode ring could not
    /// separate from the glossy core; see the Phase 3 checkpoint).
    static func ringColor(dark: Bool) -> RGB { RGB(0xCFC9DE) }
    static let pipeRadius: CGFloat = 0.035
    let root = SCNNode()
    private let core = SCNNode(geometry: SCNSphere(radius: 0.5))
    private let orbit = SCNNode()
    private var rings: [SCNGeometry] = []
    private var beads: [SCNMaterial] = []
    private var scheme: ColorScheme?
    private var angle = 0.0
    init() {
        root.addChildNode(core); root.addChildNode(orbit)
        core.name = "core"
        (core.geometry as? SCNSphere)?.segmentCount = 96
        let hue = Hue.model
        // A dark glossy core: the base hue deepened, under a full clear coat.
        let coreMaterial = StudioMaterials.surface(hue.orbRGB.mixed(with: RGB(0x000000), fraction: 0.40).nsColor, roughness: 0.18)
        coreMaterial.clearCoat.contents = 1.0; coreMaterial.clearCoatRoughness.contents = 0.05
        coreMaterial.emission.contents = NSColor(hue.a)
        core.geometry?.materials = [coreMaterial]
        for (index, radius) in [0.95, 1.15, 1.35].enumerated() {
            let torus = SCNTorus(ringRadius: radius, pipeRadius: Self.pipeRadius)
            torus.ringSegmentCount = 144; torus.pipeSegmentCount = 24
            let ring = SCNNode(geometry: torus); ring.name = "ring"
            ring.eulerAngles = SCNVector3([20.0, -35, 60][index] * .pi / 180, Double(index) * 0.65, 0.3)
            orbit.addChildNode(ring); rings.append(torus)
            for n in 0..<(index == 2 ? 2 : 3) {
                let sphere = SCNSphere(radius: 0.06); sphere.segmentCount = 32
                let bead = SCNNode(geometry: sphere); bead.name = "bead"
                let a = Double(n) * 2 * .pi / 3 + Double(index)
                bead.position = SCNVector3(radius * cos(a), 0, radius * sin(a))
                let material = StudioMaterials.surface(RGB(0xF2F0F6).nsColor, roughness: 0.3)
                material.emission.contents = NSColor(hue.a)
                bead.geometry?.materials = [material]
                beads.append(material); ring.addChildNode(bead)
            }
        }
    }
    /// Evidence only: shows one part so its material can be measured alone.
    func isolate(_ part: Part?) {
        core.isHidden = part == .rings
        orbit.isHidden = part == .core
        orbit.enumerateChildNodes { node, _ in if node.name == "bead" { node.isHidden = part == .rings } }
    }
    func apply(state: ModelHeroState, scheme: ColorScheme, time: Double, dt: Double, reduceMotion: Bool) {
        if self.scheme != scheme {
            self.scheme = scheme
            let m = StudioMaterials.surface(Self.ringColor(dark: scheme == .dark).nsColor, roughness: 0.30, metal: 0.85)
            rings.forEach { $0.materials = [m] }
        }
        core.geometry?.firstMaterial?.emission.intensity = state.coreEmission(time: time, reduceMotion: reduceMotion)
        angle += state.rotationRate(reduceMotion: reduceMotion) * dt
        orbit.eulerAngles.y = reduceMotion ? 0 : CGFloat(angle)
        for (index, material) in beads.enumerated() {
            material.emission.intensity = state.beadIntensity(index: index, time: time, reduceMotion: reduceMotion)
        }
    }
}

/// Default ribbon hero with the previous atom available for one round.
final class ModelRig {
    enum Part { case core, rings }
    let root: SCNNode
    private let atom: AtomRig?
    private let core = SCNNode(geometry: SCNSphere(radius: 0.42))
    private var ribbons: [SCNNode] = []
    private var materials: [SCNMaterial] = []
    private var lastWarning: Bool?
    private var lastScheme: ColorScheme?
    private(set) var labelCount = 0
    private(set) var signatures: [MotionRibbons.Signature] = []
    private(set) var cometTransforms: [Double] = []
    private(set) var cometIntensities: [Double] = []
    init(labelCount: Int = 3, kind: ModelHeroKind = .ribbons) {
        if kind == .atom {
            let old = AtomRig(); atom = old; root = old.root
        } else {
            atom = nil; root = SCNNode(); root.name = "motionRibbons"
            core.name = "core"; root.addChildNode(core)
            (core.geometry as? SCNSphere)?.segmentCount = 96
            core.geometry?.materials = [Self.coreMaterial()]
            setLabelCount(labelCount)
            apply(state: .untrained, scheme: .dark, time: 0, dt: 0, reduceMotion: true)
        }
    }
    /// The core: glossy candy ceramic in the section's colours (light hue at the top deepening to the
    /// second hue below), clearly a different material from the polished silver bands around it.
    static let coreRoughness = 0.24
    static let ribbonColor = RGB(0xCBC3EC), ribbonRoughness = 0.28, ribbonMetal = 0.65
    static func coreMaterial() -> SCNMaterial {
        let top = Hue.model.aRGB.mixed(with: RGB(0xFFFFFF), fraction: 0.22), bottom = Hue.model.bRGB.mixed(with: RGB(0x000000), fraction: 0.10)
        let gradient = NSImage(size: NSSize(width: 4, height: 256), flipped: false) { rect in
            NSGradient(starting: bottom.nsColor, ending: top.nsColor)?.draw(in: rect, angle: 90)
            return true
        }
        let m = StudioMaterials.surface(top.nsColor, roughness: coreRoughness)
        m.diffuse.contents = gradient
        m.clearCoat.contents = 0.9; m.clearCoatRoughness.contents = 0.06
        return m
    }
    func setLabelCount(_ count: Int, signatures: [MotionRibbons.Signature] = []) {
        let count = min(5, max(3, count))
        guard atom == nil, count != labelCount || signatures != self.signatures else { return }
        labelCount = count; self.signatures = signatures
        ribbons.forEach { $0.removeFromParentNode() }; ribbons = []; materials = []
        for curve in MotionRibbons.curves(labelCount: count, signatures: signatures) {
            let node = SCNNode(geometry: MotionRibbons.geometry(curve)); node.name = "ribbon"
            // Lavender satin metal: tinted to the section so it joins the core, polished enough that the
            // rounded band carries a light-to-shade gradient across its face instead of a flat grey.
            let m = StudioMaterials.surface(Self.ribbonColor.nsColor, roughness: Self.ribbonRoughness, metal: Self.ribbonMetal)
            m.shaderModifiers = nil // HDR emission must stay above the studio bloom threshold.
            m.emission.wrapS = .repeat; m.emission.wrapT = .repeat
            node.geometry?.materials = [m]; root.addChildNode(node); ribbons.append(node); materials.append(m)
        }
        lastWarning = nil
    }
    func isolate(_ part: Part?) {
        if let atom { atom.isolate(part.map { $0 == .core ? .core : .rings }); return }
        core.isHidden = part == .rings; ribbons.forEach { $0.isHidden = part == .core }
    }
    func apply(state: ModelHeroState, scheme: ColorScheme, time: Double, dt: Double, reduceMotion: Bool) {
        if let atom { atom.apply(state: state, scheme: scheme, time: time, dt: dt, reduceMotion: reduceMotion); return }
        let warn = state == .failed
        if lastWarning != warn || lastScheme != scheme {
            lastWarning = warn; lastScheme = scheme
            let color = warn ? (scheme == .dark ? Palette.dark : .light).warn : RGB(0xFFFFFF)
            let texture = MotionRibbons.cometTexture(color: color)
            for m in materials { m.emission.contents = texture }
        }
        cometTransforms = []; cometIntensities = []
        for (index, m) in materials.enumerated() {
            let rate = state.rotationRate(reduceMotion: reduceMotion)
            let phase = (state == .failed || reduceMotion ? 0 : time * rate).truncatingRemainder(dividingBy: 1)
            let intensity = state == .untrained || (state == .failed && index != 0) ? 0.0 : 2.2
            m.emission.contentsTransform = SCNMatrix4MakeTranslation(CGFloat(-phase), 0, 0)
            m.emission.intensity = CGFloat(intensity)
            // Distinct planes before training, one shared alignment once trained. Radial lanes
            // occupy disjoint spherical shells even when their planes differ.
            let x = state == .untrained ? 35 + Double(index) * 13 : 50
            let y = state == .untrained ? (Double(index) - Double(labelCount - 1) / 2) * 12 : 0
            let z = state == .untrained ? (Double(index) - Double(labelCount - 1) / 2) * 8 : -18
            ribbons[index].eulerAngles = SCNVector3(x * .pi / 180, y * .pi / 180, z * .pi / 180)
            cometTransforms.append(phase); cometIntensities.append(intensity)
        }
    }
}
