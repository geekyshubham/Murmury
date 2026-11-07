import Testing
@testable import MurmuryKit

@Suite("Recognition sessions")
struct TranscriptStateTests {
    /// Results from a task that ended at a boundary are dropped, however late they arrive.
    @Test func oldTaskResultsNeverReturn() {
        var s = TranscriptState()
        let reading = s.newTask()
        #expect(s.receive(generation: reading, partial: "Click. Right", isFinal: false, failed: false) == false)
        s.carryOver()
        let fresh = s.newTask()  // the boundary: reading stopped
        #expect(s.receive(generation: reading, partial: "Click. Right click. Scroll down", isFinal: true, failed: false) == nil)
        #expect(s.text == "Click. Right", "the late result didn't change the transcript")
        #expect(s.receive(generation: fresh, partial: "click", isFinal: false, failed: false) == false)
        #expect(s.text == "Click. Right click", "new words follow the kept text; the transcript never shrinks")
    }

    /// Partial results revise within a task; finalisation accumulates across tasks.
    @Test func revisionsAndFinalisation() {
        var s = TranscriptState()
        let a = s.newTask()
        _ = s.receive(generation: a, partial: "scroll dawn", isFinal: false, failed: false)
        _ = s.receive(generation: a, partial: "scroll down", isFinal: false, failed: false)
        #expect(s.text == "scroll down")
        #expect(s.receive(generation: a, partial: "scroll down", isFinal: true, failed: false) == true)
        let b = s.newTask()
        _ = s.receive(generation: b, partial: "click", isFinal: false, failed: false)
        #expect(s.text == "scroll down click")
        #expect(s.receive(generation: b, partial: nil, isFinal: false, failed: true) == true, "a failed task asks for a fresh one")
        #expect(s.text.hasPrefix("scroll down click"), "a failure keeps what the task already delivered: \(s.text)")
    }

    /// A restart timer from an older task never cancels a newer one started meanwhile.
    @Test func staleRestartTimersAreIgnored() {
        var s = TranscriptState()
        let a = s.newTask()
        #expect(s.receive(generation: a, partial: "click", isFinal: true, failed: false) == true)  // timer armed for a
        s.carryOver()
        let b = s.newTask()  // a boundary restart before a's timer fires
        #expect(!s.isCurrent(a), "a's timer sees it is stale and does nothing")
        #expect(s.isCurrent(b))
        // Repeated sessions: each boundary leaves only the newest task able to speak.
        for _ in 0..<3 { s.carryOver(); _ = s.newTask() }
        #expect(s.receive(generation: b, partial: "right click", isFinal: false, failed: false) == nil)
    }

    /// After a recognition task fails mid-command, the next intentional click and pause each act
    /// exactly once: the transcript kept its words, so the parser neither repeats nor swallows.
    @MainActor @Test func commandsActOnceAcrossAFailedTask() {
        let pointer = FakePointer()
        let mouse = HeadMouse(driver: pointer, defaults: nil, ticks: false)
        mouse.isEnabled = true
        var s = TranscriptState()
        let a = s.newTask()
        _ = s.receive(generation: a, partial: "click", isFinal: false, failed: false); mouse.hear(text: s.text)
        _ = s.receive(generation: a, partial: nil, isFinal: false, failed: true); mouse.hear(text: s.text)  // the task fails
        let b = s.newTask()
        _ = s.receive(generation: b, partial: "click", isFinal: false, failed: false); mouse.hear(text: s.text)
        _ = s.receive(generation: b, partial: "click mouse off", isFinal: false, failed: false); mouse.hear(text: s.text)
        #expect(pointer.clicks.count == 2, "the first click once, the new click once")
        #expect(mouse.isPaused, "the pause after the failure acted")
    }
}
