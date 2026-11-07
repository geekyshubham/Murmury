import SwiftUI

struct SensorsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var showCamera = false
    private let hue = Hue.motion
    var body: some View {
        let pose = model.headPose
        Page {
            PageHeader(hue: hue, title: "Live Motion", subtitle: "Your movement, mirrored live",
                       chip: StateChip(text: !model.hasMotion ? "No motion yet" : (model.isDemo ? "Demo motion" : model.sourcePresentation.chipText),
                                       color: !model.hasMotion ? Ink.tertiary : (model.isDemo ? BudsPresentation.Tone.demo.color : Ink.live)),
                       features: [Feature(symbol: "arrow.left.and.right", title: "Turn", detail: degrees(pose?.yaw, right: "right", left: "left")),
                                  Feature(symbol: "arrow.up.and.down", title: "Nod", detail: degrees(pose?.pitch, right: "up", left: "down")),
                                  Feature(symbol: RollGlyph.symbol, title: "Tilt", detail: degrees(pose?.roll, right: "right", left: "left"))],
                       notices: notices,
                       secondary: SecondaryAction(title: "Signals") { model.detailSheet = .signals },
                       more: moreItems) {
                HeadAvatar(pose: pose, hue: hue, budsLit: model.hasMotion && !model.isDemo, mouth: model.mouthOpen)
            } extra: {
                if model.hasMotion {
                    LiveStrip {
                        SignalPlot(title: "Head speed", samples: model.history, channels: SignalPlot.speed(Ink.scheme("motionLine", light: hue.actionRGB, dark: hue.aRGB)), height: 48, degreesPerSecond: true)
                    }
                }
            }
        } action: {
            OrbButton(title: "Recenter", hue: hue, disabledReason: "Connect a motion source or start the demo", caption: "Sets “straight ahead” · ⌘0") { model.recenter() }
                .keyboardShortcut("0")
                .disabled(!model.hasMotion)
        }
        .sheet(isPresented: $showCamera) { CameraCalibrationView().environment(model) }
    }
    /// Here, where the nod's direction shows live, is where a reversed nod gets noticed.
    private var notices: [StatusNotice] {
        guard model.hasMotion else {
            return [StatusNotice(tone: .info, text: "No motion yet", actionTitle: "Go to Buds", action: { model.screen = .device })]
        }
        guard !model.isDemo, !model.headMouse.config.cameraTaught(model.latest?.bud ?? 0) else { return [] }
        return [StatusNotice(tone: .info, text: "Nod reads the wrong way? Calibrate with your camera", actionTitle: "Calibrate…", action: { showCamera = true })]
    }
    private var moreItems: [MoreItem] {
        var items = [MoreItem(title: "Motion settings…", symbol: "slider.horizontal.3") { model.settingsTab = .capture; openSettings() },
                     MoreItem(title: "Calibrate with camera…", symbol: "camera") { showCamera = true }]
        if !model.hasMotion { items.append(MoreItem(title: "Try demo", symbol: "play.fill") { model.startDemo() }) }
        return items
    }
    private func degrees(_ v: Double?, right: String, left: String) -> String {
        guard let v else { return "Waiting for motion" }
        if abs(v) < 0.5 { return "Centered" }
        return String(format: "%.0f° %@", abs(v), v > 0 ? right : left)
    }
}
