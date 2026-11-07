import Foundation
import Testing
@testable import MurmuryKit

@Suite("Connected composition and hero edges")
struct CompositionTests {
    @Test func everyHeroSurfaceVanishesInsideItsFrame() {
        for kind in HeroMask.Kind.allCases {
            for i in 0...100 {
                let t = Double(i) / 100
                for p in [CGPoint(x: t, y: 0), CGPoint(x: t, y: 1), CGPoint(x: 0, y: t), CGPoint(x: 1, y: t)] {
                    #expect(HeroMask.alpha(x: p.x, y: p.y, kind: kind) == 0)
                    #expect(HeroMask.edgeAlpha(x: p.x, y: p.y) == 0)
                }
            }
            #expect(HeroMask.alpha(x: 0.5, y: 0.4, kind: kind) == 1)
        }
    }
    @Test func neutralMaskBoundsMatchScanAndFitEnvelope() {
        for kind in HeroMask.Kind.allCases {
            var scan = CGRect.null
            for y in 0...500 { for x in 0...500 {
                let p = CGPoint(x: Double(x) / 500, y: Double(y) / 500)
                if HeroMask.alpha(x: p.x, y: p.y, kind: kind) >= 0.25 {
                    scan = scan.union(CGRect(origin: p, size: CGSize(width: 0.0001, height: 0.0001)))
                }
            } }
            scan = scan.intersection(HeroMask.neutralGeometryBounds(kind: kind))
            let bounds = HeroMask.visibleBounds(kind: kind)
            for delta in [bounds.minX - scan.minX, bounds.maxX - scan.maxX, bounds.minY - scan.minY, bounds.maxY - scan.maxY] {
                #expect(abs(delta) < 0.01)
            }
            #expect(HeroMask.envelope(kind: kind).contains(bounds))
        }
    }
    /// One grid: the title line and the primary action land in the same place on every screen and
    /// in every state, whatever the copy's height or the hero's kind.
    @Test func titleAndActionHoldStillAcrossScreens() {
        for size in [CGSize(width: 888, height: 740), CGSize(width: 1368, height: 1000), CGSize(width: 2328, height: 1440)] {
            let reference = PageLayout.composition(in: size, copyHeight: 360, kind: .head)
            for kind in HeroMask.Kind.allCases { for height in [360.0, 460, 520, 900] {
                let c = PageLayout.composition(in: size, copyHeight: height, kind: kind)
                #expect(abs(c.action.minY - reference.action.minY) < 0.01 && abs(c.action.midX - reference.action.midX) < 0.01, "action holds still")
                #expect(abs(c.copy.minY - reference.copy.minY) < 0.01 && abs(c.copy.minX - reference.copy.minX) < 0.01, "title holds still")
                #expect(c.action.minY >= c.copy.maxY + 27.99)
                #expect(c.action.minY - c.visibleArt.maxY <= 56.01)
                #expect(c.action.maxY <= size.height - 16)
                #expect(c.unit.minY >= 44)
                #expect(abs(c.stack.midY - (44 + size.height - 24) / 2) < 0.5)
                #expect(abs(c.stack.midX - size.width / 2) < 0.5)
                #expect(c.unit.width <= 1120.01)
                #expect(c.visual.width >= 340)
            } }
        }
    }
}
