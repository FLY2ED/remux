import Foundation

/// Herdr's endpoint wire format, generation 1 (Herdr v0.9.3 `src/protocol/wire.rs`).
///
/// Every message in both directions is `[u32 little-endian payload length][payload]`, where the payload
/// is bincode 2 with `config::standard()`: little endian, variable-length integers, enums as a varint
/// variant index followed by their fields, structs as their fields in order.
enum HerdrWire {
    /// Largest payload Remux reads. Herdr caps server frames at 2 MiB, or 32 MiB when a surface
    /// carries images (`wire.rs:24, 29`), and Remux keeps images.
    static let maxPayloadSize = 32 * 1024 * 1024

    static func frame(_ payload: [UInt8]) -> [UInt8] {
        var framed = [UInt8]()
        framed.reserveCapacity(4 + payload.count)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { framed.append(contentsOf: $0) }
        framed.append(contentsOf: payload)
        return framed
    }
}

enum HerdrWireError: Error, Equatable, LocalizedError {
    case truncated
    case trailingBytes(Int)
    case invalidBool(UInt8)
    case invalidVarint(UInt8)
    case invalidOption(UInt8)
    case invalidUTF8
    case invalidBase64
    case invalidVariant(type: String, index: UInt32)
    case lengthOutOfRange(UInt64)
    case payloadTooLarge(Int)
    /// A generation-1 message type that Remux's endpoint connection never receives.
    case unexpectedMessage(tag: UInt32)
    /// A tag outside generation 1's frozen message set.
    case unknownMessage(tag: UInt32)
    case invalidControl(kind: String)
    /// A screen update that doesn't fit the decoder's baseline (`surface_reuse.rs` reasons).
    case invalidSurfaceUpdate(String)

    var errorDescription: String? {
        switch self {
        case .invalidSurfaceUpdate(let reason):
            return "Herdr sent a screen update Remux couldn't apply (\(reason))."
        case .unexpectedMessage(let tag):
            return "Herdr sent message type \(tag), which this connection never receives."
        case .unknownMessage(let tag):
            return "Herdr sent unknown message type \(tag)."
        case .invalidControl(let kind):
            return "Herdr sent an invalid \(kind) message."
        case .payloadTooLarge(let size):
            return "Herdr sent a \(size)-byte message, over Remux's limit."
        default:
            return "Herdr sent a message Remux couldn't decode."
        }
    }
}

/// Splits a byte stream into payloads. A declared length over the cap fails before its bytes arrive.
struct HerdrFrameSplitter {
    private var buffer: [UInt8] = []
    private var start = 0

    mutating func append(_ bytes: some Sequence<UInt8>) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete payload, or nil when more bytes are needed.
    mutating func nextPayload() throws -> [UInt8]? {
        guard buffer.count - start >= 4 else { return nil }
        let length = Int(
            UInt32(buffer[start])
                | UInt32(buffer[start + 1]) << 8
                | UInt32(buffer[start + 2]) << 16
                | UInt32(buffer[start + 3]) << 24
        )
        guard length <= HerdrWire.maxPayloadSize else {
            throw HerdrWireError.payloadTooLarge(length)
        }
        guard buffer.count - start - 4 >= length else { return nil }
        let payload = Array(buffer[(start + 4)..<(start + 4 + length)])
        start += 4 + length
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start >= 64 * 1024 {
            buffer.removeFirst(start)
            start = 0
        }
        return payload
    }
}

