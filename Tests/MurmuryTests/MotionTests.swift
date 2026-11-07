import Foundation
import simd
import Testing
@testable import MurmuryKit

@Suite("Kinematics")
struct KinematicsTests {
    static func sample(_ q: simd_quatd, bud: UInt8 = 0, gyro: [Double]? = nil, accel: [Double]? = nil) -> HeadSample {
        HeadSample(q: Quat(w: q.real, x: q.imag.x, y: q.imag.y, z: q.imag.z), gyro: gyro, accel: accel, bud: bud)
    }

    @Test func constantYawRateIsRecovered() {
        var k = Kinematics()
        var last: MotionSample?
        for i in 0..<100 {
            let t = Double(i) / 50
            last = k.ingest(Self.sample(simd_quatd(angle: 1.0 * t, axis: [0, 0, 1])), t: t)
        }
        let s = try! #require(last)
        #expect(abs(s.wz - 1) < 0.02)
        #expect(abs(s.wx) < 1e-6 && abs(s.wy) < 1e-6)
        #expect(s.angularAccel < 0.1)
    }

    @Test func signFlippedQuaternionIsNotAMovement() {
        var k = Kinematics()
        let q = simd_quatd(angle: 0.3, axis: [1, 0, 0])
        _ = k.ingest(Self.sample(q), t: 0)
        let s = k.ingest(Self.sample(simd_quatd(vector: -q.vector)), t: 0.02)
        #expect(s.angularSpeed < 1e-6)
    }

    @Test func budRoleSwitchDoesNotCreateSpike() {
        var k = Kinematics()
        _ = k.ingest(Self.sample(simd_quatd(angle: 0, axis: [0, 0, 1]), bud: 0), t: 0)
        let s = k.ingest(Self.sample(simd_quatd(angle: 1.2, axis: [0, 1, 0]), bud: 1), t: 0.02)
        #expect(s.angularSpeed == 0)
    }

    @Test func gapResetsDerivatives() {
        var k = Kinematics()
        _ = k.ingest(Self.sample(simd_quatd(angle: 0, axis: [0, 0, 1])), t: 0)
        let s = k.ingest(Self.sample(simd_quatd(angle: 1, axis: [0, 0, 1])), t: 2)
        #expect(s.angularSpeed == 0)
    }

    @Test func imuVectorsPassThrough() {
        var k = Kinematics()
        let s = k.ingest(Self.sample(simd_quatd(angle: 0, axis: [0, 0, 1]), gyro: [0.1, 0.2, 0.3], accel: [0, 0, 1]), t: 0)
        #expect(s.hasIMU)
        #expect([s.gx, s.gy, s.gz] == [0.1, 0.2, 0.3])
        #expect([s.ax, s.ay, s.az] == [0, 0, 1])
    }

    @Test func eulerOfIdentityIsZero() {
        let (p, r, y) = Kinematics.euler(simd_quatd(angle: 0, axis: [0, 0, 1]))
        #expect(p == 0 && r == 0 && y == 0)
    }

    @Test func eulerSeparatesAxes() {
        let (p, r, y) = Kinematics.euler(simd_quatd(angle: 0.4, axis: [0, 0, 1]))
        #expect(abs(y - 0.4) < 1e-9 && abs(p) < 1e-9 && abs(r) < 1e-9)
    }
}

@Suite("Sample clock")
struct SampleClockTests {
    @Test func spreadsBatchedSamplesAcrossThePacketInterval() {
        var c = SampleClock()
        #expect(c.timestamps(count: 1, arrival: 1.00) == [1.00])
        let ts = c.timestamps(count: 4, arrival: 1.08)
        #expect(ts.count == 4)
        #expect(abs(ts[0] - 1.02) < 1e-9 && abs(ts[3] - 1.08) < 1e-9)
        #expect(zip(ts, ts.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func neverGoesBackwards() {
        var c = SampleClock()
        _ = c.timestamps(count: 1, arrival: 5)
        let ts = c.timestamps(count: 3, arrival: 4.9) // late/jittered delivery
        #expect(ts.allSatisfy { $0 > 5 })
    }

    /// Real Buds3 Pro: ~42 Hz sensor, delivered in clumps of 1–8 frames a few ms apart, then
    /// 50–100 ms of silence. Timestamps must follow the sensor, not the radio.
    @Test func clumpedDeliveryStillGetsEvenlySpacedTimestamps() {
        var c = SampleClock()
        var ts: [Double] = []
        var arrivals: [Double] = []
        for k in 0..<120 {                       // 40 Hz sensor, sent 3 at a time
            let sent = Double(k / 3) * 0.075 + 0.075
            let arrival = sent + Double(k % 3) * 0.001
            arrivals.append(arrival)
            ts += c.timestamps(count: 1, arrival: arrival)
        }
        let steps = zip(ts.dropFirst(60), ts.dropFirst(61)).map { $1 - $0 }
        #expect(steps.allSatisfy { abs($0 - 0.025) < 0.004 })
        #expect(zip(ts, arrivals).allSatisfy { abs($0 - $1) < 0.15 })
        #expect(abs(c.interval - 0.025) < 0.002)
    }

