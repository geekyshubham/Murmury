import Foundation

/// Hardware facts and demo status are deliberately separate.
struct BudsPresentation {
    enum BladeState {
        case off, connecting, connected, streaming
        /// LED emission: above the studio's bloom threshold (1.6) when lit, so the LEDs glow.
        func intensity(at time: Double, reduceMotion: Bool) -> CGFloat {
            if self == .off { return 0 }
            if reduceMotion { return 2.4 }
            switch self {
            case .off: return 0
            case .connecting: return 1.4 + 0.6 * sin(time * 2 * .pi)
            case .connected: return 2.4
            case .streaming: return 2.2 + 0.4 * sin(time * .pi)
            }
        }
    }
    let bladeState: BladeState
    enum Tone { case live, quiet, busy, danger, demo }
    let chipText: String
    let tone: Tone
    let hardwareStep: Int
    let batteryText: String
    let wearText: String
    let trackingText: String
    let demoBanner: String?

    init(state: BudsService.State, isDemo: Bool, sampleRate: Double, batteryLeft: Int?, batteryRight: Int?,
         placementLeft: Placement, placementRight: Placement, sensorSupported: Bool?) {
        if isDemo { bladeState = .off }
        else {
            switch state {
            case .searching, .connecting: bladeState = .connecting
            case .connected: bladeState = .connected
            case .streaming: bladeState = .streaming
            default: bladeState = .off
            }
        }
        let connected = state == .connected || state == .streaming
        hardwareStep = state == .streaming ? 3 : (connected ? 2 : 1)
        demoBanner = isDemo ? "Showing demo motion" : nil
        if isDemo {
            chipText = connected ? "Buds idle" : "Buds not connected"
            tone = .demo
        } else {
            chipText = state == .streaming ? String(format: "Streaming · %.0f Hz", sampleRate) : state.label
            switch state {
            case .streaming, .connected: tone = .live
            case .searching, .connecting: tone = .busy
            case .failed: tone = .danger
            case .disconnected: tone = .quiet
            }
        }
        if connected {
            batteryText = "Left \(batteryLeft.map { "\($0)%" } ?? "—") · Right \(batteryRight.map { "\($0)%" } ?? "—")"
            wearText = placementLeft == placementRight ? placementLeft.label : "Left \(placementLeft.label) · Right \(placementRight.label)"
        } else {
            batteryText = "Connect to read"; wearText = "Connect to read"
        }
        if isDemo { trackingText = "Synthetic demo motion" }
        else if state == .streaming { trackingText = String(format: "%.0f samples a second", sampleRate) }
        else { trackingText = sensorSupported == false ? "Not supported by these buds" : "Not streaming" }
    }
}

extension BudsService {
    var isBusy: Bool { state == .searching || state == .connecting }
}
