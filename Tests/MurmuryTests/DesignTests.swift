import AppKit
import SwiftUI
import Testing
@testable import MurmuryKit

@Suite("Semantic design")
struct DesignTests {
    @Test func wcagReference() {
        #expect(abs(contrast(RGB(0xFFFFFF), RGB(0x000000)) - 21) < 0.0001)
        #expect(contrast(RGB(0x123456), RGB(0x123456)) == 1)
    }
    @Test func whiteOrbLabels() {
        for hue in Hue.all { #expect(contrast(RGB(0xFFFFFF), hue.orbRGB) >= 4.5) }
    }
    @Test func semanticTextOnNight() {
        for p in [Palette.light, .dark] {
            for color in [p.live, p.warn, p.danger] { #expect(contrast(color, p.night) >= 4.5) }
            #expect(contrast(p.disabledText, p.night) >= 3)
        }
    }
    @Test func accessibilityMappings() {
        for dark in [true, false] {
            let p = Palette.resolve(dark: dark, increasedContrast: true, reducedTransparency: true)
            #expect(p.secondary == p.primary)
            #expect(p.tertiary == p.primary)
            #expect(p.glass.alpha == 1)
            #expect(p.glass == RGB(dark ? 0x3A1A7A : 0xFFFFFF)) // Phase 2: luminous violet opaque surfaces.
        }
    }
    @Test func copyColumnContrastAcrossFieldsAndDrift() {
        for size in [CGSize(width: 888, height: 740), CGSize(width: 1368, height: 1000)] {
            for hue in Hue.all {
                for dark in [true, false] {
                    let palette = dark ? Palette.dark : .light
                    for time in [0.0, 4.5, 9.0, 13.5] {
                        for point in PageLayout.copySamplePoints(in: size) {
                            let bg = FieldModel.sample(at: point, size: size, hue: hue, dark: dark, time: time)
                            #expect(contrast(palette.primary, bg) >= 7)
                            #expect(contrast(palette.secondary, bg) >= 4.5)
                            #expect(contrast(palette.tertiary, bg) >= 4.5)
                            #expect(contrast(palette.disabledText, bg) >= 3, "dark=\(dark), hue=\(hue), size=\(size), point=\(point)")
                        }
                    }
                }
            }
        }
    }
    @Test func layoutReservesActionBar() {
        // Phase 5: measured action follows the visible union; no fixed bottom reserve.
        #expect(PageLayout.sidebar == 232 && PageLayout.actionHeight == 140)
        #expect(PageLayout.gutter == 40 && PageLayout.titlebarInset == 44 && PageLayout.gap == 40)
        for size in [CGSize(width: 888, height: 740), CGSize(width: 1368, height: 1000)] {
            let c = PageLayout.composition(in: size)
            #expect(PageLayout.copyRect(in: size) == c.copy)
            #expect(c.copy.maxY + 28 <= c.action.minY)
            #expect(c.copy.maxX <= size.width - PageLayout.gutter)
            #expect(c.unit.minY >= PageLayout.titlebarInset)
            #expect(abs(c.visual.height / c.visual.width - PageLayout.visualAspect) < 0.001)
        }
    }
    @Test func compositionIsOneCentredUnit() {
        // Phase 5 replaces frame-centering with alignment by alpha >= 0.25 visible bounds.
        for size in [CGSize(width: 888, height: 740), CGSize(width: 1368, height: 1000), CGSize(width: 2328, height: 1440)] {
            let c = PageLayout.composition(in: size, copyHeight: 900)
            #expect(abs(c.unit.midX - size.width / 2) < 0.5)
            #expect(abs(c.visibleArt.maxY - c.unit.maxY) < 0.5 && abs(c.copy.minY - c.unit.minY) < 0.5, "art sits on the unit's floor, copy hangs from its top")
            #expect((360...520).contains(c.copy.width))
            #expect(c.copy.minX - c.visual.maxX == PageLayout.gap)
            #expect(c.unit.width <= 1120 && c.visual.width >= 340)
            #expect(c.action.maxY <= size.height - 24)
        }
    }
    @Test func typeScaleV2() {
        typealias S = TypeStyle.Size
        #expect(S.display == 44 && S.displayWide == 52 && TypeStyle.displayTracking == -0.6)
        #expect(TypeStyle.displaySize(width: 888) == 44 && TypeStyle.displaySize(width: 1368) == 52)
        #expect(S.subtitle == 19 && TypeStyle.subtitleLineSpacing == 4)
        #expect(S.rowTitle == 17 && S.rowDetail == 14 && S.body == 15 && S.caption == 13 && S.axis == 11)
        #expect(S.chip == 13 && S.button == 15 && S.orbLabel == 18 && S.sidebarItem == 15 && S.brand == 19)
        #expect(BenefitMetrics.tile == 40 && BenefitMetrics.minHeight == 56 && BenefitMetrics.spacing == Space.md)
        // Every text role a sheet uses is a token: one change reaches every screen.
        #expect(S.sheetTitle == 28 && S.reading == 24 && S.instruction == 22 && S.stat == 28 && S.transcript == 24)
    }
    @Test func twoSentenceLinesBreakBetweenSentences() {
        #expect(TypeStyle.sentenceLines("Turn your head to point. Voice or gestures act.") == "Turn your head to point.\nVoice or gestures act.")
        #expect(TypeStyle.sentenceLines("Your gestures, recognized as you move") == "Your gestures, recognized as you move")
    }
    @Test func spacingStaysOnTheScale() {
        #expect([Space.xxs, Space.unit, Space.sm, Space.md, Space.lg, Space.gutter, Space.xl] == [4, 8, 12, 16, 24, 32, 40])
    }
    @Test func outlinesOnlyWhereTheyHelp() {
        #expect(Palette.dark.glassStroke.alpha == 0.14)
        #expect(Palette.light.glassStroke.alpha == 0.14 && Palette.light.glassStroke.saturation > 0.5, "light strokes are violet, not grey")
        for dark in [true, false] {
            #expect(Palette.resolve(dark: dark, increasedContrast: true, reducedTransparency: false).glassStroke.alpha == 0.35)
        }
    }
}

/// A child process isolates AppKit's fatal registration failure on headless CLT hosts.
private enum AuraPixelEvidence {
    static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/aura-pixels")
    static let available: Bool = {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--aura-pixel-probe", directory.path]
        let log = directory.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return false }
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        do { try process.run(); process.waitUntilExit() } catch { return false }
        return process.terminationStatus == 0
    }()
}

@Suite("Rendered field")
struct AuraPixelTests {
    @Test(.enabled(if: AuraPixelEvidence.available, "ImageRenderer/AppKit unavailable or blank in CLI; see .build/aura-pixels/probe.log"))
    func renderedCopyColumnContrast() throws {
        let data = try Data(contentsOf: AuraPixelEvidence.directory.appendingPathComponent("samples.json"))
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(fields.count == 24)
        for field in fields {
            let dark = try #require(field["dark"] as? Bool)
            let pixels = try #require(field["pixels"] as? [[Double]])
            let palette = dark ? Palette.dark : .light
            #expect(pixels.count == 12)
            for pixel in pixels {
                let bg = RGB(r: pixel[0], g: pixel[1], b: pixel[2])
                #expect(contrast(palette.primary, bg) >= 7)
                #expect(contrast(palette.secondary, bg) >= 4.5)
                #expect(contrast(palette.tertiary, bg) >= 4.5)
                #expect(contrast(palette.disabledText, bg) >= 3)
            }
        }
    }
}

@MainActor
func renderAuraPixelProbe(to directory: URL) throws -> Int32 {
    _ = NSApplication.shared
    var fields: [[String: Any]] = []
    for (index, hue) in Hue.all.enumerated() {
        for dark in [true, false] {
            for size in [CGSize(width: 888, height: 740), CGSize(width: 1368, height: 1000)] {
                let content = Aura(hue: hue, sampleTime: 0).frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1
                guard let image = renderer.cgImage else { return 2 }
                let bitmap = NSBitmapImageRep(cgImage: image)
                // colorAt applies HDR headroom tone mapping on macOS 26. Decode the stored sRGB
                // pixels through CGContext, matching the primary and hero probes.
                let decoded = Pixels(image)
                let pixels: [[Double]] = PageLayout.copySamplePoints(in: size).map { point in
                    let color = decoded.rgb(min(image.width - 1, Int(point.x)), min(image.height - 1, Int(point.y)))
                    return [color.r, color.g, color.b]
                }
                guard pixels.count == 12, pixels.contains(where: { $0.reduce(0, +) > 0.01 }) else { return 3 }
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("\(index)-\(dark ? "dark" : "light")-\(Int(size.width)).png"))
                }
                fields.append(["dark": dark, "pixels": pixels])
            }
        }
    }
    try renderSidebarPixelEvidence(to: directory)
    try JSONSerialization.data(withJSONObject: fields).write(to: directory.appendingPathComponent("samples.json"))
    return 0
}
