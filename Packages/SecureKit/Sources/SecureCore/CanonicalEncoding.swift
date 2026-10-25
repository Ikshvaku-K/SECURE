import Foundation

public enum CanonicalError: Error, Equatable, Sendable {
    case truncated
    case trailingBytes(Int)
    case fieldTooLarge(Int)
    case invalidValue(String)
    case unsupportedVersion(UInt8)
}

/// Deterministic binary encoding for everything that gets hashed or signed.
/// Big-endian integers, fixed field order, `UInt32` length prefixes, one presence byte for optionals.
public struct CanonicalWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    public mutating func writeU8(_ value: UInt8) { data.append(value) }
    public mutating func writeU16(_ value: UInt16) { appendBigEndian(value) }
    public mutating func writeU32(_ value: UInt32) { appendBigEndian(value) }
    public mutating func writeU64(_ value: UInt64) { appendBigEndian(value) }
    public mutating func writeI16(_ value: Int16) { writeU16(UInt16(bitPattern: value)) }
    public mutating func writeI64(_ value: Int64) { writeU64(UInt64(bitPattern: value)) }
    public mutating func writeBool(_ value: Bool) { writeU8(value ? 1 : 0) }

    /// Length-prefixed bytes.
    public mutating func writeBytes(_ bytes: Data) {
        precondition(bytes.count <= CanonicalReader.maxFieldLength, "field exceeds canonical size limit")
        writeU32(UInt32(bytes.count))
        data.append(bytes)
    }

    /// Bytes whose length is fixed by the format (digests, nonces): no prefix.
    public mutating func writeFixed(_ bytes: Data) { data.append(bytes) }

    public mutating func writeDigest(_ digest: Digest32) { writeFixed(digest.bytes) }

    public mutating func writeString(_ value: String) { writeBytes(Data(value.utf8)) }

    public mutating func writeOptional<T>(_ value: T?, _ body: (inout CanonicalWriter, T) -> Void) {
        guard let value else { return writeU8(0) }
        writeU8(1)
        body(&self, value)
    }

    private mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

public struct CanonicalReader {
    /// Upper bound for any single length-prefixed field; rejects oversized payloads early.
    public static let maxFieldLength = 64 * 1024

    private let data: Data
    private var offset = 0

    public init(_ data: Data) {
        self.data = Data(data)  // re-base indices at zero
    }

    public var isAtEnd: Bool { offset == data.count }

    public mutating func readU8() throws -> UInt8 { try take(1)[0] }
    public mutating func readU16() throws -> UInt16 { try readBigEndian() }
    public mutating func readU32() throws -> UInt32 { try readBigEndian() }
    public mutating func readU64() throws -> UInt64 { try readBigEndian() }
    public mutating func readI16() throws -> Int16 { Int16(bitPattern: try readU16()) }
    public mutating func readI64() throws -> Int64 { Int64(bitPattern: try readU64()) }

    public mutating func readBool() throws -> Bool {
        switch try readU8() {
        case 0: return false
        case 1: return true
        case let other: throw CanonicalError.invalidValue("bool byte \(other)")
        }
    }

    public mutating func readBytes() throws -> Data {
        let length = Int(try readU32())
        guard length <= Self.maxFieldLength else { throw CanonicalError.fieldTooLarge(length) }
        return try take(length)
    }

    public mutating func readFixed(_ count: Int) throws -> Data { try take(count) }

    public mutating func readDigest() throws -> Digest32 {
        Digest32(unchecked: try take(Digest32.byteCount))
    }

    public mutating func readString() throws -> String {
        let bytes = try readBytes()
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw CanonicalError.invalidValue("string is not UTF-8")
        }
        return string
    }

    public mutating func readOptional<T>(_ body: (inout CanonicalReader) throws -> T) throws -> T? {
        try readBool() ? try body(&self) : nil
    }

    /// Call after the last field: rejects trailing garbage.
    public func finish() throws {
        guard isAtEnd else { throw CanonicalError.trailingBytes(data.count - offset) }
    }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.count - offset >= count else { throw CanonicalError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    private mutating func readBigEndian<T: FixedWidthInteger>() throws -> T {
        let bytes = try take(MemoryLayout<T>.size)
        return bytes.reduce(T.zero) { $0 << 8 | T($1) }
    }
}
