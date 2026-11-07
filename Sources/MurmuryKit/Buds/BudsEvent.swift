import Foundation

/// Message IDs used by Murmury (see research/FINDINGS_transport.md).
enum MsgID {
    static let statusUpdated: UInt8 = 0x60
    static let extendedStatusUpdated: UInt8 = 0x61
    static let noiseControlsUpdate: UInt8 = 0x77
    static let setSpatialAudio: UInt8 = 0x7C
    static let managerInfo: UInt8 = 0x88
    static let voiceWakeUpEvent: UInt8 = 0x9A
    static let spatialAudioData: UInt8 = 0xC2
    static let spatialAudioControl: UInt8 = 0xC3
    static let neckPostureData: UInt8 = 0xC6
    static let neckPostureControl: UInt8 = 0xC7
}

enum SpatialControl {
    static let attach: UInt8 = 0, detach: UInt8 = 1, attachSuccess: UInt8 = 2, detachSuccess: UInt8 = 3
    static let keepAlive: UInt8 = 4, requestWear: UInt8 = 5, querySensorSupported: UInt8 = 6
    /// SPATIAL_BUF_ON/OFF. On, the bud batches samples (up to ~0.5 s late); off, it streams steadily.
    static let bufferOn: UInt8 = 7, bufferOff: UInt8 = 8
}

struct Quat: Equatable, Sendable {
    var w: Double, x: Double, y: Double, z: Double
}

/// One head-tracking sample. `gyro`/`accel` are present only in the 37-byte extended GRV
/// packet (vecA = int32/2^26, vecB = int32/2^25; vecB feeds Samsung's pedometer, so it is the
/// accelerometer). `bud` is the trailing flag byte, which identifies the reporting bud.
struct HeadSample: Equatable, Sendable {
    var q: Quat
    var gyro: [Double]?
    var accel: [Double]?
    var bud: UInt8
}

enum Placement: Equatable, Sendable {
    case disconnected, wearing, idle, inCase, closedCase, unknown

    init(_ nibble: UInt8) {
        switch nibble {
        case 0: self = .disconnected
        case 1: self = .wearing
        case 2: self = .idle
        case 3: self = .inCase
        case 4: self = .closedCase
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .wearing: "In ear"
        case .idle: "Out of ear"
        case .inCase: "In case"
        case .closedCase: "Case closed"
        case .unknown: "Unknown"
        }
    }
}

/// Typed view of the buds → host messages Murmury cares about.
enum BudsEvent: Equatable, Sendable {
    case motion([HeadSample], TimeInterval)
    case sensorSupported(Bool)
    case rawAccel([[Double]])
    case sensorAttached
    case sensorDetached
    case sensorWear(on: Bool)
    case gyroBias([Int])
    case sensorStuck(Int)
    case status(batteryLeft: Int, batteryRight: Int, left: Placement, right: Placement)
    case extendedStatus(batteryLeft: Int, batteryRight: Int, left: Placement, right: Placement, spatialAudio: Bool?, headTracking: Bool?)
    case noiseControl(mode: Int)
    case voiceWakeUp(detected: Bool, confidence: Int)

    init?(_ msg: SppMessage, at time: TimeInterval = 0) {
        let p = msg.payload
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(p[o]) | UInt16(p[o + 1]) << 8)) }
        func i32(_ o: Int) -> Int {
            Int(Int32(bitPattern: UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24))
        }
        // Scalar-first quaternion (w, x, y, z) as int16 / 10000 — order per Samsung's plugin.
        func quat(_ o: Int) -> Quat {
            Quat(w: Double(i16(o)) / 10000, x: Double(i16(o + 2)) / 10000,
                 y: Double(i16(o + 4)) / 10000, z: Double(i16(o + 6)) / 10000)
        }
        switch msg.id {
        case MsgID.spatialAudioData:
            guard let kind = p.first else { return nil }
            switch kind {
            case 0x20: // GRV; three layouts selected by data length (Fa/g.java:290-360)
                let n = p.count - 1
                guard n >= 9, let flag = p.last else { return nil }
                if n == 9 {
                    self = .motion([HeadSample(q: quat(1), bud: flag)], time)
                } else if n == 37 {
                    let gyro = (0..<3).map { Double(i32(9 + 4 * $0)) / 67_108_864 }   // 2^26
                    let accel = (0..<3).map { Double(i32(21 + 4 * $0)) / 33_554_432 } // 2^25
                    self = .motion([HeadSample(q: quat(1), gyro: gyro, accel: accel, bud: flag)], time)
                } else {
                    let count = Int(p[1])
                    guard count > 0, n >= 1 + 8 * count + 1 else { return nil }
                    self = .motion((0..<count).map { HeadSample(q: quat(2 + 8 * $0), bud: flag) }, time)
                }
            case 0x21: self = .sensorWear(on: true)
            case 0x22: self = .sensorWear(on: false)
            case 0x23:
                guard p.count >= 7 else { return nil }
                self = .gyroBias([i16(1), i16(3), i16(5)])
            case 0x24:
                guard p.count >= 2 else { return nil }
                self = .sensorStuck(Int(p[1]))
            case 0x25:
                guard p.count >= 2 else { return nil }
                self = .sensorSupported(p[1] == 1)
            default: return nil
            }
        case MsgID.spatialAudioControl:
            switch p.first {
            case SpatialControl.attachSuccess: self = .sensorAttached
            case SpatialControl.detachSuccess: self = .sensorDetached
            default: return nil
            }
        case MsgID.statusUpdated:
            guard p.count >= 6 else { return nil }
            self = .status(batteryLeft: Int(p[1]), batteryRight: Int(p[2]),
                           left: Placement(p[5] >> 4), right: Placement(p[5] & 0x0F))
        case MsgID.extendedStatusUpdated:
            guard p.count >= 7 else { return nil }
            self = .extendedStatus(batteryLeft: Int(p[2]), batteryRight: Int(p[3]),
                                   left: Placement(p[6] >> 4), right: Placement(p[6] & 0x0F),
                                   spatialAudio: p.count > 35 ? p[35] == 1 : nil,
                                   headTracking: p.count > 41 ? p[41] == 1 : nil)
        case MsgID.neckPostureData:
            // Fixed-size records [len, type, subtype, seq, int16…]; type 12 / sub 14 = accel/1000.
            guard let len = p.first.map(Int.init), len >= 10 else { return nil }
            var samples: [[Double]] = []
            var o = 0
            while o + len <= p.count {
                if p[o + 1] == 12, p[o + 2] == 14 {
                    samples.append((0..<3).map { Double(i16(o + 4 + 2 * $0)) / 1000 })
                }
                o += len
            }
            guard !samples.isEmpty else { return nil }
            self = .rawAccel(samples)
        case MsgID.noiseControlsUpdate:
            guard let m = p.first else { return nil }
            self = .noiseControl(mode: Int(m))
        case MsgID.voiceWakeUpEvent:
            guard p.count >= 2 else { return nil }
            self = .voiceWakeUp(detected: p[0] == 1, confidence: Int(p[1]))
        default:
            return nil
        }
    }
}
