import Foundation

// Minimal BER/ASN.1 encoder and decoder, just enough for SNMPv1 GET requests
// and parsing GetResponse PDUs. Not a general-purpose ASN.1 library.

enum BERTag: UInt8 {
    case integer = 0x02
    case octetString = 0x04
    case null = 0x05
    case objectIdentifier = 0x06
    case sequence = 0x30
    // SNMP PDU context tags
    case getRequestPDU = 0xA0
    case getNextRequestPDU = 0xA1
    case getResponsePDU = 0xA2
    case setRequestPDU = 0xA3
    case trapPDU = 0xA4
}

struct BERValue {
    let tag: UInt8
    let bytes: [UInt8] // raw content bytes for primitives; not recursively parsed here
}

enum BER {

    // MARK: - Encoding

    static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        }
        var lengthBytes: [UInt8] = []
        var len = length
        while len > 0 {
            lengthBytes.insert(UInt8(len & 0xFF), at: 0)
            len >>= 8
        }
        return [UInt8(0x80 | lengthBytes.count)] + lengthBytes
    }

    static func encodeTLV(tag: UInt8, content: [UInt8]) -> [UInt8] {
        return [tag] + encodeLength(content.count) + content
    }

    static func encodeInteger(_ value: Int) -> [UInt8] {
        let v = value
        var bytes: [UInt8] = []
        if v == 0 {
            bytes = [0x00]
        } else {
            let negative = v < 0
            var mag: [UInt8] = []
            var uv = UInt(bitPattern: v)
            if !negative {
                // build minimal big-endian representation
                var tmp = v
                while tmp != 0 {
                    mag.insert(UInt8(tmp & 0xFF), at: 0)
                    tmp >>= 8
                }
                if mag.isEmpty { mag = [0] }
                if mag[0] & 0x80 != 0 { mag.insert(0x00, at: 0) } // avoid sign ambiguity
                bytes = mag
            } else {
                // two's complement minimal encoding for negative numbers
                var byteCount = 1
                while true {
                    let bits = byteCount * 8
                    let minVal = -(1 << (bits - 1))
                    if v >= minVal { break }
                    byteCount += 1
                }
                uv = UInt(bitPattern: v) & (byteCount >= 8 ? UInt.max : (UInt(1) << (byteCount * 8)) - 1)
                var tmp = uv
                for _ in 0..<byteCount {
                    bytes.insert(UInt8(tmp & 0xFF), at: 0)
                    tmp >>= 8
                }
            }
        }
        return encodeTLV(tag: BERTag.integer.rawValue, content: bytes)
    }

    static func encodeOctetString(_ bytes: [UInt8]) -> [UInt8] {
        return encodeTLV(tag: BERTag.octetString.rawValue, content: bytes)
    }

    static func encodeOctetString(_ string: String) -> [UInt8] {
        return encodeOctetString(Array(string.utf8))
    }

    static func encodeNull() -> [UInt8] {
        return encodeTLV(tag: BERTag.null.rawValue, content: [])
    }

    static func encodeOID(_ dotted: String) -> [UInt8] {
        let parts = dotted.split(separator: ".").compactMap { Int($0) }
        precondition(parts.count >= 2, "OID needs at least two components")
        var content: [UInt8] = []
        let first = UInt8(parts[0] * 40 + parts[1])
        content.append(first)
        for value in parts.dropFirst(2) {
            content.append(contentsOf: encodeBase128(value))
        }
        return encodeTLV(tag: BERTag.objectIdentifier.rawValue, content: content)
    }

    private static func encodeBase128(_ value: Int) -> [UInt8] {
        if value == 0 { return [0x00] }
        var v = value
        var groups: [UInt8] = []
        while v > 0 {
            groups.insert(UInt8(v & 0x7F), at: 0)
            v >>= 7
        }
        for i in 0..<(groups.count - 1) {
            groups[i] |= 0x80
        }
        return groups
    }

    static func encodeSequence(_ content: [UInt8]) -> [UInt8] {
        return encodeTLV(tag: BERTag.sequence.rawValue, content: content)
    }

    static func encodeConstructed(tag: UInt8, content: [UInt8]) -> [UInt8] {
        return encodeTLV(tag: tag, content: content)
    }

    // MARK: - Decoding

    /// Parses one TLV starting at offset. Returns the tag, content bytes, and
    /// the offset immediately after this TLV.
    static func parseTLV(_ data: [UInt8], at offset: Int) throws -> (tag: UInt8, content: [UInt8], next: Int) {
        guard offset < data.count else { throw BERError.truncated }
        let tag = data[offset]
        var pos = offset + 1
        guard pos < data.count else { throw BERError.truncated }
        let firstLenByte = data[pos]
        pos += 1
        var length = 0
        if firstLenByte & 0x80 == 0 {
            length = Int(firstLenByte)
        } else {
            let numBytes = Int(firstLenByte & 0x7F)
            guard pos + numBytes <= data.count else { throw BERError.truncated }
            for _ in 0..<numBytes {
                length = (length << 8) | Int(data[pos])
                pos += 1
            }
        }
        guard pos + length <= data.count else { throw BERError.truncated }
        let content = Array(data[pos..<(pos + length)])
        return (tag, content, pos + length)
    }

    static func decodeInteger(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var value = 0
        let negative = (bytes[0] & 0x80) != 0
        for b in bytes {
            value = (value << 8) | Int(b)
        }
        if negative {
            // sign-extend for two's complement
            let bitWidth = bytes.count * 8
            if bitWidth < Int.bitWidth {
                value -= (1 << bitWidth)
            }
        }
        return value
    }

    static func decodeOID(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        var parts: [Int] = []
        let first = Int(bytes[0])
        parts.append(first / 40)
        parts.append(first % 40)
        var value = 0
        for b in bytes.dropFirst() {
            value = (value << 7) | Int(b & 0x7F)
            if b & 0x80 == 0 {
                parts.append(value)
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }
}

enum BERError: Error {
    case truncated
    case unexpectedTag(UInt8)
    case malformed(String)
}
