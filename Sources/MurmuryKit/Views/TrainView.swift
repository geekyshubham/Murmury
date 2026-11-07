import SwiftUI

struct TrainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    private let hue = Hue.teach
    static let targetTakes = 15
    static let presets = ["nothing", "nod", "shake", "click"]
    /// What the next take buys; once this gesture has its 2, what training still needs. One source
    /// for the visible line and VoiceOver.
    private func progressNote(_ n: Int) -> String {
        model.takeNote(count: n)
    }
    /// The preset chips, then the user's own gestures (up to eight chips in all).
    static func chips(labels: [String]) -> [String] {
        Array((presets + labels.filter { !presets.contains($0) }).prefix(8))
    }
    var body: some View {
        @Bindable var model = model
        let seg = model.segmenter
        let n = model.count(for: model.currentLabel)
        Page(stopAction: model.capture.ownership == .toggled ? { model.capture.toggle() } : nil) {
            PageHeader(hue: hue, title: "Teach a Gesture", subtitle: "Name a gesture, then record it.",
                       chip: StateChip(text: seg.isCapturing ? "Recording" : (seg.autoEnabled ? "Auto-capture on" : "Ready to learn"),
                                       // Ready is a neutral dot, so it never looks like the red Recording one.
                                       color: seg.isCapturing ? Ink.danger : Ink.tertiary, active: seg.isCapturing), features: [],
                       secondary: SecondaryAction(title: "Dataset") { model.detailSheet = .dataset },
                       more: [MoreItem(title: "Capture settings…", symbol: "slider.horizontal.3") { model.settingsTab = .capture; openSettings() }]) {
                HeadAvatar(pose: model.headPose, hue: hue, budsLit: model.hasMotion && !model.isDemo, recording: seg.isCapturing, mouth: model.mouthOpen)
            } extra: {
                VStack(alignment: .leading, spacing: Space.md) {
                    TextField("Gesture name", text: $model.currentLabel, prompt: Text("e.g. nod, yes, click"))
                        .textFieldStyle(FieldTextFieldStyle(label: "Gesture")).accessibilityLabel("Gesture name")
                    FlowLayout(spacing: Space.unit) {
                        // Presets, then your own gestures, each with its take count: no need to remember.
                        ForEach(Self.chips(labels: model.labels), id: \.self) { preset in
                            let count = model.count(for: preset)
                            // Names that are commands ("click") get a pointer mark: they can click for you.
                            let isCommand = VoiceCommandParser.command(forLabel: preset) != nil
                            Button { model.currentLabel = preset } label: {
                                HStack(spacing: 5) {
                                    if isCommand { Image(systemName: "cursorarrow.click").font(.system(size: 12, weight: .semibold)).accessibilityHidden(true) }
                                    Text(count > 0 ? "\(preset) · \(count)" : preset).monospacedDigit()
                                }
                            }
                                .buttonStyle(ChipStyle(selected: preset == AppModel.gestureName(model.currentLabel), hue: hue))
                                .accessibilityLabel(preset)
                                .accessibilityHint(isCommand ? "A command name: once trained, it can \(VoiceCommandParser.command(forLabel: preset)?.title.lowercased() ?? "act") for you" : "")
                                .accessibilityValue((preset == AppModel.gestureName(model.currentLabel) ? "Selected, " : "") + (count == 1 ? "1 take" : "\(count) takes"))
                                .accessibilityAddTraits(preset == AppModel.gestureName(model.currentLabel) ? .isSelected : [])
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.unit) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(n == 1 ? "1 take recorded" : "\(n) takes recorded").font(TypeStyle.rowTitle).monospacedDigit().foregroundStyle(Ink.primary)
                            // Once this gesture has its 2 takes, say what training still needs (never "Trainable" while it can't).
                            Text(progressNote(n))
                                .font(TypeStyle.body).monospacedDigit().foregroundStyle(Ink.secondary)
                        }
                        TakeProgress(count: n, labelled: true).accessibilityHidden(true)
                    }
                    .accessibilityRepresentation {
                        ProgressView(value: Double(min(n, 15)), total: 15) { Text("Takes") }
                            currentValueLabel: { Text("\(n) recorded. \(progressNote(n))") }
                    }
                    if let take = model.lastTake {
                        LiveStrip {
                            HStack(spacing: Space.sm) {
                                SignalPlot(title: "Last take · \(take.label)", samples: take.samples, channels: SignalPlot.velocity, height: 28)
                                Button { model.undoLastTake() } label: { Label("Discard", systemImage: "arrow.uturn.backward") }
                                    .keyboardShortcut("z").help("Discard the last take (⌘Z)")
                            }
                        }
                    } else if let command = VoiceCommandParser.command(forLabel: model.currentLabel), !model.headMouse.motionCommands {
                        // The naming convention made visible: this gesture can act, once gesture commands are on.
                        HStack(spacing: Space.sm) {
                            Text("Once trained, “\(model.currentLabel)” can \(command.title.lowercased()) for you")
                                .font(TypeStyle.body).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Space.unit)
                            Button("Turn on") { model.headMouse.motionCommands = true }
                                .accessibilityLabel("Turn on gesture commands")
                        }
                    } else {
                        Text("Include “nothing” so stillness is learned too").font(TypeStyle.body).foregroundStyle(Ink.secondary)
                    }
                }
            }
        } action: {
            RecordOrb(hue: hue, capture: model.capture).disabled(!model.capture.canRecord)
        }
        .onDisappear { model.capture.cancelForNavigation() }
    }
}

