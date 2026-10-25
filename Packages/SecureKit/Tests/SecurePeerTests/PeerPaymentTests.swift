import Foundation
import Testing
@testable import SecureCore
@testable import SecurePeer
@testable import SecureStore

@Suite("Phone-to-phone payments")
struct PeerPaymentTests {
    @Test func paysBetweenTwoPhones() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob)

        let outcome = try await link.payer.pay(amount: usd(120_00), categoryID: nil)

        #expect(await alice.store.balance() == usd(380_00))
        #expect(await bob.store.balance() == usd(120_00))
        #expect(try await alice.store.receipt(forEntryLink: outcome.entry.link) != nil)
        #expect(try await bob.store.peer(alice.signer.publicKey)?.displayName == "Alice")
        #expect((30...50).contains(outcome.distanceCM))
        #expect(try await link.payer.pendingDeliveries().isEmpty)
        try await waitUntil { !link.payeeEvents.received.isEmpty }
        let received = try #require(link.payeeEvents.received.first)
        #expect(received.amount == usd(120_00))
        #expect(received.from.displayName == "Alice")
        #expect(!received.wasDuplicate)
        #expect(link.offers.offers.map(\.amount) == [usd(120_00)])
        #expect(try await alice.store.reverify() == .verified)
        #expect(try await bob.store.reverify() == .verified)
    }

    @Test func thePayeeCanDecline() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob, decide: { _ in false })

        await #expect(throws: PeerError.peer(PeerFailure(.declined, "Bob declined."))) {
            try await link.payer.pay(amount: usd(20_00), categoryID: nil)
        }
        #expect(await alice.store.balance() == usd(500_00))
        #expect(await bob.store.entryCount == 1)
    }

    @Test func overBudgetIsCaughtBeforeThePayeeIsAsked() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let clothing = try await alice.store.addCategory(name: "Clothing")
        try await alice.store.saveBudget(Budget(id: 0, categoryID: clothing.id, cap: usd(100_00), period: .monthly(anchorDay: 1)))
        let link = try await connect(alice, bob)

        do {
            _ = try await link.payer.pay(amount: usd(150_00), categoryID: clothing.id)
            Issue.record("expected an over-budget stop")
        } catch StoreError.needsOverride {
        }
        #expect(link.offers.offers.isEmpty)

        _ = try await link.payer.pay(amount: usd(150_00), categoryID: clothing.id, overrideOverBudget: true)
        #expect(await bob.store.balance() == usd(150_00))
    }

    @Test(arguments: [3.0, 0.95])
    func distanceRulesStopThePaymentBeforeAnyMoneyMoves(payeeDistance: Double) async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob, payeeDistance: payeeDistance)

        do {
            _ = try await link.payer.pay(amount: usd(20_00), categoryID: nil)
            Issue.record("expected a proximity failure")
        } catch PeerError.peer(let failure) {
            #expect(failure.code == .proximity)
        }
        #expect(await alice.store.balance() == usd(500_00))
        #expect(await bob.store.balance() == usd(0))
        #expect(try await link.payer.pendingDeliveries().isEmpty)
    }

    @Test func releaseBuildsRejectSimulatedDistance() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob", policy: .device)
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob)

        do {
            _ = try await link.payer.pay(amount: usd(20_00), categoryID: nil)
            Issue.record("expected a proximity failure")
        } catch PeerError.peer(let failure) {
            #expect(failure.code == .proximity)
            #expect(failure.message == PeerText.describe(ProximityFailure.simulatedNotAllowed))
        }
        #expect(await alice.store.balance() == usd(500_00))
    }

    @Test func theAmountsMustMatchBeforeThePayerCommits() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob)
        link.toPayee.setFilter { message in
            guard case .offer(var offer) = message else { return message }
            offer.amount = usd(5_00)
            return .offer(offer)
        }

        await #expect(throws: PeerError.unexpectedMessage) {
            try await link.payer.pay(amount: usd(120_00), categoryID: nil)
        }
        #expect(await alice.store.balance() == usd(500_00))
        #expect(await bob.store.balance() == usd(0))
    }

    @Test func aTamperedTransferIsRefusedAndRedeliveredIntact() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob)
        link.toPayee.setFilter { message in
            guard case .transfer(let id, let signed, let proof) = message else { return message }
            var signature = signed.signature
            signature[signature.startIndex] ^= 0xFF
            return .transfer(id, SignedTransfer(transfer: signed.transfer, signature: signature), proof)
        }

        do {
            _ = try await link.payer.pay(amount: usd(120_00), categoryID: nil)
            Issue.record("expected an unconfirmed payment")
        } catch PeerError.unconfirmed {
        }
        // The debit is committed on the payer's side, but the payee recorded nothing.
        #expect(await alice.store.balance() == usd(380_00))
        #expect(await bob.store.balance() == usd(0))
        let pending = try await link.payer.pendingDeliveries()
        #expect(pending.count == 1)

        link.toPayee.setFilter(nil)
        let receipt = try await link.payer.redeliver(try #require(pending.first))
        #expect(receipt.isSignatureValid)
        #expect(await bob.store.balance() == usd(120_00))
        #expect(try await link.payer.pendingDeliveries().isEmpty)
        #expect(link.offers.offers.map(\.isRedelivery) == [false, true])
    }

    @Test func aLostReceiptIsRecoveredWithoutPayingTwice() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob, payerTimeouts: .init(step: .milliseconds(300)))
        link.toPayer.setFilter { message in
            if case .receipt = message { return nil }
            return message
        }

        do {
            _ = try await link.payer.pay(amount: usd(120_00), categoryID: nil)
            Issue.record("expected an unconfirmed payment")
        } catch PeerError.unconfirmed {
        }
        #expect(await bob.store.balance() == usd(120_00))
        let pending = try await link.payer.pendingDeliveries()
        #expect(pending.count == 1)

        link.toPayer.setFilter(nil)
        try await link.payer.redeliver(try #require(pending.first))
        #expect(await bob.store.balance() == usd(120_00))
        #expect(await alice.store.balance() == usd(380_00))
        #expect(try await link.payer.pendingDeliveries().isEmpty)
        try await waitUntil { link.payeeEvents.received.count == 2 }
        #expect(link.payeeEvents.received.map(\.wasDuplicate) == [false, true])
    }

    @Test func oneConnectionCarriesOnePaymentAtATime() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob, decide: { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return true
        })

        let first = Task { try await link.payer.pay(amount: usd(10_00), categoryID: nil) }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: PeerError.busy) {
            try await link.payer.pay(amount: usd(10_00), categoryID: nil)
        }
        _ = try await first.value
        #expect(await bob.store.balance() == usd(10_00))
    }

    @Test func aWithdrawnOfferClosesThePayeesPrompt() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob, payerTimeouts: .init(decision: .milliseconds(200)), decide: { _ in
            try? await Task.sleep(for: .seconds(2))
            return true
        })

        await #expect(throws: PeerError.timedOut) {
            try await link.payer.pay(amount: usd(10_00), categoryID: nil)
        }
        try await waitUntil { link.payeeEvents.withdrawn.count == 1 }
        #expect(await bob.store.balance() == usd(0))
        #expect(await alice.store.balance() == usd(500_00))
    }

    @Test func aClosedLinkFailsFast() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob)
        await link.payer.close()
        await #expect(throws: PeerError.notConnected) {
            try await link.payer.pay(amount: usd(10_00), categoryID: nil)
        }
    }
}

