import Foundation
import simd
import Testing
@testable import MurmuryKit

/// Synthetic head movements: nod = pitch oscillation, shake = yaw oscillation,
/// nothing = slow drift. Varies speed, size, heading and duration like a real user would.
enum Synthetic {
    static func take(_ label: String, seed: UInt64, imu: Bool = false) -> Take {
        var rng = SeededRNG(seed: seed)
        var k = Kinematics()
        let dur = Double.random(in: 0.8...1.3, using: &rng)
        let amp = Double.random(in: 0.15...0.3, using: &rng)
        let freq = Double.random(in: 1.6...2.4, using: &rng)
        let base = simd_quatd(angle: Double.random(in: -1...1, using: &rng), axis: [0, 0, 1])
        var samples: [MotionSample] = []
        for i in 0..<Int(dur * 50) {
            let t = Double(i) / 50
            let osc = amp * sin(2 * .pi * freq * t) * sin(.pi * t / dur)
            let jitter = Double.random(in: -0.003...0.003, using: &rng)
            let q: simd_quatd = switch label {
            case "nod": base * simd_quatd(angle: osc, axis: [1, 0, 0])
            case "shake": base * simd_quatd(angle: osc, axis: [0, 0, 1])
            default: base * simd_quatd(angle: 0.02 * sin(t) + jitter, axis: [0, 1, 0])
            }
            let quantized = Quat(w: (q.real * 10000).rounded() / 10000, x: (q.imag.x * 10000).rounded() / 10000,
                                 y: (q.imag.y * 10000).rounded() / 10000, z: (q.imag.z * 10000).rounded() / 10000)
            let hs = HeadSample(q: quantized, gyro: imu ? [osc, 0, 0] : nil, accel: imu ? [0, 0, 1] : nil, bud: 0)
            samples.append(k.ingest(hs, t: 100 + t))
        }
        return Take(label: label, samples: samples)
    }

    static func dataset(perLabel: Int = 10, seed: UInt64 = 0) -> [Take] {
        ["nod", "shake", "nothing"].enumerated().flatMap { i, label in
            (0..<perLabel).map { take(label, seed: seed + UInt64(i * 1000 + $0)) }
        }
    }
}

@Suite("DTW and templates")
struct TemplateTests {
    @Test func dtwIsZeroForIdenticalAndSymmetric() {
        let a: [[Double]] = [[0, 1], [1, 2], [2, 3]]
        let b: [[Double]] = [[0, 1], [0, 1], [1, 2], [2, 3]]
        #expect(DTW.distance(a, a) == 0)
        #expect(DTW.distance(a, b) == DTW.distance(b, a))
        #expect(DTW.distance(a, b) < DTW.distance(a, [[5, 5], [5, 5]]))
    }

    @Test func templateClassifierRecognisesNewTakes() throws {
        let classifier = try #require(TemplateClassifier(takes: Synthetic.dataset(), featureSet: .all))
        var correct = 0
        for (i, label) in ["nod", "shake", "nothing"].enumerated() {
            for s in 0..<5 {
                let p = classifier.predict(Synthetic.take(label, seed: 50_000 + UInt64(i * 100 + s)).samples,
                                           maxDistance: .infinity, minConfidence: 0)
                if p.best?.label == label { correct += 1 }
            }
        }
        #expect(correct >= 13, "got \(correct)/15")
    }

    @Test func needsTwoLabels() {
        #expect(TemplateClassifier(takes: [Synthetic.take("nod", seed: 1)], featureSet: .all) == nil)
    }

    @Test func evaluationFindsRealSignalAndRejectsNoise() throws {
        let real = try #require(Evaluation.run(takes: Synthetic.dataset(perLabel: 6), featureSet: .all, permutations: 100))
        #expect(real.accuracy > 0.8)
        #expect(real.pValue < 0.05)
        #expect(real.confusion.flatMap { $0 }.reduce(0, +) == real.takeCount)

        // Same movement under two labels: must not look significant.
        let noise = (0..<12).map { i in
            var t = Synthetic.take("nothing", seed: 900 + UInt64(i)); t.label = i % 2 == 0 ? "a" : "b"; return t
        }
        let fake = try #require(Evaluation.run(takes: noise, featureSet: .all, permutations: 100))
        #expect(fake.pValue > 0.05)
    }
}

@Suite("Dataset store")
struct DatasetStoreTests {
    @Test func roundTripsTakesInIsolatedDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmury-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DatasetStore(directory: dir)
        #expect(store.load().isEmpty)
        let takes = [Synthetic.take("nod", seed: 3), Synthetic.take("shake", seed: 4, imu: true)]
        store.save(takes)
        #expect(store.load() == takes)
    }
}

@Suite("Neural model", .serialized)
struct NeuralModelTests {
    @Test func trainsOnDeviceAndClassifiesUnseenTakes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("murmury-model-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DatasetStore(directory: dir)

        let report = try MotionModelTrainer.train(takes: Synthetic.dataset(perLabel: 10), featureSet: .all, store: store,
                                                  window: 40, augmentCopies: 8, iterations: 60)  // 30 iterations sat at the 12/15 bar and failed ~1 run in 4
        #expect(report.meta.labels == ["nod", "nothing", "shake"])
        #expect(report.meta.validationAccuracy != nil)

        let runner = try MotionModelRunner(store: store)
        var correct = 0
        var misses: [String] = []
        for (i, label) in ["nod", "shake", "nothing"].enumerated() {
            for s in 0..<5 {
                let p = try runner.predict(Synthetic.take(label, seed: 70_000 + UInt64(i * 100 + s)).samples, minConfidence: 0.5)
                if p.best?.label == label { correct += 1 } else {
                    misses.append("\(label)#\(s)→\(p.best?.label ?? "-") \(String(format: "%.2f", p.confidence))")
                }
                #expect(abs(p.ranked.map(\.score).reduce(0, +) - 1) < 0.01, "probabilities sum to 1")
            }
        }
        #expect(correct >= 12, "got \(correct)/15; misses: \(misses.joined(separator: ", "))")
    }

