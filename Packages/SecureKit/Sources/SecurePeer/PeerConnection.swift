import Foundation
import SecureCore
import SecureStore
import Synchronization

/// The other phone, as it introduced itself. The name is unverified; the fingerprint identifies the wallet key.
public struct PeerIdentity: Equatable, Hashable, Sendable {
    public let walletKey: WalletPublicKey
    public let displayName: String
}

/// Where a payment is, for the progress view on either phone.
public enum PeerPaymentStep: Equatable, Sendable {
    /// Offer sent; the other person is deciding.
    case waitingForPeer
    /// Face ID on this phone.
    case approving
    /// Measuring the distance between the phones.
    case measuring
    /// Exchanging the proof, committing and countersigning.
    case confirming
}

/// A payment offered by the other phone, waiting for this user's decision.
public struct IncomingOffer: Equatable, Sendable, Identifiable {
    public let id: OfferID
    public let from: PeerIdentity
    public let amount: Money
    /// True when the payer is re-sending a payment it already committed (the first delivery wasn't confirmed).
    public let isRedelivery: Bool
}

/// A payment request from the other phone, waiting for this user's decision.
public struct IncomingRequest: Equatable, Sendable, Identifiable {
    public let id: OfferID
    public let from: PeerIdentity
    public let amount: Money
    public let note: String?
}

/// The payer's answer to a request: the category to charge, and whether an over-budget warning was accepted.
public struct RequestAnswer: Equatable, Sendable {
    public var categoryID: Int64?
    public var overrideOverBudget: Bool

    public init(categoryID: Int64?, overrideOverBudget: Bool = false) {
        self.categoryID = categoryID
        self.overrideOverBudget = overrideOverBudget
    }
}

public struct PeerPaymentOutcome: Sendable {
    public let entry: LedgerEntry
    public let receipt: SignedReceipt
    public let distanceCM: UInt16
    public let verdict: BudgetVerdict
}

public struct PeerReceiveOutcome: Sendable {
    public let entry: LedgerEntry
    public let amount: Money
    public let from: PeerIdentity
    public let distanceCM: UInt16
    public let wasDuplicate: Bool
}

public enum PeerError: Error, Equatable, Sendable {
    /// No `hello` from the other phone yet, or the link closed.
    case notConnected
    /// This connection is already carrying a payment.
    case busy
    /// The other phone stopped the payment and said why.
    case peer(PeerFailure)
    case timedOut
    case unexpectedMessage
    /// The payer's debit is committed and the transfer was sent, but no receipt came back.
    /// The entry stays in `pendingDeliveries()` until `redeliver(_:)` gets a receipt.
    case unconfirmed(seq: Int64)
}

/// Things the screen should know about, delivered off the main actor.
public enum PeerEvent: Sendable {
    case connected(PeerIdentity)
    case step(PeerPaymentStep)
    case received(PeerReceiveOutcome)
    case receiveFailed(String)
    /// This phone paid a request from the other phone.
    case paid(PeerPaymentOutcome, to: PeerIdentity)
    /// Paying a request from the other phone failed.
    case payFailed(String)
    /// The other phone withdrew an offer or request (or the decision timed out); dismiss its prompt.
    case offerWithdrawn(OfferID)
    case rangingUnavailable(String)
}

