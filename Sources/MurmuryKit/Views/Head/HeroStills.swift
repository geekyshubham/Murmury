import AppKit
import Metal
import SceneKit
import SwiftUI

/// Offline evidence for the 3D heroes: `--dump-scene=<scn>` describes an asset and
/// `--render-hero-stills=<dir>` renders every hero pose with SCNRenderer and measures it.
@MainActor
enum HeroStills {
    /// The page's visual aspect (1:1.24), at 900 pixels wide.
    static let size = CGSize(width: 900, height: 900 * PageLayout.visualAspect)

    // MARK: Scene dump

    static func dumpScene(at url: URL) throws -> String {
        let scene = try SCNScene(url: url)
        var lines = ["# \(url.lastPathComponent): node tree, geometry, material slots, local bounds"]
        func visit(_ node: SCNNode, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            var line = pad + "\(node.name ?? "(unnamed)") position=\(fmt(node.position)) scale=\(fmt(node.scale))"
            if let geometry = node.geometry {
                let (lo, hi) = node.boundingBox
                let vertices = geometry.sources(for: .vertex).first
                line += " geometry vertices=\(vertices?.vectorCount ?? 0) elements=\(geometry.elements.count)"
                line += " materials=\(geometry.materials.count) bounds=\(fmt(lo))…\(fmt(hi))"
                lines.append(line)
                let positions = vertices.map(readVectors) ?? []
                for (i, element) in geometry.elements.enumerated() {
                    var detail = pad + "  element \(i): \(element.primitiveCount) triangles"
                    if let (a, b) = bounds(of: element, positions: positions) {
                        let world = node.convertPosition(SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2), to: nil)
                        detail += " bounds=\(fmt(SCNVector3(a.x, a.y, a.z)))…\(fmt(SCNVector3(b.x, b.y, b.z))) centre(world)=\(fmt(world))"
                    }
                    let material = geometry.materials.isEmpty ? nil : geometry.materials[i % geometry.materials.count]
                    detail += " material=\(material.map { "\($0.name ?? "unnamed") \($0.lightingModel.rawValue)" } ?? "none")"
                    lines.append(detail)
                }
            } else {
                lines.append(line + " world=\(fmt(node.worldPosition))")
            }
            for child in node.childNodes { visit(child, depth: depth + 1) }
        }
        visit(scene.rootNode, depth: 0)
        let eyes = HeadTreatment.eyeElements(in: scene.rootNode)
        lines.append("eyes: " + (eyes.isEmpty ? "not separate geometry; use the shader mask" : "separate geometry elements \(eyes) of skin; own material"))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func fmt(_ v: SCNVector3) -> String { String(format: "(%.3f, %.3f, %.3f)", v.x, v.y, v.z) }

    nonisolated static func readVectors(_ source: SCNGeometrySource) -> [SIMD3<Float>] {
        let stride = source.dataStride, offset = source.dataOffset
        return source.data.withUnsafeBytes { raw -> [SIMD3<Float>] in
            (0..<source.vectorCount).map { i in
                let base = i * stride + offset
                if source.usesFloatComponents, source.bytesPerComponent == 4 {
                    return SIMD3(raw.load(fromByteOffset: base, as: Float.self), raw.load(fromByteOffset: base + 4, as: Float.self),
                                 raw.load(fromByteOffset: base + 8, as: Float.self))
                }
                return SIMD3(Float(raw.load(fromByteOffset: base, as: Double.self)), Float(raw.load(fromByteOffset: base + 8, as: Double.self)),
                             Float(raw.load(fromByteOffset: base + 16, as: Double.self)))
            }
        }
    }

