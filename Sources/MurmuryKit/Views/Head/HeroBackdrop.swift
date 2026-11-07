import AppKit
import SwiftUI

/// A soft volumetric glow behind each hero, replacing round 1's flat disc. Every layer is an
/// ellipse whose gradient reaches zero inside its own frame, so no edge can show.
enum HeroBackdrop {
    /// Relative to the backdrop's frame, which is `scale` times the hero's visual frame.
    static let scale: CGFloat = 1.3
    struct Layer: Equatable {
        var name: String
        var color: RGB
        var centre: CGPoint
        var radii: CGSize
        /// (location, alpha) from the centre (0) to the ellipse edge (1).
        var stops: [(location: Double, alpha: Double)]
        static func == (a: Layer, b: Layer) -> Bool {
            a.name == b.name && a.color == b.color && a.centre == b.centre && a.radii == b.radii
                && a.stops.map(\.location) == b.stops.map(\.location) && a.stops.map(\.alpha) == b.stops.map(\.alpha)
        }
        func alpha(atRadius r: Double) -> Double { HeroMask.interpolate(stops, r) }
    }
    static func layers(hue: Hue, dark: Bool, recording: Bool) -> [Layer] {
        let danger = (dark ? Palette.dark : Palette.light).danger
        var glowColor = dark ? hue.bRGB : hue.aRGB
        if recording { glowColor = glowColor.mixed(with: danger, fraction: 0.6) }
        let glowStops: [(location: Double, alpha: Double)] = dark
            ? [(0, 0.50), (0.30, 0.34), (0.60, 0.14), (0.85, 0.03), (1, 0)]
            : [(0, 0.42), (0.30, 0.28), (0.60, 0.10), (0.85, 0.02), (1, 0)]
        let core = dark ? 0.28 : 0.22
        let floor = dark ? 0.22 : 0.13
        return [
            Layer(name: "glow", color: glowColor, centre: CGPoint(x: 0.5, y: 0.40), radii: CGSize(width: 0.62, height: 0.55), stops: glowStops),
            Layer(name: "core", color: hue.aRGB, centre: CGPoint(x: 0.46, y: 0.30), radii: CGSize(width: 0.30, height: 0.30),
                  stops: [(0, core), (0.40, core * 0.55), (0.75, core * 0.18), (1, 0)]),
            // Light mode grounds the bust in a soft, cool contact shadow rather than a pool of the
            // section's colour, so the neck ends deliberately instead of dissolving into a haze.
            Layer(name: "floor", color: dark ? hue.bRGB.mixed(with: RGB(0), fraction: 0.35) : hue.bRGB.mixed(with: RGB(0x2A2440), fraction: 0.6),
                  // Under the neck's fade, where the bust meets its ground, not a detached apron below it.
                  centre: CGPoint(x: 0.5, y: 0.74), radii: CGSize(width: dark ? 0.46 : 0.38, height: dark ? 0.06 : 0.045),
                  stops: [(0, floor), (0.40, floor * 0.6), (0.70, floor * 0.2), (0.90, floor * 0.04), (1, 0)]),
        ]
    }
}

/// SwiftUI drawing of the backdrop layers (radii are fractions of the frame's width and height;
/// the core's radius is a fraction of the width in both directions).
struct HeroBackdropView: View {
    var hue: Hue
    var recording: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(HeroBackdrop.layers(hue: hue, dark: scheme == .dark, recording: recording), id: \.name) { layer in
                    let rx = layer.radii.width * g.size.width
                    let ry = layer.name == "core" ? rx : layer.radii.height * g.size.height
                    Ellipse()
                        .fill(RadialGradient(stops: layer.stops.map { .init(color: layer.color.color.opacity($0.alpha), location: $0.location) },
                                             center: .center, startRadius: 0, endRadius: rx))
                        .frame(width: 2 * rx, height: 2 * rx)
                        .scaleEffect(x: 1, y: ry / rx)
                        .position(x: layer.centre.x * g.size.width, y: layer.centre.y * g.size.height)
                }
            }
        }
        .mask(HeroMask.EdgeShape())
        .animation(reduceMotion ? nil : Motion.section(false), value: recording)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The hero's screen-space mask: a vertical fade for the shoulders times a radial vignette.
