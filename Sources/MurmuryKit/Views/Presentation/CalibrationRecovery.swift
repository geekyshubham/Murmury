import Foundation

/// Every way direction calibration can stop leads to a guided next step.
struct CalibrationRecovery: Equatable {
    enum Action: Equatable { case openCameraSettings, calibrateWithoutCamera, tryAgain, connectBuds, cancel, useCamera }
    var tone: StatusNotice.Tone
    var text: String
    var actions: [Action]

    static func evaluate(cameraPhase: CameraCalibration.Phase, cameraAuth: VoiceAuthorization, hasCamera: Bool, hasMotion: Bool,
                         noCameraStep: HeadMouse.CalibrationStep?, noCameraFailed: Bool, message: String?) -> Self? {
        if let step = noCameraStep {
            // The round button is Cancel while calibrating, so the notice only instructs.
            return Self(tone: .info, text: step == .turnRight ? "Step 1 of 2 · Turn right about 20°, then back to center" : "Step 2 of 2 · Look up about 20°, then back to center",
                        actions: [])
        }
        if noCameraFailed {
            return Self(tone: .warn, text: message ?? "Calibration didn't finish", actions: [.tryAgain, .useCamera])
        }
        if cameraAuth == .denied {
            return Self(tone: .warn, text: "Camera access is off. Allow it, or calibrate by moving your head.",
                        actions: [.openCameraSettings, .calibrateWithoutCamera])
        }
        if !hasCamera {
            return Self(tone: .info, text: "No camera found. Calibrate by moving your head instead.", actions: [.calibrateWithoutCamera])
        }
        if !hasMotion {
            return Self(tone: .info, text: "Connect your buds to calibrate", actions: [.connectBuds])
        }
        if case .failed(let why) = cameraPhase {
            return Self(tone: .warn, text: why, actions: [.tryAgain, .calibrateWithoutCamera])
        }
        return nil
    }
}

extension CalibrationRecovery.Action {
    var title: String {
        switch self {
        case .openCameraSettings: "Open Camera Settings"
        case .calibrateWithoutCamera: "Calibrate without camera"
        case .tryAgain: "Try again"
        case .connectBuds: "Connect buds"
        case .cancel: "Cancel"
        case .useCamera: "Use the camera"
        }
    }
}
