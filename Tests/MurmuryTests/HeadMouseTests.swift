import CoreGraphics
import Foundation
import Testing
@testable import MurmuryKit

private let deg = Double.pi / 180

/// A sample with a given body-frame angular velocity in degrees per second.
/// What the 120 Hz output timer does in the app: ingest, then move at the sample's time.
extension HeadMouse {
    func feed(_ s: MotionSample) {
        ingest(s)
        tick(at: s.t)
    }
}

private func spin(t: Double, x: Double = 0, y: Double = 0, z: Double = 0, bud: UInt8 = 0) -> MotionSample {
    MotionSample(t: t, bud: bud, qw: 1, qx: 0, qy: 0, qz: 0, wx: x * deg, wy: y * deg, wz: z * deg)
}

/// `seconds` of constant rotation at 50 Hz.
private func rotation(from t0: Double = 0, seconds: Double, x: Double = 0, y: Double = 0, z: Double = 0) -> [MotionSample] {
    stride(from: t0, to: t0 + seconds, by: 0.02).map { spin(t: $0, x: x, y: y, z: z) }
}

// MARK: Voice commands

@Suite("Voice commands")
struct VoiceCommandTests {
    @Test func commandsCountOnlyWhenSaidAlone() {
        #expect(VoiceCommandParser.commandsAlone(["click"]) == [.leftClick])
        #expect(VoiceCommandParser.commandsAlone(["um", "scroll", "down"], fillers: HeadMouse.fillers) == [.scrollDown])
        #expect(VoiceCommandParser.commandsAlone(["i", "click", "it"]) == nil)
        #expect(VoiceCommandParser.commandsAlone(["scroll", "mode", "is", "on"]) == nil)
    }
    @Test func recognisesEachCommand() {
        #expect(VoiceCommandParser.parse("click") == [.leftClick])
        #expect(VoiceCommandParser.parse("left click") == [.leftClick])
        #expect(VoiceCommandParser.parse("Right click.") == [.rightClick])
        #expect(VoiceCommandParser.parse("double click") == [.doubleClick])
        #expect(VoiceCommandParser.parse("mouse off") == [.pause])
        #expect(VoiceCommandParser.parse("pause mouse") == [.pause])
        #expect(VoiceCommandParser.parse("Mouse on") == [.resume])
    }

    @Test func toleratesHyphensJoinedWordsAndCommonMishearings() {
        #expect(VoiceCommandParser.parse("Right-click") == [.rightClick])
        #expect(VoiceCommandParser.parse("rightclick") == [.rightClick])
        #expect(VoiceCommandParser.parse("write click") == [.rightClick])
        #expect(VoiceCommandParser.parse("Double-click!") == [.doubleClick])
        #expect(VoiceCommandParser.parse("clique") == [.leftClick])
    }

    @Test func modifierOnlyCountsDirectlyBeforeClick() {
        #expect(VoiceCommandParser.parse("turn right and click") == [.leftClick])
        #expect(VoiceCommandParser.parse("right now") == [])
        #expect(VoiceCommandParser.parse("click right click left click") == [.leftClick, .rightClick, .leftClick])
    }

    @Test func otherWordsAreIgnored() {
        #expect(VoiceCommandParser.parse("clicking the button") == [])
        #expect(VoiceCommandParser.parse("") == [])
        #expect(VoiceCommandParser.parse("the mouse is on the desk") == [])
    }

    @Test func growingTranscriptFiresEachCommandOnce() {
        var p = VoiceCommandParser()
        #expect(p.commands(in: "Right") == [])
        #expect(p.commands(in: "Right click") == [.rightClick])
        #expect(p.commands(in: "Right click") == [])
        #expect(p.commands(in: "Right click. Click") == [.leftClick])
        #expect(p.commands(in: "Right click. Click. Double click") == [.doubleClick])
    }

    @Test func revisionsOfEarlierWordsDoNotRefire() {
        var p = VoiceCommandParser()
        #expect(p.commands(in: "I click") == [.leftClick])
        #expect(p.commands(in: "Hi, click") == [])
    }

    @Test func clearedTranscriptStartsOver() {
        var p = VoiceCommandParser()
        #expect(p.commands(in: "click") == [.leftClick])
        #expect(p.commands(in: "") == [])
        #expect(p.commands(in: "click") == [.leftClick])
    }

    @Test func recognisesScrollCommands() {
        #expect(VoiceCommandParser.parse("scroll up") == [.scrollUp])
        #expect(VoiceCommandParser.parse("Scroll down.") == [.scrollDown])
        #expect(VoiceCommandParser.parse("scroll left") == [.scrollLeft])
        #expect(VoiceCommandParser.parse("scroll right click") == [.scrollRight, .leftClick])
        #expect(VoiceCommandParser.parse("scroll mode") == [.scrollMode])
        #expect(VoiceCommandParser.parse("start scrolling") == [.scrollMode])
        #expect(VoiceCommandParser.parse("stop scrolling") == [.pointerMode])
        #expect(VoiceCommandParser.parse("pointer mode") == [.pointerMode])
        #expect(VoiceCommandParser.parse("I like to scroll") == [])
    }

