import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    private let hue = Hue.detect
    var body: some View {
        let seg = model.segmenter
        let setup = DetectionSetup.evaluate(hasMotion: model.hasMotion, calibrated: seg.noiseFloor != nil,
                                            calibrating: seg.isCalibrating, listening: seg.autoEnabled, hasGestures: model.canTrain)
        Page {
            PageHeader(hue: hue, title: "Live Detection", subtitle: "Your gestures, recognized as you move",
                       chip: StateChip(text: seg.isCapturing ? "Capturing" : (seg.autoEnabled ? "Listening for gestures" : (!model.canTrain ? "Nothing taught yet" : (seg.noiseFloor == nil ? "Learn stillness first" : "Ready when you are"))),
                                       color: seg.isCapturing ? Ink.danger : (seg.autoEnabled ? Ink.live : Ink.tertiary), active: seg.isCapturing),
                       // "Last detection" appears once there is one; the transcript placeholder covers the empty state.
                       features: [Feature(symbol: "waveform.and.magnifyingglass", title: "Recognized by", detail: model.useNeural && model.neural != nil ? "Your trained model" : "Matching your recorded takes")]
                           + (model.events.isEmpty ? [] : [Feature(symbol: "text.bubble", title: "Last detection", detail: lastDetection)]),
                       notices: notices,
                       secondary: SecondaryAction(title: "History") { model.detailSheet = .detections },
                       more: [MoreItem(title: "Detection settings…", symbol: "slider.horizontal.3") { model.settingsTab = .detection; openSettings() }]) {
                HeadAvatar(pose: model.headPose, hue: hue, budsLit: model.hasMotion && !model.isDemo, recording: seg.isCapturing, mouth: model.mouthOpen)
            } extra: {
                LiveStrip {
                    HStack(spacing: Space.unit) {
                        Text(model.transcript.isEmpty ? "Your gestures appear here" : model.transcript)
                            .font(model.transcript.isEmpty ? TypeStyle.body : TypeStyle.transcript)
                            .foregroundStyle(model.transcript.isEmpty ? Ink.tertiary : Ink.primary)
                            .lineLimit(2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Gesture transcript").accessibilityValue(model.transcript.isEmpty ? "Your gestures appear here" : model.transcript)
                        // Shown only when there is something to clear.
                        Button { model.clearTranscript() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 18)) }
                            .buttonStyle(IconButtonStyle())
                            .opacity(model.transcript.isEmpty && model.events.isEmpty ? 0 : 1)
                            .disabled(model.transcript.isEmpty && model.events.isEmpty)
                            .accessibilityHidden(model.transcript.isEmpty && model.events.isEmpty)
                            .accessibilityLabel("Clear transcript").help("Remove recognized gestures from this list")
                    }
                }
            }
        } action: {
            OrbButton(title: setup.action.rawValue, hue: hue, active: seg.autoEnabled, disabledReason: setup.disabledReason,
                      caption: setup.caption) {
                switch setup.action {
                case .calibrate: seg.calibrate()
                case .listen, .stop: seg.autoEnabled.toggle()
                case .calibrating: break
                }
            }
            .disabled(setup.disabledReason != nil)
            .keyboardShortcut("l")
        }
    }
    /// One notice: teaching comes first (nothing to match without it), then stillness.
    private var notices: [StatusNotice] {
        let seg = model.segmenter
        if !model.canTrain, !seg.autoEnabled {
            // One sequence: learn stillness here now (the round button), then teach.
            // Before stillness is learned it's the next step; after, it's the only thing missing.
            // One next step at a time: while stillness is unlearned the round button is the step, so
            // the notice only explains the order; Go to Teach appears once teaching is what's next.
            if seg.noiseFloor == nil { return [StatusNotice(tone: .info, text: "Learn stillness, then teach 2 gestures")] }
            return [StatusNotice(tone: .info, text: "Teach 2 gestures to listen for", actionTitle: "Go to Teach", action: { model.screen = .train })]
        }
        // Stillness: the "Learn stillness" button and its caption say it; no notice repeats them.
        return []
    }
    private var lastDetection: String {
        guard let e = model.events.first else { return "Nothing yet" }
        return "\(e.label) · \(Int(e.confidence * 100))% · \(e.accepted ? "accepted" : "too unsure to act")"
    }
}
