import Foundation
import simd

/// The guided routine for webcam calibration: what to ask, for how long. ~26 seconds in all:
/// each movement gets 4.5 s to hear its instruction (VoiceOver speaks it) and then to move, and
/// the fit uses the window where the movement actually happened (`responseWindow`).
struct CalibrationScript: Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case centre, turnRight, turnLeft, lookUp, lookDown, tiltRight, tiltLeft, free

        var instruction: String {
            switch self {
            case .centre: "Look straight at the screen"
            case .turnRight: "Turn your head to the right, then back"
            case .turnLeft: "Now to the left, then back"
            case .lookUp: "Look up, then back"
            case .lookDown: "Look down, then back"
            case .tiltRight: "Tilt your head toward your right shoulder, then back"
            case .tiltLeft: "Now toward your left shoulder, then back"
            case .free: "Move your head around freely"
            }
        }

        /// The short name in the routine's preview.
        var title: String {
            switch self {
            case .centre: "Centre"
            case .turnRight: "Turn right"
            case .turnLeft: "Turn left"
            case .lookUp: "Look up"
            case .lookDown: "Look down"
            case .tiltRight: "Tilt right"
            case .tiltLeft: "Tilt left"
            case .free: "Move freely"
            }
        }

        var symbol: String {
            switch self {
            case .centre: "scope"
            case .turnRight: "arrow.right"
            case .turnLeft: "arrow.left"
            case .lookUp: "arrow.up"
            case .lookDown: "arrow.down"
            case .tiltRight: "arrow.clockwise"
            case .tiltLeft: "arrow.counterclockwise"
            case .free: "arrow.triangle.2.circlepath"
            }
        }
    }

    struct Step: Equatable {
        var kind: Kind
        var seconds: Double
    }

    var steps: [Step]

    static let standard = CalibrationScript(steps: [
        Step(kind: .centre, seconds: 2.5), Step(kind: .turnRight, seconds: 4.5), Step(kind: .turnLeft, seconds: 4.5),
        Step(kind: .lookUp, seconds: 4.5), Step(kind: .lookDown, seconds: 4.5),
        Step(kind: .tiltRight, seconds: 4.5), Step(kind: .tiltLeft, seconds: 4.5), Step(kind: .free, seconds: 5),
    ])

    var duration: Double { steps.reduce(0) { $0 + $1.seconds } }

    func start(of kind: Kind) -> Double {
        var t = 0.0
        for s in steps {
            if s.kind == kind { return t }
            t += s.seconds
        }
        return t
    }

    func length(of kind: Kind) -> Double { steps.first { $0.kind == kind }?.seconds ?? 0 }

    func step(at elapsed: Double) -> Step? {
        guard elapsed >= 0 else { return nil }
        var t = 0.0
        for s in steps {
            if elapsed < t + s.seconds { return s }
            t += s.seconds
        }
        return nil
    }

    func progress(at elapsed: Double) -> Double { min(max(elapsed / duration, 0), 1) }

    /// When the move goes outward (the first half of its step), in absolute time.
    func outwardWindow(of kind: Kind, startingAt t0: Double) -> ClosedRange<Double> {
        let a = t0 + start(of: kind)
        return a...(a + length(of: kind) / 2)
    }

    /// The fitting window follows the person, not the clock: it starts when the head actually
    /// begins to move within the step (angular speed over `onsetSpeed`), however long they took
    /// to hear the instruction, and covers the outward half-second-to-1.6 s of that movement.
    /// Without a clear onset it falls back to the step's first half.
    static let onsetSpeed = 15.0 * .pi / 180, outwardSeconds = 1.6
    func responseWindow(of kind: Kind, startingAt t0: Double, samples: [MotionSample]) -> ClosedRange<Double> {
        let a = t0 + start(of: kind), b = a + length(of: kind)
        guard let onset = samples.first(where: { $0.t >= a && $0.t < b && $0.angularSpeed >= Self.onsetSpeed })?.t else {
            return outwardWindow(of: kind, startingAt: t0)
        }
        return max(a, onset - 0.1)...min(b, onset + Self.outwardSeconds)
    }
}

/// Response-aware pacing for the guided routine: a movement step lasts until the person has
/// moved out and back, not a fixed time. It waits for the movement to begin (slow movement
/// counts), follows it by integrating the gyro, and ends once the head has come back and held still
/// (`maxMove` caps a very slow return). A step with no movement by `maxWait` stalls rather than
/// moving on: the person repeats it or skips it, so a missed instruction never passes silently. The fitting window
/// is the outward half of the movement (onset to the furthest point); without a detectable start it
/// is the whole step, never a clipped half. Progress never goes backwards.
struct CalibrationPacer: Equatable {
    static let onsetSpeed = 8.0 * .pi / 180
    static let maxWait = 12.0
    static let maxMove = 8.0
    static let minAngle = 5.0 * .pi / 180
    static let movements: Set<CalibrationScript.Kind> = [.turnRight, .turnLeft, .lookUp, .lookDown, .tiltRight, .tiltLeft]