    nonisolated static func indices(of element: SCNGeometryElement) -> [Int] {
        let count = element.primitiveCount * 3
        return element.data.withUnsafeBytes { raw -> [Int] in
            switch element.bytesPerIndex {
            case 2: return (0..<min(count, raw.count / 2)).map { Int(raw.load(fromByteOffset: $0 * 2, as: UInt16.self)) }
            case 4: return (0..<min(count, raw.count / 4)).map { Int(raw.load(fromByteOffset: $0 * 4, as: UInt32.self)) }
            default: return (0..<min(count, raw.count)).map { Int(raw.load(fromByteOffset: $0, as: UInt8.self)) }
            }
        }
    }

    nonisolated static func bounds(of element: SCNGeometryElement, positions: [SIMD3<Float>]) -> (SIMD3<Float>, SIMD3<Float>)? {
        let used = indices(of: element).filter { $0 < positions.count }.map { positions[$0] }
        guard let first = used.first else { return nil }
        return used.reduce((first, first)) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
    }

    // MARK: Stills

    struct Pose {
        var name: String
        var dark: Bool
        var kind: Kind
        enum Kind {
            case head(HeadPose, recording: Bool)
            case buds(BudsPresentation.BladeState)
            case model(ModelHeroState)
        }
    }

    static var poses: [Pose] {
        var result: [Pose] = []
        for dark in [true, false] {
            let a = dark ? "dark" : "light"
            for (name, pose) in [("neutral", HeadPose()), ("yaw-left", HeadPose(yaw: -45)), ("yaw-right", HeadPose(yaw: 45)),
                                 ("pitch-up", HeadPose(pitch: 25)), ("pitch-down", HeadPose(pitch: -25))] {
                result.append(Pose(name: "head-\(name)-\(a)", dark: dark, kind: .head(pose, recording: false)))
            }
            result.append(Pose(name: "head-recording-\(a)", dark: dark, kind: .head(HeadPose(), recording: true)))
            for (name, blade) in [("idle", BudsPresentation.BladeState.off), ("connected", .connected), ("streaming", .streaming)] {
                result.append(Pose(name: "buds-\(name)-\(a)", dark: dark, kind: .buds(blade)))
            }
            for state in [ModelHeroState.untrained, .ready] {
                result.append(Pose(name: "model-\(state.rawValue)-\(a)", dark: dark, kind: .model(state)))
            }
        }
        return result
    }

