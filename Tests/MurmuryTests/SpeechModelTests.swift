import CoreGraphics
import Foundation
import Testing
@testable import MurmuryKit

/// A bud sample whose fast gyro/accelerometer shake is `shake` (the jaw's), at `t` on the buds' clock.
private func budSample(t: Double, shake: Double, noise: () -> Double) -> MotionSample {
    var s = MotionSample(t: t, qw: 1, qx: 0, qy: 0, qz: 0)
    s.hasIMU = true
    (s.gx, s.gy, s.gz) = (shake + noise(), 0.6 * shake + noise(), 0.4 * shake + noise())
    (s.ax, s.ay, s.az) = (0.5 * shake + noise(), 9.8 + 0.3 * shake + noise(), noise())
    return s
}

@Suite("Speech models")
struct SpeechModelTests {
    @Test func cameraMeasuresTheLipsInEyeDistances() {
        let inner = [CGPoint(x: 0.4, y: 0.30), CGPoint(x: 0.5, y: 0.36), CGPoint(x: 0.6, y: 0.30), CGPoint(x: 0.5, y: 0.24)]
        #expect(abs((CameraMouth.opening(innerLips: inner, outerLips: nil, eyeSpan: 0.4) ?? 0) - 0.3) < 1e-9)
        #expect(CameraMouth.opening(innerLips: nil, outerLips: nil, eyeSpan: 0.4) == nil)
        #expect(CameraMouth.opening(innerLips: inner, outerLips: nil, eyeSpan: 0) == nil)
    }

    @Test func recognisedWordsLandOnTheBudsClock() {
        let words = SpokenWord.words(segments: [("Click,", 0.5, 0.3), ("—", 0.9, 0.1), ("don't", 1.2, 0.25)], requestStart: 100)
        #expect(words == [SpokenWord(text: "click", start: 100.5, duration: 0.3), SpokenWord(text: "don't", start: 101.2, duration: 0.25)])
    }

    @Test func mouthModelLearnsTheLipsFromTheBudsAndTheirDelay() throws {
        var rng = SeededRNG(seed: 11)
        func noise(_ a: Double) -> Double { Double.random(in: -a...a, using: &rng) }
        let late = 0.2
        // Syllable groups open and close the lips; the jaw shakes the buds as much as the lips open.
        func mouth(_ t: Double) -> Double { max(0, sin(2 * .pi * 0.7 * t)) * (0.6 + 0.4 * sin(2 * .pi * 0.13 * t)) }
        var frames: [(t: Double, value: Double)] = []
        for i in 0..<(90 * 30) { let t = Double(i) / 30; frames.append((t, 0.05 + 0.4 * mouth(t) + noise(0.01))) }
        var samples: [MotionSample] = []
        for i in 0..<(90 * 45) {
            let t = Double(i) / 45
            let phase = noise(1)
            samples.append(budSample(t: t + late, shake: 0.15 * mouth(t) * sin(2 * .pi * 7 * t + phase)) { noise(0.004) })
        }
        let model = try #require(MouthTrainer.train(samples: samples, mouth: frames))
        #expect(model.heldOut && model.r2 > 0.5, "held-out fit \(model.r2)")
        #expect(abs(model.lag - late) <= 0.1, "lag \(model.lag)")
        // Live: open while the jaw moves, near closed when still.
        var detector = MouthDetector(model: model)
        var open = 0.0, still = 0.0
        for i in 0..<45 { let t = 200 + Double(i) / 45; open = detector.ingest(budSample(t: t, shake: 0.15 * sin(2 * .pi * 7 * t)) { noise(0.004) }) }
        for i in 0..<90 { let t = 202 + Double(i) / 45; still = detector.ingest(budSample(t: t, shake: 0) { noise(0.004) }) }
        #expect(open > 0.4 && still < 0.15, "open \(open), still \(still)")
    }

