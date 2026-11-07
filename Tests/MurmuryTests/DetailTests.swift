import CoreGraphics
import Foundation
import simd
import Testing
@testable import MurmuryKit

@MainActor @Suite("Detail and settings state")
struct DetailTests {
    @Test func detectionSetupHasOneSafeNextAction() {
        #expect(DetectionSetup.evaluate(hasMotion: true, calibrated: false, calibrating: false, listening: false).action == .calibrate)
        #expect(DetectionSetup.evaluate(hasMotion: true, calibrated: false, calibrating: true, listening: false).action == .calibrating)
        #expect(DetectionSetup.evaluate(hasMotion: true, calibrated: true, calibrating: false, listening: false).action == .listen)
        #expect(DetectionSetup.evaluate(hasMotion: false, calibrated: true, calibrating: false, listening: true).action == .stop)
        #expect(DetectionSetup.evaluate(hasMotion: false, calibrated: false, calibrating: false, listening: false).disabledReason != nil)
        #expect(DetectionSetup.evaluate(hasMotion: true, calibrated: true, calibrating: false, listening: false).disabledReason == nil)
        // Listening needs something to match: the training readiness rule, everywhere.
        let untaught = DetectionSetup.evaluate(hasMotion: true, calibrated: true, calibrating: false, listening: false, hasGestures: false)
        #expect(untaught.action == .listen && untaught.disabledReason == DetectionSetup.needsGestures)
        #expect(DetectionSetup.evaluate(hasMotion: true, calibrated: false, calibrating: false, listening: false, hasGestures: false).disabledReason == nil)
    }
    @Test func savedTakeIsSpokenAsProgressNotAQuota() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/dataset-spoken-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatasetStore(directory: root)
        store.save([Take(label: "nod", samples: [])])
        let model = AppModel(store: store)
        #expect(model.savedTakeAnnouncement(label: "nod") == "Saved. 1 take of nod. 1 more needed for this gesture.")
        store.save([Take(label: "nod", samples: []), Take(label: "nod", samples: [])])
        let two = AppModel(store: store)
        // Two takes: the gesture is ready, but training still needs a second gesture, and says so.
        #expect(two.savedTakeAnnouncement(label: "nod") == "Saved. 2 takes of nod. Teach 1 more gesture.")
        #expect(!two.savedTakeAnnouncement(label: "nod").contains("of 15"))
    }
    @Test func deletingLabelClearsLastTakeAndEligibility() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/dataset-detail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatasetStore(directory: root)
        let nod = Take(label: "nod", samples: [])
        store.save([nod, Take(label: "nod", samples: []), Take(label: "nothing", samples: []), Take(label: "nothing", samples: [])])
        let model = AppModel(store: store)
        #expect(model.canTrain && model.canEvaluate)
        model.lastTake = nod
        model.deleteLabel("nod")
        #expect(model.lastTake == nil)
        #expect(!model.canTrain && !model.canEvaluate)
        #expect(model.count(for: "nothing") == 2)
        #expect(store.load().count == 2)
    }
    @Test func routesDoNotResetTrainingDefaults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/detail-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: DatasetStore(directory: root))
        #expect(model.settingsTab == .pointer)
        model.trainAugment = 7
        for tab in SettingsTab.allCases { model.settingsTab = tab }
        #expect(model.trainAugment == 7)
        #expect(!model.canTrain)
        #expect(!model.canEvaluate)
        #expect(model.modelHeroState == .untrained)
        for sheet in DetailDestination.allCases { model.detailSheet = sheet; #expect(model.detailSheet == sheet) }
    }
}

@Suite("Take milestones")
struct TakeMilestoneTests {
    @Test func eachTakeSaysWhatItBuys() {
        #expect(TakeProgress.next(for: 0) == "2 more needed for this gesture")
        #expect(TakeProgress.next(for: 2) == "Trainable · 3 more to measure accuracy")
        #expect(TakeProgress.next(for: 5) == "Trainable and measurable · 10 more for steadier results")
        #expect(TakeProgress.next(for: 15) == "Enough takes for this gesture")
        #expect(TakeProgress.milestones == [2, 5])
    }
}

