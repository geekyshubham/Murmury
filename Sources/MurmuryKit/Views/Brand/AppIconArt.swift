import AppKit
import SwiftUI

/// Round 1's flat icon, kept as the rollback and the art used where no GPU can render `IconHero`.
struct AppIconArtV1: View {
    private let size: CGFloat = 824
    var body: some View {
        ZStack {
            let shape = RoundedRectangle(cornerRadius: 184, style: .continuous)
            shape.fill(LinearGradient(colors: [RGB(0x9B5CFF).color, RGB(0xC21E8E).color], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.26), radius: 28, y: 18)
            shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.30), location: 0), .init(color: .clear, location: 0.55)], startPoint: .top, endPoint: .bottom))
            HeadProfile().fill(LinearGradient(colors: [.white, RGB(0xDAD4EA).color], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.2), radius: 18, y: 14)
            Capsule().fill(LinearGradient(colors: [RGB(0xD9FFF8).color, RGB(0x4BE3D1).color], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.065, height: size * 0.23).rotationEffect(.degrees(-12))
                .offset(x: -size * 0.055, y: size * 0.035)
                .shadow(color: RGB(0x91FFE7).color.opacity(0.85), radius: 22)
            MurmurArcs().stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: size * 0.026, lineCap: .round))
            shape.strokeBorder(.white.opacity(0.40), lineWidth: 2)
        }
        .frame(width: size, height: size)
        .frame(width: 1024, height: 1024)
    }
}

/// CPU-only V3: a solid violet tile and the same single mark used by the sidebar.
enum AppIconArtV3 {
    /// One solid violet; white keeps ≥ 4.5:1 against it.
    static let tileColor = RGB(0x7C3AED)
    static let shadowColor = RGB(0x3B0F7A)
    static func image(pixels: Int, concept: MurmurMark.Concept = .pointer, tileOnly: Bool = false) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = CGFloat(pixels) / 1024
        c.translateBy(x: 0, y: CGFloat(pixels)); c.scaleBy(x: scale, y: -scale)
        let rect = tileOnly ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = RoundedRectangle(cornerRadius: rect.width * 184 / 824, style: .continuous).path(in: rect).cgPath
        if !tileOnly {
            // macOS icon grid: a soft contact shadow under the tile.
            c.saveGState()
            // Shadow sizes are in device pixels (the CTM does not apply): scale them with the icon.
            c.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 28 * scale, color: RGB(0x1A0838, alpha: 0.38).nsColor.cgColor)
            c.addPath(shape); c.setFillColor(tileColor.nsColor.cgColor); c.fillPath()
            c.restoreGState()
        }
        c.saveGState(); c.addPath(shape); c.clip()
        // Flat: one solid violet and a solid white mark. No gradient ramp, glow, shade or light rim.
        c.setFillColor(tileColor.nsColor.cgColor); c.fill(rect)
        var transform = CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY)
        let mark = MurmurMark.outline(concept: concept, small: pixels <= (tileOnly ? 40 : 32)).copy(using: &transform)!
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -6 * scale * rect.width / 824), blur: 14 * scale * rect.width / 824,
                    color: CGColor(gray: 0, alpha: 0.22))
        c.addPath(mark); c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fillPath()
        c.restoreGState()
        c.restoreGState()
        return c.makeImage()
    }
}