    let script: CalibrationScript
    private(set) var index = 0
    private(set) var stepStart: Double
    private(set) var onset: Double?
    private(set) var windows: [CalibrationScript.Kind: ClosedRange<Double>] = [:]
    private(set) var finished = false
    /// The current movement step saw no movement by `maxWait`; it holds until `retry` or `skip`.
    private(set) var stalled = false
    private var rotation = SIMD3<Double>.zero
    private var furthest = 0.0
    private var furthestAt: Double?
    private var stillSince: Double?
    private var completedAt: Double?
    private var lastSampleT: Double?
    private var shown = 0.0

    init(script: CalibrationScript = .standard, start: Double) {
        self.script = script
        stepStart = start
    }

    var step: CalibrationScript.Step? { finished ? nil : script.steps[index] }
    private var isMovement: Bool { step.map { Self.movements.contains($0.kind) } ?? false }

    /// Feed every bud sample: it finds the movement's start, its furthest point and its end.
    mutating func ingest(_ s: MotionSample) {
        defer { lastSampleT = s.t }
        // While stalled the step waits for Repeat or Skip; movement then counts only after Repeat.
        guard isMovement, !stalled, s.t >= stepStart, completedAt == nil else { return }
        let w = s.turnRate  // the bud's own gyro when the packet carries it
        let speed = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).squareRoot()
        guard let onset else {
            if speed >= Self.onsetSpeed { self.onset = s.t; rotation = .zero; furthest = 0; furthestAt = s.t; stillSince = nil }
            return
        }
        let dt = min(0.1, max(0, s.t - (lastSampleT ?? s.t)))
        rotation += SIMD3(w[0], w[1], w[2]) * dt
        let angle = simd_length(rotation)
        if angle > furthest { furthest = angle; furthestAt = s.t }
        stillSince = speed < Self.onsetSpeed * 0.6 ? (stillSince ?? s.t) : nil
        // Back near the start (within 35% of the furthest point) and still for 0.4 s: done.
        if furthest >= Self.minAngle, angle <= 0.35 * furthest, let still = stillSince, s.t - still >= 0.4, s.t - onset >= 0.8 {
            completedAt = s.t
        }
    }

    /// When the current step ends, given what has happened so far.
    var stepEnd: Double? {
        guard let step else { return nil }
        guard isMovement else { return stepStart + step.seconds }
        if let completedAt { return completedAt + 0.3 }
        return onset.map { $0 + Self.maxMove } ?? stepStart + Self.maxWait
    }

    /// Moves on when the current step has ended; true when the step changed. A movement step that
    /// saw nothing stalls instead.
    mutating func advance(to t: Double) -> Bool {
        guard let step, let end = stepEnd, t >= end, !stalled else { return false }
        if isMovement && onset == nil { stalled = true; return false }
        return moveOn(step: step, end: end)
    }
    /// Starts the stalled step again from `t`, with every trace of the missed attempt cleared.
    mutating func retry(at t: Double) {
        guard stalled else { return }
        stalled = false; stepStart = t; onset = nil
        rotation = .zero; furthest = 0; furthestAt = nil; stillSince = nil; completedAt = nil
    }
    /// Leaves the stalled step out of the fit and moves on.
    mutating func skip(at t: Double) {
        guard stalled, let step else { return }
        stalled = false
        _ = moveOn(step: step, end: t, skipped: true)
    }
    private mutating func moveOn(step: CalibrationScript.Step, end: Double, skipped: Bool = false) -> Bool {
        if skipped {
            windows[step.kind] = nil
        } else if let onset {
            let outwardEnd = max(onset + 0.3, furthestAt ?? onset + CalibrationScript.outwardSeconds)
            windows[step.kind] = max(stepStart, onset - 0.1)...outwardEnd
        } else {
            windows[step.kind] = stepStart...end
        }
        index += 1; stepStart = end; onset = nil
        rotation = .zero; furthest = 0; furthestAt = nil; stillSince = nil; completedAt = nil
        if index >= script.steps.count { finished = true }
        return true
    }

    /// 0…1 across the steps, never going backwards (a late start can lengthen a step's estimate).
    mutating func progress(at t: Double) -> Double {
        guard !finished else { shown = 1; return 1 }
        let share = 1 / Double(script.steps.count)
        let span = (stepEnd ?? t) - stepStart
        let within = span > 0 ? min(1, max(0, (t - stepStart) / span)) : 0
        shown = max(shown, (Double(index) + within) * share)
        return shown
    }
}