@Suite("Dwell click")
struct DwellClickTests {
    /// Feeds positions in order; returns which steps clicked.
    private func clicks(_ steps: [(CGFloat, CGFloat, Double)]) -> [Bool] {
        var d = DwellClicker()
        return steps.map { x, y, t in d.update(CGPoint(x: x, y: y), at: t) }
    }
    @Test func clicksOnceAfterAMoveAndAStill() {
        let s = DwellClicker.defaultSeconds
        // Resting from the start never clicks: it waits for a first move. Then one click per rest.
        let result = clicks([(0, 0, 0), (2, 0, 5), (60, 0, 5.1), (64, 3, 5.1 + s * 0.5), (65, 3, 5.1 + s + 0.01),
                             (65, 3, 20), (140, 3, 20.1), (141, 3, 20.1 + s + 0.01)])
        #expect(result == [false, false, false, false, true, false, false, true])
    }
    @Test func driftingPastTheRadiusRestartsTheWait() {
        let s = DwellClicker.defaultSeconds, r = DwellClicker.radius
        let result = clicks([(0, 0, 0), (50, 0, 0.1), (50 + r + 1, 0, 0.1 + s), (50 + r + 1, 0, 0.1 + 2 * s + 0.01)])
        #expect(result == [false, false, false, true])
    }
}

@Suite("Gesture signatures")
struct GestureSignatureTests {
    @MainActor @Test func eachBandCarriesItsGesture() {
        let labels = ["nod", "nothing", "shake"]
        let signatures = GestureSignature.make(takes: AppModel.sampleGestureTakes(), labels: labels)
        #expect(signatures.count == 3)
        func span(_ s: MotionRibbons.Signature, _ axis: (SIMD2<Float>) -> Float) -> Float { s.map { abs(axis($0)) }.max() ?? 0 }
        let nod = signatures[0], still = signatures[1], shake = signatures[2]
        // A nod lifts the band; a shake bends it in and out; stillness stays a plain ring.
        #expect(span(nod, { $0.y }) > 3 * span(nod, { $0.x }))
        #expect(span(shake, { $0.x }) > 3 * span(shake, { $0.y }))
        #expect(span(still, { $0.x }) < 0.05 && span(still, { $0.y }) < 0.05)
        // Scaled together: the largest gesture reaches 1, and every loop closes.
        let peaks: [Float] = signatures.flatMap { $0 }.map { (p: SIMD2<Float>) -> Float in max(abs(p.x), abs(p.y)) }
        let peak = peaks.max() ?? 0
        #expect(abs(peak - 1) < 0.001)
        for s in signatures { #expect(simd_length(s[0]) < 1e-5 && simd_length(s[s.count - 1]) < 1e-5) }
    }
    @Test func noGesturesMeanPlainRings() {
        #expect(GestureSignature.make(takes: [], labels: ["nod"]) == [[]])
        let curves = MotionRibbons.curves(labelCount: 3, signatures: [])
        #expect(curves == MotionRibbons.curves(labelCount: 3))
    }
}

@Suite("Teach chips")
struct TeachChipTests {
    @Test func ownGesturesFollowThePresets() {
        #expect(TrainView.chips(labels: []) == ["nothing", "nod", "shake", "click"])
        #expect(TrainView.chips(labels: ["nod", "wink", "tilt left"]) == ["nothing", "nod", "shake", "click", "wink", "tilt left"])
        #expect(TrainView.chips(labels: (0..<10).map { "g\($0)" }).count == 8)
    }
}

@Suite("Notice clauses")
struct NoticeClauseTests {
    @Test func trainerMessagesReadAsAClause() {
        #expect(ModelView.clause("Each gesture needs at least two takes.") == "each gesture needs at least two takes")
        #expect(ModelView.clause("MLP diverged") == "MLP diverged")
    }
}

@Suite("Gesture names")
struct GestureNameTests {
    @MainActor @Test func oneSpellingPerGesture() {
        #expect(AppModel.gestureName("  Nod ") == "nod")
        #expect(AppModel.gestureName("Right   Click") == "right click")
    }
}