    /// GPU cost proxy: mean milliseconds per offscreen head frame (render plus readback).
    static func timing(assetURL: URL?, frames: Int = 40) -> String {
        _ = NSApplication.shared
        guard let device = MTLCreateSystemDefaultDevice() else { return "No Metal device" }
        let rig = HeadRig(assetURL: assetURL)
        var input = HeadRig.Inputs(); input.idle = false; input.budsLit = true
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = rig.scene; renderer.pointOfView = rig.camera
        rig.apply(input, time: 0)
        _ = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<frames {
            input.pose = HeadPose(yaw: Double(i % 20) * 3 - 30)
            rig.apply(input, time: Double(i) / 60)
            _ = renderer.snapshot(atTime: Double(i) / 60, with: size, antialiasingMode: .multisampling4X)
        }
        return String(format: "%.1f ms per head frame (%d frames, %.0fx%.0f, 4x MSAA)", (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(frames), frames, size.width, size.height)
    }

    /// Exit codes: 0 rendered, 3 no Metal device.
    static func render(to directory: URL, assetURL: URL?, debugEyes: Bool = false, only: String? = nil) throws -> Int32 {
        _ = NSApplication.shared
        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write(Data("No Metal device: hero stills need a GPU.\n".utf8))
            return 3
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var all: [[String: Any]] = []
        for pose in poses where only.map({ pose.name.contains($0) }) ?? true {
            let scheme: ColorScheme = pose.dark ? .dark : .light
            let renderer = SCNRenderer(device: device, options: nil)
            var metrics: [String: Any] = ["name": pose.name]
            var hue = Hue.control
            let image: CGImage
            switch pose.kind {
            case .head(let headPose, let recording):
                let rig = HeadRig(assetURL: assetURL)
                rig.debugEyes = debugEyes
                var input = HeadRig.Inputs()
                input.pose = headPose; input.idle = false; input.reduceMotion = true
                input.recording = recording; input.budsLit = true; input.scheme = scheme
                // Evidence only: MURMURY_MOUTH=<0...1> renders the stills with the jaw open.
                input.mouth = Double(ProcessInfo.processInfo.environment["MURMURY_MOUTH"] ?? "") ?? 0
                for step in 0..<40 { rig.apply(input, time: Double(step) / 60) }
                renderer.scene = rig.scene; renderer.pointOfView = rig.camera
                image = try snapshot(renderer)
                if let nose = rig.scene.rootNode.childNode(withName: "noseTip", recursively: true),
                   let skin = rig.scene.rootNode.childNode(withName: "skin", recursively: true) {
                    func project(_ world: SCNVector3) -> CGPoint {
                        let p = renderer.projectPoint(world)
                        return CGPoint(x: p.x, y: size.height - p.y)
                    }
                    let n = project(nose.convertPosition(SCNVector3Zero, to: nil))
                    metrics["nose"] = [Double(n.x), Double(n.y)]
                    // The face: eyes and nose tip, padded by a third of the eye span, down to the chin.
                    var points = [n]
                    for e in HeadTreatment.anatomy(of: skin, noseTip: nose)?.eyes ?? [] {
                        points.append(project(skin.convertPosition(SCNVector3(e.x, e.y, e.z), to: nil)))
                    }
                    if points.count == 3 {
                        let span = max(60, hypot(points[1].x - points[2].x, points[1].y - points[2].y))
                        let xs = points.map(\.x), ys = points.map(\.y)
                        let eyeY = (points[1].y + points[2].y) / 2
                        metrics["faceBox"] = [Double(xs.min()! - span / 3), Double(ys.min()! - span / 3),
                                              Double(xs.max()! - xs.min()! + 2 * span / 3), Double(ys.max()! - ys.min()! + span / 3 + abs(n.y - eyeY) * 1.7)]
                    }
                }
                metrics["bottom"] = projectedBottom(rig: rig, renderer: renderer)
            case .buds(let blade):
                hue = .buds
                let coordinator = ProductSceneView.Coordinator()
                coordinator.build(.buds)
                coordinator.set(.init(blade: blade, scheme: scheme, reduceMotion: true))
                renderer.scene = coordinator.studio.scene; renderer.pointOfView = coordinator.studio.camera
                for step in 0..<3 { coordinator.renderer(renderer, updateAtTime: Double(step) / 60) }
                image = try snapshot(renderer)
            case .model(let state):
                hue = .model
                let coordinator = ProductSceneView.Coordinator()
                coordinator.build(.model)
                coordinator.set(.init(modelState: state, scheme: scheme, reduceMotion: true))
                renderer.scene = coordinator.studio.scene; renderer.pointOfView = coordinator.studio.camera
                for step in 0..<3 { coordinator.renderer(renderer, updateAtTime: Double(step) / 60) }
                image = try snapshot(renderer)
                if let rig = coordinator.modelRig {
                    rig.isolate(.core)
                    metrics["coreLuma"] = Pixels(try snapshot(renderer)).meanLuma
                    rig.isolate(.rings)
                    metrics["ringLuma"] = Pixels(try snapshot(renderer)).meanLuma
                    rig.isolate(nil)
                }
            }
            let isHead: Bool = { if case .head = pose.kind { return true }; return false }()
            let composite = try HeroComposite.compose(image, hue: hue, dark: pose.dark, recording: { if case .head(_, let r) = pose.kind { return r }; return false }(),
                                                      masked: isHead)
            let pixels = Pixels(composite.subject)
            metrics["clipped"] = pixels.clippedShare
            metrics["shellClipped"] = pixels.neutralClippedShare
            metrics["meanLuma"] = pixels.meanLuma
            metrics["lumaStd"] = pixels.lumaStd
            if let box = metrics["faceBox"] as? [Double] {
                metrics["faceSpread"] = pixels.spread(inBox: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]))
            }
            metrics["edgeContrast"] = pixels.edgeContrast(over: Pixels(composite.image), band: 6)
            try png(composite.image).write(to: directory.appendingPathComponent(pose.name + ".png"))
            all.append(metrics)
        }
        let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("metrics.json"))
        return 0
    }

    /// One left bud in the product studio, light appearance, on white, turned to each yaw (degrees;
    /// 0 has the Blade Light ridge facing the camera), framed to its own bounds.
    static func renderBudViews(to directory: URL, yaws: [Double]) throws -> Int32 {
        _ = NSApplication.shared
        guard let device = MTLCreateSystemDefaultDevice() else { return 3 }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (dark, name) in [(false, "light"), (true, "dark")] {
            for yaw in yaws {
                let studio = Studio(preset: .buds)
                studio.update(hue: .buds, scheme: dark ? .dark : .light)
                let bud = BudsGeometry.make(side: -1)
                if ProcessInfo.processInfo.environment["MURMURY_BUDS_LIT"] != nil {
                    for led in BudsGeometry.leds(in: bud) { led.emission.contents = RGB(0xD6E4FF).nsColor; led.emission.intensity = 2.4 * ProductSceneView.Coordinator.ledGain; led.transparency = 1 }
                }
                if ProcessInfo.processInfo.environment["MURMURY_BUDS_CLAY"] != nil {  // matte white, to judge the form alone
                    bud.enumerateHierarchy { n, _ in n.geometry?.materials = [StudioMaterials.surface(NSColor(white: 0.32, alpha: 1), roughness: 0.75)] }
                }
                let pivot = SCNNode(); pivot.addChildNode(bud); studio.scene.rootNode.addChildNode(pivot)
                pivot.eulerAngles.y = CGFloat(yaw * .pi / 180)
                let (lo, hi) = bud.boundingBox
                let centre = bud.convertPosition(SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2), to: nil)
                let height = Double(hi.y - lo.y) * Double(BudsSpec.scale)
                let distance = height / 0.80 / (2 * tan(24.0 * .pi / 360))
                studio.camera.camera?.fieldOfView = 24
                studio.camera.position = SCNVector3(centre.x, centre.y + CGFloat(distance * 0.02), centre.z + CGFloat(distance))
                studio.camera.look(at: centre)
                studio.scene.background.contents = dark ? NSColor(white: 0.08, alpha: 1) : NSColor.white
                let renderer = SCNRenderer(device: device, options: nil)
                renderer.scene = studio.scene; renderer.pointOfView = studio.camera
                let image = renderer.snapshot(atTime: 1, with: CGSize(width: 700, height: 700), antialiasingMode: .multisampling4X)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CocoaError(.fileWriteUnknown) }
                try png(cg).write(to: directory.appendingPathComponent("bud-\(name)-\(Int(yaw)).png"))
            }
        }
        return 0
    }

    private static func snapshot(_ renderer: SCNRenderer) throws -> CGImage {
        let image = renderer.snapshot(atTime: 1, with: size, antialiasingMode: .multisampling4X)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CocoaError(.fileWriteUnknown) }
        return cg
    }

    /// Lowest projected point of the skin mesh, as a fraction of the view height (y down).
    static func projectedBottom(rig: HeadRig, renderer: SCNSceneRenderer) -> Double {
        guard let skin = rig.scene.rootNode.childNode(withName: "skin", recursively: true),
              let source = skin.geometry?.sources(for: .vertex).first else { return 0 }
        let positions = readVectors(source)
        var lowest = 0.0
        for p in Swift.stride(from: 0, to: positions.count, by: 7).map({ positions[$0] }) {
            let world = skin.convertPosition(SCNVector3(p.x, p.y, p.z), to: nil)
            lowest = max(lowest, 1 - Double(renderer.projectPoint(world).y) / Double(size.height))
        }
        return lowest
    }

    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

