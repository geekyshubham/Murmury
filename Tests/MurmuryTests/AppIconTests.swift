import AppKit
import Testing
import ImageIO
@testable import MurmuryKit

@MainActor @Suite("App icon export")
struct AppIconTests {
    @Test func iconArgumentIsHandledBeforeNormalLaunch() throws {
        #expect(try AppIconRenderer.destination(from: ["Murmury", "--demo"]) == nil)
        #expect(try AppIconRenderer.destination(from: ["Murmury", "--render-icon=.build/test.iconset"])?.lastPathComponent == "test.iconset")
        #expect(throws: (any Error).self) { try AppIconRenderer.destination(from: ["Murmury", "--render-icon="]) }
    }
    @Test func exportsAllIconutilSizesWithTransparentMargins() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/icon-test-\(UUID()).iconset")
        defer { try? FileManager.default.removeItem(at: root) }
        try AppIconRenderer.render(to: root)
        let expected = ["icon_16x16.png": 16, "icon_16x16@2x.png": 32, "icon_32x32.png": 32,
                        "icon_32x32@2x.png": 64, "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
                        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
                        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024]
        for (name, size) in expected {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            let image = try #require(NSBitmapImageRep(data: data))
            #expect(image.pixelsWide == size && image.pixelsHigh == size)
            #expect((image.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01)
            #expect((image.colorAt(x: size / 2, y: size / 2)?.alphaComponent ?? 0) > 0.9)
        }
    }
    @Test func nativeIconContainerDecodesAsAnAppIcon() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/icns-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let iconset = root.appendingPathComponent("AppIcon.iconset")
        let icon = root.appendingPathComponent("AppIcon.icns")
        try AppIconRenderer.render(to: iconset)
        try AppIconRenderer.writeICNS(from: iconset, to: icon)
        let source = try #require(CGImageSourceCreateWithURL(icon as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "com.apple.icns")
        let widths = (0..<CGImageSourceGetCount(source)).compactMap { index -> Int? in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyPixelWidth] as? Int
        }
        #expect(widths.contains(1024))
        #expect(widths.contains(16))
        for index in 0..<CGImageSourceGetCount(source) {
            #expect(CGImageSourceCreateImageAtIndex(source, index, nil) != nil)
        }
        #expect(Set(widths) == [16, 32, 64, 128, 256, 512, 1024])
    }
    @Test func nativeFallbackHasRealArtwork() throws {
        let image = try #require(AppIconRenderer.fallbackImage())
        let rep = NSBitmapImageRep(cgImage: image)
        #expect(rep.pixelsWide == 1024)
        #expect((rep.colorAt(x: 512, y: 512)?.alphaComponent ?? 0) > 0.9)
        #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01)
    }
}

import Metal

@MainActor @Suite("Dimensional icon")
struct IconHeroTests {
    /// A stand-in hero: an opaque pearl ellipse, 400x500, on transparency.
    static func stub(_ rgb: RGB = RGB(0xE8E6EE)) -> CGImage {
        let c = CGContext(data: nil, width: 400, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1))
        c.fillEllipse(in: CGRect(x: 0, y: 0, width: 400, height: 500))
        return c.makeImage()!
    }
    /// At 32 px: the bud's brightest pixel in the upper middle, against the field at the lower left.
    static func budAndTile(_ p: Pixels) -> (RGB, RGB) {
        var best = RGB(r: 0, g: 0, b: 0)
        for y in 3..<16 { for x in 8..<24 where p.rgb(x, y).luminance > best.luminance { best = p.rgb(x, y) } }
        return (best, p.rgb(6, 22))
    }
    @Test func stubCompositionKeepsMarginsAndTheSafeArea() throws {
        let icon = try #require(IconHero.compose(hero: Self.stub(RGB(0xFF0000))))
        let p = Pixels(icon)
        #expect(p.width == 1024 && p.height == 1024)
        for (x, y) in [(0, 0), (1023, 0), (0, 1023), (1023, 1023), (40, 512), (512, 40)] { #expect(p.alpha(x, y) < 0.01) }
        #expect(p.alpha(512, 512) > 0.99)
        // Where the stub landed: inside the tile, clear of its rounded corners.
        var minX = 1024, minY = 1024, maxX = 0, maxY = 0
        for y in Swift.stride(from: 0, to: 1024, by: 2) { for x in Swift.stride(from: 0, to: 1024, by: 2) {
            let c = p.rgb(x, y)
            if c.r > 0.9, c.g < 0.35, c.b < 0.35 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        } }
        #expect(maxX > minX && maxY > minY)
        let safe = IconHero.tile.insetBy(dx: 40, dy: 40)
        #expect(CGFloat(minX) >= safe.minX && CGFloat(maxX) <= safe.maxX && CGFloat(minY) >= safe.minY && CGFloat(maxY) <= safe.maxY)
    }
    @Test func smallSizesSeparateTheBudFromTheTile() throws {
        let small = try #require(IconHero.compose(hero: Self.stub(), small: true))
        let icon32 = try #require(AppIconRenderer.downsample(small, to: 32))
        let (bud, tile) = Self.budAndTile(Pixels(icon32))
        #expect(contrast(bud, tile) >= 3, "bud \(bud) vs tile \(tile)")
    }
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Needs a Metal GPU")) func renderedHeroIsFramedAndNotClipped() throws {
        let hero = try #require(IconHero.render(pixels: 1024, crop: false))
        let p = Pixels(hero)
        var covered = 0
        for y in Swift.stride(from: 0, to: p.height, by: 2) { for x in Swift.stride(from: 0, to: p.width, by: 2) where p.alpha(x, y) > 0.5 { covered += 1 } }
        let coverage = Double(covered) / Double((p.width / 2) * (p.height / 2))
        #expect((0.08...0.40).contains(coverage), "coverage \(coverage)")
        #expect(p.neutralClippedShare <= 0.01)
        let icon = try #require(IconHero.compose(hero: IconHero.render(pixels: 1024)))
        let smallArt = try #require(IconHero.compose(hero: IconHero.render(pixels: 1024), small: true))
        let small = try #require(AppIconRenderer.downsample(smallArt, to: 32))
        #expect(Pixels(icon).alpha(512, 512) > 0.99)
        let (bud, tile) = Self.budAndTile(Pixels(small))
        #expect(contrast(bud, tile) >= 3, "bud \(bud) vs tile \(tile)")
    }
}
