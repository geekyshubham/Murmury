import CryptoKit
import AppKit
import SceneKit
import SwiftUI

struct HeadAvatar: View {
    var pose: HeadPose?
    var hue: Hue
    var budsLit: Bool
    var showGaze = false
    var recording = false
    /// When the pose's motion sample arrived (seconds since boot), for the latency evidence log.
    var sampleTime: TimeInterval? = nil
    /// How far the mouth is open, 0 to 1.
    var mouth: Double = 0
    var body: some View {
        if ProcessInfo.processInfo.environment["MURMURY_OFFLINE"] == "1" {
            Color.clear.accessibilityLabel("Head: unavailable offline")
        } else {
        HeadSceneView(pose: pose, hue: hue, budsLit: budsLit, showGaze: showGaze, recording: recording, sampleTime: sampleTime, mouth: mouth)
            // The bust fades into its glow: shoulders dissolve, nothing ends on a hard edge.
            .mask(HeroMask.Shape())
            .heroBackdrop(hue: hue, recording: recording)
        }
    }
}

private struct HeadSceneView: NSViewRepresentable {
    var pose: HeadPose?
    var hue: Hue
    var budsLit: Bool
    var showGaze: Bool
    var recording: Bool
    var sampleTime: TimeInterval?
    var mouth: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> SCNView {
        let rig = HeadRig()
        context.coordinator.rig = rig
        let view = Studio.view(scene: rig.scene, camera: rig.camera)
        view.delegate = context.coordinator
        context.coordinator.createdAt = ProcessInfo.processInfo.systemUptime
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.set(HeadRig.Inputs(pose: pose, idle: pose == nil, hue: hue, budsLit: budsLit,
                                              gaze: showGaze, recording: recording, reduceMotion: reduceMotion,
                                              sampleTime: sampleTime, scheme: scheme, mouth: mouth))
        view.setAccessibilityLabel(pose.map(Self.spokenPose) ?? "Head model, waiting for motion")
    }
    /// What VoiceOver says about the head: whole degrees, a direction, never "-0".
    static func spokenPose(_ pose: HeadPose) -> String {
        func part(_ value: Double, _ positive: String, _ negative: String) -> String? {
            let degrees = Int(abs(value).rounded())
            return degrees < 3 ? nil : "\(degrees)° \(value > 0 ? positive : negative)"
        }
        let parts = [part(pose.yaw, "right", "left"), part(pose.pitch, "up", "down")].compactMap { $0 }
        return parts.isEmpty ? "Head facing forward" : "Head turned " + parts.joined(separator: ", ")
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var rig: HeadRig?
        private let lock = NSLock()
        private var inputs = HeadRig.Inputs()
        private var observer: NSObjectProtocol?
        override init() {
            super.init()
            observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.inputs.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
            }
        }
        deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
        func set(_ value: HeadRig.Inputs) { lock.withLock { inputs = value } }
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            var input = lock.withLock { inputs }
            input.pointer = PointerSignal.shared.snapshot(reduceMotion: input.reduceMotion)
            rig?.apply(input, time: time)
            if let pose = rig?.displayedPose { AvatarPoseTap.shared.record(time: time, pose: pose) }
            frameLog?.record(time)
            FieldJournal.shared?.frame(at: time)
            // A new motion sample's first rendered frame: sample-to-frame latency.
            if let sample = input.sampleTime, sample != lastSampleTime {
                lastSampleTime = sample
                latencyLog?.record(time - sample)
                FieldJournal.shared?.latency(time - sample)
            }
        }
        private var lastSampleTime: TimeInterval?
        var createdAt: TimeInterval?
        private var firstFrameLogged = false
        /// Evidence only (`MURMURY_STARTUP_LOG=<file>`): when the first head frame is drawn, after
        /// the view was made and after the process started, so a blank head at launch can be measured.
        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard !firstFrameLogged, let path = ProcessInfo.processInfo.environment["MURMURY_STARTUP_LOG"] else { return }
            firstFrameLogged = true
            let now = ProcessInfo.processInfo.systemUptime
            let sinceView = createdAt.map { (now - $0) * 1000 } ?? -1
            let sinceLaunch = (Date().timeIntervalSince1970 - (ProcessInfo.processInfo.environment["MURMURY_STARTUP_T0"].flatMap(Double.init) ?? Date().timeIntervalSince1970)) * 1000
            let line = String(format: "first head frame: %.0f ms after the view was made, %.0f ms after launch\n", sinceView, sinceLaunch)
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        /// Evidence only (`MURMURY_LATENCY_LOG=<file>`): time from a sample's arrival to its first frame.
        private let latencyLog = ProcessInfo.processInfo.environment["MURMURY_LATENCY_LOG"].map { LatencyLog(path: $0) }
        /// Evidence only (`MURMURY_FRAME_LOG=<file>`): the live render loop's frame times.
        private let frameLog = ProcessInfo.processInfo.environment["MURMURY_FRAME_LOG"].map { FrameLog(path: $0) }
    }
}