    @Test func trainedLabelsMapOnlyWhenTheWholeLabelIsACommand() {
        #expect(VoiceCommandParser.command(forLabel: "right click") == .rightClick)
        #expect(VoiceCommandParser.command(forLabel: "Click") == .leftClick)
        #expect(VoiceCommandParser.command(forLabel: "nod") == nil)
        #expect(VoiceCommandParser.command(forLabel: "click click") == nil)
    }
}

// MARK: Pointer law

@Suite("Head pointer")
struct HeadPointerTests {
    var config: HeadPointer.Config {
        var c = HeadPointer.Config()
        c.smoothing = 0
        c.acceleration = 0
        c.deadzone = 4
        c.speed = 10
        c.axes = .init(horizontal: AxisMap(axis: 2, sign: 1), vertical: AxisMap(axis: 0, sign: 1))
        return c
    }

    func travel(_ samples: [MotionSample], _ c: HeadPointer.Config) -> CGVector {
        var p = HeadPointer(config: c)
        return samples.reduce(CGVector.zero) { acc, s in
            let d = p.delta(for: s)
            return CGVector(dx: acc.dx + d.dx, dy: acc.dy + d.dy)
        }
    }

    @Test func holdingStillDoesNotMove() {
        let d = travel(rotation(seconds: 1, x: 3, z: -3), config)  // tremor below the 4°/s deadzone
        #expect(d == .zero)
    }

    @Test func rotationMapsToConfiguredAxes() {
        // 24°/s for 1 s: (24 − 4 deadzone) × 10 pt/° ≈ 200 pt, minus the first sample (no dt yet).
        let d = travel(rotation(seconds: 1, z: 24), config)
        #expect(abs(d.dx - 196) < 1)
        #expect(d.dy == 0)
        let v = travel(rotation(seconds: 1, x: -24), config)
        #expect(abs(v.dy + 196) < 1)
        #expect(v.dx == 0)
    }

    @Test func signAndInvertFlipDirection() {
        var c = config
        c.axes.horizontal.sign = -1
        #expect(travel(rotation(seconds: 0.5, z: 24), c).dx < 0)
        c.invertHorizontal = true
        #expect(travel(rotation(seconds: 0.5, z: 24), c).dx > 0)
    }

    @Test func accelerationMovesFastTurnsFurtherPerDegree() {
        var c = config
        c.acceleration = 1
        let slow = travel(rotation(seconds: 1, z: 20), c).dx / 20
        let fast = travel(rotation(seconds: 0.2, z: 100), c).dx / 20
        #expect(fast > 1.5 * slow)
    }

    @Test func gapsAndFirstSampleProduceNoJump() {
        var p = HeadPointer(config: config)
        #expect(p.delta(for: spin(t: 0, z: 90)) == .zero)
        #expect(p.delta(for: spin(t: 1.0, z: 90)) == .zero)  // 1 s gap: stream stalled
        #expect(p.delta(for: spin(t: 1.02, z: 90)).dx > 0)
    }

    @Test func prefersTheBudGyroWhenPacketsCarryIt() {
        var p = HeadPointer(config: config)
        var a = spin(t: 0), b = spin(t: 0.02, z: 2)  // quaternion-derived: below the deadzone
        a.hasIMU = true; b.hasIMU = true
        b.gz = 30 * deg                                 // gyro: a real 30°/s turn
        _ = p.delta(for: a)
        #expect(p.delta(for: b).dx > 0)
    }

    @Test func perBudAxesOverrideTheDefault() {
        var c = config
        c.budAxes[1] = .init(horizontal: AxisMap(axis: 1, sign: 1), vertical: AxisMap(axis: 0, sign: 1))
        var p = HeadPointer(config: c)
        _ = p.delta(for: spin(t: 0, y: 30, bud: 1))
        #expect(p.delta(for: spin(t: 0.02, y: 30, bud: 1)).dx > 0)
        // The uncalibrated partner borrows the turn as is and the nod reversed (mirrored mounting).
        _ = p.delta(for: spin(t: 0.04, y: 30, bud: 0))
        #expect(p.delta(for: spin(t: 0.06, y: 30, bud: 0)).dx > 0)
        #expect(c.axes(for: 0) == c.budAxes[1]!.mirrored && c.axes(for: 0).vertical.sign == -1)
    }

