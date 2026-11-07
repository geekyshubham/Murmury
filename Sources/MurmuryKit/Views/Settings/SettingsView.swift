import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case pointer = "Pointer", voice = "Voice", capture = "Capture", detection = "Detection", model = "Model"
    case buds = "Buds", recording = "Recording"
    var symbol: String {
        switch self {
        case .pointer: "cursorarrow"
        case .voice: "mic"
        case .capture: "record.circle"
        case .detection: "waveform"
        case .model: "brain"
        case .buds: "earbuds"
        case .recording: "folder"
        }
    }
}

struct AdjustButton: View {
    var tab: SettingsTab
    var title = "Adjust…"
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button(title) { model.settingsTab = tab; openSettings() }
            .accessibilityLabel("\(title) \(tab.rawValue) settings")
    }
}

struct SettingsView: View {
    @State private var showCommands = false
    @Environment(AppModel.self) private var model
    @AppStorage(Segmenter.takeLengthKey) private var takeSeconds: TimeInterval = Segmenter.takeLengths[0]
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            pointer.tabItem { Label("Pointer", systemImage: "cursorarrow") }.tag(SettingsTab.pointer)
            voice.tabItem { Label("Voice", systemImage: "mic") }.tag(SettingsTab.voice)
            capture.tabItem { Label("Capture", systemImage: "record.circle") }.tag(SettingsTab.capture)
            detection.tabItem { Label("Detection", systemImage: "waveform") }.tag(SettingsTab.detection)
            training.tabItem { Label("Model", systemImage: "brain") }.tag(SettingsTab.model)
            advanced.tabItem { Label("Buds", systemImage: "earbuds") }.tag(SettingsTab.buds)
            recording.tabItem { Label("Recording", systemImage: "folder") }.tag(SettingsTab.recording)
        }
        .scrollContentBackground(.hidden)
        .background(Ink.night)
        .formStyle(.grouped)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 460, idealHeight: 580)
    }
    private var pointer: some View {
        @Bindable var mouse = model.headMouse
        @Bindable var app = model
        return Form {
            Section("Starting") {
                Toggle("Start when buds connect", isOn: $app.startWhenBudsConnect)
                Text("The head mouse starts on its own when your buds begin streaming, so nobody needs to press Start")
                    .font(TypeStyle.caption).foregroundStyle(Ink.secondary)
            }
            Section("Pointer") {
                setting("Speed", $mouse.config.speed, 4...80, 1, "%.0f pt/°")
                setting("Steadiness", $mouse.config.deadzone, 0...15, 0.5, "%.1f °/s")
                setting("Acceleration", $mouse.config.acceleration, 0...4, 0.1, "%.1f×")
                setting("Smoothing", $mouse.config.smoothing, 0...0.9, 0.05, "%.2f")
                Toggle("Invert horizontal", isOn: $mouse.config.invertHorizontal)
                Toggle("Invert vertical", isOn: $mouse.config.invertVertical)
            }
            Section("Clicking without voice") {
                Toggle("Click by holding the pointer still", isOn: $mouse.dwellClicks)
                Toggle("Show the click-type palette (Left, Right, Double, Drag)", isOn: $mouse.dwellPalette).disabled(!mouse.dwellClicks)
                setting("Hold time", $mouse.dwellSeconds, DwellClicker.secondsRange, 0.1, "%.1f s").disabled(!mouse.dwellClicks)
                Text("A ring by the pointer fills while you hold still, then it clicks. Move away to click again.")
                    .font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                Toggle("Play a sound when the pointer pauses or voice stops", isOn: $app.soundsEnabled)
            }
            Section("Nodding") {
                Toggle("Nod twice to pause without voice", isOn: $app.nodToPause)
                setting("Nod depth", $app.nodDepth, AppModel.nodDepthRange, 1, "%.0f°")
                setting("Nod pace", $app.nodSlowness, AppModel.nodSlownessRange, 0.1, "%.1f× slower")
                Text("A smaller depth or a slower pace suits limited neck movement. After voice loss, nodding twice always retries voice.")
                    .font(TypeStyle.caption).foregroundStyle(Ink.secondary)
            }
            Section("Scrolling") {
                setting("Scroll mode speed", $mouse.config.scrollSpeed, 0.2...4, 0.1, "%.1f×")
                setting("Spoken step", $mouse.config.scrollStep, 40...800, 20, "%.0f pt")
                Toggle("Invert scrolling", isOn: $mouse.config.invertScroll)
            }
            Section("Direction") { DirectionCalibration() }
        }
    }
    private var voice: some View {
        @Bindable var mouse = model.headMouse
        return Form {
            Section("Voice commands") {
                Toggle("Listen for voice commands", isOn: $mouse.voiceClicks)
                    .onChange(of: mouse.voiceClicks) { model.checkVoiceHealth() }
                Text(model.controlCopy.menuLine).font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                Toggle("Hold pointer while speaking", isOn: $mouse.holdWhileSpeaking)
                Toggle("Trained gestures trigger commands", isOn: $mouse.motionCommands)
                MicrophoneControls()
                Button("Commands…") { showCommands = true }
            }
            Section("Murmur") { MurmurSettings() }
        }
        .sheet(isPresented: $showCommands) {
            CommandsSheet().environment(model)
        }
    }
    private var capture: some View {
        @Bindable var seg = model.segmenter
        return Form {
            Section("Takes") {
                Picker("Longest take", selection: $takeSeconds) {
                    ForEach(Segmenter.takeLengths, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Text("Record and Space stop a take at this length. Choose longer if you move slowly.").font(TypeStyle.caption)
            }
            Section("Automatic capture") {
                Toggle("Capture on movement", isOn: $seg.autoEnabled).disabled(seg.noiseFloor == nil)
                Button(seg.isCalibrating ? "Learning…" : "Learn stillness · stay still for 2 seconds") { seg.calibrate() }
                    .disabled(seg.isCalibrating || !model.hasMotion)
                if seg.isCalibrating { ProgressView("Learning resting motion") }
                EnergyMeter(energy: seg.energy, threshold: seg.threshold, capturing: seg.isCapturing)
                setting("Sensitivity", $seg.triggerRatio, 1.5...10, 0.5, "%.1f×")
                Text("Learn stillness once before using automatic capture").font(TypeStyle.caption)
            }
        }
    }
    private var detection: some View {
        @Bindable var model = model
        return Form {
            Section("Detection") {
                setting("Minimum confidence", $model.minConfidence, 0.3...0.99, 0.01, "%.2f")
                Picker("Recognize with", selection: Binding(get: { model.useNeural && model.neural != nil }, set: { model.useNeural = $0 })) {
                    Text("Templates").tag(false)
                    Text("Neural model").tag(true)
                }.disabled(model.neural == nil)
                if model.neural == nil { Text("Templates are used until a neural model is trained").font(TypeStyle.caption) }
            }
        }
    }
    private var training: some View {
        @Bindable var model = model
        return Form {
            Section("What it learns from") {
                FeatureToggles(set: $model.featureSet, takesWithoutIMU: model.takesWithoutIMU)
            }
            Section("Training") {
                setting("Window", $model.trainWindow, 20...100, 5, "%.0f frames")
                setting("Augmented copies", $model.trainAugment, 0...30, 1, "%.0f")
                setting("Iterations", $model.trainIterations, 10...150, 5, "%.0f")
            }
        }
    }
    private var advanced: some View {
        let buds = model.buds
        return Form {
            Section("Connection · Advanced") {
                LabeledContent("Address", value: buds.deviceAddress ?? "—")
                LabeledContent("RFCOMM channel", value: buds.channelID.map(String.init) ?? "—")
                LabeledContent("Head tracking", value: buds.sensorSupported.map { $0 ? "Supported" : "Not supported" } ?? "Unknown")
                LabeledContent("Raw gyro + accelerometer", value: buds.hasIMU ? "In every packet" : "Not seen yet")
                LabeledContent("Last sensor event", value: buds.lastSensorEvent)
                Toggle("Experimental raw accelerometer stream", isOn: Binding(get: { buds.rawAccelOn }, set: { buds.setRawAccel($0) }))
                    .disabled(!buds.isConnected)
                if let xyz = model.rawAccel.last { Text("Raw acceleration: " + xyz.map { String(format: "%.3f", $0) }.joined(separator: ", ")).monospacedDigit() }
            }
            Section("Protocol log") {
                Text(buds.log.isEmpty ? "Connect to see protocol messages" : buds.log.suffix(300).joined(separator: "\n"))
                    .font(TypeStyle.codeCaption).textSelection(.enabled)
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(buds.log.joined(separator: "\n"), forType: .string)
                }.disabled(buds.log.isEmpty)
            }
        }
    }
    private var recording: some View {
        @Bindable var model = model
        return Form {
            Section("Raw motion sessions") {
                TextField("Condition", text: $model.recordingCondition)
                Button(model.recordingURL == nil ? "Record session" : "Stop recording") { model.toggleRecording() }
                if let url = model.recordingURL { Text(url.path).font(TypeStyle.caption).textSelection(.enabled) }
                Button("Open sessions folder") {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    NSWorkspace.shared.open(docs.appendingPathComponent("Murmury/Sessions", isDirectory: true))
                }
                Text("Motion samples and events are saved in Documents/Murmury/Sessions").font(TypeStyle.caption)
            }
        }
    }
    private func setting(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ format: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: format, value.wrappedValue)).monospacedDigit() }
            Slider(value: value, in: range, step: step) { Text(title) }.labelsHidden()
        }
    }
}

