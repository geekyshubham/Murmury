import Testing
@testable import MurmuryKit

@Suite("Component decisions")
struct ComponentTests {
    @Test func segmentArrowsClampAtEdges() {
        #expect(SegmentSelection.nextIndex(current: 0, count: 3, forward: false) == 0)
        #expect(SegmentSelection.nextIndex(current: 0, count: 3, forward: true) == 1)
        #expect(SegmentSelection.nextIndex(current: 2, count: 3, forward: true) == 2)
        #expect(SegmentSelection.nextIndex(current: 2, count: 3, forward: false) == 1)
        #expect(SegmentSelection.nextIndex(current: 0, count: 0, forward: true) == nil)
    }
    @Test func onlyHighestPriorityStatusIsShown() {
        let info = StatusNotice(tone: .info, text: "Info")
        let warning = StatusNotice(tone: .warn, text: "Warning")
        let danger = StatusNotice(tone: .danger, text: "Error")
        #expect(StatusNotice.highest(in: [info, warning, danger])?.text == "Error")
        #expect(StatusNotice.highest(in: [info, warning])?.text == "Warning")
        #expect(StatusNotice.highest(in: []) == nil)
        #expect(StatusNotice.highest(in: [info, StatusNotice(tone: .info, text: "Later")])?.text == "Info")
    }
}

#if DEBUG
import AppKit
import SwiftUI

/// Supplemental component stills; these are not substitutes for the window checkpoint.
@MainActor
func renderComponentEvidence(to directory: URL) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func save<V: View>(_ view: V, as name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
    for dark in [true, false] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let scheme: ColorScheme = dark ? .dark : .light
        let name = dark ? "dark" : "light"
        let host = NSHostingView(rootView: ControlsGallery().environment(\.colorScheme, scheme))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("controls-" + name + ".png"))
            }
        }
        try save(HStack(spacing: 24) {
            BrandMark(size: 16); BrandMark(size: 30)
            ForEach(Array(Hue.all.enumerated()), id: \.offset) { _, hue in GlyphTile(symbol: "gyroscope", hue: hue, size: 36) }
        }.padding(24).background(Ink.night).environment(\.colorScheme, scheme), as: "identity-" + name)
    }
}
#endif
