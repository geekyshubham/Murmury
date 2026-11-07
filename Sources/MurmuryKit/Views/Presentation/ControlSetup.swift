struct ControlSetup {
    enum State { case done, needed, inProgress }
    enum Primary { case stop, connect, connecting, allowAccess, fixVoice, start }
    struct Row: Equatable {
        var title: String
        var detail: String
        var state: State
    }
    var rows: [Row]
    var recommendCalibration: Bool
    var primary: Primary
    /// Only the steps still missing. Demo motion counts as a motion source, and the microphone is a
    /// step only when voice failed: it starts with the head mouse.
    var visibleRows: [Row]
    /// Shown instead of setup rows once nothing is missing.
    var howItWorks: [Row] {
        [Row(title: "Turn to point", detail: "Follows your head", state: .done),
         Row(title: "Murmur “click”", detail: "Also “right click”, “scroll down”", state: .done),
         Row(title: "Say “mouse off” to pause", detail: "Or press ⇧⌘M", state: .done)]
    }
    var isComplete: Bool { visibleRows.isEmpty }

    static func evaluate(hasMotion: Bool, isDemo: Bool, budsBusy: Bool, trusted: Bool,
                         micRunning: Bool, calibrated: Bool, enabled: Bool, voiceFailure: VoiceFailure? = nil) -> Self {
        let motionRow = Row(title: "Buds", detail: isDemo ? "Demo motion — connect real buds" : (hasMotion ? "Motion ready" : (budsBusy ? "Connecting…" : "Connect a motion source")),
                            state: isDemo ? .needed : (hasMotion ? .done : (budsBusy ? .inProgress : .needed)))
        let trustRow = Row(title: "Clicking permission", detail: trusted ? "Allowed" : "Allow Accessibility access", state: trusted ? .done : .needed)
        let micRow = Row(title: "Microphone", detail: voiceFailure?.rowDetail ?? (micRunning ? "Listening" : "Optional for voice commands"),
                         state: voiceFailure != nil ? .needed : (micRunning ? .done : .needed))
        let primary: Primary = enabled ? .stop
            : (!hasMotion ? (budsBusy ? .connecting : .connect) : (!trusted ? .allowAccess : (voiceFailure != nil ? .fixVoice : .start)))
        var visible: [Row] = []
        if !hasMotion { visible.append(motionRow) }
        if !trusted { visible.append(trustRow) }
        if voiceFailure != nil { visible.append(micRow) }
        return Self(rows: [motionRow, trustRow, micRow], recommendCalibration: hasMotion && !isDemo && !calibrated, primary: primary, visibleRows: visible)
    }
}
