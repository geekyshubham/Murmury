import SwiftUI

struct ModelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    private let hue = Hue.model
    var body: some View {
        let meta = model.neural?.meta
        Page {
            PageHeader(hue: hue, title: "Your Model", subtitle: "Learns your gestures, here on your Mac",
                       chip: StateChip(text: model.isTraining ? "Training…" : (model.modelHeroState == .failed ? "Training failed" : (meta == nil ? "Not trained yet" : "Ready")),
                                       color: model.modelHeroState == .failed ? Ink.danger : (meta == nil ? Ink.tertiary : Ink.live), active: model.isTraining),
                       features: [Feature(symbol: "checkmark.seal", title: "Accuracy on new takes", detail: meta?.validationAccuracy.map { String(format: "%.0f%% on unseen takes", $0 * 100) } ?? (meta == nil ? "Train to measure" : "Record 5+ takes per gesture to measure")),
                                  Feature(symbol: "tag", title: "Gestures", detail: "\(model.labels.count) recorded"),
                                  Feature(symbol: "square.stack.3d.up", title: "Takes", detail: "\(model.takes.count) in your dataset")], notices: notices,
                       secondary: SecondaryAction(title: "Check signal") { model.detailSheet = .evaluation },
                       more: [MoreItem(title: "Model settings…", symbol: "slider.horizontal.3") { model.settingsTab = .model; openSettings() }]) {
                ModelAvatar(state: model.modelHeroState, labelCount: model.labels.count, signatures: model.gestureSignatures, gestureNames: model.labels)
            } extra: {
                if model.isTraining {
                    // Honest progress: the trainer reports no fraction, so an indeterminate bar and the phase.
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView().progressViewStyle(.linear).tint(hue.a)
                        Text("Training on this Mac · usually under a minute").font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if let e = model.evaluation {
                    // The p-value lives in Check signal; here, accuracy against chance in words.
                    Text(String(format: "Recognizes %.0f%% of takes · chance is %.0f%%", e.accuracy * 100, e.chance * 100))
                        .font(TypeStyle.body).monospacedDigit().foregroundStyle(Ink.primary)
                }
            }
        } action: {
            OrbButton(title: model.isTraining ? "Training…" : "Train", hue: hue, active: model.isTraining,
                      disabledReason: model.isTraining ? "Training on this Mac" : (model.trainBlocker ?? "2 gestures, 2 takes each"), caption: "⌘↩ to train") {
                model.train(window: Int(model.trainWindow), augment: Int(model.trainAugment), iterations: Int(model.trainIterations))
            }.disabled(model.isTraining || !model.canTrain).keyboardShortcut(.return, modifiers: .command)
        }
    }
    /// A trainer message as a clause after a colon: lower-case start, no closing period.
    static func clause(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(".") { t.removeLast() }
        guard let first = t.first, t.dropFirst().first?.isLowercase ?? true else { return t }
        return first.lowercased() + t.dropFirst()
    }
    private var notices: [StatusNotice] {
        if model.modelHeroState == .failed {
            let reason = model.trainingLog.components(separatedBy: "\n").first { $0.hasPrefix("Failed:") }.map { Self.clause(String($0.dropFirst("Failed: ".count))) }
            // Recovery moves forward: the usual cause is too few takes, so the first action is Teach.
            return [StatusNotice(tone: .danger, text: "Training failed\(reason.map { ": \($0)" } ?? "")", actionTitle: "Go to Teach", action: { model.screen = .train })]
        }
        // The rule itself is under the Train button; the notice only points the way.
        if !model.canTrain { return [StatusNotice(tone: .info, text: "Your gestures come from Teach", actionTitle: "Go to Teach", action: { model.screen = .train })] }
        return []
    }
}

struct EvaluationSummary: View {
    var e: Evaluation
    var hue: Hue

    var body: some View {
        let significant = e.pValue < 0.05
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 28) {
                stat("Accuracy", String(format: "%.0f%%", e.accuracy * 100))
                stat("Chance", String(format: "%.0f%%", e.chance * 100))
                stat("Confidence", significant ? "Real difference" : "Not yet")
            }
            Label(significant ? "These gestures are distinguishable from your head movement"
                              : "Not distinguishable from chance yet. Record more takes, or these gestures may not move your head differently.",
                  systemImage: significant ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(TypeStyle.caption)
                .foregroundStyle(significant ? Ink.live : Ink.warn)
            ConfusionMatrix(labels: e.labels, matrix: e.confusion, hue: hue)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(TypeStyle.stat).foregroundStyle(Ink.primary)
            Text(title).font(TypeStyle.caption).foregroundStyle(Ink.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ConfusionMatrix: View {
    var labels: [String]
    var matrix: [[Int]]
    var hue: Hue = .model

    var body: some View {
        let peak = max(matrix.flatMap { $0 }.max() ?? 1, 1)
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Text("actual ↓  predicted →").font(TypeStyle.caption).foregroundStyle(Ink.tertiary)
                ForEach(labels, id: \.self) { Text($0).font(TypeStyle.caption).foregroundStyle(Ink.secondary).lineLimit(1) }
            }
            ForEach(labels.indices, id: \.self) { i in
                GridRow {
                    Text(labels[i]).font(TypeStyle.caption).foregroundStyle(Ink.secondary).gridColumnAlignment(.trailing)
                    ForEach(labels.indices, id: \.self) { j in
                        let v = matrix[i][j]
                        Text("\(v)").font(TypeStyle.caption.monospacedDigit()).foregroundStyle(Ink.primary)
                            .frame(minWidth: 38, minHeight: 26)
                            .background((i == j ? hue.a : Ink.warn).opacity(v == 0 ? 0.05 : 0.18 + 0.6 * Double(v) / Double(peak)),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityLabel("\(labels[i]) predicted as \(labels[j]): \(v)")
                    }
                }
            }
        }
    }
}
