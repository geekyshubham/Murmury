import SwiftUI

/// Native vector mark; no cropped ICNS or unrelated fallback glyph.
struct BrandMark: View {
    var size: CGFloat = 30
    var body: some View {
        // The sidebar mark is the app icon's own tile artwork (one source of truth), rendered at 2×.
        Group {
            if let image = Self.tile(pixels: Int((size * 2).rounded())) {
                Image(decorative: image, scale: 2)
            } else {
                RoundedRectangle(cornerRadius: size * 184 / 824, style: .continuous).fill(AppIconArtV3.tileColor.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore).accessibilityLabel("Murmury")
    }

    @MainActor private static var cache: [Int: CGImage] = [:]
    @MainActor static func tile(pixels: Int) -> CGImage? {
        if let hit = cache[pixels] { return hit }
        let image = AppIconArtV3.image(pixels: pixels, tileOnly: true)
        cache[pixels] = image
        return image
    }
}

struct HeadProfile: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0.19, y: 0.85))
        p.addQuadCurve(to: CGPoint(x: 0.38, y: 0.71), control: CGPoint(x: 0.23, y: 0.74))
        p.addLine(to: CGPoint(x: 0.39, y: 0.62))
        p.addCurve(to: CGPoint(x: 0.31, y: 0.33), control1: CGPoint(x: 0.25, y: 0.55), control2: CGPoint(x: 0.25, y: 0.40))
        p.addCurve(to: CGPoint(x: 0.66, y: 0.27), control1: CGPoint(x: 0.38, y: 0.14), control2: CGPoint(x: 0.61, y: 0.16))
        p.addQuadCurve(to: CGPoint(x: 0.68, y: 0.39), control: CGPoint(x: 0.69, y: 0.33))
        p.addLine(to: CGPoint(x: 0.75, y: 0.46))
        p.addQuadCurve(to: CGPoint(x: 0.68, y: 0.49), control: CGPoint(x: 0.77, y: 0.49))
        p.addLine(to: CGPoint(x: 0.69, y: 0.56))
        p.addQuadCurve(to: CGPoint(x: 0.61, y: 0.64), control: CGPoint(x: 0.69, y: 0.64))
        p.addLine(to: CGPoint(x: 0.58, y: 0.71))
        p.addQuadCurve(to: CGPoint(x: 0.72, y: 0.85), control: CGPoint(x: 0.67, y: 0.75))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width, y: rect.height)).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

struct MurmurArcs: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 0..<3 {
            let x = 0.78 + Double(i) * 0.055
            let reach = 0.045 + Double(i) * 0.025
            p.move(to: CGPoint(x: x * rect.width, y: (0.51 - reach) * rect.height))
            p.addQuadCurve(to: CGPoint(x: x * rect.width, y: (0.51 + reach) * rect.height),
                           control: CGPoint(x: (x + 0.04) * rect.width, y: 0.51 * rect.height))
        }
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
