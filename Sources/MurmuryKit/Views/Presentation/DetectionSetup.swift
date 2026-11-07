struct DetectionSetup {
    /// "Learn stillness", not "Calibrate": calibration means pointer direction on Control.
    enum Action: String { case calibrate = "Learn stillness", calibrating = "Learning…", listen = "Listen", stop = "Stop" }
    var action: Action
    var disabledReason: String?
    var hasGestures = true
    /// What the round button does, under it.
    var caption: String {
        switch action {
        case .calibrate: "Hold still for 2 seconds · ⌘L"
        case .calibrating: "Learning your stillness"
        case .listen: "Listens as you move · ⌘L"
        case .stop: "Listening · ⌘L to stop"
        }
    }
    /// The same readiness rule as training: listening needs 2 takes of 2 gestures to match
    /// against. Calibrating stillness doesn't, so setup can start before teaching.
    static let needsGestures = "2 gestures, 2 takes each"
    static func evaluate(hasMotion: Bool, calibrated: Bool, calibrating: Bool, listening: Bool, hasGestures: Bool = true) -> Self {
        if listening { return Self(action: .stop) }
        if calibrating { return Self(action: .calibrating, disabledReason: "Stay still for 2 seconds") }
        if !hasMotion { return Self(action: calibrated ? .listen : .calibrate, disabledReason: "Connect a motion source or start the demo") }
        if calibrated, !hasGestures { return Self(action: .listen, disabledReason: needsGestures, hasGestures: false) }
        return Self(action: calibrated ? .listen : .calibrate, hasGestures: hasGestures)
    }
}
