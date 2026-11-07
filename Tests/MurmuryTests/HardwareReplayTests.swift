import Foundation
import Testing
@testable import MurmuryKit

/// Replays 10 s of SPP traffic captured from a real Galaxy Buds3 Pro (head moving, some rests).
/// Fixture lines: `<seconds> RX <hex bytes>`, exactly as `MURMURY_TRACE` writes them.
@Suite("Real Buds3 Pro replay")
struct HardwareReplayTests {
    static func replay() throws -> [MotionSample] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/buds3pro-stream.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var decoder = SppDecoder()
        let pipeline = MotionPipeline(historySeconds: 60)
        var out: [MotionSample] = []
        pipeline.onSample = { out.append($0) }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count > 2, parts[1] == "RX", let t = Double(parts[0]) else { continue }
            let bytes = parts.dropFirst(2).compactMap { UInt8($0, radix: 16) }
            for msg in decoder.feed(bytes) {
                if case let .motion(samples, _)? = BudsEvent(msg, at: t) { pipeline.ingest(samples, arrival: t) }
            }
        }
        return out
    }

    @Test func everyPacketIsAnExtendedGyroPacket() throws {
        let s = try Self.replay()
        #expect(s.count > 300)
        #expect(s.allSatisfy { $0.hasIMU })
        let g = s.map { ($0.ax * $0.ax + $0.ay * $0.ay + $0.az * $0.az).squareRoot() }.sorted()
        #expect(abs(g[g.count / 2] - 9.8) < 0.6)  // accelerometer at rest reads gravity (m/s²)
    }

    @Test func clumpedDeliveryGivesSteadySensorTimestamps() throws {
        let s = try Self.replay()
        let steps = zip(s, s.dropFirst()).map { $1.t - $0.t }.dropFirst(80)  // after the rate settles
        let steady = steps.filter { $0 > 0.015 && $0 < 0.035 }.count
        #expect(Double(steady) / Double(steps.count) > 0.95)
    }

    @Test func derivedVelocityHasNoSpikesAndAgreesWithTheGyro() throws {
        let s = try Self.replay()
        let deg = 180 / Double.pi
        let derived = s.map { $0.angularSpeed * deg }.sorted()
        let gyro = s.map { ($0.gx * $0.gx + $0.gy * $0.gy + $0.gz * $0.gz).squareRoot() * deg }.sorted()
        #expect(derived.last! < 600)  // a head can't turn faster; ~1 ms timestamps gave thousands
        let p90 = { (a: [Double]) in a[a.count * 9 / 10] }
        #expect(p90(derived) / p90(gyro) > 0.6 && p90(derived) / p90(gyro) < 1.7)
    }
}
