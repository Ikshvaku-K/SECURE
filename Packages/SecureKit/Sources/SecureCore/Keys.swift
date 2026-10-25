import CryptoKit
import Foundation

/// Carried in every key and payload so another algorithm (e.g. ML-DSA) can be added without a format break.
public enum SignatureAlgorithm: UInt8, Sendable, CaseIterable {
    case p256ECDSA = 1
}

public enum KeyError: Error, Equatable, Sendable {
    case unsupportedAlgorithm(UInt8)
    case invalidPublicKey
}

/// A wallet's public identity: algorithm plus key bytes (P-256: 33-byte SEC1 compressed point).
public struct WalletPublicKey: Hashable, Sendable, CustomStringConvertible {
    public let algorithm: SignatureAlgorithm
    public let bytes: Data

    public init(algorithm: SignatureAlgorithm, bytes: Data) throws {
        switch algorithm {
        case .p256ECDSA:
            guard bytes.count == 33, (try? P256.Signing.PublicKey(compressedRepresentation: bytes)) != nil else {
                throw KeyError.invalidPublicKey
            }
        }
        self.algorithm = algorithm
        self.bytes = Data(bytes)
    }

    public init(p256 key: P256.Signing.PublicKey) {
        self.algorithm = .p256ECDSA
        self.bytes = key.compressedRepresentation
    }

    /// Verifies a raw 64-byte (r ‖ s) ECDSA signature over `message`.
    public func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        switch algorithm {
        case .p256ECDSA:
            guard let key = try? P256.Signing.PublicKey(compressedRepresentation: bytes),
                  let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature)
            else { return false }
            return key.isValidSignature(ecdsa, for: message)
        }
    }

    /// Short, human-comparable fingerprint: first 8 bytes of SHA-256 in four groups.
    public var fingerprint: String {
        let hex = Data(SHA256.hash(data: bytes)).hexString.prefix(16)
        return stride(from: 0, to: 16, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    public var description: String { fingerprint }

    public func encode(to writer: inout CanonicalWriter) {
        writer.writeU8(algorithm.rawValue)
        writer.writeBytes(bytes)
    }

    public static func decode(from reader: inout CanonicalReader) throws -> WalletPublicKey {
        let raw = try reader.readU8()
        guard let algorithm = SignatureAlgorithm(rawValue: raw) else { throw KeyError.unsupportedAlgorithm(raw) }
        return try WalletPublicKey(algorithm: algorithm, bytes: try reader.readBytes())
    }

    public var canonicalBytes: Data {
        var writer = CanonicalWriter()
        encode(to: &writer)
        return writer.data
    }

    public init(canonicalBytes: Data) throws {
        var reader = CanonicalReader(canonicalBytes)
        self = try WalletPublicKey.decode(from: &reader)
        try reader.finish()
    }
}
