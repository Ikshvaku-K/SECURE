import Foundation
import SecureCore

/// One side of a payment: its ledger, its signer and its ranging hardware.
public struct PaymentParticipant: Sendable {
    public let store: WalletStore
    public let signer: any TransactionSigner
    public let ranging: any RangingSession
    public let displayName: String

    public init(store: WalletStore, signer: any TransactionSigner, ranging: any RangingSession, displayName: String) {
        self.store = store
        self.signer = signer
        self.ranging = ranging
        self.displayName = displayName
    }
}

public struct PaymentOutcome: Sendable {
    public let payerEntry: LedgerEntry
    public let payeeEntry: LedgerEntry
    public let receipt: SignedReceipt
    public let proof: SpatialProof
    public let agreedDistanceCM: UInt16
    public let verdict: BudgetVerdict
}

/// Runs both sides of the DESIGN §6 protocol in one process. Phase 4 performs the same steps,
/// in the same order, with each side on its own phone and messages carried over Bluetooth.
public enum LoopbackPayment {
    public static func run(from payer: PaymentParticipant, to payee: PaymentParticipant, amount: Money,
                           categoryID: Int64?, overrideOverBudget: Bool = false, now: Date = Date()) async throws -> PaymentOutcome {
        let payerKey = payer.signer.publicKey
        let payeeKey = payee.signer.publicKey

        // 1. Joint session nonce from both sides' randomness.
        let nonce = SessionNonce.derive(payerContribution: SessionNonce.randomContribution(),
                                        payeeContribution: SessionNonce.randomContribution())

        // 2. Payer's budget and balance check, before any Face ID prompt.
        let draft = try await payer.store.preparePayment(amount: amount, categoryID: categoryID, payee: payeeKey,
                                                         sessionNonce: nonce, now: now)
        if case .overBudget = draft.verdict, !overrideOverBudget { throw StoreError.needsOverride(draft.verdict) }

        // 3. One approval per side; each session covers that side's signatures for this transfer.
        let payerSession = try await payer.signer.authorize(reason: "Pay \(amount.formatted()) to \(payee.displayName)")
        defer { payerSession.end() }
        let payeeSession = try await payee.signer.authorize(reason: "Receive \(amount.formatted()) from \(payer.displayName)")
        defer { payeeSession.end() }

        // 4. Both phones range and sign what they measured.
        let payerSummary = try await payer.ranging.measure(peer: payeeKey, sessionNonce: nonce)
        let payeeSummary = try await payee.ranging.measure(peer: payerKey, sessionNonce: nonce)
        let payerMeasurement = ProximityMeasurement(sessionNonce: nonce, observer: payerKey, subject: payeeKey, summary: payerSummary)
        let payeeMeasurement = ProximityMeasurement(sessionNonce: nonce, observer: payeeKey, subject: payerKey, summary: payeeSummary)
        let proof = SpatialProof(
            payerSide: SignedMeasurement(measurement: payerMeasurement,
                                         signature: try await payerSession.sign(payerMeasurement.signingPayload)),
            payeeSide: SignedMeasurement(measurement: payeeMeasurement,
                                         signature: try await payeeSession.sign(payeeMeasurement.signingPayload)))

        // 5. Payee says "Ready": proof, limits and the payer's record all check out.
        try await payee.store.preflightIncoming(amount: amount, payer: payerKey, sessionNonce: nonce, spatialProof: proof)
        let distance: UInt16
        do {
            distance = try proof.verify(sessionNonce: nonce, payer: payerKey, payee: payeeKey,
                                        policy: payer.store.configuration.proximityPolicy)
        } catch let failure as ProximityFailure {
            throw StoreError.proximity(failure)
        }

        // 6. Payer signs and commits the debit before handing the transfer over.
        let transfer = draft.transfer(spatialProof: proof)
        let signed = SignedTransfer(transfer: transfer, signature: try await payerSession.sign(transfer.signingPayload))
        let payerEntry = try await payer.store.commitDebit(signed, spatialProof: proof, categoryID: categoryID,
                                                           overrideOverBudget: overrideOverBudget, now: now)

        // 7. Payee verifies, records the credit and countersigns.
        let accepted = try await payee.store.acceptTransfer(signed, spatialProof: proof, expectedNonce: nonce,
                                                            payerName: payer.displayName, now: now)
        let receipt = SignedReceipt(receipt: accepted.receipt, signature: try await payeeSession.sign(accepted.receipt.signingPayload))

        // 8. Payer keeps the receipt.
        try await payer.store.storeReceipt(receipt, now: now)

        return PaymentOutcome(payerEntry: payerEntry, payeeEntry: accepted.entry, receipt: receipt, proof: proof,
                              agreedDistanceCM: distance, verdict: draft.verdict)
    }
}
