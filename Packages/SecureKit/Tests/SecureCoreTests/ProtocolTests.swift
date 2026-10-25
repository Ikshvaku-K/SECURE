import Foundation
import Testing
@testable import SecureCore

@Suite("Spatial proof")
struct SpatialProofTests {
    let payer = SoftwareSigner()
    let payee = SoftwareSigner()
    let nonce = Fixtures.randomNonce()

    @Test func acceptsMatchingCloseMeasurements() throws {
        let proof = try Fixtures.proof(nonce: nonce, payer: payer, payee: payee, payerCM: 40, payeeCM: 44)
        #expect(try proof.verify(sessionNonce: nonce, payer: payer.publicKey, payee: payee.publicKey, policy: .device) == 42)
    }

    @Test func rejectsPhonesTooFarApart() throws {
        let proof = try Fixtures.proof(nonce: nonce, payer: payer, payee: payee, payerCM: 250, payeeCM: 255)
        #expect(throws: ProximityFailure.tooFar(distanceCM: 255, limitCM: 100)) {
            try proof.verify(sessionNonce: nonce, payer: payer.publicKey, payee: payee.publicKey, policy: .device)
        }
    }

    @Test func rejectsMeasurementsThatDisagree() throws {
        // One phone claims 20 cm, the other 90 cm: a relay or a lie, not one encounter.
        let proof = try Fixtures.proof(nonce: nonce, payer: payer, payee: payee, payerCM: 20, payeeCM: 90)
        #expect(throws: ProximityFailure.disagreement(payerCM: 20, payeeCM: 90)) {
            try proof.verify(sessionNonce: nonce, payer: payer.publicKey, payee: payee.publicKey, policy: .device)
        }
    }

    @Test func realDevicesRejectSimulatedMeasurements() throws {
        let proof = try Fixtures.proof(nonce: nonce, payer: payer, payee: payee, caps: [.preciseDistance, .simulated])
        #expect(throws: ProximityFailure.simulatedNotAllowed) {
            try proof.verify(sessionNonce: nonce, payer: payer.publicKey, payee: payee.publicKey, policy: .device)
        }
        #expect(throws: Never.self) {
            try proof.verify(sessionNonce: nonce, payer: payer.publicKey, payee: payee.publicKey, policy: .simulator)
        }
    }

    @Test func bindsToTheSessionAndTheParticipants() throws {
        let proof = try Fixtures.proof(nonce: nonce, payer: payer, payee: payee)
        #expect(throws: ProximityFailure.nonceMismatch) {
            try proof.verify(sessionNonce: Fixtures.randomNonce(), payer: payer.publicKey, payee: payee.publicKey, policy: .device)
        }
        #expect(throws: ProximityFailure.wrongParticipants) {
            try proof.verify(sessionNonce: nonce, payer: payee.publicKey, payee: payer.publicKey, policy: .device)
        }
    }

    @Test func detectsATamperedMeasurement() throws {
        let proof = try Fixtures.proof(nonce: nonce, payer: payer, payee: payee)
        var edited = proof.payeeSide.measurement
        edited.summary.distanceCM = 5
        let tampered = SpatialProof(payerSide: proof.payerSide,
                                    payeeSide: SignedMeasurement(measurement: edited, signature: proof.payeeSide.signature))
        #expect(throws: ProximityFailure.badSignature(payee.publicKey)) {
            try tampered.verify(sessionNonce: nonce, payer: payer.publicKey, payee: payee.publicKey, policy: .device)
        }
    }

    @Test func roundTripsThroughCanonicalBytes() throws {
        let proof = try Fixtures.proof(nonce: nonce, payer: payer, payee: payee)
        let decoded = try SpatialProof(canonicalBytes: proof.canonicalBytes)
        #expect(decoded == proof)
        #expect(decoded.hash == proof.hash)
    }

    @Test func simulatedRangingIsReproducibleAndFlagged() async throws {
        let ranging = SimulatedRanging(trueDistanceMeters: 0.5, noiseMeters: 0.02, sampleCount: 30, seed: 42)
        let a = try await ranging.measure(peer: payee.publicKey, sessionNonce: nonce)
        let b = try await ranging.measure(peer: payee.publicKey, sessionNonce: nonce)
        #expect(a == b)
        #expect(a.capabilities.contains(.simulated))
        #expect((48...52).contains(a.distanceCM))
    }
}

