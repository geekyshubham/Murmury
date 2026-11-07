// Records what VoiceOver speaks, for scripts/voiceover-check.sh. VoiceOver shows each phrase in its
// caption panel while speaking it; this reads the panel several times a second (its window,
// captured and read with Vision text recognition) and, where "Allow VoiceOver to be controlled
// with AppleScript" is on, VoiceOver's own last phrase, which is exact. It also dismisses
// VoiceOver's first-run welcome by choosing "Use VoiceOver".
// Usage: vo-listen <out.tsv> <stop-file> [--turn-off-at-stop]. Lines: <seconds since 1970> TAB <source>
// TAB <text>. With --turn-off-at-stop it turns VoiceOver off when the stop file appears (Command-F5,
// as a person would; quitting it only if that fails), so nothing asks for permission unattended.
import AppKit
import ApplicationServices
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: vo-listen out.tsv stop-file [--turn-off-at-stop]\n".utf8)); exit(2) }
let turnOffAtStop = args.contains("--turn-off-at-stop")
let outPath = args[1], stopPath = args[2]
FileManager.default.createFile(atPath: outPath, contents: nil)
let out = FileHandle(forWritingAtPath: outPath)!
let shot = NSTemporaryDirectory() + "vo-listen-\(getpid()).png"

func log(_ source: String, _ text: String) {
    let line = String(format: "%.3f", Date().timeIntervalSince1970) + "\t\(source)\t" + text.replacingOccurrences(of: "\n", with: " ⏎ ") + "\n"
    out.write(Data(line.utf8))
}

func copy(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }

/// Presses "Use VoiceOver" on the first-run welcome, if it is showing.
func dismissWelcome() {
    for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.apple.VoiceOverQuickstart" {
        let a = AXUIElementCreateApplication(app.processIdentifier)
        for w in (copy(a, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            for c in (copy(w, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where (copy(c, kAXTitleAttribute) as? String) == "Use VoiceOver" {
                if AXUIElementPerformAction(c, kAXPressAction as CFString) == .success { log("listener", "dismissed VoiceOver's welcome") }
            }
        }
    }
}

/// VoiceOver's own last phrase, when AppleScript control is allowed (VoiceOver Utility › General);
/// nil (and not tried again) otherwise, so no permission prompt can stall an unattended run.
var scriptAllowed = FileManager.default.fileExists(atPath: "/private/var/db/Accessibility/.VoiceOverAppleScriptEnabled")
func lastPhrase() -> String? {
    guard scriptAllowed else { return nil }
    var error: NSDictionary?
    let result = NSAppleScript(source: "tell application \"VoiceOver\" to return content of last phrase")?.executeAndReturnError(&error)
    if error != nil { scriptAllowed = false; log("listener", "AppleScript control of VoiceOver is off: reading the caption panel instead"); return nil }
    return result?.stringValue
}

/// Text in VoiceOver's on-screen windows (the caption panel), read from a capture of each.
func captionText() -> String? {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    var texts: [String] = []
    for w in windows where (w[kCGWindowOwnerName as String] as? String) == "VoiceOver" {
        guard let id = w[kCGWindowNumber as String] as? Int,
              let b = w[kCGWindowBounds as String] as? [String: Double], let h = b["Height"], let width = b["Width"],
              h >= 16, h <= 400, width >= 80 else { continue }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(id)", shot]
        try? p.run(); p.waitUntilExit()
        guard let image = NSImage(contentsOfFile: shot), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        if !lines.isEmpty { texts.append(lines.joined(separator: " ")) }
    }
    return texts.isEmpty ? nil : texts.joined(separator: " | ")
}

log("listener", "started")
var lastCaption = "", lastScript = "", voiceOverSeen = false
while !FileManager.default.fileExists(atPath: stopPath) {
    let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.VoiceOver" }
    if running != voiceOverSeen { voiceOverSeen = running; log("listener", running ? "VoiceOver is on" : "VoiceOver is off") }
    dismissWelcome()
    if running {
        if let phrase = lastPhrase(), phrase != lastScript { lastScript = phrase; log("spoke", phrase) }
        if let caption = captionText(), caption != lastCaption { lastCaption = caption; log("caption", caption) }
    }
    usleep(150_000)
}
func voiceOver() -> NSRunningApplication? { NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.VoiceOver" } }
if turnOffAtStop, voiceOver() != nil {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: source, virtualKey: 96, keyDown: down)  // F5
        if let e { e.flags = e.flags.union(.maskCommand); e.post(tap: .cghidEventTap) }
        usleep(40_000)
    }
    var waited = 0
    while voiceOver() != nil, waited < 30 { usleep(100_000); waited += 1 }
    if let vo = voiceOver() { _ = vo.terminate(); usleep(1_000_000); if !vo.isTerminated { _ = vo.forceTerminate() } }
    log("listener", voiceOver() == nil ? "turned VoiceOver off" : "couldn't turn VoiceOver off")
}
try? FileManager.default.removeItem(atPath: shot)
log("listener", "stopped")