    /// A camera result is trusted over a guess: it replaces the partner's step calibration with its
    /// own mirror, and both buds then count as camera-taught.
    @Test func cameraCalibrationTeachesBothBuds() {
        var c = HeadPointer.Config()
        #expect(!c.cameraTaught(0) && !c.cameraTaught(1))
        let stepped = HeadPointer.Axes(horizontal: AxisMap(axis: 1, sign: -1), vertical: AxisMap(axis: 0, sign: -1))
        c.learn(stepped, bud: 0, fromCamera: false)
        #expect(!c.cameraTaught(0) && !c.cameraTaught(1))
        let seen = HeadPointer.Axes(horizontal: AxisMap(vector: [0.1, -0.99, 0]), vertical: AxisMap(vector: [-0.98, 0, 0.2]))
        c.learn(seen, bud: 1, fromCamera: true)
        #expect(c.cameraTaught(1) && c.cameraTaught(0))
        #expect(c.budAxes[0] == nil && c.axes(for: 0) == seen.mirrored)
        #expect(c.axes(for: 0).vertical.direction.x > 0.9 && c.axes(for: 0).horizontal.direction.y < -0.9)
        // Saved settings from before this field still load.
        let old = #"{"budAxes":[0,{"horizontal":{"sign":-1,"axis":1},"vertical":{"sign":1,"axis":0}}],"invertHorizontal":false,"deadzone":3,"scrollStep":240,"speed":30,"invertVertical":false,"axes":{"horizontal":{"sign":-1,"axis":1},"vertical":{"sign":1,"axis":0}},"scrollSpeed":1,"acceleration":2,"invertScroll":false,"smoothing":0.15}"#
        let loaded = try? JSONDecoder().decode(HeadPointer.Config.self, from: Data(old.utf8))
        #expect(loaded?.axes(for: 1).vertical.sign == -1, "the user's saved left-bud calibration now mirrors for the right bud")
    }
}

// MARK: Calibration

@Suite("Axis calibration")
struct AxisCalibrationTests {
    /// Turn out and back: the net angle is ~0, the excursion is what counts.
    func outAndBack(x: Double = 0, y: Double = 0, z: Double = 0) -> [MotionSample] {
        rotation(from: 0, seconds: 0.5, x: x, y: y, z: z) + rotation(from: 0.5, seconds: 0.5, x: -x, y: -y, z: -z)
    }

    @Test func findsAxisAndDirectionOfTheOutwardMovement() {
        #expect(AxisCalibrator.detect(outAndBack(z: -60)) == AxisMap(axis: 2, sign: -1))
        #expect(AxisCalibrator.detect(outAndBack(x: 50, z: 8)) == AxisMap(axis: 0, sign: 1))
    }

    @Test func excludesTheAlreadyChosenAxis() {
        #expect(AxisCalibrator.detect(outAndBack(y: 20, z: 60), excluding: 2) == AxisMap(axis: 1, sign: 1))
    }

    @Test func rejectsMovementTooSmallToTrust() {
        #expect(AxisCalibrator.detect(outAndBack(z: 10)) == nil)  // 5° excursion
        #expect(AxisCalibrator.detect([]) == nil)
    }
}

// MARK: Voice activity

@Suite("Voice activity")
struct VoiceActivityTests {
    @Test func speechAboveTheNoiseFloorHoldsForTheHangover() {
        var v = VoiceActivity()
        for i in 0..<50 {
            let quiet = v.update(level: 0.2, at: Double(i) * 0.02)
            #expect(!quiet)
        }
        let spoke = v.update(level: 0.55, at: 1.0)
        #expect(spoke)
        #expect(v.isSpeaking(at: 1.3))
        #expect(!v.isSpeaking(at: 1.0 + v.hangover + 0.01))
    }

    @Test func floorAdaptsSoSteadyNoiseIsNotSpeech() {
        var v = VoiceActivity()
        var t = 0.0
        for _ in 0..<50 { _ = v.update(level: 0.2, at: t); t += 0.02 }
        for _ in 0..<2000 { _ = v.update(level: 0.5, at: t); t += 0.02 }  // fan switched on and left on
        let speaking = v.update(level: 0.5, at: t)
        #expect(!speaking)
    }
}

// MARK: Controller

@MainActor
final class FakePointer: PointerDriver {
    var location = CGPoint(x: 500, y: 400)
    var displays = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
    var isTrusted = true
    var clicks: [(MouseButton, Int, CGPoint)] = []
    var scrolls: [(dx: Int32, dy: Int32)] = []
    func requestTrust() {}
    func scroll(dx: Int32, dy: Int32) { scrolls.append((dx, dy)) }
    func move(to p: CGPoint) { location = p }
    func click(_ button: MouseButton, count: Int, at p: CGPoint) { clicks.append((button, count, p)) }
    var presses: [String] = []
    func press(_ button: MouseButton, at p: CGPoint) { presses.append("down") }
    func release(_ button: MouseButton, at p: CGPoint) { presses.append("up") }
}