@Suite("Transfers and receipts")
struct TransferTests {
    let payer = SoftwareSigner()
    let payee = SoftwareSigner()

    @Test func signedTransferRoundTripsAndVerifies() throws {
        let (signed, _) = try Fixtures.transfer(from: payer, to: payee, cents: 2_500, seq: 4, prevLink: .zero)
        let decoded = try SignedTransfer(canonicalBytes: signed.canonicalBytes)
        #expect(decoded == signed)
        #expect(decoded.isSignatureValid)
        #expect(decoded.id == signed.id)
    }

    @Test func anyChangeBreaksTheSignature() throws {
        let (signed, _) = try Fixtures.transfer(from: payer, to: payee, cents: 2_500, seq: 4, prevLink: .zero)
        var edited = signed.transfer
        edited.amount = Fixtures.dollars(250_000)
        #expect(!SignedTransfer(transfer: edited, signature: signed.signature).isSignatureValid)
    }

    @Test func decodingRejectsInvalidTransfers() throws {
        let (signed, _) = try Fixtures.transfer(from: payer, to: payee, cents: 2_500, seq: 4, prevLink: .zero)
        var zero = signed.transfer
        zero.amount = Fixtures.dollars(0)
        #expect(throws: CanonicalError.self) { try Transfer(canonicalBytes: zero.canonicalBytes) }
        #expect(throws: CanonicalError.trailingBytes(1)) { try Transfer(canonicalBytes: signed.transfer.canonicalBytes + Data([0])) }
        var wrongVersion = signed.transfer.canonicalBytes
        wrongVersion[0] = 9
        #expect(throws: CanonicalError.unsupportedVersion(9)) { try Transfer(canonicalBytes: wrongVersion) }
    }

    @Test func transferCarriesNoCategory() throws {
        // The category lives only in the payer's own ledger; nothing in the shared bytes names it.
        let (signed, _) = try Fixtures.transfer(from: payer, to: payee, cents: 2_500, seq: 4, prevLink: .zero)
        #expect(signed.canonicalBytes.range(of: Data("Clothing".utf8)) == nil)
        let labels = Mirror(reflecting: signed.transfer).children.compactMap(\.label)
        #expect(!labels.contains { $0.lowercased().contains("category") })
    }
}

@Suite("Continuity and double-spend evidence")
struct ContinuityTests {
    let cheater = SoftwareSigner()
    let alice = SoftwareSigner()
    let bob = SoftwareSigner()

    func record(_ claim: ChainClaim) -> PeerRecord {
        PeerRecord(publicKey: claim.owner, displayName: nil, lastClaim: claim)
    }

    @Test func classifiesHonestSequences() throws {
        let (t1, _) = try Fixtures.transfer(from: cheater, to: alice, cents: 100, seq: 1, prevLink: .zero)
        #expect(Continuity.check(.debit(t1), against: nil) == .firstContact)
        let link1 = ChainLink.afterDebit(t1.transfer)
        let (t2, _) = try Fixtures.transfer(from: cheater, to: alice, cents: 100, seq: 2, prevLink: link1)
        #expect(Continuity.check(.debit(t2), against: record(.debit(t1))) == .contiguous)
        let (t5, _) = try Fixtures.transfer(from: cheater, to: alice, cents: 100, seq: 5, prevLink: .zero)
        #expect(Continuity.check(.debit(t5), against: record(.debit(t2))) == .gap(missing: 3...4))
        #expect(Continuity.check(.debit(t1), against: record(.debit(t2))) == .outOfOrder)
        #expect(Continuity.check(.debit(t2), against: record(.debit(t2))) == .duplicate)
    }