struct DirectionCalibration: View {
    @Environment(AppModel.self) private var model
    @State private var showCamera = false
    var body: some View {
        let mouse = model.headMouse
        VStack(alignment: .leading, spacing: Space.sm) {
            if let step = mouse.calibration {
                ProgressView(step == .turnRight ? "Turn right about 20°, then return to center" : "Look up about 20°, then return to center")
                Button("Cancel calibration") { mouse.cancelCalibration() }
            } else {
                Button("Calibrate with camera") { showCamera = true }.disabled(!model.hasMotion)
                Button("Calibrate without camera") { mouse.startCalibration() }.disabled(!model.hasMotion)
            }
            if let message = mouse.calibrationMessage { Text(message).font(TypeStyle.caption) }
        }
        .sheet(isPresented: $showCamera) { CameraCalibrationView().environment(model) }
    }
}

struct MicrophoneControls: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: Space.unit) {
            if model.transcriber.isRunning { Text(model.transcriber.isOnDevice ? "Speech recognition on this Mac" : "Using the system speech service").font(TypeStyle.caption) }
            if model.audio.isRunning && !model.transcriber.isRunning {
                Button("Stop microphone") { model.audio.stop() }
            } else {
                Button(model.transcriber.isRunning ? "Stop microphone" : "Start microphone") { Task { await model.toggleMic() } }
            }
            if let error = model.transcriber.error ?? model.audio.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Ink.danger) }
        }
    }
}
