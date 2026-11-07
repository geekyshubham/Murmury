import Foundation
import simd
import Observation

/// One guided webcam session: records buds and camera together, fits, and applies the result.
@MainActor @Observable
final class CameraCalibration {
    enum Phase: Equatable {
        case idle, starting, running, done(GyroCameraFit.Result), failed(String)
    }

    private(set) var phase: Phase = .idle {
        didSet {
            // Field evidence: the camera measures how late the buds' motion arrives.
            if case let .done(fit) = phase { FieldJournal.shared?.event("camera-fit", ["lag_s": fit.lag, "quality": fit.quality]) }
        }
    }
    private(set) var elapsed = 0.0
    let tracker = CameraHeadTracker()
    let script = CalibrationScript.standard
    /// Fits below this aren't trusted.
    nonisolated static let minimumQuality = 0.55

    @ObservationIgnored private var bud: [MotionSample] = []
    @ObservationIgnored private var camera: [CameraPose] = []
    @ObservationIgnored private var startedAt: Double?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastBud: UInt8 = 0
    @ObservationIgnored private var apply: ((HeadPointer.Axes, HeadModel?, UInt8) -> Void)?
    /// The learned head model and its frame-by-frame comparison, after a successful session.
    private(set) var report: HeadModelFit.Report?
    /// Spoken guidance: each step's instruction as it begins, then the result.
    @ObservationIgnored var onAnnounce: ((String) -> Void)?
    /// Step instructions are time-bound: each one replaces any instruction still being spoken, so a
    /// queued prompt never arrives after its step has ended. Falls back to `onAnnounce`.
    @ObservationIgnored var onPrompt: ((String) -> Void)?
    private func prompt(_ message: String) { (onPrompt ?? onAnnounce)?(message) }
    @ObservationIgnored private var announcedKind: CalibrationScript.Kind?

    /// Paced by the person's movement, not the clock (`CalibrationPacer`).
    @ObservationIgnored private var pacer: CalibrationPacer?
    private(set) var step: CalibrationScript.Step?
    private(set) var progress = 0.0
    /// The current step saw no movement; it waits for Repeat or Skip.
    private(set) var stalled = false

    func start(apply: @escaping (HeadPointer.Axes, HeadModel?, UInt8) -> Void) async {
        guard phase != .running, phase != .starting else { return }
        self.apply = apply
        phase = .starting
        bud = []; camera = []; elapsed = 0; announcedKind = nil; report = nil
        AvatarPoseTap.shared.start()
        tracker.onPose = { [weak self] pose in self?.camera.append(pose) }
        await tracker.start()
        if let error = tracker.error { fail(error); return }
        startedAt = ProcessInfo.processInfo.systemUptime
        pacer = CalibrationPacer(script: script, start: startedAt ?? 0)
        step = pacer?.step; progress = 0
        phase = .running
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        let wasRunning = phase == .running || phase == .starting
        finishTimer()
        tracker.stop()
        _ = AvatarPoseTap.shared.stop()
        phase = .idle
        if wasRunning { onAnnounce?("Camera calibration cancelled. Your previous setup is kept.") }
    }

    /// Feed every motion sample while running.
    func ingest(_ s: MotionSample) {
        guard phase == .running else { return }
        bud.append(s)
        lastBud = s.bud
        pacer?.ingest(s)
    }

    private func tick() {
        guard let startedAt, var pacer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        elapsed = now - startedAt
        while pacer.advance(to: now) {}
        progress = pacer.progress(at: now)
        self.pacer = pacer
        if step != pacer.step { step = pacer.step }
        if let kind = pacer.step?.kind, kind != announcedKind {
            announcedKind = kind
            prompt(kind.instruction + ".")
        }
        if pacer.stalled != stalled {
            stalled = pacer.stalled
            if stalled, let kind = pacer.step?.kind {
                prompt("Didn't see that move. Choose Repeat step and \(kind.instruction.lowercased()), or Skip step.")
            }
        }
        guard pacer.finished else { return }
        finishTimer()
        tracker.stop()
        let avatar = AvatarPoseTap.shared.stop()
        guard bud.count > 100 else {
            fail("No motion from your buds arrived. Connect them and start streaming, then try again.")
            return
        }
        guard camera.count > 60 else {
            fail("The camera couldn't see your face. Sit facing the camera in good light, then try again.")
            return
        }
        let w = pacer.windows
        guard w[.turnRight] != nil || w[.turnLeft] != nil, w[.lookUp] != nil || w[.lookDown] != nil else {
            fail("Calibration needs at least one turn and one nod. Try again and move when each step asks.")
            return
        }
        // First choice: learn the full head model from Vision's face pose, frame by frame.
        let posed = camera.compactMap { c in c.angles.map { (t: c.t, angles: $0) } }
        let centre = startedAt...(startedAt + script.length(of: .centre))
        if posed.count >= 60, let report = HeadModelFit.fit(bud: bud, camera: posed, avatar: avatar, windows: w, centre: centre) {
            guard report.quality >= Self.minimumQuality else { return fail(Self.reason(turn: report.r2.x, nod: report.r2.y)) }
            self.report = report
            let axes = report.model.axes
            apply?(axes, report.model, lastBud)
            phase = .done(GyroCameraFit.Result(turn: simd_normalize(report.model.row(0)), nod: simd_normalize(report.model.row(1)),
                                               lag: report.lag, quality: report.quality))
            onAnnounce?("Calibrated with the camera. The head now follows your turns, nods and tilts.")
            return
        }
        // Fallback without Vision's angles: the turn and nod directions from rates.
        let fit = GyroCameraFit.fit(bud: bud, camera: camera, turnRightAt: w[.turnRight], lookUpAt: w[.lookUp],
                                    turnLeftAt: w[.turnLeft], lookDownAt: w[.lookDown])
        guard let fit, fit.quality >= Self.minimumQuality else {
            fail("The movements didn't line up clearly enough. Try again with bigger, slower turns and nods, facing the camera.")
            return
        }
        apply?(fit.axes, nil, lastBud)
        phase = .done(fit)
        onAnnounce?("Calibrated with the camera. The pointer follows your head.")
    }

