import AVFoundation
import Charts
import SwiftUI

/// One-time webcam calibration: the camera and the live head side by side while a short routine
/// teaches Murmury how the buds sit. The camera turns off when the sheet closes.
struct CameraCalibrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private let hue = Hue.control
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cal = model.cameraCalibration
        DetailSheet(title: "Calibrate with your camera", hue: hue, showClose: false) {
            Text("About half a minute: the camera watches your head while your buds feel it, and the head learns to move the way you do. No video is kept, and nothing leaves your Mac.")
                .font(TypeStyle.body).foregroundStyle(Ink.secondary)
                .frame(maxWidth: TypeStyle.subtitleMeasure + 80, alignment: .leading)  // a readable measure, as on the main screens
                .fixedSize(horizontal: false, vertical: true)

            if case .done = cal.phase, let report = cal.report {
                HeadCheckResults(report: report, hue: hue)
            } else {
                HStack(spacing: Space.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(.black.opacity(0.85))
                        if cal.tracker.isRunning {
                            CameraPreview(session: cal.tracker.session)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        } else {
                            Image(systemName: "video").font(.system(size: 34, weight: .light)).foregroundStyle(Ink.porcelain.opacity(0.6))
                        }
                        if cal.tracker.isRunning {
                            VStack {
                                Spacer()
                                StateChip(text: cal.tracker.faceFound ? "Face found" : "Looking for your face",
                                          color: cal.tracker.faceFound ? Ink.live : Ink.warn, active: !cal.tracker.faceFound)
                                    .padding(Space.sm)
                            }
                        }
                    }
                    .accessibilityLabel(cal.tracker.faceFound ? "Camera preview, face found" : "Camera preview")
                    HeadAvatar(pose: model.headPose, hue: hue, budsLit: model.hasMotion && !model.isDemo, mouth: model.mouthOpen)
                        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(hue.gradient.opacity(0.35)))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .frame(height: 220)
            }

            // Every way this can stop has a next step: settings, the camera-free route, or the buds.
            if let recovery {
                // The footer's own button already says Try again; the notice offers only the other ways on.
                let actions = recovery.actions.filter { $0 != .tryAgain }
                StatusLine(notices: [StatusNotice(tone: recovery.tone, text: recovery.text,
                                                  actionTitle: actions.first?.title, action: actions.first.map { a in { perform(a) } },
                                                  secondaryTitle: actions.dropFirst().first?.title,
                                                  secondaryAction: actions.dropFirst().first.map { a in { perform(a) } })])
            } else {
                instruction(cal)
            }
        } footer: {
            actions(cal)
        }
        .onDisappear { cal.cancel() }
    }

    /// The sheet's actions in the footer's fixed slots: Cancel, a secondary, the primary.
    private func actions(_ cal: CameraCalibration) -> some View {
        SheetFooter {
            switch cal.phase {
            case .idle, .failed: SlotButton("Cancel") { close() }.keyboardShortcut(.cancelAction)
            case .starting, .running: SlotButton("Cancel") { cal.cancel() }.keyboardShortcut(.cancelAction)
            case .done: EmptyView()
            }
        } secondary: {
            if cal.phase == .running, cal.stalled {
                // A missed instruction never passes silently: the step waits for one of these.
                SlotButton("Skip step") { cal.skipStep() }
            } else if case .done = cal.phase, cal.report != nil {
                SlotButton("Save frames…") {
                    if let url = cal.saveFrames() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .help("Saves each camera frame's turn, nod and tilt beside the head's, as numbers (CSV) in Documents › Murmury › Checks")
            }
        } primary: {
            switch cal.phase {
            case .idle, .failed:
                SlotButton(cal.phase == .idle ? "Start" : "Try again") { Task { await model.calibrateWithCamera() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(SolidButtonStyle(hue: hue))
                    .disabled(model.latest == nil || model.isDemo)
            case .starting, .running:
                if cal.stalled {
                    SlotButton("Repeat step") { cal.retryStep() }.keyboardShortcut(.defaultAction).buttonStyle(SolidButtonStyle(hue: hue))
                }
            case .done:
                SlotButton("Done") { close() }.keyboardShortcut(.defaultAction).buttonStyle(SolidButtonStyle(hue: hue))
            }
        }
    }

    @ViewBuilder private func instruction(_ cal: CameraCalibration) -> some View {
        switch cal.phase {
        case .idle:
            VStack(alignment: .leading, spacing: Space.sm) {
                Label(model.isDemo ? "Connect your buds first: demo motion can't be calibrated"
                      : model.latest == nil ? "Connect your buds and start streaming first" : "Sit facing the camera, then press Start",
                      systemImage: model.latest == nil || model.isDemo ? "earbuds" : "person.crop.square")
                    .font(TypeStyle.status)
                // The whole routine, so the half minute holds no surprises.
                let steps = cal.script.steps.filter { $0.kind != .centre }
                FlowLayout(spacing: Space.md, lineSpacing: Space.unit) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, s in
                        step(index + 1, s.kind)
                    }
                }
                // One line of text for VoiceOver, read in order, rather than seven unlabelled shapes.
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel("\(steps.count) steps: " + steps.map(\.kind.title).joined(separator: ", "))
            }
        case .starting:
            Label("Starting the camera…", systemImage: "video").font(TypeStyle.status)
        case .running:
            let step = cal.step
            VStack(alignment: .leading, spacing: Space.sm) {
                Label(step?.kind.instruction ?? "Hold on…", systemImage: step?.kind.symbol ?? "hourglass")
                    .font(TypeStyle.instruction)
                    .contentTransition(.opacity)
                    .animation(Motion.spring(reduceMotion), value: step?.kind)
                ProgressView(value: cal.progress).tint(hue.a)
                    .accessibilityLabel("Calibration progress")
                    .accessibilityValue("\(Int((cal.progress * 100).rounded())) percent")
                if cal.stalled {
                    Text("Didn't see that move yet. Repeat the step, or skip it.").font(TypeStyle.body).foregroundStyle(Ink.secondary)
                }
            }
            .accessibilityElement(children: .contain)
        case .done(let fit):
            VStack(alignment: .leading, spacing: Space.unit) {
                Label(cal.report == nil ? "Calibrated. Your buds follow your head now, and the camera is off."
                                        : "Learned. The head now moves the way you do, and the camera is off.", systemImage: "checkmark.circle.fill")
                    .font(TypeStyle.status).foregroundStyle(Ink.live)
                DisclosureGroup {
                    Text(String(format: "Fit %.0f%% · camera %.0f ms behind the buds", fit.quality * 100, fit.lag * 1000))
                        .font(TypeStyle.caption).foregroundStyle(Ink.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Details").frame(minWidth: 60, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                }
                .font(TypeStyle.caption).foregroundStyle(Ink.secondary)
            }
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").font(TypeStyle.status).foregroundStyle(Ink.warn)
        }
    }

    private func step(_ n: Int, _ kind: CalibrationScript.Kind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: kind.symbol).font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22).background(Circle().fill(hue.actionRGB.color)).foregroundStyle(.white)
            Text(kind.title).font(TypeStyle.body).foregroundStyle(Ink.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(n), \(kind.title)")
    }

    private var recovery: CalibrationRecovery? {
        let cal = model.cameraCalibration
        switch cal.phase {
        case .idle, .failed: break
        default: return nil
        }
        let auth: VoiceAuthorization = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
        return CalibrationRecovery.evaluate(cameraPhase: cal.phase, cameraAuth: auth, hasCamera: AVCaptureDevice.default(for: .video) != nil,
                                            hasMotion: model.latest != nil, noCameraStep: nil, noCameraFailed: false, message: nil)
    }

    private func perform(_ action: CalibrationRecovery.Action) {
        switch action {
        case .openCameraSettings: openURL(PrivacyPane.camera.url)
        case .calibrateWithoutCamera:
            close()
            model.headMouse.startCalibration()
        case .tryAgain: Task { await model.calibrateWithCamera() }
        case .connectBuds:
            close()
            model.screen = .device
        case .cancel, .useCamera: break
        }
    }

    private func close() {
        model.cameraCalibration.cancel()
        dismiss()
    }
}

/// Mirrored live camera preview.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// What the camera session found, frame by frame: how far the 3D head was from the person's real
/// movement before learning, and after, per axis, with the traces for one axis at a time.
private struct HeadCheckResults: View {
    let report: HeadModelFit.Report
    let hue: Hue
    @State private var axis = 0
    private let names = ["Turn", "Nod", "Tilt"]

    /// Column widths, so before, arrow and after line up down the three rows.
    private enum Column { static let name: CGFloat = 44, figure: CGFloat = 40, arrow: CGFloat = 12 }
    private static let series: [(name: String, dash: [CGFloat], width: CGFloat)] = [("You", [], 2.5), ("Head before", [4, 3], 1.5), ("Head after", [], 1.5)]

    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Head vs you, average error").font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                ForEach(0..<3, id: \.self) { k in
                    HStack(spacing: Space.unit) {
                        Text(names[k]).foregroundStyle(Ink.primary).frame(width: Column.name, alignment: .leading)
                        if let before = report.before {
                            Text(String(format: "%.0f°", before[k])).foregroundStyle(Ink.secondary).frame(width: Column.figure, alignment: .trailing)
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.tertiary).frame(width: Column.arrow)
                        }
                        // Same size before and after: colour, not scale, carries the improvement.
                        Text(String(format: "%.0f°", report.after[k])).foregroundStyle(Ink.live).frame(width: Column.figure, alignment: .trailing)
                    }
                    .font(TypeStyle.rowTitle.monospacedDigit())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(report.before.map { String(format: "%@: %.0f degrees before, %.0f after", names[k], $0[k], report.after[k]) }
                                        ?? String(format: "%@: %.0f degrees", names[k], report.after[k]))
                }
                if !report.learnedTilt {
                    Text("Tilt estimated from turn and nod").font(TypeStyle.caption).foregroundStyle(Ink.tertiary)
                }
            }
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(2)  // the figures first, then the chart
            VStack(alignment: .leading, spacing: Space.unit) {
                CapsuleSegmented(label: "Axis", values: [0, 1, 2], selection: $axis, hue: hue, title: { names[$0] })
                HStack(spacing: Space.md) {
                    ForEach(Self.series, id: \.name) { s in
                        HStack(spacing: 6) {
                            LegendLine().stroke(color(s.name), style: StrokeStyle(lineWidth: s.width, lineCap: .round, dash: s.dash))
                                .frame(width: 16, height: 4)
                            Text(s.name).font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                        }
                    }
                }
                .accessibilityHidden(true)  // the chart's own summary names the series
                Chart {
                    ForEach(points, id: \.id) { p in
                        LineMark(x: .value("Seconds", p.t), y: .value("Degrees", p.value), series: .value("Series", p.series))
                            .foregroundStyle(by: .value("Series", p.series))
                            .lineStyle(StrokeStyle(lineWidth: p.series == "You" ? 2.5 : 1.5, dash: p.series == "Head before" ? [4, 3] : []))
                    }
                }
                .chartForegroundStyleScale(["You": Ink.primary, "Head before": Ink.tertiary, "Head after": hue.a])
                .chartLegend(.hidden)
                .chartXAxis { AxisMarks { _ in AxisGridLine(); AxisTick(); AxisValueLabel().font(TypeStyle.axis) } }
                .chartYAxis { AxisMarks { _ in AxisGridLine(); AxisTick(); AxisValueLabel().font(TypeStyle.axis) } }
                .chartXAxisLabel { Text("seconds").font(TypeStyle.axis) }
                .chartYAxisLabel { Text("degrees").font(TypeStyle.axis) }
                .frame(minHeight: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(String(format: "%@ over the session, you against the head: after learning it follows you within %.0f degrees on average%@",
                                           names[axis], report.after[axis],
                                           report.before.map { String(format: ", %.0f before", $0[axis]) } ?? ""))
            }
            .accessibilitySortPriority(1)
        }
        .padding(Space.md)
        .cardSurface()
    }

    private func color(_ series: String) -> Color {
        series == "You" ? Ink.primary : series == "Head before" ? Ink.tertiary : hue.a
    }
    /// A short horizontal stroke for the legend, drawn with the series' own width and dash.
    private struct LegendLine: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path(); p.move(to: CGPoint(x: rect.minX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); return p
        }
    }

    private struct Point { let id: Int; let t: Double; let value: Double; let series: String }
    /// At most about 240 frames per series, so the chart stays light.
    private var points: [Point] {
        let frames = report.frames
        guard let t0 = frames.first?.t else { return [] }
        let step = max(1, frames.count / 240)
        var out: [Point] = []
        for (i, f) in frames.enumerated() where i % step == 0 {
            let t = f.t - t0
            out.append(Point(id: out.count, t: t, value: f.camera[axis], series: "You"))
            if let a = f.avatar { out.append(Point(id: out.count, t: t, value: a[axis], series: "Head before")) }
            out.append(Point(id: out.count, t: t, value: f.learned[axis], series: "Head after"))
        }
        return out
    }
}