enum HeroMask {
    enum Kind: CaseIterable { case head, product }
    /// All local surfaces fade before their rectangular host ends, including clear SCNView pixels
    /// affected by HDR/postprocessing. The field and pointer light live at full-window scope.
    static let edgeStops: [(location: Double, alpha: Double)] = [(0, 0), (0.015, 0), (0.055, 1), (0.945, 1), (0.985, 0), (1, 0)]
    static func edgeAlpha(x: Double, y: Double) -> Double {
        interpolate(edgeStops, x) * interpolate(edgeStops, y)
    }
    struct EdgeShape: View {
        var body: some View {
            LinearGradient(stops: HeroMask.edgeStops.map { .init(color: .white.opacity($0.alpha), location: $0.location) }, startPoint: .leading, endPoint: .trailing)
                .mask(LinearGradient(stops: HeroMask.edgeStops.map { .init(color: .white.opacity($0.alpha), location: $0.location) }, startPoint: .top, endPoint: .bottom))
        }
    }
    private static let headBounds = scannedBounds(kind: .head)
    private static let productBounds = scannedBounds(kind: .product)
    /// Alpha >= 0.25 is the alignment silhouette, optionally intersected with CPU-projected geometry.
    static func visibleBounds(kind: Kind, projectedGeometry: CGRect? = nil) -> CGRect {
        let mask = kind == .head ? headBounds : productBounds
        return mask.intersection(projectedGeometry ?? neutralGeometryBounds(kind: kind))
    }
    private static let projectedHead: CGRect = {
        var url = Bundle.main.url(forResource: "head", withExtension: "scn", subdirectory: "Models")
        #if DEBUG
        if url == nil {
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { root.deleteLastPathComponent() }
            url = root.appendingPathComponent("Resources/Models/head.scn")
        }
        #endif
        let rig = HeadRig(assetURL: url)
        let root = rig.scene.rootNode.childNode(withName: "skin", recursively: true) ?? rig.scene.rootNode
        return HeroFraming.projectedBounds(root: root, camera: rig.camera, aspect: 1 / PageLayout.visualAspect)
    }()
    private static let projectedProducts: CGRect = {
        let buds = ProductSceneView.Coordinator(); buds.build(.buds)
        let model = ProductSceneView.Coordinator(); model.build(.model, labelCount: 5)
        let a = HeroFraming.projectedBounds(root: buds.studio.scene.rootNode, camera: buds.studio.camera, aspect: 1 / PageLayout.visualAspect)
        let b = HeroFraming.projectedBounds(root: model.studio.scene.rootNode, camera: model.studio.camera, aspect: 1 / PageLayout.visualAspect)
        return a.union(b)
    }()
    static func neutralGeometryBounds(kind: Kind) -> CGRect { kind == .head ? projectedHead : projectedProducts }
    static func envelope(kind: Kind) -> CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }
    private static func scannedBounds(kind: Kind) -> CGRect {
        var result = CGRect.null
        for y in 0...500 { for x in 0...500 where alpha(x: Double(x) / 500, y: Double(y) / 500, kind: kind) >= 0.25 {
            result = result.union(CGRect(x: Double(x) / 500, y: Double(y) / 500, width: 0.0001, height: 0.0001))
        } }
        return result
    }
    static let vertical: [(location: Double, alpha: Double)] = [(0, 1), (0.64, 1), (0.72, 0.7), (0.79, 0.3), (0.84, 0.06), (0.88, 0), (1, 0)]
    static let radialCentre = CGPoint(x: 0.5, y: 0.40)
    /// The radial's reach: 1.0 at these fractions of the frame from its centre.
    static let radialReach = CGSize(width: 0.56, height: 0.62)
    static let radial: [(location: Double, alpha: Double)] = [(0, 1), (0.72, 1), (1, 0)]
    static func alpha(atY y: Double) -> Double { interpolate(vertical, y) }
    static func alpha(x: Double, y: Double, kind: Kind = .head) -> Double {
        if kind == .product {
            let d = hypot((x - 0.5) / 0.62, (y - 0.48) / 0.62)
            return interpolate(radial, d) * edgeAlpha(x: x, y: y)
        }
        let d = (pow((x - radialCentre.x) / radialReach.width, 2) + pow((y - radialCentre.y) / radialReach.height, 2)).squareRoot()
        return interpolate(vertical, y) * interpolate(radial, d) * edgeAlpha(x: x, y: y)
    }
    static func interpolate(_ stops: [(location: Double, alpha: Double)], _ t: Double) -> Double {
        guard let first = stops.first, let last = stops.last else { return 1 }
        if t <= first.location { return first.alpha }
        if t >= last.location { return last.alpha }
        for (a, b) in zip(stops, stops.dropFirst()) where t <= b.location {
            return a.alpha + (b.alpha - a.alpha) * (t - a.location) / max(1e-9, b.location - a.location)
        }
        return last.alpha
    }
    /// The mask as a SwiftUI view (white keeps), for the hero's SCNView.
    struct Shape: View {
        var body: some View {
            LinearGradient(stops: HeroMask.vertical.map { .init(color: .white.opacity($0.alpha), location: $0.location) }, startPoint: .top, endPoint: .bottom)
                .mask {
                    GeometryReader { g in
                        let rx = HeroMask.radialReach.width * g.size.width, ry = HeroMask.radialReach.height * g.size.height
                        Ellipse()
                            .fill(RadialGradient(stops: HeroMask.radial.map { .init(color: .white.opacity($0.alpha), location: $0.location) },
                                                 center: .center, startRadius: 0, endRadius: rx))
                            .frame(width: 2 * rx, height: 2 * rx)
                            .scaleEffect(x: 1, y: ry / rx)
                            .position(x: HeroMask.radialCentre.x * g.size.width, y: HeroMask.radialCentre.y * g.size.height)
                    }
                }
                .mask(EdgeShape())
        }
    }
    /// Products have no shoulders to fade: only a soft vignette, so nothing meets the view's edge.
    struct ProductShape: View {
        var body: some View {
            GeometryReader { g in
                let r = 0.62 * max(g.size.width, g.size.height)
                Ellipse()
                    .fill(RadialGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.72), .init(color: .white.opacity(0), location: 1)],
                                         center: .center, startRadius: 0, endRadius: r))
                    .frame(width: 2 * r, height: 2 * r)
                    .scaleEffect(x: g.size.width / max(g.size.width, g.size.height), y: g.size.height / max(g.size.width, g.size.height))
                    .position(x: g.size.width / 2, y: g.size.height * 0.48)
            }
            .mask(EdgeShape())
        }
    }
    static func image(width: Int, height: Int, edgeOnly: Bool = false) -> CGImage? {
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        guard let data = c.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = c.bytesPerRow
        for py in 0..<height {
            for px in 0..<width {
                let x = (Double(px) + 0.5) / Double(width), y = (Double(py) + 0.5) / Double(height)
                let a = edgeOnly ? edgeAlpha(x: x, y: y) : alpha(x: x, y: y)
                let v = UInt8(max(0, min(255, (a * 255).rounded())))
                let i = py * row + px * 4  // CGContext memory is top-down
                data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = v
            }
        }
        return c.makeImage()
    }
}