extension View {
    /// The hero's soft glow, 1.3 times its frame, behind it.
    func heroBackdrop(hue: Hue, recording: Bool = false) -> some View {
        background {
            GeometryReader { g in
                HeroBackdropView(hue: hue, recording: recording)
                    .frame(width: g.size.width * HeroBackdrop.scale, height: g.size.height * HeroBackdrop.scale)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
        }
    }
}

final class HeadRig {
    private let studio = Studio(preset: .head)
    var scene: SCNScene { studio.scene }
    var camera: SCNNode { studio.camera }
    private let pivot = SCNNode()
    private let cameraOrbit = SCNNode()
    private let gaze = SCNNode()
    private var skin: [SCNGeometry] = []
    /// Taubin passes applied to the supplied sculpt (0 keeps it realistic). Overridable for evidence.
    /// How a bud sits in the ear: turned so the tip points into the canal, the stem hanging down,
    /// leaning a little forward along the jaw and out from the cheek.
    static let wornYaw: Float = 12 * .pi / 180
    static let wornForwardTilt: CGFloat = 14 * .pi / 180, wornOutwardTilt: CGFloat = 8 * .pi / 180
    /// The canal entrance relative to the ear anchor, in millimetres: inward, up, forward.
    static let canalInset = (x: CGFloat(16.5), y: CGFloat(-7), z: CGFloat(18))
    nonisolated(unsafe) static var stylisePasses = Int(ProcessInfo.processInfo.environment["MURMURY_STYLISE"] ?? "") ?? 300
    /// Extra passes over the brow and mouth corners only (`HeadExpression`).
    nonisolated(unsafe) static var expressionPasses = Int(ProcessInfo.processInfo.environment["MURMURY_EXPRESSION"] ?? "") ?? 110
    private var eyeElements: [Int] = []
    private var anatomy: HeadTreatment.Anatomy?
    private var lastDebugEyes = false
    private var leds: [SCNMaterial] = []
    private var lastHue: Hue?
    private var lastScheme: ColorScheme?
    private(set) var usesSculptedAsset = false
    /// Evidence only (`--hero-debug-eyes`): paints the eye regions magenta.
    var debugEyes = false
    private(set) var displayedPose = HeadPose()

