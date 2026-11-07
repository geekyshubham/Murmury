import Foundation
import IOBluetooth
import Observation

/// IOBluetooth transport for the Galaxy Buds3 Pro. All protocol behaviour lives in the
/// unit-tested `BudsSession`; this class only finds the paired device, opens Samsung's SPP
/// RFCOMM channel and moves bytes. Runs on the main run loop, where IOBluetooth delivers
/// its callbacks.
@MainActor @Observable
final class BudsService {
    enum State: Equatable {
        case disconnected, searching, connecting, connected, streaming
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: "Not connected"
            case .searching: "Looking for buds…"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .streaming: "Streaming"
            case .failed: "Couldn't connect"  // the reason is in the notice
            }
        }
    }

    /// Buds2 and later (incl. Buds3 Pro) expose SPP under this service UUID.
    static let serviceUUID: [UInt8] = [0x2E, 0x73, 0xA4, 0xAD, 0x33, 0x2D, 0x41, 0xFC,
                                       0x90, 0xE2, 0x16, 0xBE, 0xF0, 0x65, 0x23, 0xF2]

    private(set) var state: State = .disconnected
    private(set) var deviceName: String?
    private(set) var deviceAddress: String?
    private(set) var channelID: UInt8?
    private(set) var batteryLeft: Int?
    private(set) var batteryRight: Int?
    private(set) var placementLeft: Placement = .unknown
    private(set) var placementRight: Placement = .unknown
    private(set) var lastSensorEvent = "—"
    private(set) var log: [String] = []

    var isConnected: Bool { state == .connected || state == .streaming }
    private(set) var sensorSupported: Bool?
    private(set) var hasIMU = false
    private(set) var rawAccelOn = false
    var onMotion: (([HeadSample], TimeInterval) -> Void)?
    var onRawAccel: (([[Double]]) -> Void)?
    /// Start the head-tracking stream as soon as the SPP channel opens.
    var streamOnConnect = false

    @ObservationIgnored private var device: IOBluetoothDevice?
    @ObservationIgnored private var channel: IOBluetoothRFCOMMChannel?
    @ObservationIgnored private var delegate: ChannelDelegate?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let trace = ByteTrace(path: ProcessInfo.processInfo.environment["MURMURY_TRACE"])
    @ObservationIgnored private lazy var session: BudsSession = makeSession()

    private func makeSession() -> BudsSession {
        let s = BudsSession { [weak self] bytes in self?.write(bytes) }
        s.onEvent = { [weak self] e in self?.handle(e) }
        s.onLog = { [weak self] m in self?.append(m) }
        return s
    }

    // MARK: Connect

    func connect() {
        guard !isConnected, state != .connecting, state != .searching else { return }
        state = .searching
        // The first IOBluetooth call starts its CoreBluetooth coordinator and waits on a
        // semaphore; on the main thread that froze the app for 12 s or more on real hardware.
        Task.detached(priority: .userInitiated) {
            let found = DeviceBox(Self.findBuds())
            await MainActor.run { self.found(found.device) }
        }
    }

    nonisolated private static func findBuds() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("Buds3 Pro") })
            ?? paired.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains("Buds") })
    }

    private func found(_ target: IOBluetoothDevice?) {
        guard state == .searching else { return }  // cancelled meanwhile
        guard let target else {
            fail("No paired Galaxy Buds found. Pair them in System Settings › Bluetooth.")
            return
        }
        device = target
        deviceName = target.name
        deviceAddress = target.addressString
        state = .connecting
        append("Using \(target.name ?? "?") (\(target.addressString ?? "?"))")
        Task { await open(target) }
    }

    private func open(_ target: IOBluetoothDevice) async {
        if !target.isConnected() {
            append("Opening baseband connection…")
            guard target.openConnection() == kIOReturnSuccess else {
                return fail("Buds not reachable. Take them out of the case and keep them near the Mac.")
            }
        }
        // A UUID-filtered SDP query silently fails since macOS 13; query everything.
        let sdp = SDPWaiter()
        if target.performSDPQuery(sdp) == kIOReturnSuccess {
            for _ in 0..<30 where !sdp.done { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let uuid = IOBluetoothSDPUUID(bytes: Self.serviceUUID, length: Self.serviceUUID.count)
        guard let record = target.getServiceRecord(for: uuid) else {
            return fail("These buds didn't offer head tracking. Make sure they are Galaxy Buds3 Pro, then try again.")
        }
        var id: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess else { return fail("The buds didn't answer. Put them back in your ears, then try again.") }
        channelID = id
        append("RFCOMM channel \(id)")

        let delegate = ChannelDelegate(owner: self)
        self.delegate = delegate
        var ch: IOBluetoothRFCOMMChannel?
        _ = target.openRFCOMMChannelAsync(&ch, withChannelID: id, delegate: delegate)
        // The open status is unreliable on macOS (reports errors on success); poll isOpen.
        for _ in 0..<40 {
            if ch?.isOpen() == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let ch, ch.isOpen() else { return fail("Couldn't connect. Disconnect the buds from your phone, then try again.") }
        channel = ch
        state = .connected
        append("SPP channel open")
        session.transportOpened(at: now)
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.tick(at: ProcessInfo.processInfo.systemUptime) }
        }
        if streamOnConnect { startSensor() }
    }

    func disconnect() {
        session.stopSensor()
        session.transportClosed()
        ticker?.invalidate(); ticker = nil
        _ = channel?.close()
        channel = nil
        delegate = nil
        state = .disconnected
        append("Disconnected")
    }

    func startSensor() {
        append("Starting head-tracking stream")
        session.startSensor(at: now)
        // Protocol experiments: MURMURY_SEND="C3 08;C3 07" sends each frame (id + payload) 3 s
        // after starting, one per second.
        if let spec = ProcessInfo.processInfo.environment["MURMURY_SEND"] {
            for (i, frame) in spec.split(separator: ";").enumerated() {
                let bytes = frame.split(separator: " ").compactMap { UInt8($0, radix: 16) }
                guard let id = bytes.first else { continue }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3 + i * 8))
                    self?.append("Experiment: sending \(frame)")
                    self?.write(SppCodec.encode(id: id, payload: Array(bytes.dropFirst())))
                }
            }
        }
    }

    func setRawAccel(_ on: Bool) {
        session.setRawAccel(on)
        rawAccelOn = on
        append(on ? "Requested raw accelerometer stream (neck-calibration channel)" : "Stopped raw accelerometer stream")
    }

    func stopSensor() {
        session.stopSensor()
        if state == .streaming { state = .connected }
        append("Stopped head-tracking stream")
    }

    // MARK: Transport callbacks

    fileprivate func received(_ bytes: [UInt8]) {
        trace?.write("RX", bytes)
        session.receive(bytes, at: now)
    }

    fileprivate func channelClosed() {
        guard channel != nil else { return }
        channel = nil
        session.transportClosed()
        ticker?.invalidate(); ticker = nil
        state = .disconnected
        append("Channel closed by the buds")
    }

    private func write(_ bytes: [UInt8]) {
        guard let channel, channel.isOpen() else { return }
        trace?.write("TX", bytes)
        let mtu = max(Int(channel.getMTU()), 16)
        var offset = 0
        while offset < bytes.count {
            var chunk = Array(bytes[offset..<min(offset + mtu, bytes.count)])
            let status = chunk.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
            if status != kIOReturnSuccess { append("Write failed (\(status))"); return }
            offset += chunk.count
        }
    }

    // MARK: Events

    private func handle(_ event: BudsEvent) {
        switch event {
        case let .motion(samples, t):
            if state != .streaming { state = .streaming }
            if !hasIMU, samples.contains(where: { $0.accel != nil }) { hasIMU = true; append("Extended packets: bud accelerometer + gyro present") }
            onMotion?(samples, t)
        case let .sensorSupported(ok):
            sensorSupported = ok; append(ok ? "Buds report head-tracking sensor supported" : "Buds report NO head-tracking sensor")
        case let .rawAccel(samples):
            onRawAccel?(samples)
        case .sensorAttached:
            lastSensorEvent = "Attached"; append("Head-tracking attached")
        case .sensorDetached:
            lastSensorEvent = "Detached"
        case let .sensorWear(on):
            lastSensorEvent = on ? "Worn" : "Removed"
        case let .gyroBias(b):
            lastSensorEvent = "Gyro bias \(b)"
        case let .sensorStuck(code):
            lastSensorEvent = "Sensor stuck (\(code))"; append("Sensor reported stuck: \(code)")
        case let .status(l, r, pl, pr), let .extendedStatus(l, r, pl, pr, _, _):
            batteryLeft = l; batteryRight = r; placementLeft = pl; placementRight = pr
        case .noiseControl, .voiceWakeUp:
            break
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func fail(_ message: String) {
        state = .failed(message)
        append(message)
    }

    private func append(_ line: String) {
        trace?.write("--", line)
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(line)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}

private final class SDPWaiter: NSObject {
    var done = false
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { done = true }
}

private final class ChannelDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    weak var owner: BudsService?
    init(owner: BudsService) { self.owner = owner }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated { owner?.received(bytes) }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated { owner?.channelClosed() }
    }
}

/// Raw SPP traffic for protocol debugging: set `MURMURY_TRACE=/path/to/file` when launching.
private final class ByteTrace {
    private let handle: FileHandle
    private let start = ProcessInfo.processInfo.systemUptime

    init?(path: String?) {
        guard let path, FileManager.default.createFile(atPath: path, contents: nil),
              let handle = FileHandle(forWritingAtPath: path) else { return nil }
        self.handle = handle
    }

    func write(_ tag: String, _ bytes: [UInt8]) {
        write(tag, bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
    }

    func write(_ tag: String, _ text: String) {
        let t = String(format: "%9.3f", ProcessInfo.processInfo.systemUptime - start)
        handle.write(Data("\(t) \(tag) \(text)\n".utf8))
    }
}

/// Carries an IOBluetooth device across the actor hop; it's only used on the main actor after.
private struct DeviceBox: @unchecked Sendable {
    let device: IOBluetoothDevice?
    init(_ device: IOBluetoothDevice?) { self.device = device }
}
