import CoreML
import CreateML
import Foundation
import TabularData

/// The small per-user neural model. Trained on-device with Create ML's activity classifier
/// (a conv + LSTM network built for motion-sensor windows) from the user's own takes.
///
/// Every take is trimmed, converted to feature frames, time-normalized to `window` frames and
/// augmented, so one take ⇒ one prediction window. Live segments go through the identical
/// pipeline before `predict`.
struct MotionModelMeta: Codable, Sendable {
    var labels: [String]
    var featureSet: FeatureSet
    var channels: [String]
    var window: Int
    var scales: [Double]
    var trainAccuracy: Double
    var validationAccuracy: Double?
    var takeCount: Int
    var trainedAt: Date
    /// Present when the user's rest class is clearly quieter than every gesture (models trained
    /// before the gate existed decode with nil).
    var restGate: RestGate?
}

struct TrainingReport: Sendable {
    var meta: MotionModelMeta
    var log: String
}

enum MotionModelTrainer {
    static let defaultWindow = 40

    /// Trains, validates on a held-out 20% of takes (when there is enough data), then
    /// retrains on everything and writes the model next to the dataset.
    static func train(takes: [Take], featureSet: FeatureSet, store: DatasetStore = .standard, window: Int = defaultWindow,
                      augmentCopies: Int = 12, iterations: Int = 40) throws -> TrainingReport {
        let labels = Array(Set(takes.map(\.label))).sorted()
        guard labels.count >= 2 else { throw MotionModelError.notEnoughLabels }
        let channels = featureSet.channelNames
        let rawFrames = takes.map { Features.frames(Features.trim($0.samples), set: featureSet) }
        let scales = Features.channelScales(rawFrames)
        let frames = rawFrames.map { Features.scaled($0, by: scales) }

        var log = "Takes: \(takes.count), labels: \(labels.joined(separator: ", ")), window: \(window)\n"

        // Stratified hold-out: every label with ≥5 takes contributes ~20% to validation.
        var trainIdx: [Int] = [], valIdx: [Int] = []
        for label in labels {
            let idx = takes.indices.filter { takes[$0].label == label }.shuffled()
            let nVal = idx.count >= 5 ? max(1, idx.count / 5) : 0
            valIdx += idx.prefix(nVal)
            trainIdx += idx.dropFirst(nVal)
        }

        var validationAccuracy: Double?
        if !valIdx.isEmpty {
            let probe = try fit(frames: trainIdx.map { frames[$0] }, labels: trainIdx.map { takes[$0].label },
                                channels: channels, window: window, augmentCopies: augmentCopies, iterations: iterations)
            var correct = 0
            for i in valIdx {
                let ranked = try MotionModelRunner.classify(model: probe.model, scaledFrames: frames[i],
                                                            channels: channels, window: window)
                if ranked.first?.label == takes[i].label { correct += 1 }
            }
            validationAccuracy = Double(correct) / Double(valIdx.count)
            log += String(format: "Held-out accuracy: %.1f%% on %d takes\n", validationAccuracy! * 100, valIdx.count)
        } else {
            log += "Too few takes per label for a held-out split (need ≥5); skipping validation.\n"
        }

        let model = try fit(frames: frames, labels: takes.map(\.label), channels: channels,
                            window: window, augmentCopies: augmentCopies, iterations: iterations)
        let trainAccuracy = 1 - model.trainingMetrics.classificationError
        log += String(format: "Training accuracy (final model): %.1f%%\n", trainAccuracy * 100)

        try? FileManager.default.removeItem(at: store.modelURL)
        try model.write(to: store.modelURL,
                        metadata: MLModelMetadata(author: "Murmury", shortDescription: "Per-user Buds3 Pro motion classifier"))
        let meta = MotionModelMeta(labels: labels, featureSet: featureSet, channels: channels, window: window,
                                   scales: scales, trainAccuracy: trainAccuracy, validationAccuracy: validationAccuracy,
                                   takeCount: takes.count, trainedAt: Date(), restGate: RestGate.learn(takes: takes))
        try JSONEncoder().encode(meta).write(to: store.modelMetaURL, options: .atomic)
        return TrainingReport(meta: meta, log: log)
    }

