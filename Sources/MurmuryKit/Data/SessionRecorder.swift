import Foundation

/// Writes raw experiment sessions to ~/Documents/Murmury/Sessions/<timestamp>-<condition>/:
/// motion.csv (every sample), events.csv (segments + labels/predictions), meta.json.
final class SessionRecorder {
    private(set) var directory: URL?
    private var motion: FileHandle?
    private var events: FileHandle?
    private var t0: TimeInterval = 0

    var isRecording: Bool { directory != nil }

    func start(condition: String) throws -> URL {
        stop()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safe = condition.replacingOccurrences(of: "/", with: "-")
        let dir = docs.appendingPathComponent("Murmury/Sessions/\(stamp)-\(safe)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        t0 = ProcessInfo.processInfo.systemUptime
        FileManager.default.createFile(atPath: dir.appendingPathComponent("motion.csv").path,
                                       contents: (MotionSample.csvHeader + "\n").data(using: .utf8))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("events.csv").path,
                                       contents: "t_start,t_end,kind,label,confidence\n".data(using: .utf8))
        motion = try FileHandle(forWritingTo: dir.appendingPathComponent("motion.csv"))
        events = try FileHandle(forWritingTo: dir.appendingPathComponent("events.csv"))
        motion?.seekToEndOfFile(); events?.seekToEndOfFile()
        let meta: [String: Any] = ["condition": condition, "started": ISO8601DateFormatter().string(from: Date()),
                                   "device": "Galaxy Buds3 Pro", "stream": "SPATIAL_AUDIO_DATA GRV quaternion"]
        try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted)
            .write(to: dir.appendingPathComponent("meta.json"))
        directory = dir
        return dir
    }

    func write(_ s: MotionSample) {
        motion?.write((s.csvRow(relativeTo: t0) + "\n").data(using: .utf8)!)
    }

    func event(start: TimeInterval, end: TimeInterval, kind: String, label: String, confidence: Double) {
        let row = String(format: "%.4f,%.4f,%@,%@,%.3f\n", start - t0, end - t0, kind, label, confidence)
        events?.write(row.data(using: .utf8)!)
    }

    func stop() {
        try? motion?.close(); try? events?.close()
        motion = nil; events = nil; directory = nil
    }
}