@MainActor
@Suite("Head mouse")
struct HeadMouseTests {
    func make() -> (HeadMouse, FakePointer) {
        let fake = FakePointer()
        let mouse = HeadMouse(driver: fake, defaults: nil, ticks: false)
        mouse.config.smoothing = 0
        mouse.config.axes = .init(horizontal: AxisMap(axis: 2, sign: 1), vertical: AxisMap(axis: 0, sign: 1))
        return (mouse, fake)
    }

    @Test func movesThePointerOnlyWhenEnabled() {
        let (mouse, fake) = make()
        rotation(seconds: 0.5, z: 40).forEach(mouse.feed)
        #expect(fake.location == CGPoint(x: 500, y: 400))
        mouse.isEnabled = true
        rotation(from: 1, seconds: 0.5, z: 40).forEach(mouse.feed)
        #expect(fake.location.x > 550)
        #expect(fake.location.y == 400)
    }

    @Test func spokenCommandsClickWhereThePointerIs() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.hear(text: "click")
        mouse.hear(text: "click. Right click")
        mouse.hear(text: "click. Right click. Double click")
        #expect(fake.clicks.map(\.0) == [.left, .right, .left])
        #expect(fake.clicks.map(\.1) == [1, 1, 2])
        #expect(fake.clicks.allSatisfy { $0.2 == CGPoint(x: 500, y: 400) })
        #expect(mouse.lastCommand == .doubleClick)
    }

    @Test func wordsHeardWhileDisabledAreNotReplayedLater() {
        let (mouse, fake) = make()
        mouse.hear(text: "click")
        mouse.isEnabled = true
        mouse.hear(text: "click")
        #expect(fake.clicks.isEmpty)
        mouse.hear(text: "click right click")
        #expect(fake.clicks.map(\.0) == [.right])
    }

    @Test func voiceClicksCanBeTurnedOff() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.voiceClicks = false
        mouse.hear(text: "click")
        #expect(fake.clicks.isEmpty)
    }

    @Test func mouseOffPausesMovementAndClicksUntilMouseOn() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.hear(text: "mouse off")
        #expect(mouse.isPaused)
        rotation(seconds: 0.5, z: 40).forEach(mouse.feed)
        mouse.hear(text: "mouse off. Click")
        #expect(fake.location == CGPoint(x: 500, y: 400))
        #expect(fake.clicks.isEmpty)
        mouse.hear(text: "mouse off. Click. Mouse on")
        #expect(!mouse.isPaused)
        rotation(from: 1, seconds: 0.5, z: 40).forEach(mouse.feed)
        #expect(fake.location.x > 500)
    }

    @Test func pointerHoldsStillWhileSpeaking() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        for i in 0..<50 { mouse.hear(level: 0.2, at: Double(i) * 0.02) }
        mouse.hear(level: 0.6, at: 1.0)
        #expect(mouse.isSpeaking)
        rotation(from: 1.0, seconds: 0.2, z: 40).forEach(mouse.feed)
        #expect(fake.location == CGPoint(x: 500, y: 400))
        rotation(from: 2.0, seconds: 0.5, z: 40).forEach(mouse.feed)  // speech ended
        #expect(!mouse.isSpeaking)
        #expect(fake.location.x > 500)
    }

    /// A quiet room for a second, so the microphone's noise floor is known.
    private func settle(_ mouse: HeadMouse) { for i in 0..<50 { mouse.hear(level: 0.2, at: Double(i) * 0.02) } }
    private func speak(_ mouse: HeadMouse, from t: Double, seconds: Double) {
        for t in stride(from: t, to: t + seconds, by: 0.02) { mouse.hear(level: 0.6, at: t) }
    }
    private func quiet(_ mouse: HeadMouse, from t: Double, seconds: Double) {
        for t in stride(from: t, to: t + seconds, by: 0.02) { mouse.hear(level: 0.2, at: t) }
    }

    @Test func commandWordsInsideASentenceNeverAct() {
        // Dictating or talking: the words "click", "scroll mode", "drag" are part of a sentence.
        let (mouse, fake) = make()
        mouse.isEnabled = true
        settle(mouse)
        speak(mouse, from: 1, seconds: 2)
        mouse.hear(text: "so when I click on it the page goes into scroll mode and I drag the window")
        quiet(mouse, from: 3, seconds: 1)
        #expect(fake.clicks.isEmpty && fake.location == CGPoint(x: 500, y: 400))
        #expect(mouse.mode == .pointer && !mouse.isPaused)
    }

    @Test func aCommandSaidOnItsOwnActsAtThePause() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        settle(mouse)
        speak(mouse, from: 1, seconds: 0.3)
        mouse.hear(text: "click")
        #expect(fake.clicks.isEmpty, "waits for the pause: it might be the start of a sentence")
        quiet(mouse, from: 1.3, seconds: 0.6)
        #expect(fake.clicks.count == 1)
        // The next one, with a filler, its words arriving after the pause (recogniser lag).
        speak(mouse, from: 3, seconds: 0.5)
        quiet(mouse, from: 3.5, seconds: 0.6)
        mouse.hear(text: "click please scroll down")
        #expect(fake.scrolls.count == 1 && fake.clicks.count == 1)
    }

    @Test func talkingLongerThanACommandStopsHoldingThePointer() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        settle(mouse)
        var t = 1.0
        while t < 2.2 { mouse.hear(level: 0.6, at: t); mouse.feed(spin(t: t, z: 40)); t += 0.02 }
        #expect(fake.location == CGPoint(x: 500, y: 400) && mouse.isHoldingForSpeech, "held while it could be a command")
        while t < 3.5 { mouse.hear(level: 0.6, at: t); mouse.feed(spin(t: t, z: 40)); t += 0.02 }
        #expect(fake.location.x > 500 && !mouse.isHoldingForSpeech, "still talking after 1.5 s: it's conversation, the pointer moves")
    }

    @Test func trainedMotionLabelsClickOnlyWhenAllowed() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.perform(label: "right click")
        #expect(fake.clicks.isEmpty)
        mouse.motionCommands = true
        mouse.perform(label: "right click")
        mouse.perform(label: "nod")
        #expect(fake.clicks.map(\.0) == [.right])
    }

    @Test func calibrationLearnsBothAxesForTheReportingBud() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.startCalibration()
        #expect(mouse.calibration == .turnRight)
        // Turn right: this bud reports it as negative rotation about y.
        (rotation(from: 0, seconds: 0.6, y: -60) + rotation(from: 0.6, seconds: 0.6, y: 60)
            + rotation(from: 1.2, seconds: 1, y: 0)).forEach(mouse.feed)
        #expect(mouse.calibration == .lookUp)
        // Look up: positive rotation about x. Up on screen is −y.
        (rotation(from: 3, seconds: 0.6, x: 50) + rotation(from: 3.6, seconds: 0.6, x: -50)
            + rotation(from: 4.2, seconds: 1, x: 0)).forEach(mouse.feed)
        #expect(mouse.calibration == nil)
        #expect(mouse.config.axes(for: 0) == .init(horizontal: AxisMap(axis: 1, sign: -1), vertical: AxisMap(axis: 0, sign: -1)))
        #expect(fake.location == CGPoint(x: 500, y: 400))  // pointer stays put while calibrating

        rotation(from: 6, seconds: 0.5, y: -40).forEach(mouse.feed)  // turning right moves right
        #expect(fake.location.x > 500)
    }

    @Test func failedCalibrationKeepsThePreviousAxes() {
        let (mouse, _) = make()
        let before = mouse.config.axes
        mouse.startCalibration()
        // A small twitch starts the step but is too small to trust.
        (rotation(seconds: 0.3, z: 20) + rotation(from: 0.3, seconds: 2, z: 0)).forEach(mouse.feed)
        #expect(mouse.calibration == nil)
        #expect(mouse.calibrationMessage != nil)
        #expect(mouse.config.axes == before)
    }

    @Test func calibrationWaitsForYouToStartMovingThenTimesOut() {
        let (mouse, _) = make()
        mouse.startCalibration()
        rotation(seconds: 3, z: 1).forEach(mouse.feed)  // still reading the instructions
        #expect(mouse.calibration == .turnRight)
        rotation(from: 3, seconds: 5, z: 1).forEach(mouse.feed)
        #expect(mouse.calibration == nil)
        #expect(mouse.calibrationMessage != nil)
    }

    @Test func spokenScrollStepsScrollOnePageStep() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        let step = Int32(mouse.config.scrollStep)
        mouse.hear(text: "scroll down")
        mouse.hear(text: "scroll down, scroll up")
        mouse.hear(text: "scroll down, scroll up, scroll right, scroll left")
        #expect(fake.scrolls.map(\.dx) == [0, 0, step, -step])
        #expect(fake.scrolls.map(\.dy) == [step, -step, 0, 0])
        #expect(fake.location == CGPoint(x: 500, y: 400))
    }

    @Test func scrollModeTurnsHeadMovementIntoScrolling() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.hear(text: "scroll mode")
        #expect(mouse.mode == .scroll)
        // Looking down (screen +y here) with a little sideways drift: scrolls down, straight.
        rotation(seconds: 0.5, x: 40, z: 10).forEach(mouse.feed)
        #expect(fake.location == CGPoint(x: 500, y: 400))
        #expect(fake.scrolls.reduce(0) { $0 + $1.dy } > 50)
        #expect(fake.scrolls.allSatisfy { $0.dx == 0 })

        mouse.hear(text: "scroll mode. Stop scrolling")
        #expect(mouse.mode == .pointer)
        let scrolled = fake.scrolls.count
        rotation(from: 1, seconds: 0.5, x: 40).forEach(mouse.feed)
        #expect(fake.scrolls.count == scrolled)
        #expect(fake.location.y > 400)
    }

    @Test func scrollModeKeepsFractionsSoSlowMovementStillScrolls() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.config.acceleration = 0
        mouse.config.scrollSpeed = 0.1
        mouse.mode = .scroll
        let samples = rotation(seconds: 1, x: 9)  // a few °/s past the deadzone: well under 1 pt per sample
        samples.forEach(mouse.feed)
        var p = HeadPointer(config: mouse.config)
        let expected = samples.reduce(0.0) { $0 + p.delta(for: $1).dy } * 0.1
        let total = Double(fake.scrolls.reduce(0) { $0 + $1.dy })
        #expect(expected > 8)
        #expect(abs(total - expected) <= 1)
    }

    @Test func invertScrollFlipsScrollDirection() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.config.invertScroll = true
        mouse.hear(text: "scroll down")
        mouse.mode = .scroll
        rotation(seconds: 0.5, x: 40).forEach(mouse.feed)
        #expect(fake.scrolls.allSatisfy { $0.dy < 0 })
    }

    @Test func pausedIgnoresScrolling() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.hear(text: "mouse off, scroll down, scroll mode")
        #expect(fake.scrolls.isEmpty)
        #expect(mouse.mode == .pointer)
    }

    @Test func pointerKeepsGlidingBetweenClumpedPackets() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.feed(spin(t: 0, z: 40))
        mouse.feed(spin(t: 0.025, z: 40))
        var xs: [CGFloat] = []
        for k in 1...6 {                       // 120 Hz output ticks, no new packets yet
            mouse.tick(at: 0.025 + Double(k) / 120)
            xs.append(fake.location.x)
        }
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $1 > $0 })
    }

    @Test func pointerStopsWhenTheStreamStalls() {
        let (mouse, fake) = make()
        mouse.isEnabled = true
        mouse.feed(spin(t: 0, z: 40))
        mouse.feed(spin(t: 0.025, z: 40))
        mouse.tick(at: 0.4)
        let x = fake.location.x
        mouse.tick(at: 0.5)
        mouse.tick(at: 1.0)
        #expect(fake.location.x == x)
    }

    @Test func pointerStaysOnScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 800, height: 600)]
        #expect(HeadMouse.clamp(CGPoint(x: 1200, y: 100), from: CGPoint(x: 900, y: 100), displays: screens) == CGPoint(x: 1200, y: 100))
        #expect(HeadMouse.clamp(CGPoint(x: 1200, y: 700), from: CGPoint(x: 1100, y: 500), displays: screens) == CGPoint(x: 1200, y: 599))
        #expect(HeadMouse.clamp(CGPoint(x: -50, y: -10), from: CGPoint(x: 10, y: 10), displays: screens) == CGPoint(x: 0, y: 0))
    }
}

