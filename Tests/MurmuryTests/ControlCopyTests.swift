import AppKit
import Testing
@testable import MurmuryKit

@Suite("Control copy")
struct ControlCopyTests {
    @Test func stateTableAndVoiceInvariants() {
        let states: [(ControlCopy.State, String)] = [(.off, "Off"), (.pointing, "On · moving the pointer"),
            (.scrolling, "On · scrolling"), (.speakingHold, "Holding while you speak"), (.userPaused, "Paused"),
            (.voiceLost(.waiting(5)), "Paused · voice stopped"), (.voiceLost(.restarting), "Paused · voice stopped"),
            (.voiceLost(.failed), "Paused · voice stopped"), (.pointerOnly, "On · pointer only"),
            (.voiceOff, "On · voice off"), (.calibrating, "Calibrating"), (.voiceDenied, "Paused · voice unavailable")]
        for (state, chip) in states {
            for voice in [false, true] {
                let copy = ControlCopy.make(state: state, voiceRunning: voice, motionCommands: false)
                #expect(copy.chip == chip)
                #expect(copy.rows.count == 3)
                #expect(!copy.hint.isEmpty)
                let text = ([copy.chip, copy.caption, copy.hint, copy.menuLine] + copy.rows.flatMap { [$0.title, $0.detail] }).joined(separator: " ")
                if !voice {
                    for word in ["say", "murmur", "mouse off"] { #expect(!text.localizedCaseInsensitiveContains(word)) }
                }
                if case .voiceLost = state { #expect(!text.contains("Pointing") && !text.contains("Scrolling")) }
                if state == .userPaused { #expect(!text.contains("Pointing") && !text.contains("Scrolling")) }
            }
        }
    }
    @Test func voiceLossHasIndependentRecoveryAndStop() {
        let copy = ControlCopy.make(state: .voiceLost(.waiting(5)), voiceRunning: false, motionCommands: true)
        #expect(copy.rows.map(\.title) == ["Retrying voice", "Nod twice", "Stop"])
        #expect(copy.rows.map(\.detail) == ["Next try in 5 s", "Retries voice · again to go on without it", "⇧⌘M or the menu bar"])
        #expect(ControlCopy.make(state: .voiceLost(.waiting(5)), voiceRunning: false, motionCommands: false).rows[1].detail == "Retries voice · again to go on without it")
        #expect(copy.caption == "⇧⌘M to stop")
        #expect(copy.hint == "Stops the head mouse")
    }
    @Test func pointerOnlyOnlyPromisesClicksWhenTheyExist() {
        let without = ControlCopy.make(state: .pointerOnly, voiceRunning: false, motionCommands: false)
        // With no voice and no gestures, the row offers dwell clicking inline.
        #expect(without.rows.contains { $0.title == "Clicking is off" && $0.action == .turnOnDwell })
        #expect(!without.rows.contains { $0.title == "Gesture clicks" })
        let with = ControlCopy.make(state: .pointerOnly, voiceRunning: false, motionCommands: true)
        #expect(with.rows.contains { $0.title == "Gesture clicks" })
        let off = ControlCopy.make(state: .voiceOff, voiceRunning: false, motionCommands: false)
        #expect(off.rows.contains { $0.detail == "Voice commands are off" && $0.action == .turnOnVoice })
        let dwelling = ControlCopy.make(state: .pointerOnly, voiceRunning: false, motionCommands: false, dwell: true)
        #expect(dwelling.rows.contains { $0.title == "Dwell click" && $0.action == nil })
        // Off with voice switched on: voice starts with the head mouse; nothing to turn on.
        let idle = ControlCopy.make(state: .off, voiceRunning: false, motionCommands: false)
        #expect(idle.rows[1].detail == "Starts with the head mouse" && idle.rows[1].action == nil)
        #expect(ControlCopy.make(state: .off, voiceRunning: false, motionCommands: false, voiceEnabled: false).rows[1].action == .turnOnVoice)
    }
    /// With nod-to-pause off, no row promises a nod; the menu bar is the way to pause and resume.
    @Test func pauseHintsFollowTheNodSetting() {
        let off = ControlCopy.make(state: .pointerOnly, voiceRunning: false, motionCommands: false, dwell: true, nodToPause: false)
        #expect(!off.rows.contains { $0.detail.contains("Nod") })
        let paused = ControlCopy.make(state: .userPaused, voiceRunning: false, motionCommands: false, dwell: true, nodToPause: false)
        #expect(paused.rows[0].detail == "Resume in the menu bar")
        #expect(ControlCopy.make(state: .userPaused, voiceRunning: false, motionCommands: false).rows[0].detail == "Nod twice to resume")
    }
    @Test func withoutVoiceDialogNamesOnlyTheAvailablePause() {
        for canClick in [true, false] {
            #expect(MouseView.withoutVoiceMessage(canClick: canClick, nodToPause: true).contains("Nod twice to pause"))
            let off = MouseView.withoutVoiceMessage(canClick: canClick, nodToPause: false)
            #expect(!off.contains("Nod") && off.contains("menu bar"))
        }
    }
    @Test func menuBarSymbolShowsTheState() {
        #expect(ControlCopy.make(state: .pointing, voiceRunning: true, motionCommands: false).symbol == "cursorarrow.motionlines")
        #expect(ControlCopy.make(state: .scrolling, voiceRunning: true, motionCommands: false).symbol == "arrow.up.and.down.circle")
        #expect(ControlCopy.make(state: .userPaused, voiceRunning: true, motionCommands: false).symbol == "pause.circle")
        #expect(ControlCopy.make(state: .voiceLost(.restarting), voiceRunning: false, motionCommands: false).symbol == "mic.slash")
    }
    /// ⇧⌘M is the emergency stop everywhere, so the hot key matches exactly Shift-Command-M.
    @MainActor @Test func headMouseHotKeyMatchesOnlyShiftCommandM() {
        #expect(HeadMouseHotKey.matches(keyCode: 46, characters: "m", modifiers: [.shift, .command]))
        #expect(HeadMouseHotKey.matches(keyCode: 46, characters: "M", modifiers: NSEvent.ModifierFlags([.shift, .command])))
        #expect(!HeadMouseHotKey.matches(keyCode: 46, characters: "m", modifiers: [.command]))
        #expect(!HeadMouseHotKey.matches(keyCode: 46, characters: "m", modifiers: [.shift, .command, .option]))
        #expect(!HeadMouseHotKey.matches(keyCode: 45, characters: "n", modifiers: [.shift, .command]))
    }

}
