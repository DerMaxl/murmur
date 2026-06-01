import Foundation

/// Generates RFC 9562 version-7 UUIDs: a 48-bit Unix-millisecond timestamp followed
/// by random bits, so IDs are time-ordered (sortable) yet still unique. Foundation's
/// `UUID()` only produces random v4, so we build v7 ourselves.
enum UUIDv7 {
    static func generate() -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)

        // Bytes 0...5: milliseconds since the Unix epoch, big-endian.
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<6 {
            bytes[i] = UInt8((ms >> (8 * (5 - i))) & 0xFF)
        }
        // Bytes 6...15: random.
        for i in 6..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70   // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant

        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