/// One link to one nearby phone, carrying the DESIGN §6 protocol with each side on its own phone.
/// It uses only the wallet's public steps (`preparePayment`, `preflightIncoming`, `commitDebit`, `acceptTransfer`,
/// `storeReceipt`), so every rule the wallet enforces in-process applies here unchanged.
///
/// Money safety: the payer commits its debit only after the payee has said "ready" for the exact amount, and hands
/// the transfer over only after committing. If the link drops after that, the payment is re-delivered from the
/// ledger with `redeliver(_:)`; the payee's `acceptTransfer` is idempotent, so it is never credited twice.
public actor PeerConnection {
    public typealias Send = @Sendable (Data) async throws -> Void
    public typealias Decide = @Sendable (IncomingOffer) async -> Bool
    /// Nil declines the request.
    public typealias DecideRequest = @Sendable (IncomingRequest) async -> RequestAnswer?
    public typealias Events = @Sendable (PeerEvent) -> Void

    public struct Timeouts: Sendable {
        /// Waiting for a person to accept an offer, a request or a re-delivery.
        public var decision: Duration
        /// The payee waiting for the payer's Face ID and measurement.
        public var payerApproval: Duration
        /// Machine-speed steps.
        public var step: Duration

        public init(decision: Duration = .seconds(90), payerApproval: Duration = .seconds(45), step: Duration = .seconds(20)) {
            self.decision = decision
            self.payerApproval = payerApproval
            self.step = step
        }
    }

    public nonisolated let store: WalletStore
    public nonisolated let signer: any TransactionSigner
    public nonisolated let displayName: String
    public nonisolated let timeouts: Timeouts

    public private(set) var peer: PeerIdentity?

    private let send: Send
    private let ranger: any PeerRanger
    private let decide: Decide
    private let decideRequest: DecideRequest
    private let events: Events
    private nonisolated let inbox: AsyncStream<Data>.Continuation
    private var closed = false
    private var busy = false
    private var activeIDs: Set<OfferID> = []
    private var mailbox: [OfferID: [PeerMessage]] = [:]
    private var waiters: [OfferID: (token: UUID, continuation: CheckedContinuation<PeerMessage, Error>)] = [:]
    /// Open prompts, by offer or request ID; `cancel` resolves one with its fallback answer.
    private var decisions: [OfferID: (once: Once, cancel: @Sendable () -> Void)] = [:]
    /// This phone's own outstanding request, resolved when the payer's payment completes or fails.
    private var pendingRequest: (id: OfferID, amount: Money, continuation: CheckedContinuation<PeerReceiveOutcome, Error>)?

    public init(store: WalletStore, signer: any TransactionSigner, displayName: String, ranger: any PeerRanger,
                timeouts: Timeouts = Timeouts(), send: @escaping Send, decide: @escaping Decide,
                decideRequest: @escaping DecideRequest = { _ in nil }, events: @escaping Events) {
        self.store = store
        self.signer = signer
        self.displayName = displayName
        self.ranger = ranger
        self.timeouts = timeouts
        self.send = send
        self.decide = decide
        self.decideRequest = decideRequest
        self.events = events
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        inbox = continuation
        Task { await self.consume(stream) }
    }

    /// Introduces this phone. Call once the link is up.
    public func start() async throws {
        try await transmit(.hello(PeerHello(walletKey: signer.publicKey, displayName: displayName,
                                            rangingToken: try await ranger.localToken)))
    }

    /// Hands over bytes received from the link. Order is preserved.
    public nonisolated func deliver(_ data: Data) {
        inbox.yield(data)
    }

    /// The link went away: pending waits fail, ranging stops.
    public func close() async {
        guard !closed else { return }
        closed = true
        inbox.finish()
        for (_, waiter) in waiters { waiter.continuation.resume(throwing: PeerError.notConnected) }
        waiters.removeAll()
        for (_, decision) in decisions { decision.cancel() }
        decisions.removeAll()
        resolveRequest(nil, with: .failure(PeerError.notConnected))
        await ranger.stop()
    }

    // MARK: - Paying

    /// Pays the connected phone. Budget and balance are checked before the other phone is contacted.
    public func pay(amount: Money, categoryID: Int64?, overrideOverBudget: Bool = false,
                    now: Date = Date()) async throws -> PeerPaymentOutcome {
        guard peer != nil, !closed else { throw PeerError.notConnected }
        guard !busy else { throw PeerError.busy }
        busy = true
        let id = OfferID.random()
        activeIDs.insert(id)
        defer { finish(id) }
        return try await runPayment(id, amount: amount, categoryID: categoryID, overrideOverBudget: overrideOverBudget, now: now)
    }

    /// The payer's steps. `id` is a fresh offer ID, or the ID of the request being answered.
    private func runPayment(_ id: OfferID, amount: Money, categoryID: Int64?, overrideOverBudget: Bool,
                            now: Date) async throws -> PeerPaymentOutcome {
        guard let peer, !closed else { throw PeerError.notConnected }
        let myKey = signer.publicKey

        let verdict = try await store.evaluate(amount: amount, categoryID: categoryID, now: now)
        if case .blocked(let reason) = verdict { throw StoreError.blocked(reason) }
        if case .overBudget = verdict, !overrideOverBudget { throw StoreError.needsOverride(verdict) }

        // 1. Offer with the payer's half of the session nonce; wait for the payee's decision and Face ID.
        let contribution = SessionNonce.randomContribution()
        events(.step(.waitingForPeer))
        try await transmit(.offer(PaymentOffer(id: id, payer: myKey, payee: peer.walletKey, amount: amount,
                                               payerContribution: contribution)))
        let answer: PeerMessage
        do {
            answer = try await next(id, timeout: timeouts.decision)
        } catch {
            // Withdraw the offer so the other phone's prompt closes.
            await abort(id, .cancelled, "\(displayName) stopped waiting.")
            throw error
        }
        guard case .reply(let reply) = answer else { throw await unexpected(id) }
        guard let payeeContribution = reply.payeeContribution else {
            throw PeerError.peer(PeerFailure(.declined, "\(peer.displayName) declined."))
        }
        let nonce = SessionNonce.derive(payerContribution: contribution, payeeContribution: payeeContribution)

        // 2. The payer's own checks inside the wallet, then Face ID.
        let draft: PaymentDraft
        do {
            draft = try await store.preparePayment(amount: amount, categoryID: categoryID, payee: peer.walletKey,
                                                   sessionNonce: nonce, now: now)
            if case .overBudget = draft.verdict, !overrideOverBudget { throw StoreError.needsOverride(draft.verdict) }
        } catch {
            await abort(id, .rejected, "The payer's wallet stopped the payment.")
            throw error
        }
        events(.step(.approving))
        let session: any SigningSession
        do {
            session = try await signer.authorize(reason: "Pay \(amount.formatted()) to \(peer.displayName)")
        } catch {
            await abort(id, .cancelled, "The payer didn't approve.")
            throw error
        }
        defer { session.end() }

        // 3. Both phones measure and sign; each checks the other's statement.
        events(.step(.measuring))
        let mine = try await measureAndSign(id, nonce: nonce, peerKey: peer.walletKey, session: session)
        try await transmit(.measurement(id, mine))
        let theirs = try await expectMeasurement(id, nonce: nonce, observer: peer.walletKey, subject: myKey,
                                                 timeout: timeouts.step)
        let proof = SpatialProof(payerSide: mine, payeeSide: theirs)

        // 4. The payee's "ready" must name this amount; the payer verifies the proof itself before committing.
        guard case .ready(_, let agreed) = try await next(id, timeout: timeouts.step) else { throw await unexpected(id) }
        guard agreed == amount else {
            await abort(id, .invalidMessage, "The amounts don't match.")
            throw PeerError.unexpectedMessage
        }
        let distance: UInt16
        do {
            distance = try proof.verify(sessionNonce: nonce, payer: myKey, payee: peer.walletKey,
                                        policy: store.configuration.proximityPolicy)
        } catch let failure as ProximityFailure {
            await abort(id, .proximity, PeerText.describe(failure))
            throw StoreError.proximity(failure)
        }

        // 5. Sign and commit the debit, then hand the transfer over.
        events(.step(.confirming))
        let transfer = draft.transfer(spatialProof: proof)
        let signed = SignedTransfer(transfer: transfer, signature: try await session.sign(transfer.signingPayload))
        let entry: LedgerEntry
        do {
            entry = try await store.commitDebit(signed, spatialProof: proof, categoryID: categoryID,
                                                overrideOverBudget: overrideOverBudget, now: now)
        } catch {
            await abort(id, .rejected, "The payer's wallet stopped the payment.")
            throw error
        }

        // The money has left this wallet. From here a failure leaves a payment to re-deliver, never a lost one.
        do {
            try await transmit(.transfer(id, signed, proof))
            guard case .receipt(_, let receipt) = try await next(id, timeout: timeouts.step) else { throw PeerError.unexpectedMessage }
            try await store.storeReceipt(receipt, now: now)
            return PeerPaymentOutcome(entry: entry, receipt: receipt, distanceCM: distance, verdict: draft.verdict)
        } catch {
            throw PeerError.unconfirmed(seq: entry.seq)
        }
    }

    /// Debits to this peer that have no receipt yet.
    public func pendingDeliveries() async throws -> [LedgerEntry] {
        guard let peer else { return [] }
        var pending: [LedgerEntry] = []
        for entry in try await store.entries(limit: 1_000)
        where entry.kind == .debit && entry.counterparty == peer.walletKey && entry.transfer != nil && entry.spatialProof != nil {
            if try await store.receipt(forEntryLink: entry.link) == nil { pending.append(entry) }
        }
        return pending
    }

    /// Re-sends a committed payment whose receipt never arrived. The payee confirms it with Face ID.
    @discardableResult
    public func redeliver(_ entry: LedgerEntry, now: Date = Date()) async throws -> SignedReceipt {
        guard let peer, !closed else { throw PeerError.notConnected }
        guard entry.kind == .debit, entry.counterparty == peer.walletKey,
              let signed = entry.transfer, let proof = entry.spatialProof else { throw PeerError.unexpectedMessage }
        guard !busy else { throw PeerError.busy }
        busy = true
        let id = OfferID.random()
        activeIDs.insert(id)
        defer { finish(id) }
        events(.step(.waitingForPeer))
        try await transmit(.transfer(id, signed, proof))
        guard case .receipt(_, let receipt) = try await next(id, timeout: timeouts.decision) else { throw await unexpected(id) }
        try await store.storeReceipt(receipt, now: now)
        return receipt
    }

    // MARK: - Requests

    /// Asks the connected phone to pay this amount. Returns once the payment has arrived and been countersigned;
    /// this phone still approves with Face ID when it does. Throws if the payer declines or doesn't answer.
    public func request(amount: Money, note: String? = nil) async throws -> PeerReceiveOutcome {
        guard let peer, !closed else { throw PeerError.notConnected }
        guard !busy, pendingRequest == nil else { throw PeerError.busy }
        guard amount.minorUnits > 0 else { throw StoreError.blocked(.invalidAmount) }
        busy = true
        defer { busy = false }
        let id = OfferID.random()
        let message = PeerMessage.request(PaymentRequest(id: id, payee: signer.publicKey, payer: peer.walletKey,
                                                         amount: amount, note: note))
        events(.step(.waitingForPeer))
        let timeout = timeouts.decision
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequest = (id, amount, continuation)
            Task {
                do { try await self.transmit(message) } catch { self.resolveRequest(id, with: .failure(error)) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.requestTimedOut(id)
            }
        }
    }

    /// No answer in time and no payment under way: withdraw the request so the payer's prompt closes.
    private func requestTimedOut(_ id: OfferID) async {
        guard pendingRequest?.id == id, !activeIDs.contains(id) else { return }
        resolveRequest(id, with: .failure(PeerError.timedOut))
        await abort(id, .cancelled, "\(displayName) withdrew the request.")
    }

    /// Ends this phone's outstanding request; `id` nil ends whichever is pending.
    private func resolveRequest(_ id: OfferID?, with result: Result<PeerReceiveOutcome, Error>) {
        guard let pending = pendingRequest, id == nil || pending.id == id else { return }
        pendingRequest = nil
        pending.continuation.resume(with: result)
    }

    /// The other phone asked this one to pay. The user picks a category and approves, or declines.
    private func handleRequest(_ request: PaymentRequest) async {
        guard let peer, !busy else {
            try? await transmit(.failure(request.id, PeerFailure(.busy, "\(displayName) is busy with another payment.")))
            return
        }
        guard request.payer == signer.publicKey, request.payee == peer.walletKey else {
            await abort(request.id, .invalidMessage, "The request isn't addressed to this wallet.")
            return
        }
        busy = true
        activeIDs.insert(request.id)
        defer { finish(request.id) }
        let decideRequest = decideRequest
        let incoming = IncomingRequest(id: request.id, from: peer, amount: request.amount, note: request.note)
        guard let answer = await ask(request.id, fallback: nil, { await decideRequest(incoming) }) else {
            await abort(request.id, .declined, "\(displayName) declined the request.")
            return
        }
        do {
            let outcome = try await runPayment(request.id, amount: request.amount, categoryID: answer.categoryID,
                                               overrideOverBudget: answer.overrideOverBudget, now: Date())
            events(.paid(outcome, to: peer))
        } catch {
            // Stops before the offer (budget, balance) still have to reach the payee; later steps already told it.
            await abort(request.id, .rejected, PeerText.describe(error))
            events(.payFailed(PeerText.describe(error)))
        }
    }

    // MARK: - Receiving

    private func handleOffer(_ offer: PaymentOffer) async {
        let answersRequest = pendingRequest?.id == offer.id
        guard let peer, !busy || answersRequest else {
            try? await transmit(.failure(offer.id, PeerFailure(.busy, "\(displayName) is busy with another payment.")))
            return
        }
        busy = true
        activeIDs.insert(offer.id)
        defer { finish(offer.id) }
        do {
            let outcome = try await receive(offer, from: peer)
            resolveRequest(offer.id, with: .success(outcome))
            events(.received(outcome))
        } catch {
            resolveRequest(offer.id, with: .failure(error))
            events(.receiveFailed(PeerText.describe(error)))
        }
    }

    private func receive(_ offer: PaymentOffer, from peer: PeerIdentity, now: Date = Date()) async throws -> PeerReceiveOutcome {
        let myKey = signer.publicKey
        guard offer.payee == myKey, offer.payer == peer.walletKey else {
            await abort(offer.id, .invalidMessage, "The offer isn't addressed to this wallet.")
            throw PeerError.unexpectedMessage
        }

        // 1. The user decides (unless this answers their own request for exactly this amount), then approves
        //    with Face ID before contributing to the nonce.
        let requested = pendingRequest.map { $0.id == offer.id && $0.amount == offer.amount } ?? false
        let decide = decide
        let incoming = IncomingOffer(id: offer.id, from: peer, amount: offer.amount, isRedelivery: false)
        guard requested ? true : await ask(offer.id, fallback: false, { await decide(incoming) }) else {
            try? await transmit(.reply(OfferReply(id: offer.id, payeeContribution: nil)))
            throw PeerError.peer(PeerFailure(.declined, "Declined."))
        }
        events(.step(.approving))
        let session: any SigningSession
        do {
            session = try await signer.authorize(reason: "Receive \(offer.amount.formatted()) from \(peer.displayName)")
        } catch {
            try? await transmit(.reply(OfferReply(id: offer.id, payeeContribution: nil)))
            throw error
        }
        defer { session.end() }
        let contribution = SessionNonce.randomContribution()
        try await transmit(.reply(OfferReply(id: offer.id, payeeContribution: contribution)))
        let nonce = SessionNonce.derive(payerContribution: offer.payerContribution, payeeContribution: contribution)

        // 2. Measure and sign; wait for the payer's Face ID and measurement.
        events(.step(.measuring))
        let mine = try await measureAndSign(offer.id, nonce: nonce, peerKey: offer.payer, session: session)
        try await transmit(.measurement(offer.id, mine))
        let theirs = try await expectMeasurement(offer.id, nonce: nonce, observer: offer.payer, subject: myKey,
                                                 timeout: timeouts.payerApproval)
        let proof = SpatialProof(payerSide: theirs, payeeSide: mine)

        // 3. Proof, acceptance limits and the payer's record; then "ready" for this amount.
        do {
            try await store.preflightIncoming(amount: offer.amount, payer: offer.payer, sessionNonce: nonce, spatialProof: proof)
        } catch {
            await abort(offer.id, Self.code(for: error), PeerText.describe(error))
            throw error
        }
        events(.step(.confirming))
        try await transmit(.ready(offer.id, offer.amount))

        // 4. The transfer must match what was agreed; record it and countersign.
        guard case .transfer(_, let signed, let sentProof) = try await next(offer.id, timeout: timeouts.step) else {
            throw await unexpected(offer.id)
        }
        guard sentProof == proof, signed.transfer.amount == offer.amount, signed.transfer.payer == offer.payer else {
            await abort(offer.id, .invalidMessage, "The transfer doesn't match the offer.")
            throw PeerError.unexpectedMessage
        }
        return try await acceptAndCountersign(offer.id, signed: signed, proof: proof, nonce: nonce, from: peer,
                                              session: session, now: now)
    }

    /// A payer re-sending a payment it committed earlier. The proof already carries this wallet's own signed
    /// measurement from that session, so only the user's confirmation and a fresh receipt signature are needed.
    private func handleRedelivery(_ id: OfferID, signed: SignedTransfer, proof: SpatialProof) async {
        guard let peer, !busy else {
            try? await transmit(.failure(id, PeerFailure(.busy, "\(displayName) is busy with another payment.")))
            return
        }
        busy = true
        activeIDs.insert(id)
        defer { finish(id) }
        do {
            guard signed.transfer.payee == signer.publicKey, signed.transfer.payer == peer.walletKey, signed.isSignatureValid else {
                await abort(id, .invalidMessage, "The payment isn't addressed to this wallet.")
                throw PeerError.unexpectedMessage
            }
            let decide = decide
            let incoming = IncomingOffer(id: id, from: peer, amount: signed.transfer.amount, isRedelivery: true)
            guard await ask(id, fallback: false, { await decide(incoming) }) else {
                await abort(id, .declined, "Declined.")
                throw PeerError.peer(PeerFailure(.declined, "Declined."))
            }
            events(.step(.approving))
            let session: any SigningSession
            do {
                session = try await signer.authorize(reason: "Confirm \(signed.transfer.amount.formatted()) from \(peer.displayName)")
            } catch {
                await abort(id, .cancelled, "Not confirmed.")
                throw error
            }
            defer { session.end() }
            events(.step(.confirming))
            events(.received(try await acceptAndCountersign(id, signed: signed, proof: proof, nonce: signed.transfer.sessionNonce,
                                                            from: peer, session: session, now: Date())))
        } catch {
            events(.receiveFailed(PeerText.describe(error)))
        }
    }

    private func acceptAndCountersign(_ id: OfferID, signed: SignedTransfer, proof: SpatialProof, nonce: Digest32,
                                      from peer: PeerIdentity, session: any SigningSession, now: Date) async throws -> PeerReceiveOutcome {
        let accepted: AcceptedTransfer
        do {
            accepted = try await store.acceptTransfer(signed, spatialProof: proof, expectedNonce: nonce,
                                                      payerName: peer.displayName, now: now)
        } catch {
            await abort(id, Self.code(for: error), PeerText.describe(error))
            throw error
        }
        let receipt = SignedReceipt(receipt: accepted.receipt, signature: try await session.sign(accepted.receipt.signingPayload))
        try await transmit(.receipt(id, receipt))
        let distance = (Int(proof.payerSide.measurement.summary.distanceCM) + Int(proof.payeeSide.measurement.summary.distanceCM)) / 2
        return PeerReceiveOutcome(entry: accepted.entry, amount: signed.transfer.amount, from: peer,
                                  distanceCM: UInt16(distance), wasDuplicate: accepted.wasDuplicate)
    }

    // MARK: - Steps shared by both sides

    private func measureAndSign(_ id: OfferID, nonce: Digest32, peerKey: WalletPublicKey,
                                session: any SigningSession) async throws -> SignedMeasurement {
        let summary: RangingSummary
        do {
            summary = try await ranger.measure(peer: peerKey, sessionNonce: nonce)
        } catch {
            await abort(id, .proximity, "Couldn't measure the distance between the phones.")
            throw error
        }
        let measurement = ProximityMeasurement(sessionNonce: nonce, observer: signer.publicKey, subject: peerKey, summary: summary)
        return SignedMeasurement(measurement: measurement, signature: try await session.sign(measurement.signingPayload))
    }

    private func expectMeasurement(_ id: OfferID, nonce: Digest32, observer: WalletPublicKey, subject: WalletPublicKey,
                                   timeout: Duration) async throws -> SignedMeasurement {
        guard case .measurement(_, let signed) = try await next(id, timeout: timeout) else { throw await unexpected(id) }
        let m = signed.measurement
        guard m.sessionNonce == nonce, m.observer == observer, m.subject == subject, signed.isSignatureValid else {
            await abort(id, .invalidMessage, "The other phone's distance reading doesn't check out.")
            throw PeerError.unexpectedMessage
        }
        return signed
    }

    /// Asks the user, falling back after `timeouts.decision` or when the other phone withdraws.
    private func ask<T: Sendable>(_ id: OfferID, fallback: T, _ body: @escaping @Sendable () async -> T) async -> T {
        let once = Once()
        let events = events
        let timeout = timeouts.decision
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            decisions[id] = (once, { if once.claim() { continuation.resume(returning: fallback) } })
            Task {
                let answer = await body()
                if once.claim() { continuation.resume(returning: answer) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if once.claim() {
                    continuation.resume(returning: fallback)
                    events(.offerWithdrawn(id))
                }
            }
        }
    }

    // MARK: - Messages

    private func consume(_ stream: AsyncStream<Data>) async {
        for await data in stream {
            guard let message = try? PeerMessage(encoded: data) else {
                try? await transmit(.failure(nil, PeerFailure(.invalidMessage, "Unreadable message.")))
                continue
            }
            route(message)
        }
    }

    /// Synchronous, so messages are handled in arrival order.
    private func route(_ message: PeerMessage) {
        switch message {
        case .hello(let hello):
            guard hello.walletKey != signer.publicKey else { return }
            let identity = PeerIdentity(walletKey: hello.walletKey, displayName: hello.displayName)
            peer = identity
            events(.connected(identity))
            let ranger = ranger
            let events = events
            Task {
                do { try await ranger.start(peerToken: hello.rangingToken) } catch {
                    events(.rangingUnavailable(PeerText.describe(error)))
                }
            }
        case .request(let request):
            Task { await handleRequest(request) }
        case .offer(let offer):
            Task { await handleOffer(offer) }
        case .failure(let id?, let failure) where pendingRequest?.id == id && !activeIDs.contains(id):
            // The payer declined this phone's request (or was busy) before any payment started.
            resolveRequest(id, with: .failure(PeerError.peer(failure)))
        case .transfer(let id, let signed, let proof) where !activeIDs.contains(id):
            Task { await handleRedelivery(id, signed: signed, proof: proof) }
        case .failure(let id?, _) where decisions[id] != nil:
            if let decision = decisions.removeValue(forKey: id) {
                decision.cancel()
                events(.offerWithdrawn(id))
            }
            fallthrough
        default:
            guard let id = message.offerID, activeIDs.contains(id) else { return }
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.continuation.resume(returning: message)
            } else if mailbox[id, default: []].count < 8 {
                mailbox[id, default: []].append(message)
            }
        }
    }

    /// The next message for this payment; a `failure` from the other phone is thrown as `PeerError.peer`.
    private func next(_ id: OfferID, timeout: Duration) async throws -> PeerMessage {
        let message: PeerMessage
        if var queued = mailbox[id], !queued.isEmpty {
            message = queued.removeFirst()
            mailbox[id] = queued
        } else {
            guard !closed else { throw PeerError.notConnected }
            let token = UUID()
            message = try await withCheckedThrowingContinuation { continuation in
                waiters[id] = (token, continuation)
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.expire(id, token: token)
                }
            }
        }
        if case .failure(_, let failure) = message { throw PeerError.peer(failure) }
        return message
    }

    private func expire(_ id: OfferID, token: UUID) {
        guard let waiter = waiters[id], waiter.token == token else { return }
        waiters[id] = nil
        waiter.continuation.resume(throwing: PeerError.timedOut)
    }

    private func finish(_ id: OfferID) {
        busy = false
        activeIDs.remove(id)
        mailbox[id] = nil
        decisions[id] = nil
        if let waiter = waiters.removeValue(forKey: id) { waiter.continuation.resume(throwing: PeerError.timedOut) }
    }

    private func transmit(_ message: PeerMessage) async throws {
        guard !closed else { throw PeerError.notConnected }
        try await send(message.encoded)
    }

    private func abort(_ id: OfferID, _ code: PeerFailure.Code, _ text: String) async {
        try? await transmit(.failure(id, PeerFailure(code, text)))
    }

    private func unexpected(_ id: OfferID) async -> PeerError {
        await abort(id, .invalidMessage, "Unexpected message.")
        return .unexpectedMessage
    }

    private static func code(for error: Error) -> PeerFailure.Code {
        if case StoreError.proximity = error { return .proximity }
        return .rejected
    }
}

/// Resolves a race exactly once.
final class Once: Sendable {
    private let done = Mutex(false)

    func claim() -> Bool {
        done.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
