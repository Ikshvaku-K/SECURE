import CryptoKit
import Foundation
import LocalAuthentication
import Security
import SecureCore

extension SigningError {
    static func from(_ error: Error) -> SigningError {
        guard let laError = error as? LAError else { return .failed(error.localizedDescription) }
        switch laError.code {
        case .userCancel, .appCancel, .systemCancel, .userFallback:
            return .userCancelled
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout, .passcodeNotSet:
            return .biometryUnavailable(laError.localizedDescription)
        default:
            return .failed(laError.localizedDescription)
        }
    }
}

/// The wallet key lives in the Secure Enclave and never leaves it. Its access control requires a
/// biometric match for every use, so the hardware, not app code, enforces Face ID.
///
/// `.biometryAny` rather than `.biometryCurrentSet`: enrolling a face would otherwise destroy the key,
/// and with it a balance that can't be moved off the phone (DESIGN §3.1).
public final class SecureEnclaveSigner: TransactionSigner, @unchecked Sendable {
    public let publicKey: WalletPublicKey
    public let kind: SignerKind = .secureEnclave
    /// Encrypted key blob; only this phone's Secure Enclave can use it.
    private let keyData: Data

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    private init(keyData: Data, publicKey: P256.Signing.PublicKey) {
        self.keyData = keyData
        self.publicKey = WalletPublicKey(p256: publicKey)
    }

    static func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                            [.privateKeyUsage, .biometryAny], &error) else {
            throw SigningError.failed(error.map { String(describing: $0.takeRetainedValue()) } ?? "access control")
        }
        return control
    }

    /// Loads the key blob stored under `account`, or creates a new key in the Secure Enclave.
    public static func loadOrCreate(account: String, secrets: any SecretStore) throws -> SecureEnclaveSigner {
        if let data = try secrets.read(account) {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
            return SecureEnclaveSigner(keyData: data, publicKey: key.publicKey)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: try makeAccessControl())
        try secrets.write(key.dataRepresentation, account: account)
        return SecureEnclaveSigner(keyData: key.dataRepresentation, publicKey: key.publicKey)
    }

    public func authorize(reason: String) async throws -> any SigningSession {
        let context = LAContext()
        do {
            // One Face ID match authorizes this context for the key's signing operations.
            _ = try await context.evaluateAccessControl(try Self.makeAccessControl(), operation: .useKeySign,
                                                        localizedReason: reason)
        } catch {
            throw SigningError.from(error)
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData, authenticationContext: context)
        return SecureEnclaveSession(key: key, context: context)
    }
}

final class SecureEnclaveSession: SigningSession, @unchecked Sendable {
    /// A session covers one transfer's few signatures; after this it must be re-approved.
    static let lifetime: TimeInterval = 60

    private let lock = NSLock()
    private var key: SecureEnclave.P256.Signing.PrivateKey?
    private let context: LAContext
    private let expiry = Date().addingTimeInterval(lifetime)

    init(key: SecureEnclave.P256.Signing.PrivateKey, context: LAContext) {
        self.key = key
        self.context = context
    }

    func sign(_ message: Data) async throws -> Data {
        let key = try lock.withLock { () throws -> SecureEnclave.P256.Signing.PrivateKey in
            guard let key, Date() < expiry else { throw SigningError.sessionExpired }
            return key
        }
        do {
            return try key.signature(for: message).rawRepresentation
        } catch {
            throw SigningError.from(error)
        }
    }

    func end() {
        lock.withLock { key = nil }
        context.invalidate()
    }
}

/// Simulator only. The Simulator has no Secure Enclave, so the key is a software key and Face ID is
/// checked by app code. On a phone, `SecureEnclaveSigner` is used and the hardware enforces it.
public struct SimulatorBiometricSigner: TransactionSigner {
    private let software: SoftwareSigner
    public let kind: SignerKind = .simulatorBiometric

    public var publicKey: WalletPublicKey { software.publicKey }

    public static func loadOrCreate(account: String, secrets: any SecretStore) throws -> SimulatorBiometricSigner {
        if let raw = try secrets.read(account) {
            return SimulatorBiometricSigner(software: try SoftwareSigner(rawRepresentation: raw))
        }
        let signer = SoftwareSigner()
        try secrets.write(signer.rawRepresentation, account: account)
        return SimulatorBiometricSigner(software: signer)
    }

    public func authorize(reason: String) async throws -> any SigningSession {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw SigningError.biometryUnavailable("Enroll Face ID in the Simulator: Features ▸ Face ID ▸ Enrolled")
        }
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            throw SigningError.from(error)
        }
        return try await software.authorize(reason: reason)
    }
}

public enum WalletSigners {
    /// Secure Enclave on a phone; a Face ID-gated software key on the Simulator.
    /// On a real device there is no software fallback: no Secure Enclave means no wallet.
    public static func loadOrCreate(account: String, secrets: any SecretStore) throws -> any TransactionSigner {
        #if targetEnvironment(simulator)
        return try SimulatorBiometricSigner.loadOrCreate(account: account, secrets: secrets)
        #else
        guard SecureEnclaveSigner.isAvailable else { throw SigningError.failed("This device has no Secure Enclave") }
        return try SecureEnclaveSigner.loadOrCreate(account: account, secrets: secrets)
        #endif
    }
}

public struct BiometryStatus: Sendable {
    public let name: String
    public let isAvailable: Bool
    public let message: String?

    public static func current() -> BiometryStatus {
        let context = LAContext()
        var error: NSError?
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let name = switch context.biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "Biometrics"
        }
        return BiometryStatus(name: name, isAvailable: available, message: error?.localizedDescription)
    }
}
