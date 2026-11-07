import SwiftUI

struct TakeProgress: View {
    var count: Int
    /// Labels each milestone under the rail (on Teach; the dataset list stays compact).
    var labelled = false
    /// Where takes start to count: 2 to train, 5 to hold some out and measure accuracy, 15 advised.
    static let milestones = [2, 5]
    static let milestoneLabels: [(take: Int, text: String)] = [(2, "2 minimum"), (5, "5 for accuracy"), (15, "15 recommended")]
    static let track = Ink.scheme("takeTrack", light: RGB(0x5B3AD0, alpha: 0.16), dark: RGB(0xFFFFFF, alpha: 0.24))
    /// What the next take buys, in one line under the count.
    static func next(for n: Int) -> String {
        switch n {
        case ..<2: "\(2 - n) more needed for this gesture"
        case ..<5: "Trainable · \(5 - n) more to measure accuracy"
        case ..<15: "Trainable and measurable · \(15 - n) more for steadier results"
        default: "Enough takes for this gesture"
        }
    }
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Self.track).overlay(Capsule().strokeBorder(Ink.tertiary.opacity(0.7), lineWidth: 1)).frame(height: 6)
                Capsule().fill(count >= 15 ? Ink.live : Hue.teach.a).frame(width: g.size.width * min(1, Double(count) / 15), height: 6)
                // Milestone ticks, centred on the 6 pt track.
                ForEach(Self.milestones, id: \.self) { m in
                    Capsule().fill(Ink.tertiary)
                        .frame(width: 2, height: 12).offset(x: g.size.width * Double(m) / 15 - 1)
                }
            }
        }.frame(height: 12)
            .overlay(alignment: .topLeading) {
                if labelled {
                    GeometryReader { g in
                        ForEach(Self.milestoneLabels, id: \.take) { m in
                            let x = g.size.width * Double(m.take) / 15
                            Text(m.text).font(TypeStyle.axis).foregroundStyle(Ink.tertiary).fixedSize()
                                .alignmentGuide(.leading) { d in m.take == 15 ? d.width - x : d.width / 2 - x }  // centred under its tick; the end label ends at the rail's end
                                .frame(width: g.size.width, alignment: .leading)
                        }
                    }
                    .offset(y: 16)
                }
            }
            .padding(.bottom, labelled ? 18 : 0)
            .accessibilityLabel(count == 1 ? "1 take recorded" : "\(count) takes recorded")
    }
}
struct DatasetSheet: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: String?
    var body: some View {
        DetailSheet(title: "Your dataset", hue: .teach) {
            Text("Aim for 15 takes per gesture. Include “nothing” so stillness can be recognized.").font(TypeStyle.body)
            FlowLayout(spacing: Space.unit) {
                ForEach(["nothing", "nod", "shake", "tilt left", "tilt right", "click", "right click", "talking", "chewing"], id: \.self) { preset in
                    let selected = AppModel.gestureName(model.currentLabel) == preset
                    Button(preset) { model.currentLabel = preset }
                        .buttonStyle(ChipStyle(selected: selected, hue: .teach))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if model.labels.isEmpty {
                ContentUnavailableView("No takes yet", systemImage: "square.stack.3d.up", description: Text("Name a gesture on Teach, then record your first take"))
            }
            ForEach(model.labels, id: \.self) { label in
                HStack(spacing: Space.sm) {
                    Button { model.currentLabel = label } label: {
                        VStack(spacing: Space.unit) {
                            HStack { Text(label); Spacer(); Text("\(model.count(for: label)) takes").monospacedDigit() }
                            TakeProgress(count: model.count(for: label))
                        }
                    }
                    .buttonStyle(RowButtonStyle(selected: label == model.currentLabel))
                    .accessibilityLabel("\(label), \(model.count(for: label)) takes")
                    .accessibilityAddTraits(label == model.currentLabel ? .isSelected : [])
                    Button { pendingDelete = label } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete all takes for \(label)")
                }.font(TypeStyle.body)
            }
            if let take = model.lastTake {
                Text("Last take · \(take.label) · \(take.duration, specifier: "%.2f") s").font(TypeStyle.rowTitle)
                SignalPlot(title: "Turn rate", samples: take.samples, channels: SignalPlot.velocity, height: 72)
                SignalPlot(title: "Angular acceleration", samples: take.samples, channels: SignalPlot.acceleration, height: 72)
            }
            Button("Discard last take", role: .destructive) { model.undoLastTake() }
                .keyboardShortcut("z").disabled(model.lastTake == nil)
        }
        .confirmationDialog("Delete all takes for “\(pendingDelete ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete \(model.count(for: pendingDelete ?? "")) takes", role: .destructive) {
                    if let label = pendingDelete { model.deleteLabel(label) }; pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: { Text("This can't be undone. Retrain your model afterwards.") }
    }
}
