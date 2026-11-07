import AppKit
import SwiftUI
import Testing
@testable import MurmuryKit

/// Two ordinary clicks (down and up 10 ms apart, as Murmury's spoken click posts them) on the
/// record orb save exactly one take: real AppKit event delivery into the SwiftUI gesture, in a
/// child process so AppKit failures can't take down the suite.
private enum ClickProbe {
    static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/click-probe")
    static let result: [String: Any]? = {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--click-probe", directory.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["MURMURY_OFFLINE": "1"]) { _, new in new }
        let log = directory.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return nil }
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: directory.appendingPathComponent("result.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }()
}

@Suite("Record orb clicks")
struct RecordOrbClickTests {
    @Test(.enabled(if: ClickProbe.result != nil, "AppKit event probe unavailable; see .build/click-probe/probe.log"))
    func twoClicksSaveOneTake() throws {
        let result = try #require(ClickProbe.result)
        #expect(result["afterFirstClick"] as? String == "toggled")
        #expect(result["takes"] as? Int == 1)
        #expect(result["lastFinish"] as? String == "toggled")
        #expect(result["holdTakes"] as? Int == 2)
        #expect(result["holdFinish"] as? String == "released")
    }
    @Test(.enabled(if: ClickProbe.result != nil, "AppKit event probe unavailable"))
    func composedTeachPageStartsAndStopsByOrdinaryClick() throws {
        let rows = try #require(ClickProbe.result?["composedPages"] as? [[String: Any]])
        #expect(rows.count == 2)
        for row in rows {
            #expect(row["started"] as? Bool == true)
            #expect(row["stopped"] as? Bool == true)
            #expect(row["takes"] as? Int == 1)
        }
    }
}

@MainActor
func runClickProbe(to directory: URL) throws -> Int32 {
    _ = NSApplication.shared
    // An accessory process never activates, so the probe can't steal focus from the person at the Mac.
    NSApp.setActivationPolicy(.accessory)
    let model = AppModel(store: DatasetStore(directory: directory.appendingPathComponent("data")),
                         headMouse: HeadMouse(driver: FakePointer(), defaults: nil, ticks: false))
    model.screen = .train
    model.currentLabel = "nod"
    model.startDemo()
    defer { model.stopDemo() }
    let size = CGSize(width: 300, height: 300)
    let host = NSHostingView(rootView: RecordOrb(hue: .teach, capture: model.capture).frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    func spin(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }
    spin(0.6)
    // The orb sits at the top of its column: aim at the orb face's centre.
    let orbCentre = NSPoint(x: size.width / 2, y: size.height / 2 + 14)
    func click(hold: Double) {
        for (type, delay) in [(NSEvent.EventType.leftMouseDown, hold), (.leftMouseUp, 0.0)] {
            guard let event = NSEvent.mouseEvent(with: type, location: orbCentre, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
            spin(max(delay, 0.01))
        }
    }
    func name(_ o: CaptureController.Ownership) -> String {
        switch o { case .none: "none"; case .toggled: "toggled"; case .held: "held" }
    }
    click(hold: 0.01)
    let afterFirst = name(model.capture.ownership)
    spin(1.0)
    click(hold: 0.01)
    spin(0.3)
    let takes = model.takes.count
    let lastFinish = model.capture.lastFinish.map { "\($0)" } ?? "nil"
    click(hold: 1.2)
    spin(0.3)
    window.orderOut(nil); window.contentView = nil
    var pages: [[String: Any]] = []
    #if DEBUG
    for pageSize in [CGSize(width: 1120, height: 740), CGSize(width: 1600, height: 1000)] {
        let pageModel = AppModel(store: DatasetStore(directory: directory.appendingPathComponent("page-\(Int(pageSize.width))")),
                                 headMouse: HeadMouse(driver: FakePointer(), defaults: nil, ticks: false))
        pageModel.screen = .train; pageModel.currentLabel = "nod"; pageModel.startDemo()
        PageFitLog.entries = []
        let pageHost = NSHostingView(rootView: ContentView().environment(pageModel).transaction { $0.disablesAnimations = true })
        let pageWindow = NSWindow(contentRect: CGRect(origin: CGPoint(x: -5000, y: -5000), size: pageSize), styleMask: [.borderless], backing: .buffered, defer: false)
        pageWindow.contentView = pageHost; pageWindow.orderFrontRegardless(); pageHost.layoutSubtreeIfNeeded(); spin(0.7)
        let placement = try #require(PageFitLog.entries.last?.composition)
        let centre = CGPoint(x: PageLayout.sidebar + placement.action.midX, y: pageSize.height - placement.action.minY - 56)
        func ordinaryClick(_ point: CGPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: pageWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    pageWindow.sendEvent(event); spin(0.01)
                }
            }
        }
        ordinaryClick(centre); spin(0.25)
        let started = pageModel.capture.ownership == .toggled
        // An ordinary click on the hero/content region uses the existing full StopTarget.
        spin(0.4); ordinaryClick(CGPoint(x: PageLayout.sidebar + 100, y: pageSize.height / 2)); spin(0.2)
        pages.append(["width": Int(pageSize.width), "started": started, "stopped": pageModel.capture.ownership == .none, "takes": pageModel.takes.count])
        pageModel.stopDemo(); pageWindow.orderOut(nil); pageWindow.contentView = nil
    }
    #endif
    let result: [String: Any] = ["afterFirstClick": afterFirst, "takes": takes, "lastFinish": lastFinish,
                                 "composedPages": pages, "holdTakes": model.takes.count, "holdFinish": model.capture.lastFinish.map { "\($0)" } ?? "nil"]
    try JSONSerialization.data(withJSONObject: result).write(to: directory.appendingPathComponent("result.json"))
    print(result)
    return 0
}
