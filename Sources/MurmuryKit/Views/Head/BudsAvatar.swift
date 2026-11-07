import AppKit
import SceneKit
import SwiftUI

struct BudsAvatar: View {
    var presentation: BudsPresentation
    var body: some View {
        if ProcessInfo.processInfo.environment["MURMURY_OFFLINE"] == "1" {
            Color.clear.accessibilityLabel("Buds: unavailable offline")
        } else {
        ProductSceneView(kind: .buds, blade: presentation.bladeState, label: "Galaxy Buds3 Pro, " + presentation.chipText)
            .mask(HeroMask.ProductShape())
            .heroBackdrop(hue: .buds)
        }
    }
}

/// Both product heroes use the head's studio, renderer and live accessibility preferences.
struct ProductSceneView: NSViewRepresentable {
    enum Kind { case buds, model }
    var kind: Kind
    var blade = BudsPresentation.BladeState.off
    var modelState = ModelHeroState.untrained
    var modelLabels = 3
    var modelSignatures: [MotionRibbons.Signature] = []
    var modelKind = ModelHeroKind.ribbons
    var label: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> SCNView {
        let coordinator = context.coordinator
        coordinator.build(kind, labelCount: modelLabels, modelKind: modelKind)
        let view = Studio.view(scene: coordinator.studio.scene, camera: coordinator.studio.camera)
        view.delegate = coordinator
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.set(.init(blade: blade, modelState: modelState, scheme: scheme, reduceMotion: reduceMotion, labelCount: modelLabels,
                                      signatures: modelSignatures))
        view.setAccessibilityLabel(label)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    struct Inputs {
        var blade: BudsPresentation.BladeState = .off
        var modelState = ModelHeroState.untrained
        var scheme = ColorScheme.dark
        var reduceMotion = false
        var labelCount = 3
        var signatures: [MotionRibbons.Signature] = []
    }
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        private(set) var studio = Studio()
        private let pair = SCNNode()
        private var leds: [SCNMaterial] = []
        private var spills: [SCNLight] = []
        private var core: ModelRig?
        var modelRig: ModelRig? { core }
        private let lock = NSLock()
        private var inputs = Inputs()
        private var observer: NSObjectProtocol?
        private var lastTime: Double?
        override init() {
            super.init()
            observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.inputs.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
            }
        }
        deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
        func set(_ value: Inputs) { lock.withLock { inputs = value } }
        func build(_ kind: Kind, budsAsset: URL? = BudsGeometry.bundledAssetURL, labelCount: Int = 3, modelKind: ModelHeroKind = .ribbons) {
            studio = Studio(preset: kind == .model ? .model : .buds)
            if kind == .model {
                let rig = ModelRig(labelCount: labelCount, kind: modelKind); core = rig; studio.scene.rootNode.addChildNode(rig.root)
            } else {
                let buds = BudsGeometry.pair(assetURL: budsAsset)
                if buds.usesAsset {
                    for (side, bud) in [(Float(-1), buds.left), (Float(1), buds.right)] {
                        bud.position = SCNVector3(side * 0.62, 0.3, 0)
                        bud.eulerAngles = SCNVector3(0.12, -CGFloat(side) * 35 * .pi / 180, 0)
                        pair.addChildNode(bud)
                        leds += BudsGeometry.leds(in: bud)
                        spills += BudsGeometry.spills(in: bud)
                    }
                } else {
                    // Samsung's front product shot: the pair upright, ridges and Blade Lights toward
                    // the viewer, the cones and ear tips turning outward, the right bud slightly behind.
                    let solo = ProcessInfo.processInfo.environment["MURMURY_BUDS_SOLO"].flatMap(Float.init)  // reference renders
                    for side in [Float(-1), 1] where solo.map({ $0 == side }) ?? true {
                        let bud = BudsGeometry.make(side: side)
                        bud.position = SCNVector3(solo == nil ? side * 0.56 : 0, side < 0 ? 0.05 : 0.0, side < 0 ? 0.06 : -0.06)
                        bud.eulerAngles = SCNVector3(0.06, 0, 0)
                        pair.addChildNode(bud)
                        leds += BudsGeometry.leds(in: bud)
                        spills += BudsGeometry.spills(in: bud)
                    }
                }
                pair.name = "budsPair"
                studio.scene.rootNode.addChildNode(pair)
            }
        }
        /// LED spill on the shell: none. On polished silver any spill floods the whole stem; the
        /// product's light is a crisp strip, so only the strip itself glows (and blooms).
        static let spillIntensity: CGFloat = 0
        /// The Blade Light's thin strip needs extra emission to bloom like the lit product.
        static let ledGain: CGFloat = 3.2
        /// Sways ±16° about Samsung's symmetric front shot over 18 s with a 0.025 bob over 5 s;
        /// Reduce Motion holds the front shot. `MURMURY_BUDS_YAW` (degrees) pins it for reference renders.
        static func turntable(time: Double, reduceMotion: Bool) -> (yaw: Double, bob: Double) {
            if let debug = ProcessInfo.processInfo.environment["MURMURY_BUDS_YAW"].flatMap(Double.init) { return (debug * .pi / 180, 0) }
            return reduceMotion ? (0, 0) : (16 * .pi / 180 * sin(2 * .pi * time / 18), 0.025 * sin(2 * .pi * time / 5))
        }
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let input = lock.withLock { inputs }
            let hue: Hue = core == nil ? .buds : .model
            studio.update(hue: hue, scheme: input.scheme)
            let dt = min(0.1, max(0, time - (lastTime ?? time))); lastTime = time
            let pointer = PointerSignal.shared.snapshot(reduceMotion: input.reduceMotion)
            let tilt = HeroPointerSpec.product(point: pointer.point, reduceMotion: input.reduceMotion)
            let motion = Self.turntable(time: time, reduceMotion: input.reduceMotion)
            if let core {
                core.setLabelCount(input.labelCount, signatures: input.signatures)
                core.root.eulerAngles = SCNVector3(tilt.pitch, motion.yaw + tilt.yaw, 0)
                core.apply(state: input.modelState, scheme: input.scheme, time: time, dt: dt, reduceMotion: input.reduceMotion)
            } else {
                pair.eulerAngles.x = CGFloat(tilt.pitch)
                pair.eulerAngles.y = CGFloat(motion.yaw + tilt.yaw)
                pair.position.y = CGFloat(motion.bob)
                // Blade Lights are a cool white, as on the product; amber only while connecting.
                let color = input.blade == .connecting ? NSColor(Ink.warn) : RGB(0xD6E4FF).nsColor
                let intensity = input.blade.intensity(at: time, reduceMotion: input.reduceMotion)
                for led in leds {
                    led.emission.contents = color
                    led.emission.intensity = intensity * Self.ledGain
                    led.transparency = intensity > 0 ? 1 : 0.6
                }
                for spill in spills { spill.color = color; spill.intensity = intensity > 0 ? Self.spillIntensity : 0 }
            }
        }
    }
}
