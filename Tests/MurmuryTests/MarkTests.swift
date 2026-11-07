import AppKit
import SwiftUI
import Testing
@testable import MurmuryKit

@MainActor @Suite("Murmur mark")
struct MarkTests {
    @Test func silhouetteHasAnInsetAndSmallOpticalWeight() {
        for concept in MurmurMark.Concept.allCases {
            for small in [false, true] {
                let b = MurmurMark.outline(concept: concept, small: small).boundingBoxOfPath
                #expect(CGRect(x: 0.12, y: 0.12, width: 0.76, height: 0.76).contains(b))
            }
            #expect(MurmurMark.stroke(small: true) == MurmurMark.stroke(small: false) * 1.12)
        }
    }
    @Test func cpuSmallMarksAreBoldConnectedAndHaveOpenGaps() throws {
        for concept in MurmurMark.Concept.allCases { for size in [16, 32] {
            let image = try #require(MurmurMark.mask(pixels: size, concept: concept, small: true))
            let p = Pixels(image)
            var covered = 0, runs = 0, inRun = false
            for y in 0..<size { for x in 0..<size where p.alpha(x, y) >= 0.5 { covered += 1 } }
            let coverage = Double(covered) / Double(size * size)
            #expect((0.18...0.40).contains(coverage), "\(concept) at \(size): \(coverage)")
            if concept == .ribbon {
                // At the lower M, two legs and the upward right stroke remain separate.
                for x in 0..<size {
                    let on = p.alpha(x, Int(Double(size) * 0.66)) >= 0.5
                    if on && !inRun { runs += 1 }; inRun = on
                }
                #expect(runs >= 2)
            }
            if concept == .ribbon {
                #expect(p.alpha(Int(Double(size) * 0.68), Int(Double(size) * 0.32)) >= 0.9, "pointer joins the ribbon without a winding hole")
            }
            #expect(contrast(RGB(0xFFFFFF), AppIconArtV3.tileColor) >= 4.5)
        } }
    }
    @Test func opticalVariantsAgreeAfterNormalisingWeight() throws {
        for concept in MurmurMark.Concept.allCases {
            let a = Pixels(try #require(MurmurMark.mask(pixels: 256, concept: concept, small: false)))
            let b = Pixels(try #require(MurmurMark.mask(pixels: 256, concept: concept, small: true, normalisedWeight: true)))
            var intersection = 0, union = 0
            for y in 0..<256 { for x in 0..<256 {
                let aa = a.alpha(x, y) > 0.5, bb = b.alpha(x, y) > 0.5
                if aa && bb { intersection += 1 }; if aa || bb { union += 1 }
            } }
            #expect(Double(intersection) / Double(union) >= 0.9)
        }
    }
    @Test func tileAndSidebarUseTheIdenticalShape() throws {
        let icon = Pixels(try #require(AppIconArtV3.image(pixels: 64, tileOnly: true)))
        let renderer = ImageRenderer(content: BrandMark(size: 64))
        renderer.scale = 1
        let brand = Pixels(try #require(renderer.cgImage))
        var intersection = 0, union = 0
        for y in 0..<64 { for x in 0..<64 {
            let a = icon.rgb(x, y).luminance > 0.8, b = brand.rgb(x, y).luminance > 0.8
            if a && b { intersection += 1 }; if a || b { union += 1 }
        } }
        #expect(Double(intersection) / Double(union) >= 0.9)
        let full = Pixels(try #require(AppIconArtV3.image(pixels: 64)))
        #expect(full.alpha(0, 0) == 0 && full.alpha(32, 32) > 0.99)
    }
    @Test func packagedIconMatchesSource() throws {
        let source = try Data(contentsOf: URL(fileURLWithPath: "Resources/AppIcon.icns"))
        let packaged = try Data(contentsOf: URL(fileURLWithPath: "build/Murmury.app/Contents/Resources/AppIcon.icns"))
        #expect(source == packaged)
    }
}