    @Test func sameSequenceTwiceIsProvableFork() throws {
        // The cheater pays Alice at seq 3, restores an old copy, then pays Bob at seq 3 too.
        let prev = TaggedHash.sha256(.link, Data("state at seq 2".utf8))
        let (toAlice, _) = try Fixtures.transfer(from: cheater, to: alice, cents: 5_000, seq: 3, prevLink: prev)
        let (toBob, _) = try Fixtures.transfer(from: cheater, to: bob, cents: 5_000, seq: 3, prevLink: prev)
        guard case .fork(let evidence) = Continuity.check(.debit(toBob), against: record(.debit(toAlice))) else {
            Issue.record("expected fork"); return
        }
        #expect(evidence.isValid)
        #expect(try ForkEvidence(canonicalBytes: evidence.canonicalBytes) == evidence)
    }

    @Test func nextTransferThatSkipsTheKnownOneIsProvableFork() throws {
        // Alice holds the cheater's seq-3 transfer. The cheater's seq-4 transfer must follow it.
        let prev = TaggedHash.sha256(.link, Data("state at seq 2".utf8))
        let (toAlice, _) = try Fixtures.transfer(from: cheater, to: alice, cents: 5_000, seq: 3, prevLink: prev)
        let (toBob, _) = try Fixtures.transfer(from: cheater, to: bob, cents: 5_000, seq: 3, prevLink: prev)
        let (backToAlice, _) = try Fixtures.transfer(from: cheater, to: alice, cents: 100, seq: 4,
                                                     prevLink: ChainLink.afterDebit(toBob.transfer))
        guard case .fork(let evidence) = Continuity.check(.debit(backToAlice), against: record(.debit(toAlice))) else {
            Issue.record("expected fork"); return
        }
        #expect(evidence.isValid)
    }

    @Test func receiptsExtendTheSameRecord() throws {
        // Bob countersigns the cheater's payment as his seq 7; a later debit by Bob claiming seq 7 is a fork.
        let (payment, _) = try Fixtures.transfer(from: cheater, to: bob, cents: 100, seq: 1, prevLink: .zero)
        let bobPrev = TaggedHash.sha256(.link, Data("bob at 6".utf8))
        let receipt = try Fixtures.receipt(by: bob, for: payment, seq: 7, prevLink: bobPrev)
        #expect(receipt.isSignatureValid)
        let (bobDebit, _) = try Fixtures.transfer(from: bob, to: alice, cents: 100, seq: 7, prevLink: bobPrev)
        guard case .fork(let evidence) = Continuity.check(.debit(bobDebit), against: record(.credit(receipt))) else {
            Issue.record("expected fork"); return
        }
        #expect(evidence.isValid)
        let (honest, _) = try Fixtures.transfer(from: bob, to: alice, cents: 100, seq: 8, prevLink: ChainLink.afterCredit(receipt.receipt))
        #expect(Continuity.check(.debit(honest), against: record(.credit(receipt))) == .contiguous)
    }

    @Test func evidenceNeedsTheSameSignerAndARealConflict() throws {
        let (a, _) = try Fixtures.transfer(from: cheater, to: alice, cents: 100, seq: 3, prevLink: .zero)
        let (b, _) = try Fixtures.transfer(from: alice, to: bob, cents: 100, seq: 3, prevLink: .zero)
        #expect(!ForkEvidence(earlier: .debit(a), later: .debit(b)).isValid)
        let (next, _) = try Fixtures.transfer(from: cheater, to: bob, cents: 100, seq: 4, prevLink: ChainLink.afterDebit(a.transfer))
        #expect(!ForkEvidence(earlier: .debit(a), later: .debit(next)).isValid)
    }
}
