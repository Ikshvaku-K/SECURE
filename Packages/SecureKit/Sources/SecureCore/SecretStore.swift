import Foundation

/// Small secrets: the database key, the chain anchor, the Secure Enclave key blob.
/// On iOS this is the Keychain (`SecureDevice.KeychainSecretStore`); tests use `InMemorySecretStore`.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    /// Inserts or replaces.
    func write(_ data: Data, account: String) throws
    func delete(_ account: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init(_ items: [String: Data] = [:]) {
        self.items = items
    }

    public func read(_ account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    public func write(_ data: Data, account: String) throws {
        lock.withLock { items[account] = data }
    }

    public func delete(_ account: String) throws {
        _ = lock.withLock { items.removeValue(forKey: account) }
    }

    /// Copy of everything stored, for tests that simulate restoring an old Keychain.
    public func snapshot() -> [String: Data] {
        lock.withLock { items }
    }

    public func restore(_ snapshot: [String: Data]) {
        lock.withLock { items = snapshot }
    }
}
