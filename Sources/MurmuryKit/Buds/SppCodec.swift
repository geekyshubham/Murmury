import Foundation

/// One decoded Samsung SPP message: `FD | hdr(LE16) | id | payload | crc(LE16) | DD`.
struct SppMessage: Equatable, Sendable {
    var id: UInt8
    var payload: [UInt8]
}

enum SppCodec {
    static let som: UInt8 = 0xFD
    static let eom: UInt8 = 0xDD

    /// CRC-16/XMODEM (poly 0x1021, init 0, no reflection, no final XOR).
    static func crc16(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    /// Encodes a host → buds request (type and fragment bits clear).
    static func encode(id: UInt8, payload: [UInt8] = []) -> [UInt8] {
        let size = UInt16(1 + payload.count + 2)
        let crc = crc16([id] + payload)
        return [som, UInt8(size & 0xFF), UInt8(size >> 8), id] + payload
            + [UInt8(crc & 0xFF), UInt8(crc >> 8), eom]
    }
}

/// Length-driven stream reassembler. Marker bytes can appear inside payloads (no byte
/// stuffing), so frames are delimited by the header length, then validated by EOM and CRC;
/// on any mismatch one byte is dropped and the scan resumes.
struct SppDecoder {
    private var buffer: [UInt8] = []
    private(set) var droppedBytes = 0

    mutating func feed(_ bytes: [UInt8]) -> [SppMessage] {
        buffer += bytes
        var out: [SppMessage] = []
        var start = 0
        scan: while start < buffer.count {
            switch frame(at: start) {
            case .valid(let msg, let total):
                out.append(msg)
                start += total
            case .invalid:
                start += 1
                droppedBytes += 1
            case .incomplete:
                // A stray 0xFD can claim a long frame and stall the stream. If a complete,
                // valid frame starts later in the buffer, the candidate here is noise.
                var next = start + 1
                while next < buffer.count {
                    if case .valid = frame(at: next) {
                        droppedBytes += next - start
                        start = next
                        continue scan
                    }
                    next += 1
                }
                break scan
            }
        }
        buffer.removeFirst(start)
        return out
    }

    private enum Candidate { case valid(SppMessage, Int), invalid, incomplete }

    private func frame(at i: Int) -> Candidate {
        guard buffer[i] == SppCodec.som else { return .invalid }
        guard buffer.count - i >= 4 else { return .incomplete }
        let size = (Int(buffer[i + 1]) | Int(buffer[i + 2]) << 8) & 0x3FF
        guard size >= 3 else { return .invalid }
        let total = size + 4
        guard buffer.count - i >= total else { return .incomplete }
        guard buffer[i + total - 1] == SppCodec.eom else { return .invalid }
        let body = buffer[(i + 3)..<(i + 3 + size)]
        let crc = UInt16(body[body.endIndex - 2]) | UInt16(body[body.endIndex - 1]) << 8
        guard SppCodec.crc16(body.dropLast(2)) == crc else { return .invalid }
        return .valid(SppMessage(id: body[body.startIndex], payload: Array(body.dropFirst().dropLast(2))), total)
    }
}
