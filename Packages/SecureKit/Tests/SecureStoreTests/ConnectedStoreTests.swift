import Foundation
import Testing
@testable import SecureConnect
@testable import SecureCore
@testable import SecureStore

/// 2026-09-21 14:13 UTC.
let connectedNow = Date(timeIntervalSince1970: 1_790_000_000)

func makeConnected(_ directory: URL) throws -> ConnectedStore {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return try ConnectedStore(directory: directory, secrets: InMemorySecretStore(), calendar: calendar)
}

/// Sets a credit score and confirms age, as the Profile tab does.
func unlock(_ store: ConnectedStore, score: Int = 700, age: AgeConfirmation = .adult21) async throws {
    try await store.setCreditProfile(CreditProfile(score: CreditScore(score)!, source: .selfReported, updatedAtMS: 0))
    try await store.updatePlaySettings(PlaySettings(age: age, dailyStakeLimit: usd(1_000_00)), now: connectedNow)
}

@Suite("Linked accounts (simulated)")
struct LinkedAccountTests {
    @Test func linkingImportsHistoryAndSyncIsIdempotent() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        let accounts = try await store.link(institutionID: "harbor-federal", now: connectedNow)
        #expect(accounts.count == 2)
        let imported = try await store.transactions(limit: 10_000)
        #expect(imported.count > 30)
        #expect(try await store.sync(now: connectedNow).newTransactions.isEmpty)

        let later = connectedNow.addingTimeInterval(7 * 86_400)
        let fresh = try await store.sync(now: later).newTransactions
        #expect(!fresh.isEmpty)
        #expect(try await store.sync(now: later).newTransactions.isEmpty)
        let all = try await store.transactions(limit: 10_000)
        #expect(all.count == imported.count + fresh.count)
        #expect(Set(all.map(\.id)).count == all.count)

        await #expect(throws: ConnectedError.alreadyLinked) { try await store.link(institutionID: "harbor-federal", now: later) }
        await #expect(throws: ConnectedError.unknownInstitution) { try await store.link(institutionID: "real-bank", now: later) }
    }

    @Test func netWorthAddsUpEveryAccount() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        try await store.link(institutionID: "harbor-federal", now: connectedNow)
        try await store.link(institutionID: "summit-cu", now: connectedNow)
        let accounts = try await store.linkedAccounts()
        let summary = try await store.summary(now: connectedNow)
        #expect(accounts.count == 3)
        #expect(summary.netWorth.minorUnits == accounts.reduce(0) { $0 + $1.balance.minorUnits })
        let card = try #require(accounts.first { $0.kind == .credit })
        #expect(summary.liabilities.minorUnits == max(0, -card.balance.minorUnits))
        #expect(summary.assets.minorUnits - summary.liabilities.minorUnits == summary.netWorth.minorUnits)
        #expect(summary.spendingThisMonth.allSatisfy { $0.category.isSpending && $0.amount.minorUnits > 0 })
        #expect(summary.lastSyncedMS == connectedNow.millisecondsSince1970)
    }

    @Test func unlinkingRemovesAccountsAndTheirTransactions() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        try await store.link(institutionID: "meridian", now: connectedNow)
        #expect(try await !store.transactions().isEmpty)
        try await store.unlink(institutionID: "meridian")
        #expect(try await store.linkedAccounts().isEmpty)
        #expect(try await store.transactions().isEmpty)
    }

    @Test func largeTransactionsRaiseAlerts() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        // Linked on 28 September, synced on 2 October: October's rent posts in between.
        try await store.link(institutionID: "harbor-federal", now: Date(timeIntervalSince1970: 1_790_596_800))
        let result = try await store.sync(now: Date(timeIntervalSince1970: 1_790_942_400))
        #expect(result.alerts.contains { $0.kind == .largeTransaction && $0.body.contains("Maple Court Apartments") })
    }
}