/// Unpremultiplied RGBA pixels with sRGB-encoded luma (Rec. 709 weights), y down.
struct Pixels {
    let width: Int, height: Int
    private(set) var rgba: [Double]

    init(_ image: CGImage) {
        width = image.width; height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        rgba = [Double](repeating: 0, count: bytes.count)
        for i in Swift.stride(from: 0, to: bytes.count, by: 4) {
            let a = Double(bytes[i + 3]) / 255
            for c in 0..<3 { rgba[i + c] = a > 0 ? min(1, Double(bytes[i + c]) / 255 / a) : 0 }
            rgba[i + 3] = a
        }
    }
    func alpha(_ x: Int, _ y: Int) -> Double { rgba[(y * width + x) * 4 + 3] }
    func luma(_ x: Int, _ y: Int) -> Double {
        let i = (y * width + x) * 4
        return 0.2126 * rgba[i] + 0.7152 * rgba[i + 1] + 0.0722 * rgba[i + 2]
    }
    func rgb(_ x: Int, _ y: Int) -> RGB { let i = (y * width + x) * 4; return RGB(r: rgba[i], g: rgba[i + 1], b: rgba[i + 2]) }
    private var subject: [(Int, Int)] {
        var result: [(Int, Int)] = []
        for y in 0..<height { for x in 0..<width where alpha(x, y) > 0.5 { result.append((x, y)) } }
        return result
    }
    var clippedShare: Double {
        let s = subject
        guard !s.isEmpty else { return 0 }
        return Double(s.filter { p in let i = (p.1 * width + p.0) * 4; return max(rgba[i], rgba[i + 1], rgba[i + 2]) >= 0.97 }.count) / Double(s.count)
    }
    /// Clipped and near-neutral (spread under 0.15): a blown-out shell, not a coloured LED glow.
    var neutralClippedShare: Double {
        let s = subject
        guard !s.isEmpty else { return 0 }
        return Double(s.filter { p in
            let i = (p.1 * width + p.0) * 4
            let hi = max(rgba[i], rgba[i + 1], rgba[i + 2]), lo = min(rgba[i], rgba[i + 1], rgba[i + 2])
            return hi >= 0.97 && hi - lo < 0.15
        }.count) / Double(s.count)
    }
    var meanLuma: Double {
        let s = subject
        return s.isEmpty ? 0 : s.map { luma($0.0, $0.1) }.reduce(0, +) / Double(s.count)
    }
    var lumaStd: Double {
        let values = subject.map { luma($0.0, $0.1) }
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }
    func spread(inBox box: CGRect) -> Double {
        var values: [Double] = []
        for y in max(0, Int(box.minY))..<min(height, Int(box.maxY)) {
            for x in max(0, Int(box.minX))..<min(width, Int(box.maxX)) where alpha(x, y) > 0.5 { values.append(luma(x, y)) }
        }
        guard values.count > 10 else { return 0 }
        values.sort()
        return values[Int(Double(values.count - 1) * 0.9)] - values[Int(Double(values.count - 1) * 0.1)]
    }
    /// WCAG contrast between the mean colour 1…band px inside the silhouette and 1…band px outside it,
    /// both read from `composite`.
    func edgeContrast(over composite: Pixels, band: Int) -> Double {
        var inside = (RGB(r: 0, g: 0, b: 0), 0), outside = (RGB(r: 0, g: 0, b: 0), 0)
        func add(_ acc: inout (RGB, Int), _ c: RGB) { acc.0.r += c.r; acc.0.g += c.g; acc.0.b += c.b; acc.1 += 1 }
        for y in Swift.stride(from: band, to: height - band, by: 2) {
            for x in Swift.stride(from: band, to: width - band, by: 2) {
                let solid = alpha(x, y) > 0.5
                var nearEdge = false
                for (dx, dy) in [(band, 0), (-band, 0), (0, band), (0, -band)] where (alpha(x + dx, y + dy) > 0.5) != solid { nearEdge = true }
                guard nearEdge else { continue }
                if solid { add(&inside, composite.rgb(x, y)) } else { add(&outside, composite.rgb(x, y)) }
            }
        }
        guard inside.1 > 0, outside.1 > 0 else { return 1 }
        let a = RGB(r: inside.0.r / Double(inside.1), g: inside.0.g / Double(inside.1), b: inside.0.b / Double(inside.1))
        let b = RGB(r: outside.0.r / Double(outside.1), g: outside.0.g / Double(outside.1), b: outside.0.b / Double(outside.1))
        return contrast(a, b)
    }
}

