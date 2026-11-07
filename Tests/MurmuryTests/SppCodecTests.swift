import Foundation
import Testing
@testable import MurmuryKit

/// Byte-exact vectors from research/FINDINGS_transport.md (CRC verified against a real
/// Buds2 Pro capture in GalaxyBudsClient's test data).
@Suite("SPP framing")
struct SppCodecTests {
    static func hex(_ s: String) -> [UInt8] {
        s.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    @Test func crcMatchesXmodemCheckValue() {
        #expect(SppCodec.crc16(Array("123456789".utf8)) == 0x31C3)
    }

    @Test(arguments: [
        (UInt8(0x7C), [UInt8(0x01)], "FD 04 00 7C 01 15 5D DD"),
        (0xC3, [0x00], "FD 04 00 C3 00 07 43 DD"),
        (0xC3, [0x04], "FD 04 00 C3 04 83 03 DD"),
        (0xC3, [0x01], "FD 04 00 C3 01 26 53 DD"),
        (0x7C, [0x00], "FD 04 00 7C 00 34 4D DD"),
        (0x88, [0x01, 0x01, 0x22], "FD 06 00 88 01 01 22 DA 58 DD"),
        (0x26, [], "FD 03 00 26 A4 44 DD"),
    ])
    func encodesKnownFrames(id: UInt8, payload: [UInt8], expected: String) {
        #expect(SppCodec.encode(id: id, payload: payload) == Self.hex(expected))
    }

    @Test func decodesRealExtendedStatusCapture() throws {
        let frame = Self.hex("""
        FD 31 00 61 0D 04 64 64 01 00 33 58 00 01 BF 22 00 01 46 01 46 01 00 00 03 35 \
        00 03 00 10 01 01 01 01 32 03 01 01 01 00 0C AE 01 00 03 00 01 00 01 01 B6 37 DD
        """.replacingOccurrences(of: "\\\n", with: "").replacingOccurrences(of: "\n", with: " "))
        var decoder = SppDecoder()
        let messages = decoder.feed(frame)
        try #require(messages.count == 1)
        #expect(messages[0].id == 0x61)
        #expect(messages[0].payload.count == 46)
    }

    @Test func reassemblesFramesSplitAcrossChunks() {
        let stream = Self.hex("FD 0D 00 C2 20 00 00 00 00 00 00 10 27 00 D3 88 DD")
            + Self.hex("FD 04 00 C3 02 45 63 DD")
        var decoder = SppDecoder()
        var out: [SppMessage] = []
        for chunk in stride(from: 0, to: stream.count, by: 3) {
            out += decoder.feed(Array(stream[chunk..<min(chunk + 3, stream.count)]))
        }
        #expect(out.map(\.id) == [0xC2, 0xC3])
        #expect(out[1].payload == [0x02])
    }

    @Test func resyncsAfterGarbageAndCorruptFrames() {
        var corrupt = Self.hex("FD 04 00 C3 02 45 63 DD")
        corrupt[4] = 0x09 // CRC no longer matches
        let stream = [0x00, 0xDD, 0xFD] + corrupt + Self.hex("FD 04 00 C3 02 45 63 DD")
        var decoder = SppDecoder()
        let out = decoder.feed(stream)
        #expect(out.count == 1)
        #expect(out.first?.payload == [0x02])
        #expect(decoder.droppedBytes > 0)
    }

    @Test func payloadMayContainMarkerBytes() {
        let frame = SppCodec.encode(id: 0x42, payload: [0xFD, 0xDD, 0xFD, 0x00])
        var decoder = SppDecoder()
        let out = decoder.feed(frame + frame)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.payload == [0xFD, 0xDD, 0xFD, 0x00] })
    }

    @Test func masksTypeAndFragmentBits() {
        var frame = SppCodec.encode(id: 0x60, payload: [1, 2, 3])
        frame[2] |= 0x10 // response/type bit set by some firmware
        var decoder = SppDecoder()
        #expect(decoder.feed(frame).first?.payload == [1, 2, 3])
    }
}

@Suite("Message parsing")
struct MessageParsingTests {
    static func motion(_ payload: String) throws -> [HeadSample] {
        let event = try #require(BudsEvent(SppMessage(id: 0xC2, payload: SppCodecTests.hex(payload))))
        guard case let .motion(samples, _) = event else { Issue.record("not motion: \(event)"); return [] }
        return samples
    }

    /// Samsung's plugin reads the quaternion scalar-first (w, x, y, z) — Fa/g.java, La/i.java.
    @Test func grvIsScalarFirst() throws {
        let s = try Self.motion("20 10 27 00 00 00 00 00 00 00")
        #expect(s.count == 1)
        #expect(s[0].q == Quat(w: 1, x: 0, y: 0, z: 0))
        #expect(s[0].gyro == nil && s[0].accel == nil)
    }

