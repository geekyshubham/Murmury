import Foundation

/// All operational Control copy is derived from runtime state, including menu and button semantics.
struct ControlCopy {
    enum Recovery: Equatable { case waiting(Int), restarting, failed }
    enum State: Equatable {
        case off, pointing, scrolling, speakingHold, userPaused, voiceLost(Recovery), pointerOnly, voiceOff, calibrating, voiceDenied
        /// The buds stopped streaming under a running head mouse; the next reconnect in N seconds (nil: trying now).
        case budsLost(Int?)
    }
    /// A row's one inline fix, so nobody has to find a toggle in Settings with a head pointer.
    enum RowAction: Equatable {
        case turnOnVoice, turnOnDwell
        var title: String { "Turn on" }
        /// Distinct names for VoiceOver and Voice Control, where two "Turn on" buttons would collide.
        var spokenTitle: String { self == .turnOnVoice ? "Turn on voice commands" : "Turn on dwell clicking" }
    }
    struct Row: Equatable {
        var symbol: String; var title: String; var detail: String; var action: RowAction? = nil
        var actionTitle: String? { action?.title }
    }
    var chip: String
    var tone: BudsPresentation.Tone
    var rows: [Row]
    var caption: String
    var hint: String
    var menuLine: String
    var subtitle: String
    /// The menu-bar symbol: the state stays visible while another app is in front.
    var symbol = "cursorarrow.motionlines"
    /// Voice recovery state for the screen's logic (never matched against the copy).
    var recovery: Recovery?