@Suite("Practice markets")
struct PracticeMarketTests {
    @Test func equityOrdersMoveCashAndPositions() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        try await unlock(store, score: 815)
        let quote = EquitySimulator.quote(for: Equity.find("TMKT")!, day: 0)
        try await store.placeEquityOrder(ticker: "TMKT", side: .buy, quantity: 2, now: connectedNow)
        #expect(try await store.cash() == usd(10_000_00 - quote.ask * 2))
        #expect(try await store.portfolio().positions.first?.quantity == 2)
        try await store.placeEquityOrder(ticker: "TMKT", side: .sell, quantity: 1, now: connectedNow)
        #expect(try await store.cash() == usd(10_000_00 - quote.ask * 2 + quote.bid))
        #expect(try await store.portfolio().positions.first?.quantity == 1)
        await #expect(throws: ConnectedError.play(.insufficientPosition(held: 1, requested: 5))) {
            try await store.placeEquityOrder(ticker: "TMKT", side: .sell, quantity: 5, now: connectedNow)
        }
        await #expect(throws: ConnectedError.play(.unknownInstrument)) {
            try await store.placeEquityOrder(ticker: "NOPE", side: .buy, quantity: 1, now: connectedNow)
        }
    }

    @Test func contractsSettleOnTheirCloseDay() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        try await unlock(store)
        let event = try #require(PredictionCatalog.openEvents(day: 0).first)
        let quote = event.quote(day: 0)
        try await store.placeContractOrder(eventID: event.id, side: .yes, action: .open, quantity: 3, now: connectedNow)
        let afterBuy = try await store.cash()
        #expect(afterBuy == usd(10_000_00 - Int64(quote.yesAsk) * 3))
        while await store.simDay < event.closeDay { try await store.advanceDay(now: connectedNow) }
        #expect(try await store.portfolio().positions.isEmpty)
        #expect(try await store.cash() == usd(afterBuy.minorUnits + (event.resolvesYes ? 300 : 0)))
        #expect(try await store.history().contains { $0.action == .settle && $0.instrument == event.id })
        await #expect(throws: ConnectedError.play(.marketClosed)) {
            try await store.placeContractOrder(eventID: event.id, side: .no, action: .open, quantity: 1, now: connectedNow)
        }
    }

    @Test func betsSettleAfterTheGame() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        try await unlock(store)
        let game = try #require(SportsCatalog.fixtures(fromDay: 1, throughDay: 1).first)
        try await store.placeBet(fixtureID: game.id, selection: .home, stake: usd(20_00), now: connectedNow)
        #expect(try await store.bets(status: .open).count == 1)
        while await store.simDay < game.day { try await store.advanceDay(now: connectedNow) }
        let settled = try #require(try await store.bets().first)
        let won = game.winner == .home
        #expect(settled.status == (won ? .won : .lost))
        #expect(settled.payout == usd(won ? 20_00 + Odds.profit(stake: 20_00, american: game.americanOdds(.home)) : 0))
        await #expect(throws: ConnectedError.play(.marketClosed)) {
            try await store.placeBet(fixtureID: game.id, selection: .away, stake: usd(5_00), now: connectedNow)
        }
    }

    @Test func aSwitchedOffMarketRefusesOrders() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = try ConnectedStore(directory: dir, secrets: InMemorySecretStore(), calendar: calendar,
                                       enabledMarkets: [.equity, .prediction])
        try await unlock(store)
        let game = try #require(SportsCatalog.fixtures(fromDay: 1, throughDay: 1).first)
        await #expect(throws: ConnectedError.play(.marketClosed)) {
            try await store.placeBet(fixtureID: game.id, selection: .home, stake: usd(10_00), now: connectedNow)
        }
        #expect(try await store.bets().isEmpty)
        #expect(try await store.cash() == usd(10_000_00))
        try await store.placeEquityOrder(ticker: "TMKT", side: .buy, quantity: 1, now: connectedNow)
        #expect(try await store.portfolio().positions.count == 1)
    }

    @Test func creditScoreSetsTransactionAccess() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        await #expect(throws: ConnectedError.play(.creditScoreRequired)) {
            try await store.placeEquityOrder(ticker: "HRVS", side: .buy, quantity: 1, now: connectedNow)
        }
        try await unlock(store, score: 540, age: .adult18)
        let tooBig = await #expect(throws: ConnectedError.self) {
            try await store.placeEquityOrder(ticker: "HLIO", side: .buy, quantity: 3, now: connectedNow)
        }
        guard case .play(.overTransactionSize(tier: .poor, _, _)) = tooBig else { Issue.record("expected size limit, got \(String(describing: tooBig))"); return }
        for _ in 0..<3 { try await store.placeEquityOrder(ticker: "HRVS", side: .buy, quantity: 1, now: connectedNow) }
        await #expect(throws: ConnectedError.play(.overTransactionCount(tier: .poor, limit: 3, used: 3))) {
            try await store.placeEquityOrder(ticker: "HRVS", side: .buy, quantity: 1, now: connectedNow)
        }
        let game = try #require(SportsCatalog.fixtures(fromDay: 1, throughDay: 1).first)
        await #expect(throws: ConnectedError.play(.ageNotConfirmed(required: .adult21))) {
            try await store.placeBet(fixtureID: game.id, selection: .home, stake: usd(5_00), now: connectedNow)
        }
        // A new local day resets the count.
        try await store.placeEquityOrder(ticker: "HRVS", side: .buy, quantity: 1, now: connectedNow.addingTimeInterval(86_400))
        let usage = try await store.usageToday(now: connectedNow.addingTimeInterval(86_400))
        #expect(usage.transactions == 1)
    }

    @Test func coolOffBlocksBuyingButAllowsSellingAndCantBeShortened() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        try await unlock(store, score: 815)
        try await store.placeEquityOrder(ticker: "TMKT", side: .buy, quantity: 2, now: connectedNow)
        var settings = try await store.playSettings()
        let until = connectedNow.millisecondsSince1970 + 86_400_000
        settings.coolOffUntilMS = until
        try await store.updatePlaySettings(settings, now: connectedNow)
        await #expect(throws: ConnectedError.play(.coolingOff(untilMS: until))) {
            try await store.placeEquityOrder(ticker: "TMKT", side: .buy, quantity: 1, now: connectedNow)
        }
        try await store.placeEquityOrder(ticker: "TMKT", side: .sell, quantity: 1, now: connectedNow)
        var shorter = settings
        shorter.coolOffUntilMS = nil
        await #expect(throws: ConnectedError.play(.cannotShortenExclusion)) {
            try await store.updatePlaySettings(shorter, now: connectedNow)
        }
    }

    @Test func resetKeepsScoreAndPlaySettings() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        try await unlock(store)
        try await store.placeEquityOrder(ticker: "VITA", side: .buy, quantity: 1, now: connectedNow)
        try await store.advanceDay(now: connectedNow)
        let settings = try await store.playSettings()
        try await store.resetPractice()
        #expect(try await store.cash() == usd(10_000_00))
        #expect(try await store.portfolio().positions.isEmpty)
        #expect(await store.simDay == 0)
        #expect(try await store.playSettings() == settings)
        #expect(try await store.creditProfile()?.score.value == 700)
    }
}

@Suite("Separation from the wallet")
struct SeparationTests {
    @Test func connectedDataIsEncryptedInItsOwnFile() async throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try makeConnected(dir)
        try await store.link(institutionID: "harbor-federal", now: connectedNow)
        let url = try #require(store.databaseURL)
        #expect(url.lastPathComponent == "connected.sqlite")
        #expect(try Data(contentsOf: url).prefix(16) != Data("SQLite format 3\0".utf8))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("wallet.sqlite").path))
    }

    @Test func walletTransfersIgnoreTheCreditScore() async throws {
        let community = try await Community()
        defer { community.cleanUp() }
        let store = try makeConnected(community.directory)
        try await unlock(store, score: 320)
        // The lowest tier allows $100 per practice transaction; a $150 wallet payment is unaffected.
        let outcome = try await LoopbackPayment.run(from: community.member.participant, to: community.shop.participant,
                                                    amount: usd(150_00), categoryID: nil)
        #expect(outcome.payerEntry.amount == usd(150_00))
        #expect(await community.member.store.balance().minorUnits == 350_00)
    }
}
