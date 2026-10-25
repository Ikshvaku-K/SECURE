import Foundation
import Testing
@testable import SecureCore
@testable import SecureStore

@Suite("Encrypted storage")
struct EncryptionTests {
    @Test func databaseFileIsEncrypted() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wallet = try TestWallet(name: "w", directory: dir)
        _ = try wallet.reopen()

        let header = try Data(contentsOf: wallet.databaseURL).prefix(16)
        #expect(header != Data("SQLite format 3\0".utf8), "a plain SQLite header means the file is not encrypted")
        #expect(!wallet.store.cipherVersion.isEmpty)
    }

    @Test func wrongKeyCannotOpenTheDatabase() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wallet = try TestWallet(name: "w", directory: dir)
        try wallet.secrets.write(Data(repeating: 7, count: 32), account: "w.database-key")
        #expect(throws: SQLiteError.self) { try wallet.reopen() }
    }

    @Test func missingKeyIsReportedNotReplaced() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wallet = try TestWallet(name: "w", directory: dir)
        try wallet.secrets.delete("w.database-key")
        #expect(throws: StoreError.databaseKeyMissing) { try wallet.reopen() }
    }

    @Test func aDifferentWalletKeyIsRejected() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wallet = try TestWallet(name: "w", directory: dir)
        #expect(throws: StoreError.walletKeyMismatch) {
            try WalletStore(directory: dir, name: "w", secrets: wallet.secrets, walletKey: SoftwareSigner().publicKey,
                            configuration: wallet.configuration)
        }
    }

    @Test func ledgerIsAppendOnlyInTheDatabaseItself() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        let key = try #require(try community.member.secrets.read("member.database-key"))
        let raw = try SQLiteDatabase(path: community.member.databaseURL.path, key: key)
        #expect(throws: SQLiteError.self) { try raw.execute("UPDATE ledger SET amount_minor = 99999999 WHERE seq = 1;") }
        #expect(throws: SQLiteError.self) { try raw.execute("DELETE FROM ledger WHERE seq = 1;") }
        #expect(throws: SQLiteError.self) {
            try raw.execute("INSERT INTO ledger (seq, kind, amount_minor, currency, created_at_ms, prev_link, link) VALUES (9, 'credit', 1, 'USD', 0, x'00', x'01');")
        }
        #expect(throws: SQLiteError.self) {
            try raw.execute("INSERT INTO budgets (category_id, cap_minor, period, anchor) VALUES (1, 100, 'monthly', 40);")
        }
    }
}

