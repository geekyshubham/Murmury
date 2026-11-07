import AppKit
import AVFoundation
import SwiftUI

struct MouseView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings
    /// "Check again" found Accessibility still off.
    @State private var trustStillOff = false
    static let trustStillOffText = "Still off for this copy of Murmury. If its switch is already on, remove Murmury there with –, then choose Open Settings and turn it on again"
    @State private var showCamera = false
    @State private var showMurmur = false
    @State private var confirmPointerOnly = false
    private let hue = Hue.control
    private var setup: ControlSetup {
        let mouse = model.headMouse
        return ControlSetup.evaluate(hasMotion: model.hasMotion, isDemo: model.isDemo, budsBusy: model.buds.isBusy,
                                     trusted: mouse.isTrusted, micRunning: model.transcriber.isRunning,
                                     calibrated: mouse.config.cameraTaught(model.latest?.bud ?? 0),
                                     enabled: model.showsMouseOn, voiceFailure: model.voiceFailure)
    }
    var body: some View {
        let status = HeadMouseStatus(model)
        TimelineView(.periodic(from: .now, by: model.voiceFailure == .stopped || model.motionLost ? 1 : 3600)) { _ in
        Page {
            PageHeader(hue: hue, title: "Head Mouse", subtitle: model.controlCopy.subtitle,
                       chip: StateChip(text: status.text, color: status.color, active: model.showsMouseOn && !model.showsMousePaused),
                       features: features, notices: notices,
                       secondary: SecondaryAction(title: "Voice commands") { model.detailSheet = .commands },
                       more: moreItems) {
                HeadAvatar(pose: model.headPose, hue: hue, budsLit: model.hasMotion && !model.isDemo, showGaze: model.showsMouseOn, sampleTime: model.latestArrival, mouth: model.mouthOpen)
            }
        } action: { primary }
        }
        .sheet(isPresented: $showCamera) { CameraCalibrationView().environment(model) }
        .sheet(isPresented: $showMurmur) { MurmurEnrollmentView().environment(model) }
        .confirmationDialog(model.showsMouseOn ? "Continue without voice?" : "Start the head mouse without voice?", isPresented: $confirmPointerOnly) {
            Button(model.showsMouseOn ? "Continue without voice" : "Start without voice") { Task { await model.setHeadMouse(true, pointerOnly: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.withoutVoiceMessage(canClick: model.canClickWithoutVoice, nodToPause: model.nodToPause))
        }
    }

    private var features: [Feature] {
        let mouse = model.headMouse
        if model.showsMouseOn || setup.isComplete || model.showsCalibrationStep != nil {
            return model.controlCopy.rows.enumerated().map { index, row in
                let canSwitch = index == 0 && model.showsMouseOn && !model.showsMousePaused && model.showsCalibrationStep == nil
                if let action = row.action {
                    return Feature(symbol: row.symbol, title: row.title, detail: row.detail, actionTitle: action.title, action: {
                        switch action {
                        case .turnOnVoice: model.turnOnVoice()
                        case .turnOnDwell: mouse.dwellClicks = true
                        }
                    }, actionSpokenTitle: action.spokenTitle)
                }
                return Feature(symbol: row.symbol, title: row.title, detail: row.detail,
                               actionTitle: canSwitch ? (mouse.mode == .scroll ? "Pointer mode" : "Scroll mode") : nil,
                               action: canSwitch ? { mouse.perform(mouse.mode == .scroll ? .pointerMode : .scrollMode) } : nil)
            }
        }
        return setup.visibleRows.map { row in
            switch row.title {
            case "Buds":
                return Feature(symbol: "earbuds", title: row.title, detail: row.detail, actionTitle: model.buds.isBusy ? nil : "Connect",
                               action: { model.connectMotionSource() })
            case "Clicking permission":
                return Feature(symbol: "hand.raised", title: row.title, detail: row.detail, actionTitle: "Allow", action: allowAccess)
            default:
                // Status only: the notice above and the orb carry the fix.
                return Feature(symbol: "mic.slash", title: row.title, detail: row.detail)
            }
        }
    }

    private var poseText: String {
        guard let p = model.headPose else { return "Waiting for motion" }
        return String(format: "Turn %+.0f° · Nod %+.0f°", p.yaw, p.pitch)
    }

    /// One notice, by priority: voice, calibration, permission, then the calibration tip.
    private var notices: [StatusNotice] {
        if model.motionLost || model.controlCopy.chip == "Paused · buds disconnected" {
            // A long outage escalates: what to check, and the way to Bluetooth.
            if model.motionRetries >= AppModel.motionEscalateAfter {
                return [StatusNotice(tone: .danger, text: "Still can't reach the buds — check they're out of the case and charged",
                                     actionTitle: "Reconnect now", action: { model.reconnectNow() },
                                     secondaryTitle: "Bluetooth Settings…", secondaryAction: {
                                         if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { openURL(url) }
                                     })]
            }
            return [StatusNotice(tone: .danger, text: "Reconnecting automatically", actionTitle: "Reconnect now", action: { model.reconnectNow() })]
        }
        if model.handsFreeMode == .pointerOnly {
            return [StatusNotice(tone: .info, text: model.controlCopy.menuLine, actionTitle: "Retry voice", action: { Task { await model.restartVoice() } })]
        }
        if let failure = model.voiceFailure {
            var r = failure.recovery
            if failure == .stopped {
                // Without voice the way on is dwell or gesture clicks, when either is set up.
                r.secondary = .startWithoutVoice  // dwell comes on with it when nothing else clicks
                // Retries ran out: say where to look, and offer the voice settings.
                if model.controlCopy.recovery == .failed {
                    // "Continue without voice…" keeps the button slot; the microphone is the other way on.
                    r.text = "Voice still stopped after several tries"; r.secondary = .startWithoutVoice; r.tertiary = .voiceSettings
                }
            }
            // When the round button carries the fix, the notice offers the other ways on.
            let next = voiceFixAction == nil ? r.primary : r.secondary
            var other = voiceFixAction == nil ? r.secondary : r.tertiary
            if other == next { other = nil }
            return [StatusNotice(tone: failure == .stopped ? .danger : .warn, text: r.text,
                                 actionTitle: next.map(title), action: next.map { action in { perform(action) } },
                                 secondaryTitle: other.map(title), secondaryAction: other.map { action in { perform(action) } })]
        }
        if let recovery = CalibrationRecovery.evaluate(cameraPhase: .idle, cameraAuth: .authorized, hasCamera: true, hasMotion: true,
                                                        noCameraStep: model.showsCalibrationStep, noCameraFailed: model.showsCalibrationFailed,
                                                        message: model.showsCalibrationMessage) {
            // After a failed calibration the round button is "Try again"; the notice offers the other way.
            let actions = model.showsCalibrationFailed ? recovery.actions.filter { $0 != .tryAgain } : recovery.actions
            return [StatusNotice(tone: recovery.tone, text: recovery.text,
                                 actionTitle: actions.first?.title, action: actions.first.map { a in { perform(a) } },
                                 secondaryTitle: actions.dropFirst().first?.title, secondaryAction: actions.dropFirst().first.map { a in { perform(a) } })]
        }
        if !model.headMouse.isTrusted {
            // Checked and still off: the switch may be on for an older copy of Murmury (macOS keeps
            // a grant per build when it was given to an unsigned one), so say how to renew it.
            return [StatusNotice(tone: .warn, text: trustStillOff ? Self.trustStillOffText : "Allow clicking in Accessibility settings",
                                 actionTitle: "Open Settings", action: allowAccess,
                                 secondaryTitle: "Check again", secondaryAction: {
                                     model.headMouse.refreshTrust()
                                     trustStillOff = !model.headMouse.isTrusted
                                 })]
        }
        if setup.recommendCalibration {
            return [StatusNotice(tone: .info, text: "Let your camera calibrate up, down, left and right", actionTitle: "Calibrate…", action: { showCamera = true })]
        }
        return []
    }

    private var moreItems: [MoreItem] {
        var items = [MoreItem(title: "Pointer settings…", symbol: "slider.horizontal.3") { model.settingsTab = .pointer; openSettings() },
                     MoreItem(title: "Calibrate with camera…", symbol: "camera") { showCamera = true },
                     MoreItem(title: "Calibrate without camera", symbol: "scope") { model.headMouse.startCalibration() },
                     MoreItem(title: model.murmurModel == nil ? "Teach your murmur…" : "Teach your murmur again…", symbol: "waveform.and.mic") { showMurmur = true }]
        if model.voiceFailure != nil, model.voiceFailure != .stopped, !model.showsMouseOn {
            items.append(MoreItem(title: "Start without voice…", symbol: "cursorarrow") { confirmPointerOnly = true })
        }
        return items
    }

    private func perform(_ action: VoiceFailure.Action) {
        switch action {
        case .openSettings(let pane): openURL(pane.url)
        case .checkAgain: model.recheckVoice()
        case .tryAgain: Task { if model.headMouse.isEnabled { await model.restartVoice() } else { await model.setHeadMouse(true) } }
        case .voiceSettings: model.settingsTab = .voice; openSettings()
        case .restartVoice: Task { await model.restartVoice() }
        case .startWithoutVoice: confirmPointerOnly = true
        }
    }

    private func perform(_ action: CalibrationRecovery.Action) {
        switch action {
        case .cancel: model.headMouse.cancelCalibration()
        case .tryAgain, .calibrateWithoutCamera: model.headMouse.startCalibration()
        case .useCamera: showCamera = true
        case .openCameraSettings: openURL(PrivacyPane.camera.url)
        case .connectBuds: model.screen = .device
        }
    }

    private func allowAccess() {
        model.headMouse.requestTrust()
        openURL(PrivacyPane.accessibility.url)
    }

    /// What going on without voice means, naming only the pause that is actually on.
    static func withoutVoiceMessage(canClick: Bool, nodToPause: Bool) -> String {
        let clicks = canClick ? "No spoken click or pause." : "No spoken click or pause, so dwell clicking turns on: hold the pointer still to click."
        let pause = nodToPause ? " Nod twice to pause;" : " Pause and resume from the menu bar;"
        return clicks + pause + " stop with ⇧⌘M or the menu bar."
    }

    /// One name per action, by context: before the head mouse runs it starts, after it continues.
    private func title(_ action: VoiceFailure.Action) -> String {
        action == .startWithoutVoice && !model.showsMouseOn ? "Start without voice…" : action.title
    }

    /// The voice fix the round button carries: while voice loss or denial pauses a running head
    /// mouse, and before starting when voice is the one thing missing. Stop stays on ⇧⌘M.
    private var voiceFixAction: VoiceFailure.Action? {
        guard let failure = model.voiceFailure else { return nil }
        if model.showsMouseOn, model.showsMousePaused, model.handsFreeMode == .voice { return failure == .stopped ? .restartVoice : failure.recovery.primary }
        return setup.primary == .fixVoice ? failure.recovery.primary : nil
    }

    @ViewBuilder private var primary: some View {
        let caption = model.controlCopy.caption
        if let fix = voiceFixAction, fix == .restartVoice, model.controlCopy.recovery == .restarting {
            // A restart is already under way: nothing to press until it finishes.
            OrbButton(title: "Restarting…", hue: hue, active: true, disabledReason: "Voice is restarting now") {}.disabled(true)
        } else if let fix = voiceFixAction {
            OrbButton(title: fix.orbTitle, hue: hue, active: model.showsMouseOn,
                      caption: model.showsMouseOn ? "⇧⌘M to stop" : "Then press Start") {
                perform(fix)
            }.accessibilityHint(fix.title)
        } else {
        switch setup.primary {
        case .connect: OrbButton(title: "Connect", hue: hue, caption: "Pair in Bluetooth settings first") { model.connectMotionSource() }.accessibilityHint("Connects your motion source").keyboardShortcut("k")
        case .connecting: OrbButton(title: "Connecting…", hue: hue, disabledReason: "Opening the motion connection") {}.disabled(true)
        case .allowAccess: OrbButton(title: "Allow access", hue: hue, caption: "Needed to click for you") { allowAccess() }.accessibilityHint("Opens Accessibility settings to allow clicking")
        case .fixVoice:
            OrbButton(title: "Fix voice", hue: hue, caption: "Spoken click and pause need it") {
                if let action = model.voiceFailure?.recovery.primary { perform(action) }
            }
        case .start, .stop:
            if model.showsCalibrationFailed, !model.showsMouseOn {
                OrbButton(title: "Try again", hue: hue, caption: "Then turn right, then look up") { model.headMouse.startCalibration() }
                    .accessibilityHint("Calibrates direction again")
            } else if model.showsCalibrationStep != nil {
                // While calibrating, the one action is to leave it, not to start something else.
                OrbButton(title: "Cancel", hue: hue, active: true, caption: "Follow the steps above · Esc cancels") {
                    model.headMouse.cancelCalibration()
                }.accessibilityHint("Stops calibrating and keeps your previous setup").keyboardShortcut(.cancelAction)
            } else {
                OrbButton(title: model.showsMouseOn ? "Stop" : "Start", hue: hue, active: model.showsMouseOn, caption: caption) {
                    Task { await model.setHeadMouse(!model.showsMouseOn) }
                }.accessibilityHint(model.controlCopy.hint + " (⇧⌘M)").keyboardShortcut("m", modifiers: [.shift, .command])
            }
        }
        }
    }
}

/// Status text and colour shared by the screen and the menu-bar menu.
struct HeadMouseStatus {
    let text: String
    let color: Color

    @MainActor init(_ model: AppModel) {
        let copy = model.controlCopy
        text = copy.chip; color = copy.tone.color
    }
}

/// Available while the head mouse runs, even with another app in front.
struct HeadMouseMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    var body: some View {
        let mouse = model.headMouse
        let status = HeadMouseStatus(model)
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack { BrandMark(); Text("Murmury").font(TypeStyle.rowTitle) }
            StateChip(text: status.text, color: status.color)
            if let failure = model.voiceFailure {
                Label(model.handsFreeMode == .pointerOnly ? model.controlCopy.menuLine : failure.recovery.text, systemImage: "mic.slash").font(TypeStyle.body).foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .openSettings(let pane) = failure.recovery.primary {
                    Button("Open Settings") { openURL(pane.url) }
                } else {
                    Button("Retry voice") { Task { await model.restartVoice() } }
                }
            }
            // The voice label above already says it while voice is failing.
            if model.voiceFailure == nil {
                Text(model.controlCopy.menuLine).font(TypeStyle.body).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.voiceFailure == .stopped, model.showsMousePaused, model.handsFreeMode == .voice {
                Button("Continue without voice") { Task { await model.setHeadMouse(true, pointerOnly: true) } }
            }
            if model.motionLost {
                if model.motionRetries >= AppModel.motionEscalateAfter {
                    Text("Still can't reach the buds — check they're out of the case and charged").font(TypeStyle.body)
                        .foregroundStyle(Ink.primary).fixedSize(horizontal: false, vertical: true)
                    Button("Bluetooth Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { openURL(url) }
                    }
                }
                Button("Reconnect buds now") { model.reconnectNow() }
            }
            Button(mouse.isPaused ? "Resume head mouse" : "Pause head mouse") { mouse.perform(mouse.isPaused ? .resume : .pause) }
                // A voice-loss pause waits for voice and a buds-loss pause for the buds; a pause in a
                // voiceless mode resumes here.
                .disabled((model.voiceFailure == .stopped && model.handsFreeMode == .voice) || model.motionLost)
            Button(mouse.mode == .scroll ? "Switch to pointer" : "Switch to scrolling") {
                mouse.perform(mouse.mode == .scroll ? .pointerMode : .scrollMode)
            }.disabled(model.showsMousePaused)
            Divider()
            Button("Turn off head mouse") { Task { await model.setHeadMouse(false) } }
            Button("Show Murmury") {
                model.screen = .mouse
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.identifier?.rawValue == "Murmury.main" }?.makeKeyAndOrderFront(nil)
            }
            AdjustButton(tab: .pointer, title: "Settings…")
        }
        .font(TypeStyle.body).foregroundStyle(Ink.primary).buttonStyle(.quiet)
        .padding(Space.md).frame(width: 300).background(Ink.night)
    }
}
