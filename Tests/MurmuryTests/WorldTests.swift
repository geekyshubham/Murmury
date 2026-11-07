import SwiftUI
import Testing
@testable import MurmuryKit

@Suite("Luminous world")
struct WorldTests {
    @Test func fullWindowGridKeepsBrightnessSaturationAndStatusContrast() {
        for size in [CGSize(width: 1120, height: 740), CGSize(width: 1600, height: 1000)] {
            for hue in Hue.all {
                for time in [0.0, 4.5, 9, 13.5] {
                    var levels: [Double] = []
                    for x in 0..<12 { for y in 0..<8 {
                        let point = CGPoint(x: CGFloat(x) / 11 * size.width, y: CGFloat(y) / 7 * size.height)
                        var bg = FieldModel.sample(at: point, size: size, hue: hue, dark: true, time: time,
                                                   origin: CGPoint(x: PageLayout.sidebar, y: 0))
                        if point.x < PageLayout.sidebar { bg = SidebarSurface.sample(over: bg, hue: hue, dark: true) }
                        levels.append(bg.luminance)
                        #expect(bg.luminance >= 0.04)
                        #expect(bg.saturation >= 0.45)
                        for ink in [Palette.dark.live, Palette.dark.warn, Palette.dark.danger] { #expect(contrast(ink, bg) >= 3) }
                    } }
                    #expect(levels.sorted()[levels.count / 2] >= 0.06)
                }
            }
        }
    }
    @Test func fullWindowCopyColumnAndSidebarMeetAA() {
        for size in [CGSize(width: 1120, height: 740), CGSize(width: 1600, height: 1000)] {
            for hue in Hue.all {
                for time in [0.0, 4.5, 9, 13.5] {
                    for point in PageLayout.copySamplePoints(in: CGSize(width: size.width - PageLayout.sidebar, height: size.height)) {
                        let bg = FieldModel.sample(at: CGPoint(x: point.x + PageLayout.sidebar, y: point.y), size: size, hue: hue,
                                                   dark: true, time: time, origin: CGPoint(x: PageLayout.sidebar, y: 0))
                        #expect(bg.luminance <= 0.10)
                        #expect(contrast(Palette.dark.primary, bg) >= 7)
                        #expect(contrast(Palette.dark.secondary, bg) >= 4.5)
                        #expect(contrast(Palette.dark.tertiary, bg) >= 4.5)
                        #expect(contrast(Palette.dark.disabledText, bg) >= 3)
                    }
                    for dark in [true, false] { for y in 0..<8 {
                        let p = dark ? Palette.dark : .light
                        let field = FieldModel.sample(at: CGPoint(x: 100, y: CGFloat(y) / 7 * size.height), size: size, hue: hue, dark: dark, time: time)
                        for selected in [false, true] {
                            let bg = selected ? SidebarSurface.selection(hue: hue, dark: dark) : SidebarSurface.sample(over: field, hue: hue, dark: dark)
                            #expect(contrast(p.primary, bg) >= 7)
                            #expect(contrast(p.secondary, bg) >= 4.5)
                        }
                    } }
                }
            }
        }
    }
    @Test func lightConstantsArePinnedAndHeroFollowsPageOrigin() {
        for hue in Hue.all {
            let light = FieldModel.layers(hue: hue, dark: false)
            #expect(light.top == RGB(0xF8F5FE) && light.bottom == RGB(0xEEE8FA))
            #expect(light.lights.map(\.opacity) == [0.26, 0.07, 0.35])
            let size = CGSize(width: 1120, height: 740)
            let model = FieldModel.layers(hue: hue, dark: true, size: size, origin: CGPoint(x: 232, y: 0))
            #expect(abs(model.lights[0].center.x * size.width - (232 + 0.27 * 888)) < 0.001)
            #expect(model.lights[0].center.y == 0.40)
            #expect(model.lights[0].opacity == 0.50 && model.lights[3].opacity == 0.41)  // round 38: a quieter copy pool, within the floor
            #expect(model.lights.count == 4 && model.lights[3].center.x > 0.8)
        }
        #expect(Palette.light.night == RGB(0xEEE8FA))
        #expect(Palette.light.sidebar == RGB(0xFFFFFF, alpha: 0.45))
    }
    @Test func sidebarBoundaryAndBackdropAreSoft() {
        for hue in Hue.all {
            let size = CGSize(width: 1120, height: 740)
            for y in 0..<8 {
                let field = FieldModel.sample(at: CGPoint(x: 232, y: CGFloat(y) / 7 * 740), size: size, hue: hue, dark: true)
                let left = SidebarSurface.sample(over: field, hue: hue, dark: true)
                let right = SidebarSurface.edge(over: field, hue: hue, fraction: 1.0 / 24)
                #expect(abs(left.luminance - right.luminance) <= 0.02)
            }
            let layers = HeroBackdrop.layers(hue: hue, dark: true, recording: false)
            #expect(layers.first { $0.name == "floor" }!.color.luminance >= 0.02)
            for layer in layers { #expect(layer.alpha(atRadius: 1) < 0.01) }
        }
    }
}

import AppKit

@MainActor func renderSidebarPixelEvidence(to directory: URL) throws {
    var rows: [[String: Any]] = []
    for (index, hue) in Hue.all.enumerated() {
        for dark in [true, false] {
            let size = CGSize(width: 1120, height: 740)
            let content = ZStack(alignment: .leading) {
                Aura(hue: hue, sampleTime: 0, pageOrigin: 232)
                SidebarSurfaceView(hue: hue).frame(width: 232)
            }.frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            guard let image = renderer.cgImage else { throw CocoaError(.fileReadUnknown) }
            let pixels = Pixels(image)
            var minimum = 1.0
            for x in 0..<232 { for y in 0..<740 { minimum = min(minimum, pixels.rgb(x, y).luminance) } }
            rows.append(["hue": index, "dark": dark, "minimumSidebarLuminance": minimum])
            if dark, minimum < 0.04 { throw CocoaError(.coderInvalidValue) }
        }
    }
    try JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted).write(to: directory.appendingPathComponent("sidebar.json"))
}