@Suite("Wallet ledger and budgets")
struct WalletLedgerTests {
    @Test func freshWalletStartsVerifiedAtGenesis() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wallet = try TestWallet(name: "w", directory: dir)
        #expect(await wallet.store.integrity == .verified)
        #expect(await wallet.store.tip.seq == 0)
        #expect(await wallet.store.balance().minorUnits == 0)
        try wallet.reopen()
        #expect(await wallet.store.integrity == .verified)
    }

    @Test func mintFromAPinnedIssuerCreditsTheMember() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        #expect(await community.member.store.balance().minorUnits == 50_000)
        #expect(await community.issuer.store.balance().minorUnits == -50_000)
        let entries = try await community.member.store.entries()
        #expect(entries.first?.kind == .mint)
        #expect(entries.first?.counterparty == community.issuer.publicKey)
        // The issuer holds the member's countersigned receipt.
        let issuerDebit = try #require(try await community.issuer.store.entries().first)
        #expect(try await community.issuer.store.receipt(forEntryLink: issuerDebit.link)?.isSignatureValid == true)
        // Everything still verifies after reopening.
        try community.member.reopen()
        #expect(await community.member.store.integrity == .verified)
        #expect(await community.member.store.balance().minorUnits == 50_000)
    }

    @Test func budgetsFollowThePRDExample() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        let member = community.member
        let clothing = try await member.store.addCategory(name: "Clothing", iconName: "tshirt")
        try await member.store.saveBudget(Budget(id: 0, categoryID: clothing.id, cap: usd(20_000), period: .monthly(anchorDay: 1)))

        let first = try await LoopbackPayment.run(from: member.participant, to: community.shop.participant, amount: usd(15_000),
                                                  categoryID: clothing.id)
        guard case .ok = first.verdict else { Issue.record("expected ok, got \(first.verdict)"); return }

        let second = try await LoopbackPayment.run(from: member.participant, to: community.shop.participant, amount: usd(3_000),
                                                   categoryID: clothing.id)
        guard case .alert = second.verdict else { Issue.record("expected alert, got \(second.verdict)"); return }

        // $180 spent; another $25 would make $205 of $200.
        await #expect(throws: StoreError.self) {
            try await LoopbackPayment.run(from: member.participant, to: community.shop.participant, amount: usd(2_500),
                                          categoryID: clothing.id)
        }
        #expect(await member.store.balance().minorUnits == 32_000, "a refused payment must not debit anything")
        let overridden = try await LoopbackPayment.run(from: member.participant, to: community.shop.participant, amount: usd(2_500),
                                                       categoryID: clothing.id, overrideOverBudget: true)
        guard case .overBudget = overridden.verdict else { Issue.record("expected overBudget"); return }

        let statuses = try await member.store.budgetStatuses()
        #expect(statuses.first?.spentBefore == 20_500)
        #expect(await member.store.balance().minorUnits == 29_500)
        #expect(await community.shop.store.balance().minorUnits == 20_500)
        // The shop never learns the member's category.
        #expect(try await community.shop.store.entries().allSatisfy { $0.categoryID == nil })
    }

    @Test func hardCapsAndBalanceBlockBeforeAnyApproval() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        let member = community.member
        let food = try await member.store.addCategory(name: "Food")
        try await member.store.saveBudget(Budget(id: 0, categoryID: food.id, cap: usd(5_000), period: .weekly(anchorWeekday: 2),
                                                 hardCap: true))
        await #expect(throws: StoreError.self) {
            try await LoopbackPayment.run(from: member.participant, to: community.shop.participant, amount: usd(6_000), categoryID: food.id)
        }
        await #expect(throws: StoreError.self) {
            try await LoopbackPayment.run(from: member.participant, to: community.shop.participant, amount: usd(60_000), categoryID: nil)
        }
        #expect(await member.store.balance().minorUnits == 50_000)
    }

    @Test func farOrSimulatedProximityIsRefusedBeforeTheDebit() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        community.member.distanceMeters = 3.0
        community.shop.distanceMeters = 3.0
        let error = await #expect(throws: StoreError.self) {
            try await LoopbackPayment.run(from: community.member.participant, to: community.shop.participant, amount: usd(1_000),
                                          categoryID: nil)
        }
        guard case .proximity(.tooFar(_, let limit)) = error else { Issue.record("expected tooFar, got \(String(describing: error))"); return }
        #expect(limit == 100)
        #expect(await community.member.store.balance().minorUnits == 50_000)

        // A shop configured for real devices rejects simulated measurements.
        let strictShop = try TestWallet(name: "strict-shop", directory: community.directory,
                                        configuration: TestWallet.simulatorConfig(policy: .device))
        community.member.distanceMeters = 0.4
        await #expect(throws: StoreError.proximity(.simulatedNotAllowed)) {
            try await LoopbackPayment.run(from: community.member.participant, to: strictShop.participant, amount: usd(1_000),
                                          categoryID: nil)
        }
        #expect(await community.member.store.balance().minorUnits == 50_000)
    }

    @Test func acceptanceLimitCapsExposure() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let issuer = try TestWallet(name: "issuer", directory: dir, configuration: TestWallet.simulatorConfig(isIssuer: true))
        let cautious = try TestWallet(name: "cautious", directory: dir,
                                      configuration: TestWallet.simulatorConfig(acceptance: OfflineLimits(perTransfer: usd(10_000))))
        await #expect(throws: StoreError.blocked(.overTransferLimit(limit: usd(10_000), requested: usd(20_000)))) {
            try await LoopbackPayment.run(from: issuer.participant, to: cautious.participant, amount: usd(20_000), categoryID: nil)
        }
        #expect(await issuer.store.balance().minorUnits == 0, "the issuer must not be debited for a refused transfer")
    }

    @Test func redeliveryIsIdempotent() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        let outcome = try await LoopbackPayment.run(from: community.member.participant, to: community.shop.participant,
                                                    amount: usd(1_000), categoryID: nil)
        let signed = try #require(outcome.payerEntry.transfer)
        let again = try await community.shop.store.acceptTransfer(signed, spatialProof: outcome.proof,
                                                                  expectedNonce: signed.transfer.sessionNonce)
        #expect(again.wasDuplicate)
        #expect(again.entry == outcome.payeeEntry)
        #expect(await community.shop.store.balance().minorUnits == 1_000)
    }
}

