import Foundation

/// Transport-independent protocol logic for one SPP connection: handshake, head-tracking
/// attach, keep-alive, silence refresh and teardown. Time is injected so it is testable.
/// Sequences mirror Samsung's Buds3 Pro plugin (research/FINDINGS_samsung_sensors.md §2).
final class BudsSession {
    enum Phase: Equatable { case closed, awaitingStatus, ready, attaching, streaming }

    static let handshakeTimeout: TimeInterval = 2
    static let keepAliveInterval: TimeInterval = 2
    static let silenceTimeout: TimeInterval = 2

    var onEvent: ((BudsEvent) -> Void)?
    var onLog: ((String) -> Void)?
    private(set) var phase: Phase = .closed
    private(set) var unknownMessages = 0

    private let send: ([UInt8]) -> Void
    private var decoder = SppDecoder()
    private var wantsSensor = false
    private var openedAt: TimeInterval = 0
    private var lastKeepAlive: TimeInterval = 0
    private var lastData: TimeInterval = 0
    private var greeted = false
    /// The user's own settings, restored when we release the sensor.
    private var userSpatialAudio = false
    private var userHeadTracking = false

    init(send: @escaping ([UInt8]) -> Void) { self.send = send }

    func transportOpened(at t: TimeInterval) {
        decoder = SppDecoder()
        phase = .awaitingStatus
        openedAt = t
        greeted = false
    }

    func transportClosed() {
        phase = .closed
        wantsSensor = false
    }

    func receive(_ bytes: [UInt8], at t: TimeInterval) {
        for msg in decoder.feed(bytes) {
            guard let event = BudsEvent(msg, at: t) else { unknownMessages += 1; continue }
            handle(event, at: t)
            onEvent?(event)
        }
    }

    func startSensor(at t: TimeInterval) {
        wantsSensor = true
        if phase == .ready { attach(at: t) }
    }

    func stopSensor() {
        let held = phase == .attaching || phase == .streaming
        wantsSensor = false
        guard held else { return }
        write(MsgID.spatialAudioControl, [SpatialControl.detach])
        write(MsgID.setSpatialAudio, [userSpatialAudio ? 1 : 0, userHeadTracking ? 1 : 0])
        phase = .ready
    }

    /// Neck-posture calibration accelerometer stream (≈50 Hz, 0xC6 records).
    func setRawAccel(_ on: Bool) {
        write(MsgID.neckPostureControl, [0x04, on ? 1 : 0])
    }

    func tick(at t: TimeInterval) {
        if phase == .awaitingStatus, t - openedAt >= Self.handshakeTimeout {
            onLog?("No status from buds after \(Int(Self.handshakeTimeout)) s; continuing")
            becomeReady(at: t)
            return
        }
        guard wantsSensor, phase == .attaching || phase == .streaming else { return }
        if t - lastKeepAlive >= Self.keepAliveInterval {
            write(MsgID.spatialAudioControl, [SpatialControl.keepAlive])
            write(MsgID.spatialAudioControl, [SpatialControl.bufferOff])
            lastKeepAlive = t
        }
        if t - lastData > Self.silenceTimeout {
            onLog?("No sensor data for \(Int(Self.silenceTimeout)) s; refreshing")
            write(MsgID.spatialAudioControl, [SpatialControl.detach])
            write(MsgID.spatialAudioControl, [SpatialControl.attach])
            write(MsgID.spatialAudioControl, [SpatialControl.bufferOff])
            lastData = t
        }
    }

    private func handle(_ event: BudsEvent, at t: TimeInterval) {
        switch event {
        case let .extendedStatus(_, _, _, _, spatial, headTracking):
            if !greeted {
                greeted = true
                write(MsgID.managerInfo, [0x01, 0x01, 0x22])
            }
            // While we hold the sensor the buds echo our forced values; don't record those.
            if phase == .awaitingStatus || phase == .ready {
                userSpatialAudio = spatial ?? false
                userHeadTracking = headTracking ?? false
            }
            if phase == .awaitingStatus { becomeReady(at: t) }
        case .sensorAttached:
            if wantsSensor { phase = .streaming; lastData = t }
        case .motion:
            lastData = t
            if phase == .attaching { phase = .streaming }
        default:
            break
        }
    }

    private func becomeReady(at t: TimeInterval) {
        phase = .ready
        write(MsgID.spatialAudioControl, [SpatialControl.querySensorSupported])
        if wantsSensor { attach(at: t) }
    }

    private func attach(at t: TimeInterval) {
        write(MsgID.setSpatialAudio, [0x01, 0x01])
        write(MsgID.spatialAudioControl, [SpatialControl.requestWear])
        write(MsgID.spatialAudioControl, [SpatialControl.attach])
        write(MsgID.spatialAudioControl, [SpatialControl.bufferOff])
        phase = .attaching
        lastKeepAlive = t
        lastData = t
    }

    private func write(_ id: UInt8, _ payload: [UInt8]) {
        send(SppCodec.encode(id: id, payload: payload))
    }
}
