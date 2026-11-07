import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

// Presented-frame evidence: records the Murmury window as the compositor shows it (ScreenCaptureKit
// frame display times, not renderer callbacks).
// Usage: present-probe <pid> <seconds> <out.txt> [step-log]
// With a step log (MURMURY_STEP_PROBE), it also times each motion step from its sample's arrival to
// the first displayed frame that differs, and to the frame that reaches 90% of the step's change.

_ = NSApplication.shared  // CoreGraphics must be initialised before ScreenCaptureKit and NSScreen
let args = CommandLine.arguments
guard args.count >= 4, let pid = Int32(args[1]), let seconds = Double(args[2]) else {
    FileHandle.standardError.write(Data("Usage: present-probe <pid> <seconds> <out.txt> [step-log]\n".utf8)); exit(2)
}
let outPath = args[3], stepPath = args.count > 4 ? args[4] : nil

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func machSeconds(_ t: UInt64) -> Double { Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }

/// One displayed frame: its display time (uptime seconds) and a coarse luma grid of the hero region.
struct Frame { var t: Double; var grid: [Float] }
let gridSize = 40

final class Recorder: NSObject, SCStreamOutput {
    let lock = NSLock()
    var frames: [Frame] = []
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first, let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let display = info[.displayTime] as? UInt64, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels), row = CVPixelBufferGetBytesPerRow(pixels)
        let p = base.assumingMemoryBound(to: UInt8.self)
        // The hero sits between the sidebar and the copy column.
        let x0 = Int(Double(w) * 0.22), x1 = Int(Double(w) * 0.58), y0 = Int(Double(h) * 0.08), y1 = Int(Double(h) * 0.80)
        var grid = [Float](repeating: 0, count: gridSize * gridSize)
        for gy in 0..<gridSize {
            for gx in 0..<gridSize {
                let x = x0 + (x1 - x0) * gx / gridSize, y = y0 + (y1 - y0) * gy / gridSize
                let i = y * row + x * 4
                grid[gy * gridSize + gx] = 0.114 * Float(p[i]) + 0.587 * Float(p[i + 1]) + 0.299 * Float(p[i + 2])
            }
        }
        lock.withLock { frames.append(Frame(t: machSeconds(display), grid: grid)) }
    }
}

func percentile(_ v: [Double], _ q: Double) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * q + 0.5))]
}
func meanAbs(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(a.count) }

let done = DispatchSemaphore(value: 0)
var report = ""
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.frame.width >= 1000 }) else {
            report = "error: Murmury window not found"; done.signal(); return
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width); config.height = Int(window.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 240)  // never throttle below the display rate
        config.queueDepth = 8; config.pixelFormat = kCVPixelFormatType_32BGRA; config.showsCursor = false
        let recorder = Recorder()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        try await stream.stopCapture()
        let frames = recorder.lock.withLock { recorder.frames }.sorted { $0.t < $1.t }
        let screenHz = NSScreen.main?.maximumFramesPerSecond ?? 0
        // Pacing over frames whose content changed (the compositor only marks those complete).
        let gaps = zip(frames, frames.dropFirst()).map { ($1.t - $0.t) * 1000 }
        report += String(format: "presented frames %d over %.2f s (display max %d Hz): rate %.1f/s, interval p50 %.2f ms p95 %.2f ms p99 %.2f ms max %.2f ms\n",
                         frames.count, (frames.last?.t ?? 0) - (frames.first?.t ?? 0), screenHz,
                         Double(max(0, frames.count - 1)) / max(0.001, (frames.last?.t ?? 0) - (frames.first?.t ?? 0)),
                         percentile(gaps, 0.5), percentile(gaps, 0.95), percentile(gaps, 0.99), gaps.max() ?? .nan)
        if let stepPath, let text = try? String(contentsOfFile: stepPath, encoding: .utf8) {
            let steps = text.split(separator: "\n").compactMap { line -> Double? in
                let parts = line.split(separator: " "); return parts.count >= 2 ? Double(parts[1]) : nil
            }
            var first: [Double] = [], ninety: [Double] = [], moving = 0, moved = 0
            for (k, s) in steps.enumerated() {
                let next = k + 1 < steps.count ? steps[k + 1] : s + 1
                guard let before = frames.last(where: { $0.t < s }),
                      let settled = frames.last(where: { $0.t < next - 0.05 }), settled.t > s else { continue }
                let total = meanAbs(before.grid, settled.grid)
                guard total > 2 else { continue }  // the step must visibly move the head
                if let f = frames.first(where: { $0.t > s && meanAbs(before.grid, $0.grid) > 0.05 * total }) { first.append((f.t - s) * 1000) }
                if let f = frames.first(where: { $0.t > s && meanAbs(settled.grid, $0.grid) < 0.1 * total }) { ninety.append((f.t - s) * 1000) }
                // While the head is still travelling (first 150 ms after it starts), does every displayed frame show a new pose?
                if let start = frames.firstIndex(where: { $0.t > s && meanAbs(before.grid, $0.grid) > 0.05 * total }) {
                    var i = start
                    while i + 1 < frames.count, frames[i + 1].t < frames[start].t + 0.15 {
                        moving += 1
                        if meanAbs(frames[i].grid, frames[i + 1].grid) > 0.01 * total { moved += 1 }
                        i += 1
                    }
                }
            }
            report += String(format: "steps %d: sample arrival to first displayed change p50 %.1f ms p95 %.1f ms max %.1f ms; to 90%% of the move p50 %.1f ms p95 %.1f ms\n",
                             first.count, percentile(first, 0.5), percentile(first, 0.95), first.max() ?? .nan,
                             percentile(ninety, 0.5), percentile(ninety, 0.95))
            report += String(format: "while moving: %d of %d consecutive displayed frames show a new head pose (%.0f%%)\n", moved, moving, 100 * Double(moved) / Double(max(1, moving)))
            report += String(format: "clock check: uptime %.3f s, mach %.3f s\n", ProcessInfo.processInfo.systemUptime, machSeconds(mach_absolute_time()))
        }
    } catch {
        report = "error: \(error)"
    }
    done.signal()
}
done.wait()
try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
print(report, terminator: "")
