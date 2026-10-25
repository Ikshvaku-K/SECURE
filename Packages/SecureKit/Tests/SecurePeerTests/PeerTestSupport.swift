import Foundation
import Synchronization
import Testing
@testable import SecureCore
@testable import SecurePeer
@testable import SecureStore

func usd(_ minor: Int64) -> Money { Money(minorUnits: minor, currency: .usd) }

/// One simulated phone: an in-memory wallet with a software key.
final class Phone: Sendable {
    let name: String
    let store: WalletStore
    let signer: SoftwareSigner

    init(_ name: String, policy: ProximityPolicy = .simulator, issuer: Bool = false) throws {
        self.name = name
        signer = SoftwareSigner()
        store = try WalletStore(directory: nil, name: name, secrets: InMemorySecretStore(), walletKey: signer.publicKey,
                                configuration: WalletConfiguration(isIssuer: issuer, proximityPolicy: policy))
    }

    var participant: PaymentParticipant {
        PaymentParticipant(store: store, signer: signer, ranging: SimulatedRanging(), displayName: name)
    }

    /// Mints funds from a fresh issuer, as the app's Demo Issuer does.
    func fund(_ amount: Money) async throws {
        let issuer = try Phone("Issuer", issuer: true)
        _ = try await LoopbackPayment.run(from: issuer.participant, to: participant, amount: amount, categoryID: nil)
    }
}

/// A one-way in-memory link that can watch, rewrite or drop messages.
final class Wire: Sendable {
    typealias Filter = @Sendable (PeerMessage) -> PeerMessage?
    private let state = Mutex<(target: PeerConnection?, filter: Filter?)>((nil, nil))
    private let log = Mutex<[PeerMessage]>([])

    func connect(to target: PeerConnection) { state.withLock { $0.target = target } }
    func setFilter(_ filter: Filter?) { state.withLock { $0.filter = filter } }
    var messages: [PeerMessage] { log.withLock { $0 } }

    func send(_ data: Data) {
        let (target, filter) = state.withLock { ($0.target, $0.filter) }
        guard let target, let message = try? PeerMessage(encoded: data) else { return }
        log.withLock { $0.append(message) }
        guard let filter else { return target.deliver(data) }
        if let rewritten = filter(message) { target.deliver(rewritten.encoded) }
    }
}

final class EventLog: Sendable {
    private let events = Mutex<[PeerEvent]>([])

    func append(_ event: PeerEvent) { events.withLock { $0.append(event) } }
    var all: [PeerEvent] { events.withLock { $0 } }

    var received: [PeerReceiveOutcome] {
        all.compactMap { if case .received(let outcome) = $0 { outcome } else { nil } }
    }
    var failures: [String] {
        all.compactMap { if case .receiveFailed(let text) = $0 { text } else { nil } }
    }
    var withdrawn: [OfferID] {
        all.compactMap { if case .offerWithdrawn(let id) = $0 { id } else { nil } }
    }
}

final class Counter: Sendable {
    private let value = Mutex<[IncomingOffer]>([])
    func record(_ offer: IncomingOffer) { value.withLock { $0.append(offer) } }
    var offers: [IncomingOffer] { value.withLock { $0 } }
}

/// Two phones joined by in-memory wires, both introduced.
struct Link {
    let payer: PeerConnection
    let payee: PeerConnection
    let toPayee: Wire
    let toPayer: Wire
    let payeeEvents: EventLog
    let offers: Counter
}

func connect(_ payer: Phone, _ payee: Phone, payerDistance: Double = 0.4, payeeDistance: Double = 0.4,
             payerTimeouts: PeerConnection.Timeouts = .init(), payeeTimeouts: PeerConnection.Timeouts = .init(),
             decide: @escaping PeerConnection.Decide = { _ in true }) async throws -> Link {
    let toPayee = Wire(), toPayer = Wire()
    let payeeEvents = EventLog(), offers = Counter()
    let a = PeerConnection(store: payer.store, signer: payer.signer, displayName: payer.name,
                           ranger: SimulatedPeerRanger(distanceMeters: payerDistance, seed: 1), timeouts: payerTimeouts,
                           send: { toPayee.send($0) }, decide: { _ in false }, events: { _ in })
    let b = PeerConnection(store: payee.store, signer: payee.signer, displayName: payee.name,
                           ranger: SimulatedPeerRanger(distanceMeters: payeeDistance, seed: 2), timeouts: payeeTimeouts,
                           send: { toPayer.send($0) },
                           decide: { offer in offers.record(offer); return await decide(offer) },
                           events: { payeeEvents.append($0) })
    toPayee.connect(to: b)
    toPayer.connect(to: a)
    try await a.start()
    try await b.start()
    try await waitUntil {
        let introduced = (await a.peer, await b.peer)
        return introduced.0 != nil && introduced.1 != nil
    }
    return Link(payer: a, payee: b, toPayee: toPayee, toPayer: toPayer, payeeEvents: payeeEvents, offers: offers)
}

func waitUntil(timeout: Duration = .seconds(3), _ condition: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met in time")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