/// Offline drawing of the same backdrop for stills: the page field, then the backdrop layers, in a
/// frame `HeroBackdrop.scale` times the still, cropped to the still.
enum HeroBackdropRenderer {
    static func draw(in context: CGContext, size: CGSize, hue: Hue, dark: Bool, recording: Bool) {
        let page = CGSize(width: 888, height: 740)
        let c = FieldModel.sample(at: CGPoint(x: page.width * 0.27, y: page.height * 0.40), size: page, hue: hue, dark: dark)
        context.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let frame = CGSize(width: size.width * HeroBackdrop.scale, height: size.height * HeroBackdrop.scale)
        let origin = CGPoint(x: (size.width - frame.width) / 2, y: (size.height - frame.height) / 2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        context.saveGState()
        if let mask = HeroMask.image(width: 500, height: 500, edgeOnly: true) {
            context.clip(to: CGRect(origin: origin, size: frame), mask: mask)
        }
        for layer in HeroBackdrop.layers(hue: hue, dark: dark, recording: recording) {
            let rx = layer.radii.width * frame.width
            let ry = layer.name == "core" ? rx : layer.radii.height * frame.height
            // CG is y-up: flip the layer's centre.
            let centre = CGPoint(x: origin.x + layer.centre.x * frame.width, y: size.height - (origin.y + layer.centre.y * frame.height))
            let colors = layer.stops.map { CGColor(srgbRed: layer.color.r, green: layer.color.g, blue: layer.color.b, alpha: $0.alpha) }
            guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: layer.stops.map { CGFloat($0.location) }) else { continue }
            context.saveGState()
            context.translateBy(x: centre.x, y: centre.y)
            context.scaleBy(x: 1, y: ry / rx)
            context.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: rx, options: [])
            context.restoreGState()
        }
        context.restoreGState()
    }
}
