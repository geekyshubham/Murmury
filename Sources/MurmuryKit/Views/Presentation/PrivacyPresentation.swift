enum PrivacyPresentation {
    static func detail(cameraRunning: Bool, micRunning: Bool, speechRunning: Bool, onDevice: Bool) -> String {
        if cameraRunning { return "Calibration camera in use" }
        if !micRunning && !speechRunning { return "Camera off · microphone off" }
        if !speechRunning { return "Camera off · microphone is on" }
        return onDevice ? "Camera off · speech stays on this Mac" : "Camera off · system speech service"
    }
}