@MainActor @Suite("Calibration failure flag")
struct CalibrationFailureFlagTests {
    func make() -> HeadMouse {
        let mouse = HeadMouse(driver: FakePointer(), defaults: nil, ticks: false)
        mouse.config.smoothing = 0
        return mouse
    }
    @Test func setOnFailureClearedOnStartAndSuccess() {
        let mouse = make()
        #expect(!mouse.lastCalibrationFailed)
        mouse.startCalibration()
        rotation(seconds: 8, z: 1).forEach(mouse.feed)  // never starts moving: times out
        #expect(mouse.calibration == nil)
        #expect(mouse.lastCalibrationFailed)
        mouse.startCalibration()
        #expect(!mouse.lastCalibrationFailed)
        (rotation(from: 0, seconds: 0.6, y: -60) + rotation(from: 0.6, seconds: 0.6, y: 60) + rotation(from: 1.2, seconds: 1, y: 0)).forEach(mouse.feed)
        (rotation(from: 3, seconds: 0.6, x: 50) + rotation(from: 3.6, seconds: 0.6, x: -50) + rotation(from: 4.2, seconds: 1, x: 0)).forEach(mouse.feed)
        #expect(mouse.calibration == nil)
        #expect(!mouse.lastCalibrationFailed)
    }
    @Test func cancelIsNotAFailure() {
        let mouse = make()
        mouse.startCalibration(); mouse.cancelCalibration()
        #expect(!mouse.lastCalibrationFailed)
    }
}

