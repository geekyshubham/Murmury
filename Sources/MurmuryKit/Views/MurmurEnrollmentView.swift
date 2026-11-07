import SwiftUI

/// Teaches the murmur model: read a few short passages aloud while the buds stream. About two minutes.
struct MurmurEnrollmentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private let hue = Hue.control

    var body: some View {
        let e = model.murmurEnrollment
        DetailSheet(title: "Teach your murmur", hue: hue, showClose: false) {
            Text("Read each passage aloud. Your buds learn how your jaw moves and the words you say, and your camera, if allowed, teaches the head's mouth to move like yours. Commands you read won't act. About two minutes; nothing leaves your Mac.")
                .font(TypeStyle.body).foregroundStyle(Ink.secondary)
                .frame(maxWidth: TypeStyle.subtitleMeasure + 80, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if case .failed(let why, let micDenied) = e.phase {
                // Failure reads as every other notice does, with its way on beside it.
                StatusLine(notices: [StatusNotice(tone: .warn, text: why,
                                                  actionTitle: micDenied ? "Open Microphone Settings" : nil,
                                                  action: micDenied ? { openURL(PrivacyPane.microphone.url) } : nil)])
            } else {
                card(e)
                    // Room for a passage only while reading; other states take the height they need.
                    .frame(maxWidth: .infinity, minHeight: e.phase == .running ? 170 : nil, alignment: .topLeading)
                    .padding(Space.lg)
                    .cardSurface()
            }
            status(e)
        } footer: {
            buttons(e)
        }
        .onDisappear { e.cancel(); model.stopSpeechCamera() }
    }

    @ViewBuilder private func card(_ e: MurmurEnrollment) -> some View {
        switch e.phase {
        case .idle:
            VStack(alignment: .leading, spacing: Space.sm) {
                Label(ready ? "Sit as you usually do, then press Start" : readyReason, systemImage: ready ? "text.bubble" : "exclamationmark.circle")
                    .font(TypeStyle.status)
                Text("\(e.readingCount) short passages, with quiet pauses between them. One pause asks you to turn your head without speaking, so it learns that moving isn't talking.")
                    .font(TypeStyle.body).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .running:
            if let prompt = e.prompt {
                switch prompt {
                case .read(let text, let why):
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("Passage \(e.readingNumber) of \(e.readingCount) · \(why)").font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                        Text(text).font(TypeStyle.reading).lineSpacing(6).foregroundStyle(Ink.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                case .quiet:
                    timed(e, icon: "speaker.slash", text: "Stay quiet")
                case .turnQuietly:
                    timed(e, icon: "arrow.left.and.right", text: "Stay quiet, and turn your head slowly left and right")
                }
            }
        case .training:
            HStack(spacing: Space.sm) { ProgressView().controlSize(.small); Text("Learning your murmur…").font(TypeStyle.status) }
        case .done(let m, let accepted):
            VStack(alignment: .leading, spacing: Space.md) {
                if accepted {
                    Label("Learned. Your buds now feel when you're murmuring.", systemImage: "checkmark.circle.fill")
                        .font(TypeStyle.status).foregroundStyle(Ink.live)
                } else {
                    Label("The result is weak, so it isn't in use yet", systemImage: "exclamationmark.triangle.fill")
                        .font(TypeStyle.status).foregroundStyle(Ink.warn)
                }
                HStack(spacing: Space.gutter) {
                    figure(String(format: "%.0f%%", m.recall * 100), "of your speech felt")
                    figure(String(format: "%.0f%%", m.falseAlarms * 100), "false alarms while quiet")
                }
                Text(m.heldOut == true ? "Measured on the last quarter of your reading, which it didn't learn from."
                     : "Measured on your whole reading: there was too little to set some aside, so real use may be lower.")
                    .font(TypeStyle.caption).foregroundStyle(Ink.tertiary).fixedSize(horizontal: false, vertical: true)
                // What the camera and the recogniser's words taught, when they could.
                ForEach(e.speech?.report ?? [], id: \.self) { line in
                    Text(line).font(TypeStyle.body).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !accepted {
                    Text("Try again a little closer to your Mac, speaking at your usual murmur, or use it anyway.")
                        .font(TypeStyle.body).foregroundStyle(Ink.secondary)
                }
            }
        case .failed:
            EmptyView()  // shown as a notice above
        }
    }

    private func timed(_ e: MurmurEnrollment, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Label(text, systemImage: icon).font(TypeStyle.instruction)
            if let r = e.remaining { Text(String(format: "%.0f s", r.rounded(.up))).font(TypeStyle.stat).foregroundStyle(Ink.secondary) }
        }
        .accessibilityElement(children: .combine)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(TypeStyle.stat).foregroundStyle(Ink.primary)
            Text(label).font(TypeStyle.caption).foregroundStyle(Ink.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func status(_ e: MurmurEnrollment) -> some View {
        if e.phase == .running {
            VStack(alignment: .leading, spacing: 6) {
                // The microphone and the camera, on one line: what each is getting right now.
                HStack(spacing: Space.unit) {
                    Circle().fill(e.hearing ? Ink.live : Ink.tertiary).frame(width: 8, height: 8)
                    Text(e.hearing ? "Hearing you" : "Listening").font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                    Text("·").font(TypeStyle.caption).foregroundStyle(Ink.tertiary)
                    Text(model.speechCamera.isRunning ? (model.speechCamera.faceFound ? "Camera sees your lips" : "Camera is looking for your face")
                                                      : "Camera off: the mouth isn't learned this time")
                        .font(TypeStyle.caption).foregroundStyle(Ink.secondary)
                }
                .accessibilityElement(children: .combine)
                ProgressView(value: e.progress).tint(hue.a).frame(maxWidth: 280)
                    .accessibilityLabel("Teaching progress")
                    .accessibilityValue("\(Int((e.progress * 100).rounded())) percent")
                Text(model.transcriber.isRunning ? "Say “\(MurmurEnrollment.stopPhrase)” or press Esc to stop"
                                                 : "Press Esc to stop (speech recognition is off, so the spoken stop isn't available)")
                    .font(TypeStyle.caption).foregroundStyle(Ink.tertiary)
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// The sheet's actions in the footer's fixed slots: Cancel, a secondary, the primary.
    private func buttons(_ e: MurmurEnrollment) -> some View {
        SheetFooter {
            switch e.phase {
            case .idle, .failed: SlotButton("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            case .running, .training: SlotButton("Cancel") { e.cancel() }.keyboardShortcut(.cancelAction)
            case .done: EmptyView()
            }
        } secondary: {
            if case .done(_, false) = e.phase { SlotButton("Use it anyway") { e.accept() } }
        } primary: {
            switch e.phase {
            case .idle, .failed:
                SlotButton(e.phase == .idle ? "Start" : "Try again") { Task { await begin() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(SolidButtonStyle(hue: hue)).disabled(!ready)
            case .running:
                if let prompt = e.prompt, !prompt.isTimed {
                    SlotButton("Done reading") { e.next() }.keyboardShortcut(.defaultAction).buttonStyle(SolidButtonStyle(hue: hue))
                }
            case .training:
                EmptyView()
            case .done(_, let accepted):
                if accepted {
                    SlotButton("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(SolidButtonStyle(hue: hue))
                } else {
                    SlotButton("Try again") { Task { await begin() } }.keyboardShortcut(.defaultAction).buttonStyle(SolidButtonStyle(hue: hue))
                }
            }
        }
    }

    private var ready: Bool { model.hasMotion && !model.isDemo }
    private var readyReason: String {
        model.isDemo ? "Connect your buds first: demo motion has no jaw to feel" : "Connect your buds and start streaming first"
    }

    /// The microphone labels speech, so it runs during the session even if voice commands are off.
    private func begin() async {
        let audio = model.audio
        if !audio.isRunning { await audio.start() }
        // Speech recognition hears the spoken way out ("stop teaching"); best effort if voice is off.
        if audio.isRunning, !model.transcriber.isRunning { await model.transcriber.start(sink: audio.sink) }
        // The camera labels the lips' opening for the mouth model; teaching works without it.
        if audio.isRunning { await model.startSpeechCamera() }
        model.murmurEnrollment.start(micRunning: { audio.isRunning }, micError: audio.error)
        if !model.murmurEnrollment.phase.isActive { model.stopSpeechCamera() }
    }
}

/// Settings › Voice: the murmur model's state and what it does.
struct MurmurSettings: View {
    @Environment(AppModel.self) private var model
    @State private var teaching = false
    var body: some View {
        @Bindable var model = model
        if let m = model.murmurModel {
            LabeledContent("Murmur model", value: String(format: "Feels %.0f%% of your speech · %.0f%% false alarms", m.recall * 100, m.falseAlarms * 100))
            Text(m.heldOut == true ? "Measured on reading it didn't learn from" : "Measured on the reading it learned from, so real use may be lower")
                .font(TypeStyle.caption).foregroundStyle(Ink.tertiary)
            ForEach(model.speechModels?.report ?? [], id: \.self) { line in
                Text(line).font(TypeStyle.caption).foregroundStyle(Ink.secondary)
            }
            Toggle("Only act when my buds feel me speak", isOn: $model.ownVoiceOnly)
            if let words = model.speechModels?.words {
                Toggle("Act on silent words", isOn: $model.silentCommands)
                Text("Mouth “click”, “up”, “down”, “left” or “right” without a sound, and your buds act on it. It knows \(words.vocabulary.count) words you taught (\(words.vocabulary.prefix(8).joined(separator: ", "))); silent words are less certain than spoken ones.")
                    .font(TypeStyle.caption).foregroundStyle(Ink.secondary)
            }
            Text("A spoken command counts only if your buds felt your jaw move as it was said, so speech nearby doesn't act while you're quiet. It senses that you are speaking, not who is speaking. The pointer also holds still while your buds feel you murmur.")
                .font(TypeStyle.caption).foregroundStyle(Ink.secondary)
            HStack {
                Button("Teach again…") { teaching = true }
                Button("Forget", role: .destructive) { model.murmurModel = nil; model.ownVoiceOnly = false; model.speechModels = nil; model.silentCommands = false }
            }
        } else {
            Text("Read a few short passages so your buds learn how your jaw moves when you murmur. It then holds the pointer while you speak, and can act on commands only when your buds feel you speaking.")
                .font(TypeStyle.caption).foregroundStyle(Ink.secondary)
            Button("Teach your murmur…") { teaching = true }
        }
        EmptyView().sheet(isPresented: $teaching) { MurmurEnrollmentView().environment(model) }
    }
}
