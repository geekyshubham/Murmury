import SwiftUI

/// One silhouette in normalised tile coordinates. CPU icon export and SwiftUI share this path.
struct MurmurMark: Shape {
    enum Concept: String, CaseIterable { case pointer, ribbon, cursor }
    var concept = Concept.pointer
    var small = false
    static func stroke(small: Bool) -> CGFloat { 0.15 * (small ? 1.12 : 1) }
    static func outline(concept: Concept = .pointer, small: Bool = false) -> CGPath {
        let p = CGMutablePath()
        if concept == .pointer {
            // A soft classic pointer (a true rounded polygon: tangent arcs at every corner) with two
            // round-capped motion arcs in the wedge above its leading edge: the head moves the
            // pointer. Small sizes drop the arcs so the arrow stays crisp. Subpaths never overlap,
            // so no boolean union (which left slivers) is needed.
            // Small sizes use a bolder, larger arrow (≈ 21% of the tile) so 16–32 px stay legible.
            let corners = small
                ? [CGPoint(x: 0.26, y: 0.13), CGPoint(x: 0.26, y: 0.86), CGPoint(x: 0.445, y: 0.715), CGPoint(x: 0.555, y: 0.875),
                   CGPoint(x: 0.685, y: 0.82), CGPoint(x: 0.585, y: 0.655), CGPoint(x: 0.83, y: 0.655)]
                : [CGPoint(x: 0.30, y: 0.19), CGPoint(x: 0.30, y: 0.78), CGPoint(x: 0.445, y: 0.655), CGPoint(x: 0.545, y: 0.845),
                   CGPoint(x: 0.645, y: 0.80), CGPoint(x: 0.548, y: 0.615), CGPoint(x: 0.735, y: 0.615)]
            let radii: [CGFloat] = [0.035, 0.03, 0.012, 0.028, 0.028, 0.012, 0.03]
            let result = CGMutablePath()
            let n = corners.count
            let start = CGPoint(x: (corners[n - 1].x + corners[0].x) / 2, y: (corners[n - 1].y + corners[0].y) / 2)
            result.move(to: start)
            for i in 0..<n {
                result.addArc(tangent1End: corners[i], tangent2End: corners[(i + 1) % n], radius: radii[i] * (small ? 1.2 : 1))
            }
            result.closeSubpath()
            guard !small else { return result }
            for radius: CGFloat in [0.33, 0.45] {
                let arc = CGMutablePath()
                arc.addArc(center: CGPoint(x: 0.30, y: 0.19), radius: radius, startAngle: 0.08, endAngle: 0.62, clockwise: false)
                result.addPath(arc.copy(strokingWithWidth: 0.05, lineCap: .round, lineJoin: .round, miterLimit: 2))
            }
            return result
        }
        if concept == .ribbon {
            p.move(to: CGPoint(x: 0.22, y: 0.72))
            p.addLine(to: CGPoint(x: 0.33, y: 0.32))
            p.addLine(to: CGPoint(x: 0.50, y: 0.57))
            p.addLine(to: CGPoint(x: 0.68, y: 0.30))
            p.addLine(to: CGPoint(x: 0.78, y: 0.72))
            let result = CGMutablePath()
            let ribbon = p.copy(strokingWithWidth: stroke(small: small), lineCap: .round, lineJoin: .round, miterLimit: 2)
            // The right peak terminates in a tapered upward pointer, integral to the ribbon.
            result.move(to: CGPoint(x: 0.68, y: 0.19))
            result.addLine(to: CGPoint(x: 0.58, y: 0.365))
            result.addLine(to: CGPoint(x: 0.785, y: 0.365)); result.closeSubpath()
            return ribbon.union(result)
        }
        // Tilted cursor with a broad shoulder and two enclosed negative-space murmur arcs.
        p.move(to: CGPoint(x: 0.20, y: 0.16))
        for q in [CGPoint(x: 0.84, y: 0.48), CGPoint(x: 0.60, y: 0.56), CGPoint(x: 0.72, y: 0.77),
                  CGPoint(x: 0.58, y: 0.84), CGPoint(x: 0.46, y: 0.62), CGPoint(x: 0.28, y: 0.78)] { p.addLine(to: q) }
        p.closeSubpath()
        let result = CGMutablePath()
        // Counter-wound holes preserve a single connected outer silhouette.
        let gap: CGFloat = small ? 0.035 : 0.028
        for (x, y, width) in [(0.31, 0.36, 0.13), (0.33, 0.46, 0.18)] {
            result.move(to: CGPoint(x: x, y: y))
            result.addLine(to: CGPoint(x: x, y: y + gap))
            result.addQuadCurve(to: CGPoint(x: x + width, y: y - 0.025 + gap), control: CGPoint(x: x + width * 0.55, y: y - 0.055 + gap))
            result.addLine(to: CGPoint(x: x + width, y: y - 0.025))
            result.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x + width * 0.55, y: y - 0.055)); result.closeSubpath()
        }
        return p.subtracting(result)
    }

    func path(in rect: CGRect) -> Path {
        var t = CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY)
        return Path(Self.outline(concept: concept, small: small).copy(using: &t)!)
    }
    static func mask(pixels: Int, concept: Concept = .pointer, small: Bool = false, normalisedWeight: Bool = false) -> CGImage? {
        guard let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(pixels)); c.scaleBy(x: CGFloat(pixels), y: -CGFloat(pixels))
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.addPath(outline(concept: concept, small: small && !normalisedWeight)); c.fillPath()
        return c.makeImage()
    }
}
