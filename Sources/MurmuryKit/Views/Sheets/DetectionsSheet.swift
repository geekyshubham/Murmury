import SwiftUI

struct DetectionsSheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        DetailSheet(title: "Detection history", hue: .detect) {
            if model.events.isEmpty { Text("No detections yet").font(TypeStyle.body) }
            ForEach(model.events) { e in
                HStack {
                    Label(e.accepted ? "Accepted" : "Low confidence", systemImage: e.accepted ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(e.accepted ? Ink.live : Ink.secondary)
                    Text(e.label).fontWeight(.semibold)
                    Spacer()
                    Text("\(Int(e.confidence * 100))% · \(e.source)").monospacedDigit()
                    Text(e.time, style: .time)
                }.font(TypeStyle.body).accessibilityElement(children: .combine)
            }
            Text("Microphone transcript").font(TypeStyle.rowTitle)
            MicrophoneControls()
            Text(model.transcriber.text.isEmpty ? "No speech yet" : model.transcriber.text)
                .font(TypeStyle.body).textSelection(.enabled)
            Button("Clear history and transcripts") { model.clearTranscript(); model.transcriber.clear() }
                .disabled(model.events.isEmpty && model.transcript.isEmpty && model.transcriber.text.isEmpty)
        }
    }
}