@Suite("Rollback and double-spend")
struct RollbackTests {
    @Test func restoringAnOlderDatabaseLocksTheWallet() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        let member = community.member
        let beforeSpending = try member.snapshotDatabase()
        _ = try await LoopbackPayment.run(from: member.participant, to: community.shop.participant, amount: usd(40_000), categoryID: nil)
        #expect(await member.store.balance().minorUnits == 10_000)

        // The member puts back the copy that still shows $500.
        try member.restoreDatabase(from: beforeSpending)
        try member.reopen()
        #expect(await member.store.integrity == .rolledBack(anchorSeq: 2, databaseSeq: 1))
        await #expect(throws: StoreError.self) {
            try await LoopbackPayment.run(from: member.participant, to: community.shop.participant, amount: usd(40_000), categoryID: nil)
        }
    }

    @Test func aMissingAnchorLocksAWalletWithHistory() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        try community.member.secrets.delete("member.chain-anchor")
        try community.member.reopen()
        #expect(await community.member.store.integrity == .anchorMissing)
    }

    @Test func aReinstallMustNotReuseTheOldKey() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        // The database disappears (app deleted) but the Keychain survives with the anchor at seq 1.
        try FileManager.default.removeItem(at: community.member.databaseURL)
        try community.member.reopen()
        #expect(await community.member.store.integrity == .rolledBack(anchorSeq: 1, databaseSeq: 0))
    }

    @Test func anInterruptedCommitIsRepaired() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        let member = community.member
        let keychainBefore = member.secrets.snapshot()
        _ = try await LoopbackPayment.run(from: member.participant, to: community.shop.participant, amount: usd(1_000), categoryID: nil)
        // As if the app stopped after the database commit but before the Keychain write.
        member.secrets.restore(keychainBefore)
        try member.reopen()
        #expect(await member.store.integrity == .anchorAdvanced(from: 1, to: 2))
        try member.reopen()
        #expect(await member.store.integrity == .verified)
    }

    @Test func aFullRestoreIsCaughtWhenTheCheaterMeetsAnEarlierPayee() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        let member = community.member
        let shop = community.shop
        let cafe = try TestWallet(name: "cafe", directory: community.directory)

        // A complete copy of the app state: database and Keychain together.
        let database = try member.snapshotDatabase()
        let keychain = member.secrets.snapshot()

        // Spend $400 at the shop (member seq 2).
        _ = try await LoopbackPayment.run(from: member.participant, to: shop.participant, amount: usd(40_000), categoryID: nil)

        // Restore everything. On its own phone this is undetectable: the old state is internally consistent.
        try member.restoreDatabase(from: database)
        member.secrets.restore(keychain)
        try member.reopen()
        #expect(await member.store.integrity == .verified)
        #expect(await member.store.balance().minorUnits == 50_000)

        // Spend the same $400 again at the cafe, also as seq 2.
        _ = try await LoopbackPayment.run(from: member.participant, to: cafe.participant, amount: usd(40_000), categoryID: nil)

        // Back at the shop, the next transfer can't follow the seq-2 transfer the shop holds: provable fork.
        await #expect(throws: StoreError.self) {
            try await LoopbackPayment.run(from: member.participant, to: shop.participant, amount: usd(500), categoryID: nil)
        }
        let record = try #require(try await shop.store.peer(member.publicKey))
        let evidence = try #require(record.forkEvidence)
        #expect(evidence.isValid)
        #expect(evidence.earlier.owner == member.publicKey)
        // The shop now refuses this wallet outright.
        await #expect(throws: StoreError.fork(evidence)) {
            try await LoopbackPayment.run(from: member.participant, to: shop.participant, amount: usd(100), categoryID: nil)
        }
    }
}
