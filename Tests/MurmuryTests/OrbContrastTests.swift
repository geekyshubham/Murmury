import AppKit
import SwiftUI
import Testing
@testable import MurmuryKit

/// White orb labels measured on the real composite: the label-less orb face rendered over the page
/// field for every hue, appearance, breathing phase and state.
private enum OrbProbe {
    static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/orb-contrast")
    static let samples: [[String: Any]]? = {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--orb-contrast-probe", directory.path]
        let log = directory.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return nil }
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: directory.appendingPathComponent("orbs.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }()
}

@Suite("Orb label contrast")
struct OrbContrastTests {
    @Test(.enabled(if: OrbProbe.samples != nil, "ImageRenderer unavailable; see .build/orb-contrast/probe.log"))
    func whiteLabelPassesOnRenderedOrb() throws {
        let samples = try #require(OrbProbe.samples)
        #expect(samples.count == 6 * 2 * 5) // Phase 3: idle/active/hover/pressed/disabled.
        for sample in samples {
            let worst = try #require(sample["worstContrast"] as? Double)
            #expect(worst >= ((sample["enabled"] as? Bool == false) ? 3 : 4.5), "\(sample["name"] ?? "?"): \(worst)")
        }
    }
    @Test(.enabled(if: OrbProbe.samples != nil, "ImageRenderer unavailable; see .build/orb-contrast/probe.log"))
    func glowFadesBeforeItsFrameEdge() throws {
        let samples = try #require(OrbProbe.samples)
        for sample in samples {
            let edge = try #require(sample["glowTopRowAlpha"] as? Double)
            #expect(edge < 0.01, "\(sample["name"] ?? "?"): \(edge)")
        }
    }
    @Test(.enabled(if: OrbProbe.samples != nil, "ImageRenderer unavailable; see .build/orb-contrast/probe.log"))
    func heroBackdropHasNoEdges() throws {
        let data = try Data(contentsOf: OrbProbe.directory.appendingPathComponent("backdrops.json"))
        let backdrops = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(backdrops.count == 6 * 2 * 2)
        for b in backdrops {
            let edge = try #require(b["borderAlpha"] as? Double)
            #expect((b["maskBorderAlpha"] as? Double ?? 1) < 0.01)
            #expect((b["maskCenterAlpha"] as? Double ?? 0) > 0.99)
            #expect(edge < 0.01, "\(b["name"] ?? "?"): \(edge)")
        }
    }
    @Test(.enabled(if: OrbProbe.samples != nil, "ImageRenderer unavailable; see .build/orb-contrast/probe.log"))
    func flatSecondaryLabelsPassOnTheirRenderedSurface() throws {
        let data = try Data(contentsOf: OrbProbe.directory.appendingPathComponent("secondaries.json"))
        let samples = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(samples.count == 120)
        for sample in samples {
            let worst = try #require(sample["worstContrast"] as? Double)
            #expect(worst >= ((sample["enabled"] as? Bool == false) ? 3 : 4.5))
        }
    }
    @Test func glowFitsTheApron() {
        #expect(OrbMetrics.glowRadius <= OrbMetrics.orbCentreFromBarTop + PageLayout.glowApron)
        #expect(OrbMetrics.diameter == 112)
    }
}

@MainActor
func renderOrbContrastProbe(to directory: URL) throws -> Int32 {
    _ = NSApplication.shared
    var results: [[String: Any]] = []
    let d = OrbMetrics.diameter
    let states: [(String, Bool, Bool, Bool, Bool)] = [("idle", false, false, true, false),
        ("active", true, false, true, false), ("hover", false, false, true, true),
        ("pressed", false, true, true, false), ("disabled", false, false, false, false)]
    for (hueIndex, hue) in Hue.all.enumerated() {
        for dark in [true, false] {
            for (name, active, pressed, enabled, hovering) in states {
                let frame = OrbMetrics.glowFrame
                let content = ZStack {
                    Aura(hue: hue, sampleTime: 0)
                    OrbFace(hue: hue, active: active, pressed: pressed, enabled: enabled, label: EmptyView(), hovering: hovering, sampleTime: 0)
                }
                .frame(width: frame, height: frame)
                .environment(\.colorScheme, dark ? .dark : .light)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.cgImage else { return 2 }
                let pixels = Pixels(image)
                var worst = 21.0, worstAt = [0.0, 0.0], worstRGB = [0.0, 0.0, 0.0]
                let c = Double(image.width) / 2, scale = Double(image.width) / frame
                for y in Int(c - 0.18 * d * scale)...Int(c + 0.18 * d * scale) {
                    for x in Int(c - 0.36 * d * scale)...Int(c + 0.36 * d * scale) {
                        let value = contrast(RGB(0xFFFFFF), pixels.rgb(x, y))
                        if value < worst {
                            worst = value
                            worstAt = [(Double(x) - c) / (d * scale), (Double(y) - c) / (d * scale)]
                            let p = pixels.rgb(x, y); worstRGB = [p.r, p.g, p.b]
                        }
                    }
                }
                // Solid face plus contact shadow, on transparency, with no radial glow.
                let glow = ImageRenderer(content: PrimaryActionFace(hue: hue, active: active, pressed: pressed, enabled: enabled,
                    label: EmptyView(), hovering: hovering, sampleTime: 0).frame(width: frame, height: frame)
                    .environment(\.colorScheme, dark ? .dark : .light))
                glow.scale = 2
                guard let glowImage = glow.cgImage else { return 2 }
                let glowPixels = Pixels(glowImage)
                var topRow = 0.0
                for x in 0..<glowImage.width { topRow = max(topRow, glowPixels.alpha(x, 0), glowPixels.alpha(x, glowImage.height - 1)) }
                for y in 0..<glowImage.height { topRow = max(topRow, glowPixels.alpha(0, y), glowPixels.alpha(glowImage.width - 1, y)) }
                let label = "\(hueIndex)-\(dark ? "dark" : "light")-\(name)"
                if name == "idle" || name == "disabled",
                   let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent(label + ".png"))
                }
                results.append(["name": label, "enabled": enabled, "worstContrast": worst, "worstAt": worstAt, "worstRGB": worstRGB, "glowTopRowAlpha": topRow])
            }
        }
    }
    var secondaries: [[String: Any]] = []
    for hue in Hue.all { for dark in [true, false] { for selected in [false, true] {
        for (_, _, pressed, enabled, hovering) in states {
            let view = ZStack {
                Aura(hue: hue, sampleTime: 0)
                if selected { Capsule().fill(hue.actionRGB.color).frame(width: 160, height: 40) }
                else { FlatCapsule(pressed: pressed && enabled, hovering: hovering && enabled).frame(width: 160, height: 40) }
            }.frame(width: 224, height: 100).environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            guard let image = renderer.cgImage else { return 2 }
            let pixels = Pixels(image), label = FlatControlSpec.label(dark: dark, enabled: enabled, selected: selected)
            var worst = 21.0
            for y in 80..<120 { for x in 140..<300 { worst = min(worst, contrast(label, pixels.rgb(x, y))) } }
            secondaries.append(["enabled": enabled, "dark": dark, "selected": selected, "worstContrast": worst])
        }
    } } }
    try JSONSerialization.data(withJSONObject: secondaries, options: .prettyPrinted).write(to: directory.appendingPathComponent("secondaries.json"))
    try JSONSerialization.data(withJSONObject: results, options: .prettyPrinted).write(to: directory.appendingPathComponent("orbs.json"))
    // The hero backdrop alone: every layer must already be transparent along its frame's border.
    var backdrops: [[String: Any]] = []
    var maskBorder = 0.0, maskCenter = 1.0
    for kind in HeroMask.Kind.allCases {
        let shape = kind == .head ? AnyView(HeroMask.Shape()) : AnyView(HeroMask.ProductShape())
        let renderer = ImageRenderer(content: Color.white.frame(width: 454, height: 563).mask(shape))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return 2 }
        let p = Pixels(image)
        maskCenter = min(maskCenter, p.alpha(image.width / 2, image.height / 2))
        for x in 0..<image.width { maskBorder = max(maskBorder, p.alpha(x, 0), p.alpha(x, image.height - 1)) }
        for y in 0..<image.height { maskBorder = max(maskBorder, p.alpha(0, y), p.alpha(image.width - 1, y)) }
    }
    for (hueIndex, hue) in Hue.all.enumerated() {
        for dark in [true, false] {
            for recording in [false, true] {
                // Phase 5: inspect the actual frame boundary; a blank outer canvas hid clipped layers.
                let renderer = ImageRenderer(content: HeroBackdropView(hue: hue, recording: recording).frame(width: 454, height: 563)
                    .environment(\.colorScheme, dark ? .dark : .light))
                renderer.scale = 1
                guard let image = renderer.cgImage else { return 2 }
                let p = Pixels(image)
                var border = 0.0
                for x in 0..<image.width { border = max(border, p.alpha(x, 0), p.alpha(x, image.height - 1)) }
                for y in 0..<image.height { border = max(border, p.alpha(0, y), p.alpha(image.width - 1, y)) }
                backdrops.append(["name": "\(hueIndex)-\(dark ? "dark" : "light")\(recording ? "-recording" : "")", "borderAlpha": border, "maskBorderAlpha": maskBorder, "maskCenterAlpha": maskCenter])
            }
        }
    }
    try JSONSerialization.data(withJSONObject: backdrops, options: .prettyPrinted).write(to: directory.appendingPathComponent("backdrops.json"))
    return 0
}