@MainActor
enum AppIconRenderer {
    static func destination(from args: [String]) throws -> URL? {
        guard let option = args.first(where: { $0.hasPrefix("--render-icon=") }) else { return nil }
        let path = String(option.dropFirst("--render-icon=".count))
        guard !path.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    enum IconError: LocalizedError {
        case noMetal
        var errorDescription: String? {
            "No Metal device: the app icon is rendered with SceneKit. Run scripts/make-icon.sh on a Mac with a GPU; the existing icon was left unchanged."
        }
    }
    /// V3 renders every size on the CPU. `--icon-style=hero` retains the previous GPU icon rollback.
    static func render(to directory: URL, requireMetal: Bool = false, hero: CGImage?? = nil) throws {
        _ = NSApplication.shared
        let useHero = CommandLine.arguments.contains("--icon-style=hero") || hero != nil
        let large: CGImage, small: CGImage
        if useHero {
            let heroImage: CGImage? = hero ?? IconHero.render()
            if heroImage == nil, requireMetal { throw IconError.noMetal }
            if let heroImage, let l = IconHero.compose(hero: heroImage), let s = IconHero.compose(hero: heroImage, small: true) {
                large = l; small = s
            } else {
                guard let fallback = fallbackImage() else { throw CocoaError(.fileWriteUnknown) }
                large = fallback; small = fallback
            }
        } else {
            guard let l = AppIconArtV3.image(pixels: 1024), let s = AppIconArtV3.image(pixels: 32) else { throw CocoaError(.fileWriteUnknown) }
            large = l; small = s
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let image = (useHero ? downsample(pixels <= 32 ? small : large, to: pixels) : AppIconArtV3.image(pixels: pixels)),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try png.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        }
    }
    /// Halves repeatedly before the last step, so small sizes stay crisp.
    static func downsample(_ image: CGImage, to pixels: Int) -> CGImage? {
        var current = image
        while current.width / 2 >= pixels, current.width / 2 > 0 {
            guard let half = resize(current, to: current.width / 2) else { return nil }
            current = half
        }
        return current.width == pixels ? current : resize(current, to: pixels)
    }
    private static func resize(_ image: CGImage, to pixels: Int) -> CGImage? {
        guard let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.interpolationQuality = .high
        c.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return c.makeImage()
    }
    /// Finder/Dock-style previews of an icon file or app: each size, plus the 1024 art on light and dark grounds.
    static func previews(of path: String, to directory: URL) throws {
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let icon = path.hasSuffix(".icns") ? (NSImage(contentsOfFile: path) ?? NSImage()) : NSWorkspace.shared.icon(forFile: path)
        func save(_ size: Int, background: NSColor?, name: String) throws {
            let pad = background == nil ? 0 : size / 4
            let total = size + 2 * pad
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: total, pixelsHigh: total, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            if let background { background.setFill(); NSRect(x: 0, y: 0, width: total, height: total).fill() }
            icon.draw(in: NSRect(x: pad, y: pad, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
        for size in [16, 32, 128, 512] {
            try save(size, background: nil, name: "icon-\(size).png")
            for concept in MurmurMark.Concept.allCases {
                guard let art = AppIconArtV3.image(pixels: size, concept: concept) else { continue }
                for dark in [false, true] {
                    let total = size + size / 2
                    let c = CGContext(data: nil, width: total, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    c.setFillColor((dark ? RGB(0x211F29) : RGB(0xEEEEF2)).nsColor.cgColor)
                    c.fill(CGRect(x: 0, y: 0, width: total, height: total))
                    c.draw(art, in: CGRect(x: size / 4, y: size / 4, width: size, height: size))
                    if let image = c.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        try png.write(to: directory.appendingPathComponent("\(concept.rawValue)-\(dark ? "dark" : "light")-\(size).png"))
                    }
                }
            }
        }
        // One CPU contact sheet keeps the optical-size decision reviewable in a single artifact.
        let sheetWidth = 2240, sheetHeight = 1000
        if let c = CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
            var y = sheetHeight - 48
            for size in [16, 32, 128, 512] {
                for (column, choice) in [(MurmurMark.Concept.ribbon, false), (.ribbon, true), (.cursor, false), (.cursor, true)].enumerated() {
                    let x = column * 560, height = max(72, size + 48)
                    c.setFillColor((choice.1 ? RGB(0x211F29) : RGB(0xEEEEF2)).nsColor.cgColor)
                    c.fill(CGRect(x: x, y: y - height, width: 560, height: height))
                    NSAttributedString(string: "\(choice.0.rawValue) · \(size) px", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: choice.1 ? NSColor.white : .black])
                        .draw(at: CGPoint(x: x + 16, y: y - 24))
                    if let art = AppIconArtV3.image(pixels: size, concept: choice.0) {
                        c.draw(art, in: CGRect(x: x + (560 - size) / 2, y: y - height + 8, width: size, height: size))
                    }
                }
                y -= max(72, size + 48)
            }
            NSGraphicsContext.restoreGraphicsState()
            if let sheet = c.makeImage(), let png = NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("concept-sheet.png"))
            }
        }
        try save(512, background: NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1), name: "dock-light-512.png")
        try save(512, background: NSColor(srgbRed: 0.13, green: 0.12, blue: 0.16, alpha: 1), name: "dock-dark-512.png")
        try save(64, background: NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1), name: "dock-light-64.png")
        try save(64, background: NSColor(srgbRed: 0.13, green: 0.12, blue: 0.16, alpha: 1), name: "dock-dark-64.png")
    }
    /// ICNS is a length-prefixed collection of PNG representations. This path also works
    /// on CLT hosts where iconutil's image encoder is unavailable; ImageIO verifies it in tests.
    static func writeICNS(from directory: URL, to destination: URL) throws {
        let representations = [("icp4", "16x16"), ("ic11", "16x16@2x"), ("icp5", "32x32"), ("ic12", "32x32@2x"),
                               ("ic07", "128x128"), ("ic13", "128x128@2x"), ("ic08", "256x256"), ("ic14", "256x256@2x"),
                               ("ic09", "512x512"), ("ic10", "512x512@2x")]
        func chunk(_ type: String, _ payload: Data) throws -> Data {
            guard var length = UInt32(exactly: payload.count + 8) else { throw CocoaError(.fileWriteUnknown) }
            length = length.bigEndian
            var result = Data(type.utf8)
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(payload)
            return result
        }
        var contents = Data()
        for (type, name) in representations {
            contents.append(try chunk(type, Data(contentsOf: directory.appendingPathComponent("icon_" + name + ".png"))))
        }
        try chunk("icns", contents).write(to: destination, options: .atomic)
    }
    private static func bitmap(size: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }
    /// CPU-only fallback uses the same profile and arcs, without starting SwiftUI's app lifecycle.
    static func fallbackImage() -> CGImage? {
        guard let rep = bitmap(size: 1024), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        cg.translateBy(x: 0, y: 1024); cg.scaleBy(x: 1, y: -1)
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tile = CGPath(roundedRect: rect, cornerWidth: 184, cornerHeight: 184, transform: nil)
        func gradient(_ path: CGPath, _ colors: [NSColor]) {
            cg.saveGState(); cg.addPath(path); cg.clip()
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil) {
                cg.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 824, y: 924), options: [])
            }
            cg.restoreGState()
        }
        cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 28, color: NSColor.black.withAlphaComponent(0.26).cgColor)
        cg.addPath(tile); cg.setFillColor(RGB(0x9B5CFF).nsColor.cgColor); cg.fillPath()
        cg.setShadow(offset: .zero, blur: 0, color: nil)
        gradient(tile, [RGB(0x9B5CFF).nsColor, RGB(0xC21E8E).nsColor])
        gradient(tile, [.white.withAlphaComponent(0.30), .white.withAlphaComponent(0)])
        let head = HeadProfile().path(in: rect).cgPath
        cg.setShadow(offset: CGSize(width: 0, height: 14), blur: 18, color: NSColor.black.withAlphaComponent(0.20).cgColor)
        cg.addPath(head); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()
        cg.setShadow(offset: .zero, blur: 0, color: nil)
        gradient(head, [.white, RGB(0xDAD4EA).nsColor])
        cg.saveGState()
        let center = CGPoint(x: 512 - 824 * 0.055, y: 512 + 824 * 0.035)
        cg.translateBy(x: center.x, y: center.y); cg.rotate(by: -.pi / 15); cg.translateBy(x: -center.x, y: -center.y)
        let blade = CGPath(roundedRect: CGRect(x: center.x - 27, y: center.y - 95, width: 54, height: 190), cornerWidth: 27, cornerHeight: 27, transform: nil)
        cg.setShadow(offset: .zero, blur: 22, color: RGB(0x91FFE7).nsColor.cgColor)
        cg.addPath(blade); cg.setFillColor(RGB(0x91FFE7).nsColor.cgColor); cg.fillPath()
        cg.restoreGState()
        cg.addPath(MurmurArcs().path(in: rect).cgPath)
        cg.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor); cg.setLineWidth(824 * 0.026); cg.setLineCap(.round); cg.strokePath()
        cg.addPath(tile); cg.setStrokeColor(NSColor.white.withAlphaComponent(0.40).cgColor); cg.setLineWidth(2); cg.strokePath()
        return rep.cgImage
    }
}