    @Test func refusesSingleLabel() {
        let store = DatasetStore(directory: FileManager.default.temporaryDirectory)
        #expect(throws: MotionModelError.self) {
            try MotionModelTrainer.train(takes: [Synthetic.take("nod", seed: 1)], featureSet: .all, store: store)
        }
    }

    @Test func runnerWithoutModelThrows() {
        let store = DatasetStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID())"))
        #expect(throws: (any Error).self) { try MotionModelRunner(store: store) }
    }
}

@MainActor
@Suite("Segmenter")
struct SegmenterTests {
    func feed(_ seg: Segmenter, from t0: Double, seconds: Double, moving: Bool, k: inout Kinematics) {
        for i in 0..<Int(seconds * 50) {
            let t = t0 + Double(i) / 50
            let angle = moving ? 0.3 * sin(2 * .pi * 2 * t) : 0
            seg.ingest(k.ingest(KinematicsTests.sample(simd_quatd(angle: angle, axis: [1, 0, 0])), t: t))
        }
    }

    @Test func holdCapturesWithPreroll() {
        let seg = Segmenter()
        var out: [[MotionSample]] = []
        seg.onSegment = { out.append($0) }
        var k = Kinematics()
        feed(seg, from: 0, seconds: 1, moving: false, k: &k)
        seg.begin()
        feed(seg, from: 1, seconds: 1, moving: true, k: &k)
        seg.end()
        #expect(out.count == 1)
        #expect(out[0].first!.t < 1, "includes pre-roll")
        #expect(out[0].count >= 50)
    }

    @Test func autoDetectsMovementAfterCalibration() {
        let seg = Segmenter()
        var out: [[MotionSample]] = []
        seg.onSegment = { out.append($0) }
        var k = Kinematics()
        seg.calibrate()
        feed(seg, from: 0, seconds: 2.5, moving: false, k: &k)
        #expect(seg.noiseFloor != nil)
        seg.autoEnabled = true
        feed(seg, from: 2.5, seconds: 1, moving: false, k: &k)
        #expect(out.isEmpty, "stillness doesn't trigger")
        feed(seg, from: 3.5, seconds: 1, moving: true, k: &k)
        feed(seg, from: 4.5, seconds: 1, moving: false, k: &k)
        #expect(out.count == 1)
        #expect(out[0].count > 25)
    }

    @Test func tinySegmentsAreDiscarded() {
        let seg = Segmenter()
        var out: [[MotionSample]] = []
        seg.onSegment = { out.append($0) }
        seg.begin()
        var k = Kinematics()
        feed(seg, from: 0, seconds: 0.04, moving: true, k: &k)
        seg.end()
        #expect(out.isEmpty)
    }
}

/// Stillness is near-zero input, where an untrained-looking network answers from its random
/// biases (it collapsed "nothing" into "nod" in ~1 of 4 trainings). The gate decides "nothing"
/// from motion energy before the network is asked.
@Suite("Rest gate")
struct RestGateTests {
    @Test func learnsAThresholdBetweenStillnessAndGestures() throws {
        let takes = Synthetic.dataset(perLabel: 10)
        let gate = try #require(RestGate.learn(takes: takes))
        #expect(gate.restLabel == "nothing")
        let still = takes.filter { $0.label == "nothing" }.map { RestGate.energy($0.samples) }
        let moving = takes.filter { $0.label != "nothing" }.map { RestGate.energy($0.samples) }
        #expect(still.max()! < gate.threshold && gate.threshold < moving.min()!)
    }

    @Test func gatesStillTakesAndPassesGestures() throws {
        let gate = try #require(RestGate.learn(takes: Synthetic.dataset(perLabel: 10)))
        for s in 0..<5 {
            #expect(gate.isRest(Synthetic.take("nothing", seed: 90_000 + UInt64(s)).samples))
            #expect(!gate.isRest(Synthetic.take("nod", seed: 91_000 + UInt64(s)).samples))
            #expect(!gate.isRest(Synthetic.take("shake", seed: 92_000 + UInt64(s)).samples))
        }
    }

    @Test func needsARestLabelAndSeparableClasses() {
        let gestures = Synthetic.dataset(perLabel: 6).filter { $0.label != "nothing" }
        #expect(RestGate.learn(takes: gestures) == nil, "no rest class")
        let fakeRest = gestures.filter { $0.label == "nod" }.map { Take(label: "nothing", samples: $0.samples) }
        #expect(RestGate.learn(takes: fakeRest + gestures) == nil, "overlapping energy: let the network decide")
    }

    @Test func oldModelMetadataStillLoads() throws {
        let json = #"{"labels":["a","b"],"featureSet":7,"channels":["x"],"window":40,"scales":[1],"trainAccuracy":1,"takeCount":4,"trainedAt":0}"#
        let meta = try JSONDecoder().decode(MotionModelMeta.self, from: Data(json.utf8))
        #expect(meta.restGate == nil)
    }
}
