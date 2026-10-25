import Foundation
@preconcurrency import MultipeerConnectivity
import Observation
import SecureCore
import SecurePeer
import SecureStore

/// Phone-to-phone payments. While the Nearby screen is open, this phone is visible to nearby phones running the
/// app, connects to them, and runs one `PeerConnection` (the payment protocol) and one ranger per phone.
@Observable
final class NearbyModel {
    struct Phone: Identifiable {
        let id: MCPeerID
        var identity: PeerIdentity?
        /// Live UWB distance in metres; nil until the first fix.
        var distance: Double?
        var simulatedRanging: Bool
        var pending: [LedgerEntry] = []

        var name: String { identity?.displayName ?? id.displayName }
        var isReady: Bool { identity != nil }
    }

    struct Progress: Equatable {
        let peerName: String
        let step: PeerPaymentStep
    }

    private(set) var isRunning = false
    private(set) var phones: [Phone] = []
    private(set) var progress: Progress?
    /// An offer from another phone waiting for this user's decision.
    var incoming: IncomingOffer?
    /// A payment request from another phone waiting for this user's decision.
    var incomingRequest: IncomingRequest?
    var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: Self.nameKey) }
    }

    private weak var model: AppModel?
    private var link: (any NearbyLink)?
    private var connections: [MCPeerID: PeerConnection] = [:]
    private var decision: (id: OfferID, continuation: CheckedContinuation<Bool, Never>)?
    private var requestDecision: (id: OfferID, continuation: CheckedContinuation<RequestAnswer?, Never>)?

    private static let nameKey = "nearbyDisplayName"

    init() {
        displayName = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
    }

    // MARK: - Lifecycle

    func start(_ model: AppModel) {
        guard !isRunning else { return }
        self.model = model
        if displayName.isEmpty { displayName = "S.E.C.U.R.E · \(model.diagnostics.walletFingerprint.prefix(4))" }
        let onEvent: (NearbyLinkEvent) -> Void = { [weak self] event in self?.handle(event) }
        #if targetEnvironment(simulator)
        // Two Simulators on one Mac can't complete a MultipeerConnectivity session; they use loopback TCP instead.
        let link: any NearbyLink = LoopbackLink(onEvent: onEvent)
        #else
        let link: any NearbyLink = MultipeerLink(displayName: displayName, onEvent: onEvent)
        #endif
        self.link = link
        link.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        link?.stop()
        link = nil
        for connection in connections.values { Task { await connection.close() } }
        connections.removeAll()
        phones.removeAll()
        isRunning = false
        resolveDecision(false)
        resolveRequestDecision(nil)
    }

    // MARK: - Paying

    func pay(_ phoneID: MCPeerID, amount: Money, categoryID: Int64?, overrideOverBudget: Bool) async -> Bool {
        guard let connection = connections[phoneID], let phone = phones.first(where: { $0.id == phoneID }) else { return false }
        do {
            let outcome = try await connection.pay(amount: amount, categoryID: categoryID, overrideOverBudget: overrideOverBudget)
            progress = nil
            model?.banner = Banner(kind: .success, text: "Paid \(amount.formatted()) to \(phone.name) · \(outcome.distanceCM) cm apart")
            await model?.nearbyPaymentFinished(verdict: outcome.verdict)
            return true
        } catch {
            progress = nil
            model?.banner = Banner(kind: .error, text: PeerText.describe(error))
            await model?.nearbyPaymentFinished(verdict: nil)
            await refreshPending(phoneID)
            return false
        }
    }

    /// Re-sends a payment whose receipt never arrived; the other person confirms it with Face ID.
    func retry(_ entry: LedgerEntry, to phoneID: MCPeerID) async {
        guard let connection = connections[phoneID] else { return }
        do {
            try await connection.redeliver(entry)
            model?.banner = Banner(kind: .success, text: "Confirmed: \(entry.amount.formatted())")
        } catch {
            model?.banner = Banner(kind: .error, text: PeerText.describe(error))
        }
        progress = nil
        await model?.nearbyPaymentFinished(verdict: nil)
        await refreshPending(phoneID)
    }

    // MARK: - Requesting

    /// Asks a nearby phone to pay this amount. This phone approves with Face ID when the payment arrives.
    func request(_ phoneID: MCPeerID, amount: Money, note: String?) async -> Bool {
        guard let connection = connections[phoneID] else { return false }
        do {
            _ = try await connection.request(amount: amount, note: note)
            // The "Received…" banner comes from the payment's own event.
            progress = nil
            return true
        } catch {
            progress = nil
            model?.banner = Banner(kind: .error, text: PeerText.describe(error))
            return false
        }
    }

    /// The user's answer to an incoming request: a category (and over-budget approval) to pay, or nil to decline.
    func answerRequest(_ answer: RequestAnswer?) {
        incomingRequest = nil
        resolveRequestDecision(answer)
    }

    private func askToPay(_ request: IncomingRequest) async -> RequestAnswer? {
        resolveRequestDecision(nil)
        return await withCheckedContinuation { continuation in
            requestDecision = (request.id, continuation)
            incomingRequest = request
        }
    }

    private func resolveRequestDecision(_ answer: RequestAnswer?) {
        guard let pending = requestDecision else { return }
        requestDecision = nil
        pending.continuation.resume(returning: answer)
    }

    // MARK: - Receiving

    func answer(_ accept: Bool) {
        incoming = nil
        resolveDecision(accept)
    }

    private func ask(_ offer: IncomingOffer) async -> Bool {
        resolveDecision(false)
        return await withCheckedContinuation { continuation in
            decision = (offer.id, continuation)
            incoming = offer
        }
    }

    private func resolveDecision(_ accept: Bool) {
        guard let pending = decision else { return }
        decision = nil
        pending.continuation.resume(returning: accept)
    }

    // MARK: - Link events

    private func handle(_ event: NearbyLinkEvent) {
        switch event {
        case .connected(let peerID):
            guard connections[peerID] == nil, let access = model?.nearbyAccess else { return }
            let connection = makeConnection(for: peerID, wallet: access.wallet, signer: access.signer)
            connections[peerID] = connection
            if !phones.contains(where: { $0.id == peerID }) {
                phones.append(Phone(id: peerID, simulatedRanging: !NearbyRanger.isSupported || NearbyRanger.readingsAreSimulated))
            }
            Task { try? await connection.start() }
        case .disconnected(let peerID):
            let gone = phones.first { $0.id == peerID }
            let key = gone?.identity?.walletKey
            if let connection = connections.removeValue(forKey: peerID) { Task { await connection.close() } }
            phones.removeAll { $0.id == peerID }
            if let incoming, incoming.from.walletKey == key {
                self.incoming = nil
                resolveDecision(false)
            }
            if let incomingRequest, incomingRequest.from.walletKey == key {
                self.incomingRequest = nil
                resolveRequestDecision(nil)
            }
            if let gone, progress?.peerName == gone.name { progress = nil }
        case .received(let data, let peerID):
            connections[peerID]?.deliver(data)
        }
    }

    private func makeConnection(for peerID: MCPeerID, wallet: WalletStore, signer: any TransactionSigner) -> PeerConnection {
        let box = PeerBox(peerID)
        let ranger: any PeerRanger
        if NearbyRanger.isSupported {
            ranger = NearbyRanger { [weak self] distance in
                Task { @MainActor in self?.update(box.peerID) { $0.distance = distance } }
            }
        } else {
            // The Simulator has no UWB. Simulated readings are flagged and only accepted by debug builds.
            ranger = SimulatedPeerRanger(distanceMeters: 0.4)
        }
        return PeerConnection(
            store: wallet, signer: signer, displayName: displayName, ranger: ranger,
            send: { [weak self] data in try await MainActor.run { try self?.link?.send(data, to: box.peerID) } },
            decide: { [weak self] offer in await self?.ask(offer) ?? false },
            decideRequest: { [weak self] request in await self?.askToPay(request) ?? nil },
            events: { [weak self] event in Task { @MainActor in self?.handle(event, from: box.peerID) } })
    }

    private func handle(_ event: PeerEvent, from peerID: MCPeerID) {
        let name = phones.first { $0.id == peerID }?.name ?? peerID.displayName
        switch event {
        case .connected(let identity):
            NearbyNames.remember(identity)
            update(peerID) { $0.identity = identity }
            Task { await refreshPending(peerID) }
        case .step(let step):
            progress = Progress(peerName: name, step: step)
        case .received(let outcome):
            progress = nil
            model?.banner = Banner(kind: .success, text: outcome.wasDuplicate
                                   ? "Confirmed \(outcome.amount.formatted()) from \(outcome.from.displayName)"
                                   : "Received \(outcome.amount.formatted()) from \(outcome.from.displayName) · \(outcome.distanceCM) cm apart")
            Task { await model?.nearbyPaymentFinished(verdict: nil) }
        case .receiveFailed(let reason):
            progress = nil
            if reason != "Declined." { model?.banner = Banner(kind: .error, text: reason) }
        case .paid(let outcome, let payee):
            progress = nil
            model?.banner = Banner(kind: .success, text: "Paid \(outcome.entry.amount.formatted()) to \(payee.displayName) · \(outcome.distanceCM) cm apart")
            Task { await model?.nearbyPaymentFinished(verdict: outcome.verdict) }
        case .payFailed(let reason):
            progress = nil
            model?.banner = Banner(kind: .error, text: reason)
            Task {
                await model?.nearbyPaymentFinished(verdict: nil)
                await refreshPending(peerID)
            }
        case .offerWithdrawn(let id):
            if incoming?.id == id { incoming = nil }
            if decision?.id == id { resolveDecision(false) }
            if incomingRequest?.id == id { incomingRequest = nil }
            if requestDecision?.id == id { resolveRequestDecision(nil) }
            progress = nil
        case .rangingUnavailable(let reason):
            model?.banner = Banner(kind: .error, text: "Distance unavailable: \(reason)")
        }
    }

    private func refreshPending(_ peerID: MCPeerID) async {
        guard let connection = connections[peerID] else { return }
        let pending = (try? await connection.pendingDeliveries()) ?? []
        update(peerID) { $0.pending = pending }
    }

    private func update(_ peerID: MCPeerID, _ change: (inout Phone) -> Void) {
        guard let index = phones.firstIndex(where: { $0.id == peerID }) else { return }
        change(&phones[index])
    }
}

/// Lets an `MCPeerID` (immutable once created) cross into the payment engine's closures.
private struct PeerBox: @unchecked Sendable {
    let peerID: MCPeerID
    init(_ peerID: MCPeerID) { self.peerID = peerID }
}

/// Names that nearby phones introduced themselves with, so the activity list can show "Bob" instead of a key.
/// Unverified labels, kept on this phone only.
enum NearbyNames {
    private static let key = "nearbyNames"

    static func remember(_ identity: PeerIdentity) {
        var names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        names[identity.walletKey.fingerprint] = identity.displayName
        UserDefaults.standard.set(names, forKey: key)
    }

    static func name(for key: WalletPublicKey) -> String? {
        (UserDefaults.standard.dictionary(forKey: self.key) as? [String: String])?[key.fingerprint]
    }
}
