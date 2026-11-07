import Testing
@testable import MurmuryKit

/// Session logic (handshake, attach, keep-alive, refresh, teardown) against a fake transport.
/// Expected sequences follow Samsung's own plugin (research/FINDINGS_samsung_sensors.md §2).
// `C3 08` (SPATIAL_BUF_OFF) keeps the bud from batching samples: measured on a real Buds3 Pro,
// buffered mode (`C3 07`) had 187 gaps over 45 ms in 23 s and up to 536 ms of lag; with `C3 08`,
// 53 Hz steady and the longest gap 98 ms. It is re-sent with every keep-alive.
@Suite("Buds session")
struct BudsSessionTests {
    final class Wire {
        var sent: [[UInt8]] = []
        var messages: [SppMessage] {
            var d = SppDecoder()
            return sent.flatMap { d.feed($0) }
        }
        var trace: [String] { messages.map { m in ([m.id] + m.payload).map { String(format: "%02X", $0) }.joined(separator: " ") } }
    }

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    static func esu(spatial: Bool, headTracking: Bool = false) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 46)
        p[2] = 90; p[3] = 90; p[6] = 0x11; p[35] = spatial ? 1 : 0; p[41] = headTracking ? 1 : 0
        return SppCodec.encode(id: 0x61, payload: p)
    }

    static let grv = SppCodec.encode(id: 0xC2, payload: [0x20, 0x10, 0x27, 0, 0, 0, 0, 0, 0, 0])

    func make() -> (BudsSession, Wire, Box<[BudsEvent]>) {
        let wire = Wire()
        let events = Box<[BudsEvent]>([])
        let session = BudsSession(send: { wire.sent.append($0) })
        session.onEvent = { events.value.append($0) }
        return (session, wire, events)
    }

    func ready() -> (BudsSession, Wire, Box<[BudsEvent]>) {
        let r = make()
        r.0.transportOpened(at: 0)
        r.0.receive(Self.esu(spatial: false), at: 0)
        r.1.sent.removeAll()
        return r
    }

    @Test func greetsAndQueriesSensorSupportOnStatus() {
        let (s, wire, _) = make()
        s.transportOpened(at: 0)
        s.receive(Self.esu(spatial: false), at: 0.1)
        #expect(wire.trace == ["88 01 01 22", "C3 06"])
    }

    @Test func startUsesSamsungAttachSequence() {
        let (s, wire, _) = ready()
        s.startSensor(at: 0)
        #expect(wire.trace == ["7C 01 01", "C3 05", "C3 00", "C3 08"])
        #expect(s.phase == .attaching)
    }

    @Test func startBeforeHandshakeIsDeferredUntilStatusArrives() {
        let (s, wire, _) = make()
        s.transportOpened(at: 0)
        s.startSensor(at: 0.05)
        #expect(wire.sent.isEmpty)
        s.receive(Self.esu(spatial: false), at: 0.2)
        #expect(wire.trace == ["88 01 01 22", "C3 06", "7C 01 01", "C3 05", "C3 00", "C3 08"])
    }

    @Test func handshakeTimesOutAndAttachesAnyway() {
        let (s, wire, _) = make()
        s.transportOpened(at: 0)
        s.startSensor(at: 0)
        s.tick(at: 1.0)
        #expect(wire.sent.isEmpty)
        s.tick(at: 2.1)
        #expect(wire.trace == ["C3 06", "7C 01 01", "C3 05", "C3 00", "C3 08"])
    }

    @Test func keepAliveEveryTwoSecondsWhileDataFlows() {
        let (s, wire, _) = ready()
        s.startSensor(at: 0)
        wire.sent.removeAll()
        for t in stride(from: 0.1, through: 4.2, by: 0.1) {
            s.receive(Self.grv, at: t)
            s.tick(at: t)
        }
        #expect(wire.trace == ["C3 04", "C3 08", "C3 04", "C3 08"])
    }

    @Test func refreshesWithRemoveThenAddAfterTwoSecondsOfSilence() {
        let (s, wire, _) = ready()
        s.startSensor(at: 0)
        s.receive(Self.grv, at: 0.5)
        wire.sent.removeAll()
        s.tick(at: 2.4)
        #expect(wire.trace == ["C3 04", "C3 08"], "only the keep-alive is due")
        s.tick(at: 2.6)
        #expect(wire.trace.suffix(3) == ["C3 01", "C3 00", "C3 08"])
    }

    @Test func stopRestoresUsersSettings() {
        for (spatial, ht) in [(true, true), (false, false), (true, false)] {
            let (s, wire, _) = make()
            s.transportOpened(at: 0)
            s.receive(Self.esu(spatial: spatial, headTracking: ht), at: 0)
            s.startSensor(at: 0)
            // While we hold the sensor the buds report our forced setting; it must not
            // overwrite what we restore.
            s.receive(Self.esu(spatial: true, headTracking: true), at: 0.5)
            wire.sent.removeAll()
            s.stopSensor()
            #expect(wire.trace == ["C3 01", "7C \(spatial ? "01" : "00") \(ht ? "01" : "00")"])
            s.tick(at: 10)
            #expect(wire.sent.count == 2, "no keep-alive after stop")
        }
    }

    @Test func forwardsMotionWithReceiveTimestamp() {
        let (s, _, events) = make()
        s.transportOpened(at: 0)
        s.receive(Self.grv, at: 5.25)
        #expect(events.value.contains { if case .motion(_, 5.25) = $0 { true } else { false } })
    }

    @Test func attachAckOrDataMarksStreaming() {
        let (s, _, _) = ready()
        s.startSensor(at: 0)
        s.receive(SppCodec.encode(id: 0xC3, payload: [0x02]), at: 0.1)
        #expect(s.phase == .streaming)

        let (s2, _, _) = ready()
        s2.startSensor(at: 0)
        s2.receive(Self.grv, at: 0.1)
        #expect(s2.phase == .streaming)
    }

    @Test func rawAccelStreamToggle() {
        let (s, wire, _) = ready()
        s.setRawAccel(true)
        s.setRawAccel(false)
        #expect(wire.trace == ["C7 04 01", "C7 04 00"])
    }

    @Test func closingStopsEverything() {
        let (s, wire, _) = ready()
        s.startSensor(at: 0)
        s.transportClosed()
        wire.sent.removeAll()
        s.tick(at: 10)
        #expect(wire.sent.isEmpty)
        #expect(s.phase == .closed)
    }
}
