import AppKit
import SwiftUI
import Testing
@testable import MurmuryKit

/// Every screen's copy column fits its region at both reference window sizes, in the demo,
/// setup-missing, running, notice and recording states (measured by the real layout pass).
private enum PageFitProbe {
    static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/page-fit")
    static let entries: [[String: Any]]? = {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--page-fit-probe", directory.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["MURMURY_OFFLINE": "1"]) { _, new in new }
        let log = directory.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else { return nil }
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: directory.appendingPathComponent("fit.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }()
}

@Suite("Page fit")
struct PageFitTests {
    @Test(.enabled(if: PageFitProbe.entries != nil, "AppKit layout probe unavailable; see .build/page-fit/probe.log"))
    func copyColumnsFitTheirRegion() throws {
        let entries = try #require(PageFitProbe.entries)
        #expect(entries.count >= 2 * 11)
        for entry in entries {
            let natural = try #require(entry["natural"] as? Double), region = try #require(entry["region"] as? Double)
            let copyBottom = try #require(entry["copyBottom"] as? Double)
            let actionTop = try #require(entry["actionTop"] as? Double)
            let actionBottom = try #require(entry["actionBottom"] as? Double)
            let windowHeight = try #require(entry["windowHeight"] as? Double)
            #expect(copyBottom + 28 <= actionTop + 0.01)
            #expect(actionBottom <= windowHeight - 24 + 0.01)
            #expect(natural <= region, "\(entry["name"] ?? "?"): copy \(natural) > region \(region)")
        }
    }
}

#if DEBUG
@MainActor
func runPageFitProbe(to directory: URL) throws -> Int32 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    struct State { var name: String; var screen: AppModel.Screen; var demo = true; var trusted = true; var scenario: AppModel.Scenario? = nil }
    let states: [State] = AppModel.Screen.allCases.map { State(name: "demo-\($0.title)", screen: $0) } + [
        State(name: "setup-missing-Control", screen: .mouse, demo: false, trusted: false),
        State(name: "notice-Motion", screen: .sensors, demo: false),
        State(name: "running-Control", screen: .mouse, scenario: .controlRunning),
        State(name: "voice-lost-Control", screen: .mouse, scenario: .controlVoiceLost),
        State(name: "pointer-only-Control", screen: .mouse, scenario: .controlPointerOnly),
        State(name: "voice-off-Control", screen: .mouse, scenario: .controlVoiceOff),
        State(name: "voice-retrying-Control", screen: .mouse, scenario: .controlVoiceRetrying),
        State(name: "voice-recovery-failed-Control", screen: .mouse, scenario: .controlVoiceRecoveryFailed),
        State(name: "voice-denied-Control", screen: .mouse, scenario: .controlVoiceDenied),
        State(name: "recording-Teach", screen: .train, scenario: .teachRecording),
        State(name: "failed-Model", screen: .model, scenario: .modelFailed),
        State(name: "feedback-Detect", screen: .live, scenario: .detectFeedback),
    ]
    var results: [[String: Any]] = []
    for size in [CGSize(width: 1120, height: 740), CGSize(width: 1600, height: 1000)] {
        for state in states {
            let pointer = FakePointer(); pointer.isTrusted = state.trusted
            let data = directory.appendingPathComponent("data-\(UUID())")
            defer { try? FileManager.default.removeItem(at: data) }  // one throwaway store per state
            let model = AppModel(store: DatasetStore(directory: data),
                                 headMouse: HeadMouse(driver: pointer, defaults: nil, ticks: false))
            if state.demo { model.startDemo() }
            model.screen = state.screen
            if let scenario = state.scenario { model.applyScenario(scenario) }
            PageFitLog.entries = []
            let host = NSHostingView(rootView: ContentView().environment(model))
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
            host.layoutSubtreeIfNeeded()
            let page = size.width - PageLayout.sidebar - 1
            let mine = PageFitLog.entries.filter { abs($0.page.width - page) < 2 }
            let natural = mine.map(\.natural).max() ?? -1
            let region = mine.map(\.region).min() ?? 0
            let placement = mine.last?.composition
            results.append(["name": "\(state.name)-\(Int(size.width))", "natural": Double(natural), "region": Double(region),
                            "copyBottom": Double(placement?.copy.maxY ?? -1), "actionTop": Double(placement?.action.minY ?? -1),
                            "actionBottom": Double(placement?.action.maxY ?? -1), "windowHeight": Double(size.height)])
            model.stopDemo()
            window.orderOut(nil)
            window.contentView = nil
        }
    }
    try JSONSerialization.data(withJSONObject: results, options: .prettyPrinted).write(to: directory.appendingPathComponent("fit.json"))
    print(results.map { "\($0["name"]!): \($0["natural"]!) / \($0["region"]!)" }.joined(separator: "\n"))
    return results.contains { ($0["natural"] as? Double ?? -1) < 0 } ? 4 : 0
}
#endif
