import Foundation
@testable import SecureCore
@testable import SecureStore

/// A wallet on disk in a temporary directory, with in-memory "Keychain" and a software key.
final class TestWallet: @unchecked Sendable {
    let name: String
    let directory: URL
    let secrets: InMemorySecretStore
    let signer: SoftwareSigner
    let configuration: WalletConfiguration
    var store: WalletStore
    var distanceMeters: Double = 0.4

    init(name: String, directory: URL, configuration: WalletConfiguration = TestWallet.simulatorConfig()) throws {
        self.name = name
        self.directory = directory
        self.secrets = InMemorySecretStore()
        self.signer = SoftwareSigner()
        self.configuration = configuration
        self.store = try WalletStore(directory: directory, name: name, secrets: secrets, walletKey: signer.publicKey,
                                     configuration: configuration)
    }

    static func simulatorConfig(isIssuer: Bool = false, acceptance: OfflineLimits = .none,
                                policy: ProximityPolicy = .simulator) -> WalletConfiguration {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return WalletConfiguration(currency: .usd, isIssuer: isIssuer, acceptanceLimits: acceptance, proximityPolicy: policy,
                                   calendar: calendar)
    }

    var publicKey: WalletPublicKey { signer.publicKey }
    var databaseURL: URL { directory.appendingPathComponent("\(name).sqlite") }

    var participant: PaymentParticipant {
        PaymentParticipant(store: store, signer: signer,
                           ranging: SimulatedRanging(trueDistanceMeters: distanceMeters, noiseMeters: 0.01, sampleCount: 15),
                           displayName: name)
    }

    @discardableResult
    func reopen() throws -> WalletStore {
        store = try WalletStore(directory: directory, name: name, secrets: secrets, walletKey: signer.publicKey,
                                configuration: configuration)
        return store
    }

    /// Copies the database file aside, like an attacker keeping an old copy.
    func snapshotDatabase() throws -> URL {
        let copy = directory.appendingPathComponent("\(name)-\(UUID().uuidString).copy")
        try FileManager.default.copyItem(at: databaseURL, to: copy)
        return copy
    }

    func restoreDatabase(from copy: URL) throws {
        try FileManager.default.removeItem(at: databaseURL)
        try FileManager.default.copyItem(at: copy, to: databaseURL)
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("securekit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func usd(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: .usd) }

/// An issuer, a member wallet and a shop, with $500 minted to the member.
struct Community {
    let directory: URL
    let issuer: TestWallet
    let member: TestWallet
    let shop: TestWallet

    init(memberAcceptance: OfflineLimits = .none) async throws {
        directory = try makeTemporaryDirectory()
        issuer = try TestWallet(name: "issuer", directory: directory, configuration: TestWallet.simulatorConfig(isIssuer: true))
        member = try TestWallet(name: "member", directory: directory,
                                configuration: TestWallet.simulatorConfig(acceptance: memberAcceptance))
        shop = try TestWallet(name: "shop", directory: directory)
        try await member.store.pinIssuer(issuer.publicKey)
        try await shop.store.pinIssuer(issuer.publicKey)
        _ = try await LoopbackPayment.run(from: issuer.participant, to: member.participant, amount: usd(50_000), categoryID: nil)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
