import AppKit
import Foundation

/// Evidence only (`MURMURY_FIELD_LOG=<file.jsonl>`, set by scripts/field-test.sh): a journal of a
/// real session with the buds on. One JSON object per line, each with `wall` (seconds since 1970),
/// `up` (seconds since boot, the clock motion samples use) and `kind`.
///
/// - `second`, once a second: head frames drawn and their worst gap, motion samples received and
///   their worst gap, the bud that reported, sample-to-frame latency, pointer travel, whether the
///   microphone heard speech, the front app, the appearance and the app's state (`state`).
/// - events: what Murmury said (`said`), commands acted (`command`), commands heard inside
///   conversation (`conversation`) or from a voice that wasn't the wearer's (`not-wearer`), buds and
///   voice loss and recovery, the reporting bud changing (`bud`), and the camera fit (`camera-fit`).
final class FieldJournal: @unchecked Sendable {
    static let shared: FieldJournal? = ProcessInfo.processInfo.environment["MURMURY_FIELD_LOG"].flatMap { FieldJournal(path: $0) }

    private let handle: FileHandle
    private let lock = NSLock()
    private var frames = 0, lastFrame: TimeInterval?, frameGapMax = 0.0
    private var latencies: [Double] = []
    private var samples = 0, lastSample: TimeInterval?, sampleGapMax = 0.0, reportingBud: UInt8?, budsSeen: Set<UInt8> = []
    private var heardSpeech = false
    private var lastMouse: NSPoint?
    private var lastTick: TimeInterval?
    private var timer: Timer?
    /// The app's state for each `second` line (set by the app; read on the main thread).
    var state: (@MainActor () -> [String: Any])?

    init?(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
        handle.seekToEndOfFile()
        DispatchQueue.main.async { [self] in
            write(["kind": "start", "pid": Int(getpid()), "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"])
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    // MARK: Called from anywhere

    func event(_ kind: String, _ fields: [String: Any] = [:]) {
        var line = fields
        line["kind"] = kind
        write(line)
    }

    /// A head frame (SceneKit's renderer clock, seconds since boot).
    func frame(at t: TimeInterval) {
        lock.withLock {
            frames += 1
            if let lastFrame { frameGapMax = max(frameGapMax, t - lastFrame) }
            lastFrame = t
        }
    }
    /// A new motion sample's first frame came `seconds` after the sample arrived.
    func latency(_ seconds: Double) {
        guard seconds >= 0, seconds < 2 else { return }
        lock.withLock { latencies.append(seconds) }
    }
    /// `count` motion samples arrived at `arrival` (seconds since boot) from bud `bud`.
    func samples(_ count: Int, at arrival: TimeInterval, bud: UInt8?) {
        var changed: (from: UInt8, to: UInt8)?
        lock.withLock {
            samples += count
            if let lastSample { sampleGapMax = max(sampleGapMax, arrival - lastSample) }
            lastSample = arrival
            if let bud {
                budsSeen.insert(bud)
                if let reportingBud, reportingBud != bud { changed = (reportingBud, bud) }
                reportingBud = bud
            }
        }
        if let changed { event("bud", ["from": Int(changed.from), "to": Int(changed.to)]) }
    }
    func heard(speaking: Bool) { if speaking { lock.withLock { heardSpeech = true } } }

    // MARK: Once a second, on the main thread

    @MainActor private func tick() {
        let mouse = NSEvent.mouseLocation
        let travel = lastMouse.map { hypot(mouse.x - $0.x, mouse.y - $0.y) } ?? 0
        lastMouse = mouse
        let now = ProcessInfo.processInfo.systemUptime
        let span = lastTick.map { now - $0 }
        lastTick = now
        var line: [String: Any] = lock.withLock {
            let lat = latencies.sorted()
            func pct(_ p: Double) -> Double? { lat.isEmpty ? nil : lat[min(lat.count - 1, Int(Double(lat.count) * p))] * 1000 }
            let s: [String: Any?] = [
                "frames": frames, "frame_gap_max_ms": frames > 1 ? frameGapMax * 1000 : nil,
                "samples": samples, "sample_gap_max_ms": samples > 1 ? sampleGapMax * 1000 : nil,
                "since_sample_ms": lastSample.map { (ProcessInfo.processInfo.systemUptime - $0) * 1000 },
                "buds": budsSeen.sorted().map(Int.init),
                "latency_p50_ms": pct(0.5), "latency_max_ms": lat.last.map { $0 * 1000 }, "latency_n": lat.count,
                "speech": heardSpeech,
            ]
            frames = 0; frameGapMax = 0; latencies = []; samples = 0; sampleGapMax = 0; budsSeen = []; heardSpeech = false
            return s.compactMapValues { $0 }
        }
        line["kind"] = "second"
        if let span { line["span_s"] = (span * 1000).rounded() / 1000 }  // a late timer covers more than a second
        line["pointer_px"] = (travel * 10).rounded() / 10
        line["front"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        line["dark"] = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if let state { line.merge(state()) { a, _ in a } }
        write(line)
    }

    private func write(_ fields: [String: Any]) {
        var line = fields
        line["wall"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        line["up"] = (ProcessInfo.processInfo.systemUptime * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        lock.withLock { handle.write(data + Data("\n".utf8)) }
    }
}