    init(assetURL: URL? = Bundle.main.url(forResource: "head", withExtension: "scn", subdirectory: "Models")) {
        // Orbit the camera around its original target; tracking remains entirely in the head pivot.
        let framing = Studio.framing(.head)
        cameraOrbit.name = "pointerCameraOrbit"; cameraOrbit.position = framing.target
        camera.removeFromParentNode()
        camera.position = SCNVector3(framing.position.x - framing.target.x, framing.position.y - framing.target.y, framing.position.z - framing.target.z)
        cameraOrbit.addChildNode(camera); scene.rootNode.addChildNode(cameraOrbit)
        let head: SCNNode
        if let assetURL, FileManager.default.fileExists(atPath: assetURL.path), let archive = try? SCNScene(url: assetURL),
           let loaded = archive.rootNode.childNode(withName: "head", recursively: true),
           loaded.childNode(withName: "skin", recursively: true) != nil,
           ["earLeft", "earRight", "noseTip"].allSatisfy({ loaded.childNode(withName: $0, recursively: true) != nil }) {
            head = loaded.clone(); usesSculptedAsset = true
            // Stylise the realistic sculpt (soften fine anatomy into calm sculptural planes, then calm the
            // brow and mouth corners). Costly, so it runs once per install: memory, then a disk cache.
            if let skinNode = head.childNode(withName: "skin", recursively: true), let g = skinNode.geometry {
                skinNode.geometry = SkinCache.styled(g, skin: skinNode, head: head, asset: assetURL)
            }
        } else {
            head = SCNNode(); head.name = "head"
            let surface = SCNNode(geometry: HeadMesh.geometry()); surface.name = "skin"; head.addChildNode(surface)
            for (name, p) in [("earLeft", SCNVector3(-0.83, -0.06, 0.16)), ("earRight", SCNVector3(0.83, -0.06, 0.16)),
                              ("noseTip", SCNVector3(0, -0.14, 1.10))] {
                let n = SCNNode(); n.name = name; n.position = p; head.addChildNode(n)
            }
        }
        pivot.name = "neckPivot"
        pivot.position = SCNVector3(0, -0.62, -0.04)
        head.position = SCNVector3(0, 0.62, 0.04)
        pivot.addChildNode(head); scene.rootNode.addChildNode(pivot)
        head.enumerateChildNodes { node, _ in if let geometry = node.geometry { skin.append(geometry) } }
        if let skinNode = head.childNode(withName: "skin", recursively: true) {
            eyeElements = HeadTreatment.eyeElements(in: head)
            anatomy = HeadTreatment.anatomy(of: skinNode, noseTip: head.childNode(withName: "noseTip", recursively: true))
            if let anatomy, let interior = HeadTreatment.mouthInterior(anatomy: anatomy) { skinNode.addChildNode(interior) }
        }
        for (name, side) in [("earLeft", Float(-1)), ("earRight", Float(1))] {
            guard let ear = head.childNode(withName: name, recursively: true) else { continue }
            // Worn, the ear tip points into the canal (toward the head's centre), so each ear takes the
            // mirrored model: its Blade Light then faces forward, where the viewer sees it.
            let bud = BudsGeometry.make(side: -side)
            // Chin-to-crown is 230 mm; measure in the head's coordinates, including the asset transform.
            let skinNode = head.childNode(withName: "skin", recursively: true)
            let chin = anatomy?.chinY ?? -0.5, crown = anatomy?.bounds.max.y ?? 1
            let lower = skinNode?.convertPosition(SCNVector3(0, chin, 0), to: head).y ?? CGFloat(chin)
            let upper = skinNode?.convertPosition(SCNVector3(0, crown, 0), to: head).y ?? CGFloat(crown)
            let scale = BudsSpec.onHeadScale(chinToCrown: Float(upper - lower))
            bud.scale = SCNVector3(scale, scale, scale)
            bud.eulerAngles.y = CGFloat(side * Self.wornYaw)
            let mount = SCNNode(); mount.name = "budMount"
            mount.eulerAngles = SCNVector3(-Self.wornForwardTilt, 0, CGFloat(-side) * Self.wornOutwardTilt)
            mount.addChildNode(bud)
            ear.addChildNode(mount)
            // Seat it: the ear tip's face goes to the canal entrance, which lies inward and a little
            // forward of the ear anchor (the outermost point of the rim), so the bud's head sits in
            // the bowl of the ear and the stem hangs below it.
            if let tip = bud.childNode(withName: "silicone", recursively: true) {
                let mm = CGFloat(scale)
                let canal = SCNVector3(CGFloat(-side) * Self.canalInset.x * mm, Self.canalInset.y * mm, Self.canalInset.z * mm)
                let face = tip.convertPosition(SCNVector3(0, 0, CGFloat(Buds3Pro.tipFace)), to: ear)
                mount.position = SCNVector3(canal.x - face.x, canal.y - face.y, canal.z - face.z)
            }
            leds += BudsGeometry.leds(in: bud)
        }
        let beam = SCNCylinder(radius: 0.006, height: 1.5)
        let m = StudioMaterials.surface(NSColor.white, roughness: 1)
        m.lightingModel = .constant; m.transparency = 0.28
        m.transparencyMode = .aOne
        m.transparent.contents = NSImage(size: NSSize(width: 4, height: 128), flipped: false) { rect in
            NSGradient(starting: NSColor.white, ending: NSColor.white.withAlphaComponent(0))?.draw(in: rect, angle: 90)
            return true
        }
        beam.materials = [m]
        let beamNode = SCNNode(geometry: beam); beamNode.eulerAngles.x = .pi / 2
        beamNode.position.z = 0.75; gaze.name = "gaze"; gaze.addChildNode(beamNode)
        head.childNode(withName: "noseTip", recursively: true)?.addChildNode(gaze)
    }
    struct Inputs {
        var pose: HeadPose?
        var pointer = PointerState()
        var idle = true
        var hue = Hue.control
        var budsLit = false
        var gaze = false
        var recording = false
        var reduceMotion = false
        var sampleTime: TimeInterval?
        var scheme = ColorScheme.dark
        /// How far the mouth is open, 0 to 1 (from the buds' learned mouth model, or speech).
        var mouth = 0.0
    }
    /// The jaw as shown: opens quickly, closes a little slower, as a real jaw settles.
    private(set) var displayedMouth = 0.0
    private var shownJawAngle: Float = -1
    static func follow(dt: Double) -> Double { 1 - exp(-25.8 * dt) }
    private var lastApplyTime: TimeInterval?
    static func displayPose(_ pose: HeadPose) -> HeadPose {
        func limit(_ v: Double, _ bound: Double) -> Double { v.isFinite ? min(bound, max(-bound, v)) : 0 }
        return HeadPose(yaw: limit(pose.yaw, 70), pitch: limit(pose.pitch, 35), roll: limit(pose.roll, 30))
    }
    func apply(_ input: Inputs, time: TimeInterval = CACurrentMediaTime()) {
        var target = input.pose ?? HeadPose()
        if input.pose == nil, !input.reduceMotion {
            if input.pointer.hasInfluence {
                target = HeadPose(yaw: 14 * input.pointer.point.x, pitch: 8 * input.pointer.point.y)
            } else if input.idle {
                target = HeadPose(yaw: 7 * sin(time * 0.6), pitch: 2 * sin(time * 0.43))
            }
        }
        let orbit = input.pose != nil && !input.reduceMotion ? input.pointer.point : .zero
        cameraOrbit.eulerAngles = SCNVector3(-2 * orbit.y * .pi / 180, 3 * orbit.x * .pi / 180, 0)
        target = Self.displayPose(target)
        // Frame-rate independent following: the same settle time at 30, 60 or 120 Hz (0.35 per
        // frame at 60 Hz). A resume after a pause is clamped, so it never jumps.
        let dt = lastApplyTime.flatMap { time - $0 > 0 ? min(time - $0, 0.1) : nil } ?? 1.0 / 60
        lastApplyTime = time
        let alpha = Self.follow(dt: dt)
        displayedPose.yaw += (target.yaw - displayedPose.yaw) * alpha
        displayedPose.pitch += (target.pitch - displayedPose.pitch) * alpha
        displayedPose.roll += (target.roll - displayedPose.roll) * alpha
        let r = Double.pi / 180
        pivot.eulerAngles = SCNVector3(-displayedPose.pitch * r, displayedPose.yaw * r, -displayedPose.roll * r)
        studio.update(hue: input.hue, scheme: input.scheme)
        if lastHue != input.hue || lastScheme != input.scheme || lastDebugEyes != debugEyes {
            lastHue = input.hue; lastScheme = input.scheme; lastDebugEyes = debugEyes
            let m = HeadTreatment.materials(style: HeadTreatment.style, eyes: HeadTreatment.eyes, scheme: input.scheme, hue: input.hue,
                                            anatomy: anatomy, debugEyes: debugEyes)
            for geometry in skin {
                geometry.materials = geometry.elements.indices.map { eyeElements.contains($0) ? m.eye : m.skin }
            }
            shownJawAngle = -1  // new materials start closed: set the jaw again
        }
        let mouthTarget = min(1, max(0, input.mouth.isFinite ? input.mouth : 0))
        let mouthRate = mouthTarget > displayedMouth ? 1 - exp(-28 * dt) : 1 - exp(-11 * dt)
        displayedMouth += (mouthTarget - displayedMouth) * mouthRate
        let jawAngle = Float(displayedMouth) * HeadTreatment.jawRange
        if let anatomy, abs(jawAngle - shownJawAngle) > 0.0004 {
            shownJawAngle = jawAngle
            let jaw = HeadTreatment.float4(HeadTreatment.jaw(anatomy: anatomy, angle: jawAngle).a)
            for geometry in skin { for material in geometry.materials { material.setValue(jaw, forKey: "jawA") } }
        }
        // The Blade Lights glow the product's cool white once the buds are connected and streaming
        // (red only while a take records, as the recording signal).
        let color = input.recording ? (input.scheme == .dark ? Palette.dark.danger : Palette.light.danger).nsColor : RGB(0xD6E4FF).nsColor
        for led in leds {
            led.emission.contents = input.budsLit ? color : NSColor.black
            // Above the bloom threshold, so a lit bud glows.
            led.emission.intensity = input.budsLit ? (input.reduceMotion ? 2.2 : 2.2 + 0.2 * sin(time * 3)) : 0
        }
        gaze.isHidden = !input.gaze
        gaze.childNodes.first?.geometry?.firstMaterial?.diffuse.contents = NSColor(input.hue.a)
    }
}

/// Where the calm-expression smoothing applies: the brow shelf above each eye and the two mouth
/// corners, with a soft falloff so nothing seams. The eyes themselves are left alone.
enum HeadExpression {
    /// Eases the lips' forward bulge back toward the face, so the mouth rests rather than purses:
    /// a smooth, shallow push confined to the mouth, strongest at its centre line.
    static func relaxedMouth(anatomy a: HeadTreatment.Anatomy, noseY: Float) -> (SIMD3<Float>) -> SIMD3<Float> {
        let eyes = a.eyes
        let spacing = eyes.count == 2 ? abs(eyes[1].x - eyes[0].x) : 0.6 * (a.bounds.max.x - a.bounds.min.x)
        let mouthY = noseY + (a.chinY - noseY) * 0.42
        let front = (a.bounds.max.z + a.bounds.min.z) / 2
        let depth = 0.022 * a.height
        return { p in
            guard p.z > front else { return p }
            let dx = p.x / (0.5 * spacing), dy = (p.y - mouthY) / (0.22 * spacing)
            let r = (dx * dx + dy * dy).squareRoot()
            guard r < 1 else { return p }
            let u = 1 - r, w = u * u * u * (u * (6 * u - 15) + 10)
            return SIMD3(p.x, p.y, p.z - depth * w)
        }
    }
    /// Rounds the supplied sculpt's broad, flat cranium: a little less height above the brow and a
    /// narrower upper skull, easing in from the brow so the face itself is untouched.
    static func crown(anatomy a: HeadTreatment.Anatomy) -> (SIMD3<Float>) -> SIMD3<Float> {
        let brow = a.eyes.isEmpty ? a.bounds.min.y + 0.6 * a.height : a.eyes.map(\.y).reduce(0, +) / Float(a.eyes.count) + 1.3 * a.eyeRadius
        let top = a.bounds.max.y, cx = (a.bounds.min.x + a.bounds.max.x) / 2, cz = (a.bounds.min.z + a.bounds.max.z) / 2
        let halfWidth = max(0.001, (a.bounds.max.x - a.bounds.min.x) / 2)
        return { p in
            guard p.y > brow, top > brow else { return p }
            let t = (p.y - brow) / (top - brow)
            // A dome, not a lid: the skull's upper corners drop more than its centre.
            let side = min(1, abs(p.x - cx) / halfWidth), dome = 0.2 * (top - brow) * t * t * t * side * side
            return SIMD3(cx + (p.x - cx) * (1 - 0.15 * t * t), brow + (p.y - brow) * (1 - 0.08 * t) - dome, cz + (p.z - cz) * (1 - 0.03 * t * t))
        }
    }
    static func weight(anatomy a: HeadTreatment.Anatomy, noseY: Float) -> (SIMD3<Float>) -> Float {
        let eyes = a.eyes, r = max(a.eyeRadius, 0.001)
        let spacing = eyes.count == 2 ? abs(eyes[1].x - eyes[0].x) : 0.6 * (a.bounds.max.x - a.bounds.min.x)
        let mouthY = noseY + (a.chinY - noseY) * 0.42
        let corners = [SIMD2<Float>(-0.42 * spacing, mouthY), SIMD2<Float>(0.42 * spacing, mouthY)]
        let nostrilY = noseY - 0.07 * spacing
        let nostrils = [SIMD2<Float>(-0.16 * spacing, nostrilY), SIMD2<Float>(0.16 * spacing, nostrilY)]
        let front = (a.bounds.max.z + a.bounds.min.z) / 2
        func falloff(_ d: Float, _ radius: Float) -> Float { let u = max(0, 1 - d / radius); return u * u * u * (u * (6 * u - 15) + 10) }
        return { p in
            guard p.z > front else { return 0 }
            var w: Float = 0
            for e in eyes {
                // Leave the eye and its lids' rim; smooth the shelf above it.
                let d = simd_distance(p, e)
                if d < 1.08 * r { return 0 }
                // A light ring just outside the lids eases the socket's depth into the cheek and brow.
                w = max(w, 0.5 * falloff(abs(d - 1.5 * r), 0.5 * r))
                let brow = SIMD2<Float>(e.x, e.y + 1.3 * r)
                // A wide, soft falloff: the change blends into the forehead with no visible edge.
                w = max(w, falloff(simd_distance(SIMD2(p.x, p.y), brow), 3.0 * r) * 0.8)
            }
            // Mouth corners only lightly: strong passes there open the seam between the lips.
            for c in corners { w = max(w, 0.3 * falloff(simd_distance(SIMD2(p.x, p.y), c), 0.3 * spacing)) }
            // The lip line itself, very lightly and only near the middle: a softer seam, not a dark cut.
            w = max(w, 0.18 * falloff(simd_distance(SIMD2(p.x, p.y), SIMD2(0, mouthY)), 0.36 * spacing))
            // Nostrils: soften the openings' rims so they shade as hollows, not black cut-outs.
            for n in nostrils { w = max(w, 0.55 * falloff(simd_distance(SIMD2(p.x, p.y), n), 0.2 * spacing)) }
            return w
        }
    }
}

/// Records render-loop timestamps and writes interval statistics once (evidence for frame pacing).
final class FrameLog: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var times: [TimeInterval] = []
    private var written = false
    private var warmup = 0
    static let frames = 600, warmupFrames = 240
    init(path: String) { self.path = path }
    func record(_ t: TimeInterval) {
        lock.withLock {
            guard !written else { return }
            warmup += 1
            guard warmup > Self.warmupFrames else { return }  // steady state, after scene setup
            times.append(t)
            guard times.count >= Self.frames else { return }
            written = true
            let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }.sorted()
            func pct(_ p: Double) -> Double { intervals[min(intervals.count - 1, Int(Double(intervals.count) * p))] }
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            // These are SceneKit's renderer(updateAtTime:) callbacks: update cadence, not presented frames.
            let text = String(format: "renderer updates %d span %.2f s mean interval %.2f ms p50 %.2f ms p95 %.2f ms p99 %.2f ms max %.2f ms rate %.1f/s\n",
                              times.count, times.last! - times.first!, mean, pct(0.5), pct(0.95), pct(0.99), intervals.last ?? 0, 1000 / mean)
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// Sample-to-frame latency statistics, written once after enough samples (evidence only).
final class LatencyLog: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var values: [Double] = []
    private var written = false
    private var skipped = 0
    init(path: String) { self.path = path }
    func record(_ seconds: Double) {
        lock.withLock {
            guard !written else { return }
            skipped += 1
            guard skipped > 120, seconds >= 0, seconds < 1 else { return }
            values.append(seconds * 1000)
            guard values.count >= 400 else { return }
            written = true
            let v = values.sorted()
            func pct(_ p: Double) -> Double { v[min(v.count - 1, Int(Double(v.count) * p))] }
            // From a sample's arrival to the next renderer update that applies it (not to the display).
            let text = String(format: "samples %d sample-arrival-to-renderer-update latency p50 %.1f ms p95 %.1f ms p99 %.1f ms max %.1f ms\n",
                              v.count, pct(0.5), pct(0.95), pct(0.99), v.last ?? 0)
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// The stylised head skin, computed once: an in-memory copy for this session and a SceneKit file in
/// Caches for later launches, keyed by the asset's contents and the smoothing settings (not its date:
/// every build copies the asset anew, and the bundled and source copies must share one entry).
enum SkinCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memory: [String: SCNGeometry] = [:]

    static func key(asset: URL) -> String {
        let digest = (try? Data(contentsOf: asset)).map { SHA256.hash(data: $0).prefix(8).map { String(format: "%02x", $0) }.joined() } ?? "missing"
        return "\(asset.lastPathComponent)-\(digest)-s\(HeadRig.stylisePasses)-e\(HeadRig.expressionPasses)-v10"
    }
    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmury/HeadSkin", isDirectory: true)
    }

    static func styled(_ raw: SCNGeometry, skin: SCNNode, head: SCNNode, asset: URL) -> SCNGeometry {
        let key = key(asset: asset)
        if let hit = lock.withLock({ memory[key] }) { return hit.copy() as? SCNGeometry ?? hit }
        let file = directory.appendingPathComponent(key + ".scn")
        if let scene = try? SCNScene(url: file), let geometry = scene.rootNode.childNode(withName: "skin", recursively: true)?.geometry,
           geometry.elements.count == raw.elements.count {
            lock.withLock { memory[key] = geometry }
            return geometry.copy() as? SCNGeometry ?? geometry
        }
        var g = raw
        if HeadRig.stylisePasses > 0 { g = MeshSmoother.taubin(g, iterations: HeadRig.stylisePasses) }
        skin.geometry = g
        if HeadRig.expressionPasses > 0, let noseTip = head.childNode(withName: "noseTip", recursively: true),
           let a = HeadTreatment.anatomy(of: skin, noseTip: noseTip) {
            let noseY = Float(skin.convertPosition(noseTip.position, from: noseTip.parent).y)
            // Plain Laplacian here (no inflating step): it flattens the brow ridge and fills the pinched
            // corners, which volume-preserving Taubin passes leave in place.
            g = MeshSmoother.taubin(g, iterations: HeadRig.expressionPasses, lambda: 0.5, mu: 0, weight: HeadExpression.weight(anatomy: a, noseY: noseY))
            g = MeshSmoother.deformed(g, by: HeadExpression.crown(anatomy: a))
            g = MeshSmoother.deformed(g, by: HeadExpression.relaxedMouth(anatomy: a, noseY: noseY))
        }
        lock.withLock { memory[key] = g }
        // Best effort: a failed write only means the next launch computes it again.
        let scene = SCNScene(), node = SCNNode(geometry: g); node.name = "skin"
        scene.rootNode.addChildNode(node)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Each rebuilt asset or new setting makes a new key: drop the stale files so the cache holds one.
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix(asset.lastPathComponent + "-") && old != file {
            try? FileManager.default.removeItem(at: old)
        }
        _ = scene.write(to: file, options: nil, delegate: nil, progressHandler: nil)
        return g.copy() as? SCNGeometry ?? g
    }
}