    @Test func wordModelLearnsEachWordsMovementFromTheRecognisersTimings() throws {
        var rng = SeededRNG(seed: 21)
        func noise(_ a: Double) -> Double { Double.random(in: -a...a, using: &rng) }
        let late = 0.15
        // Three words, each a different movement for 0.4 s, said five times each with pauses.
        let shapes: [String: (Double) -> [Double]] = [
            "click": { u in [sin(2 * .pi * u / 0.4), 0, 0] },
            "down": { u in [0, sin(2 * .pi * u / 0.4), 0] },
            "up": { u in [0, 0, sin(4 * .pi * u / 0.4)] },
        ]
        var samples: [MotionSample] = [], words: [SpokenWord] = []
        var t = 0.0
        for _ in 0..<5 {
            for word in ["click", "down", "up"] {
                words.append(SpokenWord(text: word, start: t + 0.3, duration: 0.4))
                for k in 0..<54 {
                    let tt = t + Double(k) / 45, u = tt - (t + 0.3)
                    var s = MotionSample(t: tt + late, qw: 1, qx: 0, qy: 0, qz: 0); s.hasIMU = true
                    let g = (u >= 0 && u < 0.4) ? shapes[word]!(u).map { 0.5 * $0 } : [0, 0, 0]
                    (s.gx, s.gy, s.gz) = (g[0] + noise(0.01), g[1] + noise(0.01), g[2] + noise(0.01))
                    (s.ax, s.ay, s.az) = (noise(0.005), 9.8 + noise(0.005), noise(0.005))
                    samples.append(s)
                }
                t += 1.2
            }
        }
        // "the" was said only twice: not enough to learn.
        words.append(SpokenWord(text: "the", start: 1, duration: 0.2)); words.append(SpokenWord(text: "the", start: 5, duration: 0.2))
        let model = try #require(WordTrainer.build(samples: samples, words: words, lag: late))
        #expect(model.vocabulary == ["click", "down", "up"])
        #expect((model.accuracy ?? 0) >= 0.8 && (model.chance ?? 1) < 0.5, "accuracy \(model.accuracy ?? -1)")
        // A new, silent "down" is recognised from its movement alone.
        let recognizer = try #require(SilentWordRecognizer(model: model))
        var fresh: [MotionSample] = []
        for k in 0..<36 {
            let u = Double(k) / 45 - 0.2
            var s = MotionSample(t: 500 + Double(k) / 45, qw: 1, qx: 0, qy: 0, qz: 0); s.hasIMU = true
            let g = (u >= 0 && u < 0.4) ? shapes["down"]!(u).map { 0.5 * $0 } : [0, 0, 0]
            (s.gx, s.gy, s.gz) = (g[0] + noise(0.01), g[1] + noise(0.01), g[2] + noise(0.01))
            (s.ax, s.ay, s.az) = (noise(0.005), 9.8 + noise(0.005), noise(0.005))
            fresh.append(s)
        }
        #expect(recognizer.recognize(fresh)?.word == "down")
    }

    @Test func modelsSurviveSavingAndReport() throws {
        let mouth = MouthModel(mean: [0], scale: [1], weights: [0.5], bias: 0.2, lo: 0.05, hi: 0.4, lag: 0.2, r2: 0.71, examples: 400, heldOut: true)
        let models = SpeechModels(mouth: mouth, words: nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        models.save(to: url)
        let loaded = try #require(SpeechModels.load(from: url))
        #expect(loaded.mouth == mouth && loaded.words == nil)
        #expect(loaded.report == ["Mouth: follows yours, fit 71%"])
    }

    @Test func voiceOpensTheMouthBeforeAModelIsLearned() {
        var m = AudioMouth()
        for _ in 0..<40 { _ = m.update(level: 0.2) }
        var open = 0.0
        for _ in 0..<6 { open = m.update(level: 0.6) }
        var shut = 1.0
        for _ in 0..<30 { shut = m.update(level: 0.2) }
        #expect(open > 0.5 && shut == 0)
    }

    @Test func onlyFiveSilentWordsAct() {
        #expect(AppModel.silentCommand(for: "click") == .leftClick)
        #expect(AppModel.silentCommand(for: "down") == .scrollDown)
        #expect(AppModel.silentCommand(for: "yes") == nil && AppModel.silentCommand(for: "the") == nil)
    }

    @Test func teachingDrillsEachSilentWordThreeTimes() {
        let text = MurmurEnrollment.standard.compactMap { if case .read(let t, _) = $0 { return t.lowercased() } else { return nil } }.joined(separator: " ")
        let tokens = text.split { !$0.isLetter }.map(String.init)
        for word in ["click", "down", "up", "left", "right"] {
            #expect(tokens.filter { $0 == word }.count >= WordTrainer.minimumTakes, "\(word)")
        }
    }

    @Test func findsWhereTheLipsMeetOnTheFaceProfile() {
        // A face profile near the midline in a head 1.2 tall with the nose tip at 1.0: the upper lip
        // forward at 0.916, the seam's dip at 0.88, the lower lip forward again at 0.844.
        var points: [SIMD3<Float>] = []
        for i in 0..<400 {
            let y = 0.78 + Float(i) / 400 * 0.17
            points.append(SIMD3(0, y, 0.9 + 0.02 * cos(2 * .pi * (y - 0.916) / 0.072)))
        }
        let bounds = (SIMD3<Float>(-1, 0, 0), SIMD3<Float>(1, 1.2, 1))
        let seam = HeadTreatment.lipSeam(points, bounds: bounds, noseY: 1.0)
        #expect(seam.map { abs($0.y - 0.88) < 0.004 } == true, "\(String(describing: seam))")
    }
}

@Suite("Field journal")
struct FieldJournalTests {
    @Test func eventsAreOneJSONObjectPerLineWithBothClocks() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("field-\(UUID()).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let journal = try #require(FieldJournal(path: path))
        journal.event("said", ["text": "Buds disconnected. Pointer paused. Reconnecting.", "urgent": true])
        journal.samples(3, at: 10, bud: 1)
        journal.samples(3, at: 10.02, bud: 2)  // the other bud took over reporting
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        let objects = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        let said = try #require(objects.first { $0["kind"] as? String == "said" })
        #expect(said["text"] as? String == "Buds disconnected. Pointer paused. Reconnecting." && said["urgent"] as? Bool == true)
        #expect(said["wall"] is Double && said["up"] is Double)
        let bud = try #require(objects.first { $0["kind"] as? String == "bud" })
        #expect(bud["from"] as? Int == 1 && bud["to"] as? Int == 2)
    }
}
