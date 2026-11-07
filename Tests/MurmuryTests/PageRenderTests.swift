#if DEBUG
import AppKit
import SceneKit
import SwiftUI
@testable import MurmuryKit

/// Supplemental offscreen layout evidence; it cannot certify window, focus or GPU behaviour.
@MainActor
func renderPageEvidence(to directory: URL) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func save<V: View>(_ view: V, size: CGSize, name: String) throws {
        let offline = ProcessInfo.processInfo.environment["MURMURY_OFFLINE"] == "1"
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .transaction { if offline { $0.disablesAnimations = true } })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.setFrameSize(size); host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: offline ? 0.2 : 0.9))
        host.layoutSubtreeIfNeeded(); host.needsDisplay = true
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        window.contentView = nil
    }
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let scheme: ColorScheme = dark ? .dark : .light
        let appearance = dark ? "dark" : "light"
        for size in [CGSize(width: 1120, height: 740), CGSize(width: 1600, height: 1000)] {
            for screen in AppModel.Screen.allCases {
                let model = AppModel(store: DatasetStore(directory: directory.appendingPathComponent("isolated-data")))
                model.screen = screen
                try save(ContentView().environment(model).environment(\.colorScheme, scheme), size: size,
                         name: "\(screen.title.lowercased())-\(appearance)-\(Int(size.width))x\(Int(size.height))")
            }
        }
        for scenario in AppModel.Scenario.allCases {
            let pointer = FakePointer(); pointer.isTrusted = true
            let model = AppModel(store: DatasetStore(directory: directory.appendingPathComponent("isolated-data")),
                                 headMouse: HeadMouse(driver: pointer, defaults: nil, ticks: false))
            model.startDemo(); model.applyScenario(scenario)
            try save(ContentView().environment(model).environment(\.colorScheme, scheme), size: CGSize(width: 1120, height: 740),
                     name: "state-\(scenario.rawValue)-\(appearance)")
            model.stopDemo()
        }
        for tab in SettingsTab.allCases {
            let model = AppModel(store: DatasetStore(directory: directory.appendingPathComponent("isolated-data")))
            model.settingsTab = tab
            try save(SettingsView().environment(model).environment(\.colorScheme, scheme), size: CGSize(width: 620, height: 460),
                     name: "settings-\(tab.rawValue.lowercased())-\(appearance)")
        }
        for destination in DetailDestination.allCases {
            let model = AppModel(store: DatasetStore(directory: directory.appendingPathComponent("isolated-data")))
            try save(DetailDestinationView(destination: destination).environment(model).environment(\.colorScheme, scheme),
                     size: CGSize(width: 720, height: 560), name: "sheet-\(destination.rawValue)-\(appearance)")
        }
        let model = AppModel(store: DatasetStore(directory: directory.appendingPathComponent("isolated-data")))
        try save(CameraCalibrationView().environment(model).environment(\.colorScheme, scheme), size: CGSize(width: 720, height: 560),
                 name: "sheet-camera-\(appearance)")
        model.applyScenario(.controlVoiceLost)
        try save(HeadMouseMenu().environment(model).environment(\.colorScheme, scheme), size: CGSize(width: 300, height: 520),
                 name: "menu-voice-lost-\(appearance)")
    }
}
#endif