    /// Why a fit was refused, by axis, in words a person can act on.
    nonisolated static func reason(turn: Double, nod: Double) -> String {
        let bar = minimumQuality
        switch (turn >= bar, nod >= bar) {
        case (true, false): return "Your turns lined up, but your nods didn't. Try again and nod a little further and more slowly."
        case (false, true): return "Your nods lined up, but your turns didn't. Try again and turn a little further and more slowly."
        default: return "The movements didn't line up clearly enough. Try again with bigger, slower turns and nods, facing the camera."
        }
    }

    /// Saves the last session's frames (camera, avatar and learned pose per camera frame) as CSV in
    /// Documents › Murmury › Checks, and returns the file. Only numbers: no video is ever kept.
    func saveFrames() -> URL? {
        guard let report else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Murmury/Checks", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("head-check-\(stamp).csv")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try report.csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    /// Starts the stalled step again.
    func retryStep() {
        guard var pacer else { return }
        pacer.retry(at: ProcessInfo.processInfo.systemUptime)
        self.pacer = pacer
        stalled = false
        if let kind = pacer.step?.kind { prompt(kind.instruction + ".") }
    }
    /// Leaves the stalled step out and goes on to the next.
    func skipStep() {
        guard var pacer else { return }
        pacer.skip(at: ProcessInfo.processInfo.systemUptime)
        self.pacer = pacer
        stalled = false
        step = pacer.step
        if let kind = pacer.step?.kind {
            announcedKind = kind
            prompt("Step skipped. " + kind.instruction + ".")
        }
    }

    /// Evidence only (`--evidence-surface=calibration-<running|stalled|done|failed>`): shows a state
    /// without the camera or buds, so each can be captured at the sheet's real size.
    func stage(_ name: String) {
        switch name {
        case "running": phase = .running; step = script.steps[1]; progress = 0.3
        case "stalled":
            // A real pacer, stalled on the fourth step, so Repeat step and Skip step act as they do live.
            var p = CalibrationPacer(script: script, start: 0)
            var t = 0.0
            while !(p.stalled && p.step == script.steps[3]), !p.finished, t < 600 {
                t += 0.5
                while p.advance(to: t) {}
                if p.stalled, p.step != script.steps[3] { p.skip(at: t) }
            }
            pacer = p; phase = .running; step = p.step; progress = 0.55; stalled = p.stalled; announcedKind = p.step?.kind
        case "done":
            phase = .done(GyroCameraFit.Result(turn: SIMD3(0, -1, 0), nod: SIMD3(1, 0, 0), lag: 0.08, quality: 0.93))
            // An illustrative session: a turn, a nod and a tilt, with the avatar off before learning.
            let frames = (0..<600).map { i -> HeadModelFit.Frame in
                let t = Double(i) / 30
                let cam = SIMD3(25 * sin(t * 0.9), 15 * sin(t * 1.3 + 1), 10 * sin(t * 0.7 + 2))
                return HeadModelFit.Frame(t: t, camera: cam, avatar: SIMD3(cam.x * 0.7, -cam.y * 0.4, cam.z * 0.2 + cam.x * 0.3),
                                          learned: cam + SIMD3(sin(t * 7), cos(t * 5), sin(t * 3)) * 1.5)
            }
            report = HeadModelFit.Report(model: HeadModel(rows: SIMD3(0, -1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1)), lag: -0.18,
                                         r2: SIMD3(0.96, 0.93, 0.88), before: SIMD3(9.8, 12.4, 7.1), after: SIMD3(2.1, 1.9, 2.6),
                                         learnedTilt: true, frames: frames)
        case "failed": phase = .failed("The movements didn't line up clearly enough. Try again with bigger, slower turns and nods.")
        default: break
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        onAnnounce?("Calibration didn't finish. " + message)
    }

    private func finishTimer() {
        timer?.invalidate()
        timer = nil
    }
}