/// Composes a transparent hero render the way the page shows it: screen-space mask, then the page
/// field behind it at the hero's centre.
@MainActor
enum HeroComposite {
    struct Result { var subject: CGImage; var image: CGImage }

    static func compose(_ render: CGImage, hue: Hue, dark: Bool, recording: Bool, masked: Bool) throws -> Result {
        let w = render.width, h = render.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func context() throws -> CGContext {
            guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            return c
        }
        // Subject: the render with the hero's screen-space mask applied (CG's origin is bottom-left).
        let subjectContext = try context()
        subjectContext.draw(render, in: CGRect(x: 0, y: 0, width: w, height: h))
        if masked, let mask = HeroMask.image(width: w, height: h) {
            subjectContext.setBlendMode(.destinationIn)
            subjectContext.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        guard let subject = subjectContext.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let out = try context()
        HeroBackdropRenderer.draw(in: out, size: CGSize(width: w, height: h), hue: hue, dark: dark, recording: recording)
        out.draw(subject, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = out.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return Result(subject: subject, image: image)
    }
}

/// Framing checks without a GPU: the camera's own vertical field of view and transform.
enum HeroFraming {
    /// CPU projection of mesh vertices, in normalised y-down screen coordinates.
    static func projectedBounds(root: SCNNode, camera: SCNNode, aspect: Double) -> CGRect {
        let view = simd_inverse(camera.simdWorldTransform)
        let halfHeight = tan((camera.camera?.fieldOfView ?? 24) * .pi / 360)
        var bounds = CGRect.null
        func include(_ node: SCNNode) {
            guard node.name != "gaze", let source = node.geometry?.sources(for: .vertex).first else { return }
            for p in HeroStills.readVectors(source) {
                let v = view * SIMD4<Float>(node.simdConvertPosition(p, to: nil), 1)
                guard v.z < 0 else { continue }
                let x = 0.5 + Double(v.x / -v.z) / (2 * halfHeight * aspect)
                let y = 0.5 - Double(v.y / -v.z) / (2 * halfHeight)
                bounds = bounds.union(CGRect(x: x, y: y, width: 1e-7, height: 1e-7))
            }
        }
        include(root); root.enumerateChildNodes { node, _ in include(node) }
        return bounds
    }

    /// The lowest point of the skin mesh, as a fraction of the view height from its top.
    static func projectedBottom(rig: HeadRig, aspect: Double) -> Double {
        guard let skin = rig.scene.rootNode.childNode(withName: "skin", recursively: true),
              let source = skin.geometry?.sources(for: .vertex).first, let cam = rig.camera.camera else { return 0 }
        let view = simd_inverse(rig.camera.simdWorldTransform)
        let halfHeight = tan(cam.fieldOfView * .pi / 360)
        var lowest = 0.0
        let positions = HeroStills.readVectors(source)
        for p in Swift.stride(from: 0, to: positions.count, by: 5).map({ positions[$0] }) {
            let world = skin.simdConvertPosition(p, to: nil)
            let v = view * SIMD4<Float>(world, 1)
            guard v.z < 0 else { continue }
            let ndcY = Double(v.y / -v.z) / halfHeight
            lowest = max(lowest, (1 - ndcY) / 2)
        }
        return lowest
    }
}
