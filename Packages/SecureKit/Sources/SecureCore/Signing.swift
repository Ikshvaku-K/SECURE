import CryptoKit
import Foundation

public enum SignerKind: String, Sendable {
    /// Key lives in the Secure Enclave; the hardware requires a Face ID match for every signature.
    case secureEnclave
    /// Software key behind an app-level Face ID check. Simulator only: the Simulator has no Secure Enclave.
    case simulatorBiometric
    /// Software key, no user check. Tests and the in-app demo peer.
    case software
}

public enum SigningError: Error, Equatable, Sendable {
    case userCancelled
    case biometryUnavailable(String)
    case sessionExpired
    case failed(String)
}

/// Signs protocol messages. One Face ID approval opens a short session that can sign the
/// handful of messages a single transfer needs (measurement, transfer or receipt).
public protocol TransactionSigner: Sendable {
    var publicKey: WalletPublicKey { get }
    var kind: SignerKind { get }
    /// `reason` is the text of the Face ID prompt, e.g. "Pay $25.00 to Alex".
    func authorize(reason: String) async throws -> any SigningSession
}

public protocol SigningSession: Sendable {
    /// Returns a raw 64-byte (r ‖ s) ECDSA signature over `message`.
    func sign(_ message: Data) async throws -> Data
    /// Ends the session early; later `sign` calls fail.
    func end()
}

public struct SoftwareSigner: TransactionSigner {
    private let privateKey: P256.Signing.PrivateKey
    public let kind: SignerKind = .software

    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.privateKey = privateKey
    }

    public init(rawRepresentation: Data) throws {
        self.privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }

    public var publicKey: WalletPublicKey { WalletPublicKey(p256: privateKey.publicKey) }

    public func authorize(reason: String) async throws -> any SigningSession {
        SoftwareSigningSession(privateKey: privateKey)
    }

    /// Synchronous signing for tests and in-process peers.
    public func signNow(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }
}

/// A session over a software key. `end()` is honoured so it behaves like the hardware sessions.
public final class SoftwareSigningSession: SigningSession, @unchecked Sendable {
    private let privateKey: P256.Signing.PrivateKey
    private let lock = NSLock()
    private var ended = false

    public init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public func sign(_ message: Data) async throws -> Data {
        try lock.withLock {
            guard !ended else { throw SigningError.sessionExpired }
            return try privateKey.signature(for: message).rawRepresentation
        }
    }

    public func end() {
        lock.withLock { ended = true }
    }
}
