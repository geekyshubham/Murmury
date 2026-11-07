import SwiftUI

struct EvaluationSheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        DetailSheet(title: "Signal and evaluation", hue: .model) {
            Text("Checks whether your gestures are told apart reliably: each one is tested on takes the model hasn't seen, against plain guessing").font(TypeStyle.body)
            Button(model.isEvaluating ? "Checking…" : "Check signal") { model.evaluate() }
                .disabled(model.isEvaluating || !model.canEvaluate)
            if !model.canEvaluate { Text("Record 2 takes of 2 gestures").font(TypeStyle.caption) }
            if let e = model.evaluation { EvaluationSummary(e: e, hue: .model) }
            if let meta = model.neural?.meta {
                Text("Trained \(meta.trainedAt.formatted(date: .abbreviated, time: .shortened))").font(TypeStyle.caption)
            }
            if !model.trainingLog.isEmpty {
                Text("Training log").font(TypeStyle.rowTitle)
                Text(model.trainingLog).font(TypeStyle.codeCaption).textSelection(.enabled)
            }
        }
    }
}