    @Test func grvSignedComponents() throws {
        // w = 0.5 (0x1388), x = -0.5 (0xEC78), y = 0.5, z = -0.5
        let s = try Self.motion("20 88 13 78 EC 88 13 78 EC 00")
        #expect(s[0].q == Quat(w: 0.5, x: -0.5, y: 0.5, z: -0.5))
    }

    @Test func grvFlagIdentifiesBud() throws {
        #expect(try Self.motion("20 10 27 00 00 00 00 00 00 00")[0].bud == 0)
        #expect(try Self.motion("20 10 27 00 00 00 00 00 00 01")[0].bud == 1)
    }

    /// 37-byte GRV: quat, vecA 3×int32/2^26 (gyro?), vecB 3×int32/2^25 (accel), int32, flag.
    @Test func extendedGrvCarriesImuVectors() throws {
        func i32(_ v: Int32) -> String {
            withUnsafeBytes(of: v.littleEndian) { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }
        }
        let quat = "10 27 00 00 00 00 00 00"
        let vecA = [i32(1 << 26), i32(-(1 << 25)), i32(0)].joined(separator: " ")       // 1, -0.5, 0
        let vecB = [i32(0), i32(1 << 25), i32(-(1 << 26))].joined(separator: " ")      // 0, 1, -2
        let s = try Self.motion("20 \(quat) \(vecA) \(vecB) \(i32(80)) 01")
        #expect(s.count == 1)
        #expect(s[0].gyro == [1, -0.5, 0])
        #expect(s[0].accel == [0, 1, -2])
        #expect(s[0].bud == 1)
    }

    @Test func batchedGrvYieldsEverySample() throws {
        let s = try Self.motion("20 03 10 27 00 00 00 00 00 00 88 13 88 13 88 13 88 13 00 00 10 27 00 00 00 00 00")
        #expect(s.map(\.q.w) == [1, 0.5, 0])
        #expect(s[2].q.x == 1)
    }

    @Test func truncatedGrvIsRejected() {
        #expect(BudsEvent(SppMessage(id: 0xC2, payload: [0x20, 0x00, 0x00])) == nil)
    }

    @Test func sensorSupported() {
        #expect(BudsEvent(SppMessage(id: 0xC2, payload: [0x25, 0x01])) == .sensorSupported(true))
        #expect(BudsEvent(SppMessage(id: 0xC2, payload: [0x25, 0x00])) == .sensorSupported(false))
    }

    /// 0xC6 neck-posture records: [len, type, subtype, seq, int16…]; type 12/sub 14 = accel/1000.
    @Test func neckCalibrationAccelRecords() {
        let r1: [UInt8] = [10, 12, 14, 0, 0xE8, 0x03, 0x18, 0xFC, 0xF4, 0x01] // 1000, -1000, 500
        let r2: [UInt8] = [10, 12, 14, 1, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00] // 0, 100, 0
        let event = BudsEvent(SppMessage(id: 0xC6, payload: r1 + r2))
        #expect(event == .rawAccel([[1, -1, 0.5], [0, 0.1, 0]]))
    }

    @Test func neckRecordsOfOtherTypesAreIgnored() {
        let context: [UInt8] = [14, 10, 0, 0, 1, 0, 2, 0, 1, 0, 0, 0, 0, 0]
        #expect(BudsEvent(SppMessage(id: 0xC6, payload: context)) == nil)
    }

    @Test func spatialControlReplies() {
        #expect(BudsEvent(SppMessage(id: 0xC3, payload: [0x02])) == .sensorAttached)
        #expect(BudsEvent(SppMessage(id: 0xC3, payload: [0x03])) == .sensorDetached)
    }

    @Test func wearEventsFromSensorStream() {
        #expect(BudsEvent(SppMessage(id: 0xC2, payload: [0x21, 0x01])) == .sensorWear(on: true))
        #expect(BudsEvent(SppMessage(id: 0xC2, payload: [0x22, 0x00])) == .sensorWear(on: false))
    }

    @Test func statusUpdateBatteryAndPlacement() {
        // rev, battL 80, battR 75, coupled, main, placement L=wearing(1) R=case(3), case batt 50
        let msg = SppMessage(id: 0x60, payload: [0x0D, 80, 75, 1, 0, 0x13, 50, 0])
        #expect(BudsEvent(msg) == .status(batteryLeft: 80, batteryRight: 75, left: .wearing, right: .inCase))
    }

    @Test func extendedStatusCarriesSpatialSetting() {
        var payload = [UInt8](repeating: 0, count: 46)
        payload[2] = 80; payload[3] = 70; payload[6] = 0x11; payload[35] = 1; payload[41] = 0
        #expect(BudsEvent(SppMessage(id: 0x61, payload: payload))
            == .extendedStatus(batteryLeft: 80, batteryRight: 70, left: .wearing, right: .wearing,
                               spatialAudio: true, headTracking: false))
    }
}