@Suite("Peer messages")
struct PeerMessageTests {
    @Test func everyMessageRoundTrips() async throws {
        let alice = try Phone("Alice"), bob = try Phone("Bob")
        try await alice.fund(usd(500_00))
        let link = try await connect(alice, bob)
        _ = try await link.payer.pay(amount: usd(42_00), categoryID: nil)
        let messages = link.toPayee.messages + link.toPayer.messages
            + [.failure(nil, PeerFailure(.busy, "Busy")), .reply(OfferReply(id: .random(), payeeContribution: nil))]

        let kinds = Set(messages.map { String(describing: $0).prefix { $0 != "(" } })
        #expect(kinds == ["hello", "offer", "reply", "measurement", "ready", "transfer", "receipt", "failure"])
        for message in messages {
            #expect(try PeerMessage(encoded: message.encoded) == message)
        }
    }

    @Test func malformedMessagesAreRejected() throws {
        let offer = PeerMessage.offer(PaymentOffer(id: .random(), payer: SoftwareSigner().publicKey, payee: SoftwareSigner().publicKey,
                                                   amount: usd(10_00), payerContribution: SessionNonce.randomContribution()))
        let bytes = offer.encoded
        #expect(throws: (any Error).self) { try PeerMessage(encoded: bytes.dropLast()) }
        #expect(throws: (any Error).self) { try PeerMessage(encoded: bytes + Data([0])) }
        var wrongVersion = bytes
        wrongVersion[wrongVersion.startIndex] = 2
        #expect(throws: CanonicalError.unsupportedVersion(2)) { try PeerMessage(encoded: wrongVersion) }
        #expect(throws: (any Error).self) { try PeerMessage(encoded: Data([1, 99])) }

        let negative = PeerMessage.offer(PaymentOffer(id: .random(), payer: SoftwareSigner().publicKey, payee: SoftwareSigner().publicKey,
                                                      amount: usd(-5_00), payerContribution: SessionNonce.randomContribution()))
        #expect(throws: CanonicalError.invalidValue("amount")) { try PeerMessage(encoded: negative.encoded) }
        let shortNonce = PeerMessage.offer(PaymentOffer(id: .random(), payer: SoftwareSigner().publicKey, payee: SoftwareSigner().publicKey,
                                                        amount: usd(5_00), payerContribution: Data([1, 2, 3])))
        #expect(throws: CanonicalError.invalidValue("contribution")) { try PeerMessage(encoded: shortNonce.encoded) }
    }
}