@MainActor @Suite("Dwell settings")
struct DwellSettingsTests {
    /// A stored hold time out of range loads clamped (and loading never re-enters its own observer).
    @Test func storedHoldTimeLoadsClamped() throws {
        let suite = "murmury.tests.dwell.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "headMouse.dwellClicks")
        defaults.set(10.0, forKey: "headMouse.dwellSeconds")
        defaults.set(true, forKey: "headMouse.motionCommands")
        defaults.set(false, forKey: "headMouse.holdWhileSpeaking")
        let mouse = HeadMouse(driver: FakePointer(), defaults: defaults, ticks: false)
        // Every stored setting survives loading (none is overwritten by an earlier one's save).
        #expect(mouse.dwellClicks && mouse.motionCommands && !mouse.holdWhileSpeaking)
        #expect(mouse.dwellSeconds == DwellClicker.secondsRange.upperBound)
        #expect(mouse.dwellProgress(at: 0) == nil)
    }
}

@MainActor @Suite("Dwell click types and feedback")
struct DwellTypeTests {
    /// Right and double apply to one dwell click, then it returns to left; the source is dwell.
    @Test func rightClickAppliesOnceThenLeft() {
        let pointer = FakePointer()
        let mouse = HeadMouse(driver: pointer, defaults: nil, ticks: false)
        mouse.dwellClicks = true
        mouse.isEnabled = true
        mouse.dwellAction = .right
        let s = DwellClicker.defaultSeconds
        func step(_ t: Double, at p: CGPoint) {
            pointer.location = p
            mouse.ingest(MotionSample(t: t, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0))
            mouse.tick(at: t)
        }
        step(0, at: CGPoint(x: 500, y: 400))
        step(0.1, at: CGPoint(x: 600, y: 400))       // a real move arms it
        step(0.2 + s, at: CGPoint(x: 600, y: 400))   // held still: one right click
        #expect(pointer.clicks.map(\.0) == [.right])
        #expect(mouse.dwellAction == .left)
        #expect(mouse.lastSource == .dwell)
        #expect(mouse.lastVoiceCommand == nil)
    }
    @Test func pointerLabelsSayWhereACommandCameFrom() {
        #expect(DwellRing.label(for: .rightClick, source: .voice) == "Heard: Right click")
        #expect(DwellRing.label(for: .leftClick, source: .gesture) == "Gesture: Left click")
        #expect(DwellRing.label(for: .leftClick, source: .dwell) == nil)
        #expect(DwellRing.label(for: .doubleClick, source: .dwell) == "Double click")
        #expect(DwellPalette.isShown(enabled: true, dwell: true, palette: true))
        #expect(!DwellPalette.isShown(enabled: true, dwell: false, palette: true))
    }
    @Test func voiceRowSaysWhatWasHeard() {
        let copy = ControlCopy.make(state: .pointing, voiceRunning: true, motionCommands: false, heard: "right click")
        #expect(copy.rows[1].detail == "Heard “right click”")
        // Without running voice, nothing claims to have heard anything.
        #expect(ControlCopy.make(state: .pointing, voiceRunning: false, motionCommands: false, heard: "click").rows[1].detail != "Heard “click”")
    }
}