    @Test func aStallRestartsFromTheArrivalTime() {
        var c = SampleClock()
        for k in 0..<50 { _ = c.timestamps(count: 1, arrival: Double(k) * 0.025) }
        let after = c.timestamps(count: 1, arrival: 3.0)  // 1.8 s with nothing
        #expect(abs(after[0] - 3.0) < 1e-9)
    }

    @Test func firstBatchUsesNominalSpacing() {
        var c = SampleClock()
        let ts = c.timestamps(count: 3, arrival: 10)
        #expect(ts.last == 10)
        #expect(abs((ts[1] - ts[0]) - SampleClock.nominalInterval) < 1e-9)
    }
}

@Suite("Features")
struct FeatureTests {
    static func take(yawAt heading: Double, nod amplitude: Double) -> [MotionSample] {
        var k = Kinematics()
        return (0..<50).map { i in
            let t = Double(i) / 50
            let q = simd_quatd(angle: heading, axis: [0, 0, 1]) * simd_quatd(angle: amplitude * sin(2 * .pi * 2 * t), axis: [1, 0, 0])
            return k.ingest(KinematicsTests.sample(q), t: t)
        }
    }

    @Test func orientationFeaturesIgnoreHeading() {
        let a = Features.frames(Self.take(yawAt: 0, nod: 0.2), set: .orientation)
        let b = Features.frames(Self.take(yawAt: 1.3, nod: 0.2), set: .orientation)
        let diff = zip(a, b).map { zip($0, $1).map { abs($0 - $1) }.max()! }.max()!
        #expect(diff < 1e-6)
    }

    @Test func channelCountsMatchFeatureSet() {
        #expect(FeatureSet.all.channelNames.count == 9)
        #expect(FeatureSet.imu.channelNames.count == 6)
        #expect(FeatureSet([.orientation, .imu]).channelNames.count == 9)
        let frames = Features.frames(Self.take(yawAt: 0, nod: 0.2), set: [.velocity, .imu])
        #expect(frames.first?.count == 9)
    }

    @Test func resampleKeepsEndpoints() {
        let f: [[Double]] = [[0], [10], [20]]
        let r = Features.resample(f, to: 5)
        #expect(r.map { $0[0] } == [0, 5, 10, 15, 20])
    }

    @Test func trimDropsQuietLeadIn() {
        var k = Kinematics()
        var samples: [MotionSample] = []
        for i in 0..<60 {
            let t = Double(i) / 50
            let angle = i < 30 ? 0 : 0.3 * sin(2 * .pi * 3 * (t - 0.6))
            samples.append(k.ingest(KinematicsTests.sample(simd_quatd(angle: angle, axis: [1, 0, 0])), t: t))
        }
        let trimmed = Features.trim(samples)
        #expect(trimmed.count < samples.count)
        #expect(trimmed.first!.t > 0.4)
    }

    @Test func augmentationPreservesShape() {
        var rng = SeededRNG(seed: 1)
        let frames = Features.frames(Self.take(yawAt: 0, nod: 0.2), set: .all)
        let copies = Features.augment(frames, copies: 5, rng: &rng)
        #expect(copies.count == 5)
        #expect(copies.allSatisfy { $0.first?.count == 9 && $0.count > 10 })
    }
}

@Suite("Motion pipeline")
struct MotionPipelineTests {
    @Test func turnsPacketsIntoTimestampedSamplesAndTracksRate() {
        let p = MotionPipeline()
        for i in 0..<100 {
            let q = simd_quatd(angle: Double(i) * 0.01, axis: [0, 0, 1])
            p.ingest([KinematicsTests.sample(q)], arrival: Double(i) * 0.02)
        }
        #expect(p.history.count == 100)
        #expect(abs(p.sampleRate - 50) < 1)
        #expect(abs(p.latest!.wz - 0.5) < 0.05)
    }

    @Test func historyIsBounded() {
        let p = MotionPipeline(historySeconds: 1)
        for i in 0..<200 { p.ingest([KinematicsTests.sample(simd_quatd(angle: 0, axis: [0, 0, 1]))], arrival: Double(i) * 0.02) }
        #expect(p.history.first!.t >= p.history.last!.t - 1)
    }

    @Test func recenterMakesCurrentPoseZero() throws {
        let p = MotionPipeline()
        p.ingest([KinematicsTests.sample(simd_quatd(angle: 0.5, axis: [0, 0, 1]))], arrival: 0)
        p.recenter()
        let a = try #require(p.relativeAngles)
        #expect(abs(a.yaw) < 1e-9)
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
