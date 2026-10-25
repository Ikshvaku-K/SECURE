import Foundation
import Testing
@testable import SecureCore

@Suite("Hash chain")
struct ChainTests {
    let owner = SoftwareSigner()
    let issuer = SoftwareSigner()
    let shop = SoftwareSigner()

    /// genesis → mint $500 from issuer → debit $25 to shop
    func validChain() throws -> [LedgerEntry] {
        let genesis = LedgerEntry.genesis(owner: owner.publicKey, currency: .usd, createdAtMS: 1)
        let (mint, mintProof) = try Fixtures.transfer(from: issuer, to: owner, cents: 50_000, seq: 1,
                                                      prevLink: ChainLink.genesis(owner: issuer.publicKey))
        let first = LedgerEntry.next(after: ChainTip(seq: 0, link: genesis.link), kind: .mint, transfer: mint,
                                     spatialProof: mintProof, categoryID: nil, createdAtMS: 2)
        let (debit, debitProof) = try Fixtures.transfer(from: owner, to: shop, cents: 2_500, seq: 2, prevLink: first.link)
        let second = LedgerEntry.next(after: ChainTip(seq: 1, link: first.link), kind: .debit, transfer: debit,
                                      spatialProof: debitProof, categoryID: 3, createdAtMS: 3)
        return [genesis, first, second]
    }

    @Test func verifiesAValidChainAndComputesTheBalance() throws {
        let entries = try validChain()
        let summary = try ChainVerifier.verify(entries, owner: owner.publicKey, allowNegativeBalance: false)
        #expect(summary.tip.seq == 2)
        #expect(summary.balance(.usd).minorUnits == 47_500)
    }

    @Test func genesisIsBoundToTheOwner() throws {
        let entries = try validChain()
        #expect(throws: ChainViolation.badGenesis) {
            try ChainVerifier.verify(entries, owner: shop.publicKey, allowNegativeBalance: false)
        }
    }

    @Test func detectsAChangedAmount() throws {
        var entries = try validChain()
        let e = entries[2]
        entries[2] = LedgerEntry(seq: e.seq, kind: e.kind, counterparty: e.counterparty, amount: Fixtures.dollars(1),
                                 categoryID: e.categoryID, transfer: e.transfer, spatialProof: e.spatialProof,
                                 createdAtMS: e.createdAtMS, prevLink: e.prevLink, link: e.link)
        #expect(throws: ChainViolation.amountMismatch(seq: 2)) {
            try ChainVerifier.verify(entries, owner: owner.publicKey, allowNegativeBalance: false)
        }
    }

    @Test func detectsADroppedEntry() throws {
        var entries = try validChain()
        entries.remove(at: 1)
        #expect(throws: ChainViolation.self) {
            try ChainVerifier.verify(entries, owner: owner.publicKey, allowNegativeBalance: false)
        }
    }

    @Test func detectsARewrittenLink() throws {
        var entries = try validChain()
        let e = entries[1]
        entries[1] = LedgerEntry(seq: e.seq, kind: e.kind, counterparty: e.counterparty, amount: e.amount, categoryID: e.categoryID,
                                 transfer: e.transfer, spatialProof: e.spatialProof, createdAtMS: e.createdAtMS,
                                 prevLink: e.prevLink, link: TaggedHash.sha256(.link, Data("forged".utf8)))
        #expect(throws: ChainViolation.linkMismatch(seq: 1)) {
            try ChainVerifier.verify(entries, owner: owner.publicKey, allowNegativeBalance: false)
        }
    }

    @Test func rejectsADebitSignedBySomeoneElse() throws {
        var entries = try validChain()
        // The shop signs a "debit" from the owner's chain to itself.
        let (forged, proof) = try Fixtures.transfer(from: shop, to: shop, cents: 100, seq: 3, prevLink: entries[2].link)
        entries.append(LedgerEntry.next(after: ChainTip(seq: 2, link: entries[2].link), kind: .debit, transfer: forged,
                                        spatialProof: proof, categoryID: nil, createdAtMS: 4))
        #expect(throws: ChainViolation.wrongParty(seq: 3)) {
            try ChainVerifier.verify(entries, owner: owner.publicKey, allowNegativeBalance: false)
        }
    }

    @Test func rejectsADebitThatClaimsAnotherPosition() throws {
        var entries = try validChain()
        let (debit, proof) = try Fixtures.transfer(from: owner, to: shop, cents: 100, seq: 9, prevLink: entries[2].link)
        entries.append(LedgerEntry.next(after: ChainTip(seq: 2, link: entries[2].link), kind: .debit, transfer: debit,
                                        spatialProof: proof, categoryID: nil, createdAtMS: 4))
        #expect(throws: ChainViolation.positionMismatch(seq: 3)) {
            try ChainVerifier.verify(entries, owner: owner.publicKey, allowNegativeBalance: false)
        }
    }

    @Test func balanceCannotGoNegativeExceptForIssuers() throws {
        let genesis = LedgerEntry.genesis(owner: owner.publicKey, currency: .usd, createdAtMS: 1)
        let (debit, proof) = try Fixtures.transfer(from: owner, to: shop, cents: 100, seq: 1, prevLink: genesis.link)
        let entries = [genesis, LedgerEntry.next(after: ChainTip(seq: 0, link: genesis.link), kind: .debit, transfer: debit,
                                                 spatialProof: proof, categoryID: nil, createdAtMS: 2)]
        #expect(throws: ChainViolation.negativeBalance(seq: 1)) {
            try ChainVerifier.verify(entries, owner: owner.publicKey, allowNegativeBalance: false)
        }
        #expect(try ChainVerifier.verify(entries, owner: owner.publicKey, allowNegativeBalance: true).balance(.usd).minorUnits == -100)
    }

    @Test func proofMustMatchTheTransfer() throws {
        var entries = try validChain()
        let e = entries[2]
        let otherProof = try Fixtures.proof(nonce: Fixtures.randomNonce(), payer: owner, payee: shop)
        entries[2] = LedgerEntry(seq: e.seq, kind: e.kind, counterparty: e.counterparty, amount: e.amount, categoryID: e.categoryID,
                                 transfer: e.transfer, spatialProof: otherProof, createdAtMS: e.createdAtMS,
                                 prevLink: e.prevLink, link: e.link)
        #expect(throws: ChainViolation.proofMismatch(seq: 2)) {
            try ChainVerifier.verify(entries, owner: owner.publicKey, allowNegativeBalance: false)
        }
    }

    @Test func counterpartiesCanRecomputeLinksFromPublicData() throws {
        let entries = try validChain()
        // The payer's link after the debit, from the signed transfer alone.
        #expect(ChainLink.afterDebit(entries[2].transfer!.transfer) == entries[2].link)
        // The category is a local note: it is not part of the link.
        let e = entries[2]
        let recategorized = LedgerEntry(seq: e.seq, kind: e.kind, counterparty: e.counterparty, amount: e.amount, categoryID: 99,
                                        transfer: e.transfer, spatialProof: e.spatialProof, createdAtMS: e.createdAtMS,
                                        prevLink: e.prevLink, link: e.link)
        #expect(throws: Never.self) {
            try ChainVerifier.verify([entries[0], entries[1], recategorized], owner: owner.publicKey, allowNegativeBalance: false)
        }
    }
}