@MainActor @Suite("Drag")
struct DragTests {
    @Test func dwellDragPressesThenDrops() {
        let pointer = FakePointer()
        let mouse = HeadMouse(driver: pointer, defaults: nil, ticks: false)
        mouse.dwellClicks = true
        mouse.isEnabled = true
        mouse.dwellAction = .drag
        let s = DwellClicker.defaultSeconds
        func step(_ t: Double, at p: CGPoint) {
            pointer.location = p
            mouse.ingest(MotionSample(t: t, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0))
            mouse.tick(at: t)
        }
        step(0, at: CGPoint(x: 500, y: 400)); step(0.1, at: CGPoint(x: 600, y: 400))
        step(0.2 + s, at: CGPoint(x: 600, y: 400))                       // first hold: press
        #expect(pointer.presses == ["down"] && mouse.isDragging && mouse.dwellAction == .drag)
        step(0.3 + s, at: CGPoint(x: 700, y: 420))                       // move while held
        step(0.4 + 2 * s, at: CGPoint(x: 700, y: 420))                   // second hold: drop
        #expect(pointer.presses == ["down", "up"] && !mouse.isDragging && mouse.dwellAction == .left)
    }
    @Test func pausingNeverLeavesTheButtonHeld() {
        let pointer = FakePointer()
        let mouse = HeadMouse(driver: pointer, defaults: nil, ticks: false)
        mouse.isEnabled = true
        mouse.perform(.drag, source: .voice)
        mouse.perform(.pause)
        #expect(pointer.presses == ["down", "up"] && !mouse.isDragging)
        #expect(VoiceCommandParser.parse("drag it over and drop") == [.drag, .drop])
    }
    @Test func voiceOverHearsCommands() {
        #expect(AppModel.spoken(.rightClick, source: .voice) == "Heard right click")
        #expect(AppModel.spoken(.leftClick, source: .dwell) == nil)
        #expect(AppModel.spoken(.drag, source: .dwell) == "Drag")
        #expect(AppModel.spoken(.pointerMode, source: .dwell) == "Pointer mode.")
        #expect(AppModel.spoken(.scrollMode, source: .other, dwell: true)?.contains("hold still") == true)
        #expect(AppModel.spoken(.scrollMode, source: .other) == "Scroll mode. Turn to scroll.")
        let scrolling = ControlCopy.make(state: .scrolling, voiceRunning: false, motionCommands: false, voiceEnabled: false, dwell: true)
        #expect(scrolling.rows[0].detail == "Scroll, then hold still to point again")
    }
}

