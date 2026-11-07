import AppKit
import Metal
import SceneKit
import SwiftUI

/// The app icon: one lit Buds3 Pro bud with a porcelain cursor glint, on a glowing violet squircle,
/// in the same studio and materials as the in-app heroes.
@MainActor
enum IconHero {
    /// macOS icon grid: an 824-point continuous squircle centred on a 1024 canvas.
    static let canvas: CGFloat = 1024
    static let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let cornerRadius: CGFloat = 185
    static let hue = Hue.control

    /// The bud on transparency, three-quarter view, blade at 20 degrees, LED lit. Nil without Metal.
    static func render(pixels: Int = 2048, crop: Bool = true) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let studio = Studio(preset: .icon)
        studio.update(hue: hue, scheme: .dark)
        let bud = BudsGeometry.make(side: 1)
        // Three-quarter view with the blade's lit face toward the viewer; with its own 8° lean the
        // blade stands at about 20°.
        bud.eulerAngles = SCNVector3(0.10, 0.42, 12 * .pi / 180)
        let pivot = SCNNode(); pivot.addChildNode(bud)
        studio.scene.rootNode.addChildNode(pivot)
        for led in BudsGeometry.leds(in: bud) {
            led.emission.contents = hue.aRGB.nsColor; led.emission.intensity = 2.4; led.transparency = 1
        }
        for spill in BudsGeometry.spills(in: bud) { spill.color = hue.aRGB.nsColor; spill.intensity = 25 }
        // Frame the bud: centre its bounds and fill most of the view's height.
        let (lo, hi) = pivot.boundingBox
        bud.position = SCNVector3(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -(lo.z + hi.z) / 2)
        let height = Double(hi.y - lo.y)
        let fov = Studio.framing(.icon).fieldOfView
        let distance = height / 0.86 / (2 * tan(fov * .pi / 360))
        studio.camera.position = SCNVector3(0, 0, distance)
        studio.camera.look(at: SCNVector3Zero)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = studio.scene
        renderer.pointOfView = studio.camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return crop ? cropToContent(cg) : cg
    }

    /// Trims transparent margins (2% padding kept), so composition places the bud by what is visible.
    static func cropToContent(_ image: CGImage) -> CGImage? {
        let p = Pixels(image)
        var minX = p.width, minY = p.height, maxX = -1, maxY = -1
        for y in Swift.stride(from: 0, to: p.height, by: 2) {
            for x in Swift.stride(from: 0, to: p.width, by: 2) where p.alpha(x, y) > 0.02 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return image }
        let pad = Int(Double(max(maxX - minX, maxY - minY)) * 0.02)
        let rect = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                          width: min(p.width, maxX + pad) - max(0, minX - pad), height: min(p.height, maxY + pad) - max(0, minY - pad))
        return image.cropping(to: rect)
    }

    /// Composes the 1024 icon. `small` is the 16/32-pixel variant: a larger bud and a crisp arrow, no glow.
    static func compose(hero: CGImage?, small: Bool = false) -> CGImage? {
        let size = Int(canvas)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        // Work top-down, like the design grid.
        c.translateBy(x: 0, y: canvas); c.scaleBy(x: 1, y: -1)
        let squircle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: tile).cgPath
        func color(_ rgb: RGB, _ alpha: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [rgb.r, rgb.g, rgb.b, alpha])! }
        func gradient(_ stops: [(RGB, CGFloat, CGFloat)]) -> CGGradient {
            CGGradient(colorsSpace: space, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: stops.map(\.2))!
        }
        // Drop shadow under the tile (y grows downward here).
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -20), blur: 30, color: color(RGB(0x000000), 0.30))
        c.addPath(squircle); c.setFillColor(color(RGB(0x120A29))); c.fillPath()
        c.restoreGState()
        // The lit field.
        c.saveGState()
        c.addPath(squircle); c.clip()
        c.drawLinearGradient(gradient([(RGB(0x3A1477), 1, 0), (RGB(0x120A29), 1, 1)]),
                             start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
        func radial(_ rgb: RGB, _ alpha: CGFloat, at p: CGPoint, radius r: CGFloat) {
            let centre = CGPoint(x: tile.minX + p.x * tile.width, y: tile.minY + p.y * tile.height)
            c.drawRadialGradient(gradient([(rgb, alpha, 0), (rgb, alpha * 0.45, 0.45), (rgb, 0, 1)]),
                                 startCenter: centre, startRadius: 0, endCenter: centre, endRadius: r * tile.width, options: [])
        }
        radial(hue.bRGB, 0.55, at: CGPoint(x: 0.30, y: 0.62), radius: 0.7)
        radial(hue.aRGB, 0.45, at: CGPoint(x: 0.72, y: 0.25), radius: 0.55)
        // Bevel: light along the top edge, shade along the bottom.
        c.drawLinearGradient(gradient([(RGB(0xFFFFFF), 0.35, 0), (RGB(0xFFFFFF), 0, 1)]),
                             start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.minY + 0.06 * tile.height), options: [])
        c.drawLinearGradient(gradient([(RGB(0x000000), 0, 0), (RGB(0x000000), 0.25, 1)]),
                             start: CGPoint(x: 0, y: tile.maxY - 0.30 * tile.height), end: CGPoint(x: 0, y: tile.maxY), options: [])
        // The bud, fitted into a 640 box (larger at small sizes), with a soft contact shadow.
        let box: CGFloat = small ? 640 * 1.18 : 640
        let aspect = hero.map { CGFloat($0.width) / CGFloat($0.height) } ?? 0.8
        let budSize = aspect > 1 ? CGSize(width: box, height: box / aspect) : CGSize(width: box * aspect, height: box)
        let budRect = CGRect(x: canvas / 2 - budSize.width / 2 - (small ? 30 : 50), y: canvas / 2 - budSize.height / 2 + (small ? 20 : 40),
                             width: budSize.width, height: budSize.height)
        let shadowCentre = CGPoint(x: budRect.midX + 30, y: min(tile.maxY - 70, budRect.maxY + 18))
        c.saveGState()
        c.translateBy(x: shadowCentre.x, y: shadowCentre.y); c.scaleBy(x: 1, y: 0.22)
        c.drawRadialGradient(gradient([(RGB(0x000000), 0.35, 0), (RGB(0x000000), 0, 1)]), startCenter: .zero, startRadius: 0,
                             endCenter: .zero, endRadius: budSize.width * 0.45 + 24, options: [])
        c.restoreGState()
        if let hero {
            c.saveGState()
            // Undo the top-down flip for the image itself.
            c.translateBy(x: budRect.minX, y: budRect.maxY); c.scaleBy(x: 1, y: -1)
            c.draw(hero, in: CGRect(origin: .zero, size: budRect.size))
            c.restoreGState()
        }
        // The cursor glint: porcelain arrow at the bud's upper right, with the accent glow.
        let arrowSize: CGFloat = small ? 230 : 150
        let tipPoint = CGPoint(x: min(tile.maxX - arrowSize * 0.75, budRect.maxX - (small ? 40 : 10)), y: max(tile.minY + 70, budRect.minY - (small ? 10 : 30)))
        let arrow = cursorPath(tip: tipPoint, height: arrowSize)
        if !small {
            c.saveGState()
            c.setShadow(offset: .zero, blur: 30, color: color(hue.aRGB, 0.8))
            c.addPath(arrow); c.setFillColor(color(RGB(0xFFFFFF))); c.fillPath()
            c.restoreGState()
        }
        c.saveGState()
        c.addPath(arrow); c.clip()
        c.drawLinearGradient(gradient([(RGB(0xFFFFFF), 1, 0), (RGB(0xE6E1F2), 1, 1)]),
                             start: CGPoint(x: tipPoint.x, y: tipPoint.y), end: CGPoint(x: tipPoint.x, y: tipPoint.y + arrowSize), options: [])
        c.restoreGState()
        c.addPath(arrow); c.setStrokeColor(color(RGB(0x2A1F4D), small ? 0.9 : 0.55)); c.setLineWidth(small ? 14 : 6); c.setLineJoin(.round); c.strokePath()
        // Glass sheen over the upper half, then a crisp rim.
        c.drawLinearGradient(gradient([(RGB(0xFFFFFF), 0.18, 0), (RGB(0xFFFFFF), 0, 1)]),
                             start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.midY), options: [])
        c.restoreGState()
        c.addPath(squircle); c.setStrokeColor(color(RGB(0xFFFFFF), 0.18)); c.setLineWidth(2); c.strokePath()
        return c.makeImage()
    }

    /// The macOS arrow pointer, tip at `tip`, `height` tall (top-down coordinates).
    static func cursorPath(tip: CGPoint, height h: CGFloat) -> CGPath {
        let u = h / 100
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 82), (20, 64), (33, 94), (47, 88), (34, 59), (60, 59)]
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: tip.x + $0.0 * u, y: tip.y + $0.1 * u) })
        path.closeSubpath()
        return path
    }
}