    private static func fit(frames: [[[Double]]], labels: [String], channels: [String], window: Int,
                            augmentCopies: Int, iterations: Int) throws -> MLActivityClassifier {
        let data = try table(frames: frames, labels: labels, channels: channels, window: window,
                             augmentCopies: augmentCopies, startSession: 0)
        let params = MLActivityClassifier.ModelParameters(validation: .none, batchSize: 32,
                                                          maximumIterations: iterations,
                                                          predictionWindowSize: window)
        return try MLActivityClassifier(trainingData: data, featureColumns: channels, labelColumn: "label",
                                        recordingFileColumn: "session", parameters: params)
    }

    /// One row per (augmented) take; each feature column holds that take's time-normalized
    /// sequence, which is the layout this Create ML version expects.
    static func table(frames: [[[Double]]], labels: [String], channels: [String], window: Int,
                      augmentCopies: Int, startSession: Int) throws -> MLDataTable {
        var rng = SystemRandomNumberGenerator()
        var session: [String] = [], label: [String] = []
        var cols = [[MLDataValue.SequenceType]](repeating: [], count: channels.count)
        var sid = startSession
        for (f, l) in zip(frames, labels) {
            for v in [f] + Features.augment(f, copies: augmentCopies, rng: &rng) {
                let r = Features.resample(v, to: window)
                session.append("take-\(sid)"); label.append(l)
                for c in channels.indices {
                    cols[c].append(MLDataValue.SequenceType(r.map { $0[c] }))
                }
                sid += 1
            }
        }
        var dict: [String: MLDataValueConvertible] = ["session": session, "label": label]
        for (c, name) in channels.enumerated() { dict[name] = cols[c] }
        return try MLDataTable(dictionary: dict)
    }
}

enum MotionModelError: LocalizedError {
    case notEnoughLabels, noModel
    var errorDescription: String? {
        switch self {
        case .notEnoughLabels: "Record takes for at least two gestures (for example yours and “nothing”)."
        case .noModel: "No trained model yet."
        }
    }
}

/// Loads the compiled Core ML model and classifies segments.
final class MotionModelRunner: @unchecked Sendable {
    let meta: MotionModelMeta
    private let model: MLModel

    init(store: DatasetStore = .standard) throws {
        guard FileManager.default.fileExists(atPath: store.modelURL.path),
              let metaData = try? Data(contentsOf: store.modelMetaURL) else { throw MotionModelError.noModel }
        meta = try JSONDecoder().decode(MotionModelMeta.self, from: metaData)
        let compiled = try MLModel.compileModel(at: store.modelURL)
        model = try MLModel(contentsOf: compiled)
    }

    func predict(_ samples: [MotionSample], minConfidence: Double) throws -> Prediction {
        if let gate = meta.restGate, gate.isRest(samples) {
            let ranked = [RankedLabel(label: gate.restLabel, score: 1)]
                + meta.labels.filter { $0 != gate.restLabel }.map { RankedLabel(label: $0, score: 0) }
            return Prediction(ranked: ranked, confidence: 1, accepted: true, source: "Neural · rest gate")
        }
        let frames = Features.scaled(Features.frames(Features.trim(samples), set: meta.featureSet), by: meta.scales)
        let ranked = try Self.classify(model: model, scaledFrames: frames, channels: meta.channels, window: meta.window)
        let top = ranked.first?.score ?? 0
        return Prediction(ranked: ranked, confidence: top, accepted: top >= minConfidence, source: "Neural")
    }

    /// Runs one time-normalized window through an activity-classifier model.
    static func classify(model: MLModel, scaledFrames: [[Double]], channels: [String], window: Int) throws -> [RankedLabel] {
        let frames = Features.resample(scaledFrames, to: window)
        var inputs: [String: MLFeatureValue] = [:]
        for (name, desc) in model.modelDescription.inputDescriptionsByName {
            guard let constraint = desc.multiArrayConstraint else { continue }
            let shape = constraint.shape
            let array = try MLMultiArray(shape: shape, dataType: .double)
            for i in 0..<array.count { array[i] = 0 }
            if let c = channels.firstIndex(of: name) {
                for (i, frame) in frames.enumerated() where i < array.count { array[i] = NSNumber(value: frame[c]) }
            }
            inputs[name] = MLFeatureValue(multiArray: array) // unknown inputs (e.g. stateIn) stay zero
        }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        var probs: [String: Double] = [:]
        for name in out.featureNames {
            guard let dict = out.featureValue(for: name)?.dictionaryValue, !dict.isEmpty else { continue }
            for (key, value) in dict { probs["\(key.base)"] = value.doubleValue }
        }
        return probs.map { RankedLabel(label: $0.key, score: $0.value) }.sorted { $0.score > $1.score }
    }
}
