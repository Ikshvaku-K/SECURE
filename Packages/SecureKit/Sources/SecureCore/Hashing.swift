import CryptoKit
import Foundation

extension Data {
    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// Lowercase hex, two characters per byte.
    public var hexString: String {
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(Self.hexDigits[Int(byte >> 4)])
            out.append(Self.hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Parses lowercase or uppercase hex. Returns nil for odd lengths or non-hex characters.
    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = Self.nibble(chars[index]), let low = Self.nibble(chars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// A 32-byte SHA-256 value: chain links, transfer IDs, proof hashes, session nonces.
public struct Digest32: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 32
    public static let zero = Digest32(unchecked: Data(count: byteCount))

    public let bytes: Data

    public init?(_ bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Data(bytes)
    }

    init(unchecked bytes: Data) {
        self.bytes = Data(bytes)
    }

    public var hex: String { bytes.hexString }

    /// First 8 bytes in hex, for display.
    public var short: String { String(hex.prefix(16)) }

    public var description: String { short }
}

/// Domain-separation tags. Every hash and signature in the protocol commits to one of these,
/// so bytes signed for one purpose can never be replayed as another.
public enum DomainTag: String, Sendable, CaseIterable {
    case link = "SECURE/link/v1"
    case genesis = "SECURE/genesis/v1"
    case session = "SECURE/session/v1"
    case measurement = "SECURE/measurement/v1"
    case proof = "SECURE/proof/v1"
    case transfer = "SECURE/transfer/v1"
    case receipt = "SECURE/receipt/v1"
}

public enum TaggedHash {
    /// SHA-256 over the length-prefixed tag followed by `body`.
    public static func sha256(_ tag: DomainTag, _ body: Data) -> Digest32 {
        var hasher = SHA256()
        hasher.update(data: tagPrefix(tag))
        hasher.update(data: body)
        return Digest32(unchecked: Data(hasher.finalize()))
    }

    /// The exact bytes handed to a signer: length-prefixed tag followed by `body`.
    public static func signingPayload(_ tag: DomainTag, _ body: Data) -> Data {
        tagPrefix(tag) + body
    }

    private static func tagPrefix(_ tag: DomainTag) -> Data {
        var writer = CanonicalWriter()
        writer.writeString(tag.rawValue)
        return writer.data
    }
}