/// Reads bincode 2 `standard()` values. Every read checks the remaining length.
struct HerdrWireReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
    }

    var remaining: Int { bytes.count - offset }

    /// Herdr's reader requires every payload to be consumed exactly (`wire.rs:1702-1736`).
    func finish() throws {
        guard offset == bytes.count else {
            throw HerdrWireError.trailingBytes(bytes.count - offset)
        }
    }

    mutating func u8() throws -> UInt8 {
        guard offset < bytes.count else { throw HerdrWireError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bool() throws -> Bool {
        let value = try u8()
        switch value {
        case 0: return false
        case 1: return true
        default: throw HerdrWireError.invalidBool(value)
        }
    }

    mutating func u16() throws -> UInt16 {
        UInt16(try varint(widestMarker: 251))
    }

    mutating func u32() throws -> UInt32 {
        UInt32(try varint(widestMarker: 252))
    }

    mutating func u64() throws -> UInt64 {
        try varint(widestMarker: 253)
    }

    /// Zigzag, then varint.
    mutating func i32() throws -> Int32 {
        let zigzag = try u32()
        return Int32(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))
    }

    /// Enum variant index.
    mutating func variant() throws -> UInt32 {
        try u32()
    }

    mutating func byteArray() throws -> [UInt8] {
        let count = try length()
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func string() throws -> String {
        let count = try length()
        defer { offset += count }
        guard let value = String(validating: bytes[offset..<(offset + count)], as: UTF8.self) else {
            throw HerdrWireError.invalidUTF8
        }
        return value
    }

    /// serde `char`: its UTF-8 bytes, with no length prefix.
    mutating func character() throws -> Character {
        let lead = try u8()
        let width: Int
        switch lead {
        case 0x00..<0x80: width = 1
        case 0xC0..<0xE0: width = 2
        case 0xE0..<0xF0: width = 3
        case 0xF0..<0xF8: width = 4
        default: throw HerdrWireError.invalidUTF8
        }
        guard remaining >= width - 1 else { throw HerdrWireError.truncated }
        let start = offset - 1
        offset += width - 1
        guard let value = String(validating: bytes[start..<offset], as: UTF8.self),
              value.unicodeScalars.count == 1,
              let character = value.first
        else {
            throw HerdrWireError.invalidUTF8
        }
        return character
    }

    mutating func optional<T>(_ read: (inout HerdrWireReader) throws -> T) throws -> T? {
        let tag = try u8()
        switch tag {
        case 0: return nil
        case 1: return try read(&self)
        default: throw HerdrWireError.invalidOption(tag)
        }
    }

    mutating func array<T>(_ read: (inout HerdrWireReader) throws -> T) throws -> [T] {
        let count = try u64()
        // Every element takes at least one byte, so a count beyond the remaining bytes is corrupt;
        // checking first keeps a forged count from reserving memory.
        guard count <= UInt64(remaining) else { throw HerdrWireError.lengthOutOfRange(count) }
        var values = [T]()
        values.reserveCapacity(Int(count))
        for _ in 0..<count {
            values.append(try read(&self))
        }
        return values
    }

    private mutating func length() throws -> Int {
        let count = try u64()
        guard count <= UInt64(remaining) else { throw HerdrWireError.lengthOutOfRange(count) }
        return Int(count)
    }

    /// One byte up to 250 holds the value; 251, 252 and 253 announce a u16, u32 or u64 that follows.
    /// A marker wider than the type is invalid.
    private mutating func varint(widestMarker: UInt8) throws -> UInt64 {
        let first = try u8()
        if first <= 250 { return UInt64(first) }
        guard first <= widestMarker else { throw HerdrWireError.invalidVarint(first) }
        let width: Int
        switch first {
        case 251: width = 2
        case 252: width = 4
        default: width = 8
        }
        guard remaining >= width else { throw HerdrWireError.truncated }
        var value: UInt64 = 0
        for index in 0..<width {
            value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
        }
        offset += width
        return value
    }
}

/// Writes bincode 2 `standard()` values.
struct HerdrWireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func bool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    mutating func u16(_ value: UInt16) { varint(UInt64(value)) }
    mutating func u32(_ value: UInt32) { varint(UInt64(value)) }
    mutating func u64(_ value: UInt64) { varint(value) }
    mutating func variant(_ index: UInt32) { varint(UInt64(index)) }

    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        varint(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func byteArray(_ value: [UInt8]) {
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    /// serde `char`: its UTF-8 bytes, with no length prefix.
    mutating func character(_ value: Character) {
        bytes.append(contentsOf: Array(String(value).utf8))
    }

    mutating func optional<T>(_ value: T?, _ write: (inout HerdrWireWriter, T) -> Void) {
        guard let value else {
            bytes.append(0)
            return
        }
        bytes.append(1)
        write(&self, value)
    }

    mutating func array<T>(_ values: [T], _ write: (inout HerdrWireWriter, T) -> Void) {
        varint(UInt64(values.count))
        for value in values {
            write(&self, value)
        }
    }

    private mutating func varint(_ value: UInt64) {
        switch value {
        case 0...250:
            bytes.append(UInt8(value))
        case 251...UInt64(UInt16.max):
            bytes.append(251)
            withUnsafeBytes(of: UInt16(value).littleEndian) { bytes.append(contentsOf: $0) }
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            bytes.append(252)
            withUnsafeBytes(of: UInt32(value).littleEndian) { bytes.append(contentsOf: $0) }
        default:
            bytes.append(253)
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
    }
}