    /// `voiceEnabled`: the Settings switch for voice commands. `dwell`: click by holding still.
    /// `heard`: the last command voice produced, shown in the Voice row so a mishearing is visible.
    /// `retried`: one double nod already retried voice, so the next one continues without it.
    static func make(state: State, voiceRunning: Bool, motionCommands: Bool, voiceEnabled: Bool = true, dwell: Bool = false,
                     heard: String? = nil, retried: Bool = false, nodToPause: Bool = true, budsHold: String? = nil) -> Self {
        // Without voice, pause and resume by nodding when that's on; otherwise the menu bar.
        let resumeHint = nodToPause ? "Nod twice to resume" : "Resume in the menu bar"
        let pauseHint = nodToPause ? "Nod twice; again to resume" : "From the menu bar"
        let stop = Row(symbol: "stop.circle", title: "Stop", detail: "⇧⌘M or the menu bar")
        // Without voice, clicks come from trained gestures or dwell; with neither, the row offers dwell.
        let clicks: Row = if motionCommands {
            Row(symbol: "cursorarrow.click", title: "Gesture clicks", detail: "Your trained motion commands")
        } else if dwell {
            Row(symbol: "cursorarrow.click", title: "Dwell click", detail: "Hold the pointer still to click")
        } else {
            Row(symbol: "cursorarrow.click", title: "Clicking is off", detail: "Click by holding the pointer still", action: .turnOnDwell)
        }
        let voice = Row(symbol: "waveform", title: "Voice", detail: voiceRunning ? (heard.map { "Heard “\($0)”" } ?? "Say “click” to act") : "Voice unavailable")
        let voiceOffRow = Row(symbol: "mic.slash", title: "Voice", detail: "Voice commands are off", action: .turnOnVoice)
        let control = Row(symbol: "cursorarrow.motionlines", title: "Turn to point", detail: "Follows your head")
        let offSecond: Row = if voiceRunning { voice }
            else if voiceEnabled { Row(symbol: "waveform", title: "Voice", detail: "Starts with the head mouse") }
            else if motionCommands || dwell { clicks }
            else { voiceOffRow }
        var copy = Self(chip: "Off", tone: .quiet, rows: [control, offSecond, stop],
                        caption: "⇧⌘M to start", hint: "Starts the head mouse", menuLine: "Head control is off",
                        subtitle: voiceRunning ? "Turn your head to point." : "Turn your head to point. Voice or gestures act.")
        switch state {
        case .off: break
        case .calibrating:
            copy.chip = "Calibrating"; copy.tone = .busy; copy.symbol = "scope"
            copy.rows = [Row(symbol: "scope", title: "Calibrating direction", detail: "About 10 seconds · follow the step above"),
                         Row(symbol: "location.north.line", title: "One-time setup", detail: "Kept for these buds"),
                         Row(symbol: "checkmark.circle", title: "Then it's done", detail: "The pointer follows your head again")]
            copy.menuLine = "Calibrating direction"
        case .voiceDenied:
            copy.chip = "Paused · voice unavailable"; copy.tone = .danger; copy.symbol = "mic.slash"
            copy.rows = [Row(symbol: "pause.circle", title: "Pointer paused", detail: "Voice permission is unavailable"),
                         Row(symbol: "gearshape", title: "Open Settings", detail: "Restore Microphone and Speech Recognition access"), stop]
            copy.caption = "⇧⌘M to stop · restore voice in Settings"
            copy.hint = "Stops the head mouse"; copy.menuLine = "Voice permission unavailable — open Settings"
            copy.subtitle = "The pointer is paused. Restore voice access in Settings."
        case .voiceLost(let recovery):
            let detail: String = switch recovery {
            case .waiting(let seconds): "Voice stopped — retrying in \(max(0, seconds)) s"
            case .restarting: "Voice stopped — restarting now"
            case .failed: "Voice still stopped after several tries"
            }
            copy.chip = "Paused · voice stopped"; copy.tone = .danger; copy.symbol = "mic.slash"; copy.recovery = recovery
            let retry: String = switch recovery {
            case .waiting(let seconds): "Next try in \(max(0, seconds)) s"
            case .restarting: "Restarting now"
            case .failed: "Still trying in the background"
            }
            // Retries ran out: the notice and the button say "retry"; this row says where to look.
            let first = recovery == .failed ? Row(symbol: "mic", title: "Check the microphone", detail: "Connected, and allowed in System Settings")
                : Row(symbol: "arrow.triangle.2.circlepath", title: "Retrying voice", detail: retry)
            copy.rows = [first,
                         Row(symbol: "chevron.down.2", title: retried ? "Nod twice now" : "Nod twice",
                             detail: retried ? (motionCommands || dwell ? "Continues without voice" : "Continues; hold the pointer still to click")
                                : "Retries voice · again to go on without it"), stop]
            copy.caption = "⇧⌘M to stop"
            copy.subtitle = "Turn your head to point."
            copy.hint = "Stops the head mouse"; copy.menuLine = detail + ". Nod twice to retry."
        case .budsLost(let seconds):
            copy.chip = "Paused · buds disconnected"; copy.tone = .danger; copy.symbol = "earbuds"
            copy.rows = [Row(symbol: "clock.arrow.circlepath", title: "Next try",
                             detail: seconds.map { "In \($0) s" } ?? "Now"),
                         Row(symbol: "earbuds", title: "Keep the buds in your ears", detail: "Near this Mac, out of the case"), stop]
            copy.caption = "⇧⌘M to stop"; copy.hint = "Stops the head mouse"
            copy.menuLine = "Buds disconnected — pointer paused, reconnecting"
            // Already held by you or by voice: say so, since the buds' return won't move it.
            copy.subtitle = budsHold.map { $0 + "." } ?? "Pointer paused until your buds are back."
        case .userPaused:
            copy.chip = "Paused"; copy.tone = .busy; copy.symbol = "pause.circle"
            copy.rows = [Row(symbol: "pause.circle", title: "Pointer paused", detail: voiceRunning ? "Say “mouse on” to resume" : resumeHint), voiceRunning ? voice : clicks, stop]
            copy.caption = "⇧⌘M to stop"; copy.hint = "Stops the head mouse"; copy.menuLine = "Pointer paused"
        case .pointerOnly:
            // Voice lives in the notice (with its restart); the rows say what still works.
            copy.chip = "On · pointer only"; copy.tone = .busy
            copy.rows = [control, clicks, Row(symbol: "pause.circle", title: "Pause", detail: pauseHint)]
            copy.caption = "⇧⌘M to stop"; copy.hint = "Stops the head mouse"
            copy.menuLine = "Pointer only — voice unavailable"
            copy.subtitle = "Turn your head to point."
        case .voiceOff:
            copy.chip = "On · voice off"; copy.tone = .busy
            copy.rows = [control, clicks, voiceOffRow]
            copy.caption = "⇧⌘M to stop"; copy.hint = "Stops the head mouse"
            copy.menuLine = "Voice commands are off"
            copy.subtitle = "Turn your head to point."
        case .pointing, .scrolling, .speakingHold:
            copy.chip = state == .pointing ? "On · moving the pointer" : (state == .scrolling ? "On · scrolling" : "Holding while you speak")
            copy.tone = .live
            copy.symbol = state == .scrolling ? "arrow.up.and.down.circle" : (state == .speakingHold ? "waveform" : "cursorarrow.motionlines")
            copy.rows = [Row(symbol: state == .scrolling ? "arrow.up.and.down" : "cursorarrow.motionlines",
                             title: state == .pointing ? "Pointing" : (state == .scrolling ? "Scrolling" : "Pointer held"),
                             detail: state == .speakingHold ? "Steady while you speak"
                                : state == .scrolling ? (dwell ? "Scroll, then hold still to point again" : (voiceRunning ? "Say “pointer mode” to point again" : "Following your head"))
                                : "Following your head"),
                         voiceRunning ? voice : clicks,
                         // The round button and its caption already say how to stop; this row says how to pause.
                         Row(symbol: "pause.circle", title: "Pause", detail: voiceRunning ? "Say “mouse off”" : pauseHint)]
            copy.caption = "⇧⌘M to stop"
            copy.hint = "Stops the head mouse"
            copy.menuLine = voiceRunning ? "Voice on · say “click” or “mouse off”" : "Voice unavailable"
        }
        return copy
    }
}
