import Foundation
import Testing
@testable import MurmuryKit

// Command Line Tools can't run swift-testing through `swift test`, so the suite is an
// executable: `swift run murmury-tests` (or scripts/test.sh).
if let i = CommandLine.arguments.firstIndex(of: "--offline-icon-probe"), CommandLine.arguments.count > i + 1 {
    do {
        let directory = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        try AppIconRenderer.render(to: directory.appendingPathComponent("legacy-cpu.iconset"), hero: .some(nil))
        try AppIconRenderer.previews(of: "Resources/AppIcon.icns", to: directory.appendingPathComponent("current-icon-previews"))
        exit(0)
    } catch { print(error); exit(1) }
}
if let i = CommandLine.arguments.firstIndex(of: "--inspect-scenes"), CommandLine.arguments.count > i + 1 {
    do { try inspectScenes(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); exit(0) }
    catch { print(error); exit(1) }
}
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--pointer-perf-probe"), CommandLine.arguments.count > i + 1 {
    do { exit(try runPointerPerformanceProbe(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))) }
    catch { print(error); exit(1) }
}
#endif
if let i = CommandLine.arguments.firstIndex(of: "--aura-pixel-probe"), CommandLine.arguments.count > i + 1 {
    do { exit(try renderAuraPixelProbe(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))) }
    catch { print(error); exit(1) }
}
if let i = CommandLine.arguments.firstIndex(of: "--orb-contrast-probe"), CommandLine.arguments.count > i + 1 {
    do { exit(try renderOrbContrastProbe(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))) }
    catch { print(error); exit(1) }
}
if let i = CommandLine.arguments.firstIndex(of: "--click-probe"), CommandLine.arguments.count > i + 1 {
    do { exit(try runClickProbe(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))) }
    catch { print(error); exit(1) }
}
#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--page-fit-probe"), CommandLine.arguments.count > i + 1 {
    do { exit(try runPageFitProbe(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))) }
    catch { print(error); exit(1) }
}
if let i = CommandLine.arguments.firstIndex(of: "--render-pages"), CommandLine.arguments.count > i + 1 {
    do { try renderPageEvidence(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); exit(0) }
    catch { print(error); exit(1) }
}
if let i = CommandLine.arguments.firstIndex(of: "--render-components"), CommandLine.arguments.count > i + 1 {
    do { try renderComponentEvidence(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); exit(0) }
    catch { print(error); exit(1) }
}
#endif
exit(await Testing.__swiftPMEntryPoint() as CInt)