@MainActor @Suite("Dwell on real buds")
struct DwellCadenceTests {
    private func rig() -> (FakePointer, HeadMouse) {
        let pointer = FakePointer()
        let mouse = HeadMouse(driver: pointer, defaults: nil, ticks: false)
        mouse.dwellClicks = true
        mouse.isEnabled = true
        return (pointer, mouse)
    }
    private func still(_ t: Double) -> MotionSample { MotionSample(t: t, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0) }

    /// Buds send about one sample a second while still; display ticks run at 60 Hz in between.
    @Test func completesOnTheOneHertzStillnessStream() {
        let (pointer, mouse) = rig()
        mouse.ingest(still(0)); mouse.tick(at: 0)
        pointer.location = CGPoint(x: 600, y: 400)
        mouse.ingest(still(0.1)); mouse.tick(at: 0.1)   // the move that arms it
        var t = 0.1
        while t < 2.5 {
            t += 1.0 / 60
            if Int(t * 60) % 60 == 0 { mouse.ingest(still(t)) }  // ~1 Hz
            mouse.tick(at: t)
        }
        #expect(pointer.clicks.count == 1)
    }
    /// A dead stream also holds the pointer still: without a sample during the hold, no click.
    @Test func neverClicksWhenTheStreamDies() {
        let (pointer, mouse) = rig()
        mouse.ingest(still(0)); mouse.tick(at: 0)
        pointer.location = CGPoint(x: 600, y: 400)
        mouse.ingest(still(0.1)); mouse.tick(at: 0.1)
        var t = 0.1
        while t < 4 { t += 1.0 / 60; mouse.tick(at: t) }
        #expect(pointer.clicks.isEmpty)
    }
    /// Scroll mode has a hands-free exit: after scrolling, holding still returns to pointing.
    @Test func holdingStillAfterScrollingReturnsToPointing() {
        let (_, mouse) = rig()
        mouse.perform(.scrollMode)
        #expect(mouse.mode == .scroll)
        // Not before any scrolling happened.
        var t = 0.0
        while t < 3 { t += 1.0 / 60; if Int(t * 60) % 30 == 0 { mouse.ingest(still(t)) }; mouse.tick(at: t) }
        #expect(mouse.mode == .scroll)
        // Scroll a little (a turn), then hold still.
        rotation(from: 3, seconds: 0.5, x: 40).forEach(mouse.feed)
        t = 3.6
        while t < 8 { t += 1.0 / 60; if Int(t * 60) % 30 == 0 { mouse.ingest(still(t)) }; mouse.tick(at: t) }
        #expect(mouse.mode == .pointer)
    }
}

@MainActor @Suite("Calibration outcome")
struct CalibrationOutcomeTests {
    /// The step callback must see the real result: cancel and failure never read as success.
    @Test func callbackSeesCancelAndFailure() {
        let mouse = HeadMouse(driver: FakePointer(), defaults: nil, ticks: false)
        var outcomes: [HeadMouse.CalibrationOutcome?] = []
        mouse.onCalibrationStep = { step in if step == nil { outcomes.append(mouse.lastCalibrationOutcome) } }
        mouse.startCalibration()
        mouse.cancelCalibration()
        mouse.startCalibration()
        // No movement for longer than the timeout: fails.
        var t = 0.0
        while t <= HeadMouse.calibrationTimeout + 0.5 { mouse.ingest(MotionSample(t: t, bud: 0, qw: 1, qx: 0, qy: 0, qz: 0)); t += 0.1 }
        #expect(outcomes == [.cancelled, .failed])
        #expect(mouse.lastCalibrationFailed)
    }
}
