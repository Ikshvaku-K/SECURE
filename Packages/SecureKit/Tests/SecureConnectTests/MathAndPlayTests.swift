import Foundation
import Testing
@testable import SecureConnect
@testable import SecureCore

func usd(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: .usd) }

@Suite("Odds and strategy maths")
struct OddsAndStrategyTests {
    @Test func impliedProbabilities() {
        #expect(abs(Odds.impliedProbability(american: 150) - 0.40) < 1e-12)
        #expect(abs(Odds.impliedProbability(american: -200) - 2.0 / 3.0) < 1e-12)
        #expect(Odds.impliedProbability(american: 100) == 0.5)
        #expect(Odds.impliedProbability(american: -100) == 0.5)
    }

    @Test func decimalAndAmericanConvert() {
        #expect(Odds.decimal(american: 150) == 2.5)
        #expect(Odds.decimal(american: -200) == 1.5)
        #expect(Odds.american(decimal: 2.5) == 150)
        #expect(Odds.american(decimal: 1.5) == -200)
        for odds in [-500, -250, -110, 105, 180, 400] {
            #expect(Odds.american(decimal: Odds.decimal(american: odds)) == odds)
        }
    }

    @Test func profitIsWholeCents() {
        #expect(Odds.profit(stake: 10_00, american: 150) == 15_00)
        #expect(Odds.profit(stake: 10_00, american: -200) == 5_00)
        #expect(Odds.profit(stake: 3_33, american: -110) == 3_02)
    }

    @Test func fairProbabilitiesRemoveTheMargin() {
        #expect(Odds.fairProbabilities(american: [-110, -110]) == [0.5, 0.5])
        #expect(abs(Odds.overround(american: [-110, -110]) - 220.0 / 210.0) < 1e-12)
    }

    @Test func kellyFractions() {
        #expect(abs(StrategyMath.kellyFraction(probability: 0.55, decimalOdds: 2.0) - 0.10) < 1e-12)
        #expect(StrategyMath.kellyFraction(probability: 0.40, decimalOdds: 2.0) == 0)
        #expect(abs(StrategyMath.kellyFraction(probability: 0.55, contractPriceCents: 40) - 0.25) < 1e-12)
        #expect(StrategyMath.kellyFraction(probability: 0.5, contractPriceCents: 100) == 0)
    }

    @Test func dollarCostAveragingBuysMoreOnDips() throws {
        let result = try #require(StrategyMath.dollarCostAveraging(prices: [10_00, 5_00, 10_00], every: 1, amountPerBuy: 100_00))
        #expect(result.buys == 3)
        #expect(abs(result.unitsDCA - 40) < 1e-9)
        #expect(abs(result.averageCostDCA - 7_50) < 1e-9)
        #expect(abs(result.unitsLumpSum - 30) < 1e-9)
        #expect(result.valueDCA > result.valueLumpSum)
    }

    @Test func lumpSumWinsInASteadyRise() throws {
        let rising: [Int64] = (0..<100).map { 100_00 + Int64($0) * 50 }
        let result = try #require(StrategyMath.dollarCostAveraging(prices: rising, every: 10, amountPerBuy: 100_00))
        #expect(result.valueLumpSum > result.valueDCA)
        #expect(StrategyMath.dollarCostAveraging(prices: [], every: 1, amountPerBuy: 1) == nil)
    }

    @Test func martingaleUsuallyEndsInRuinAndIsReproducible() {
        let run = { StrategyMath.martingale(bankroll: 1_000, baseStake: 10, winProbability: 0.4762, decimalOdds: 2.0,
                                            rounds: 1_000, trials: 400, seed: 7) }
        let first = run()
        #expect(first == run())
        #expect(first.ruinProbability > 0.5)
    }

    @Test func martingaleNeverRuinsWithoutLosses() {
        let result = StrategyMath.martingale(bankroll: 100, baseStake: 10, winProbability: 1, decimalOdds: 2,
                                             rounds: 50, trials: 10, seed: 1)
        #expect(result.ruined == 0)
        #expect(result.medianFinal == 600)
    }
}

@Suite("Strategy catalogue")
struct StrategyCatalogTests {
    @Test func everyStrategyIsComplete() {
        for strategy in StrategyCatalog.all {
            #expect(!strategy.name.isEmpty && !strategy.summary.isEmpty && !strategy.howItWorks.isEmpty)
            #expect(!strategy.example.isEmpty && !strategy.whenUsed.isEmpty && !strategy.horizon.isEmpty)
            #expect(!strategy.practiceNote.isEmpty)
            #expect(strategy.risks.count >= 2, "\(strategy.id) needs at least two risks")
        }
    }

    @Test func idsAreUniqueAndEveryGroupIsCovered() {
        #expect(Set(StrategyCatalog.all.map(\.id)).count == StrategyCatalog.all.count)
        for group in Strategy.Group.allCases {
            #expect(StrategyCatalog.strategies(in: group).count >= 5)
        }
        #expect(StrategyCatalog.all.count == 27)
    }

    /// The worked examples in the guide, recomputed so the text can't drift from the maths.
    @Test func workedExamplesAreCorrect() {
        #expect(abs(StrategyMath.contractEdge(probability: 0.50, priceCents: 40) - 10) < 1e-9)
        #expect(abs(StrategyMath.contractEdge(probability: 0.55, priceCents: 40) - 15) < 1e-9)
        #expect(abs(StrategyMath.contractEdge(probability: 0.96, priceCents: 93) - 3) < 1e-9)
        let valueBet = StrategyMath.expectedValue(probability: 0.46, decimalOdds: Odds.decimal(american: 150), stake: 10)
        #expect(abs(valueBet - 1.50) < 1e-9)
        #expect(abs(Odds.impliedProbability(american: -110) - 0.5238) < 0.0001)
        #expect(abs(Odds.impliedProbability(american: 110) - 0.4762) < 0.0001)
        #expect((0..<7).map { 10 << $0 }.reduce(0, +) == 1_270)
        #expect(10 << 7 == 1_280)
        // Hedge: $10 at +200 and $12 at +150 both return $30.
        #expect(10_00 + Odds.profit(stake: 10_00, american: 200) == 30_00)
        #expect(12_00 + Odds.profit(stake: 12_00, american: 150) == 30_00)
    }
}

@Suite("Responsible play")
struct ResponsiblePlayTests {
    let now: Int64 = 1_000_000_000
    let adult = PlaySettings(age: .adult21, dailyStakeLimit: usd(1_000_00))

    func check(_ order: PlayGuard.Order, market: MarketKind = .equity, settings: PlaySettings? = nil,
               tier: CreditTier? = .good, transactions: Int = 0, staked: Int64 = 0, cash: Int64 = 10_000_00) throws(PlayBlock) {
        try PlayGuard.check(order, market: market, settings: settings ?? adult, tier: tier, ordersToday: transactions,
                            stakedToday: usd(staked), cash: usd(cash), nowMS: now)
    }

    @Test func selfExclusionComesFirst() {
        var excluded = PlaySettings(age: .none)
        excluded.selfExcludedUntilMS = now + 1
        #expect(throws: PlayBlock.selfExcluded(untilMS: now + 1)) { try check(.opening(cost: usd(1_00)), settings: excluded, tier: nil) }
    }

    @Test func aCreditScoreUnlocksTheMarkets() {
        #expect(throws: PlayBlock.creditScoreRequired) { try check(.opening(cost: usd(1_00)), tier: nil) }
        #expect(throws: Never.self) { try check(.opening(cost: usd(1_00)), tier: .poor) }
    }

    @Test func coolOffBlocksNewRiskButNotSelling() {
        var cooling = adult
        cooling.coolOffUntilMS = now + 60_000
        #expect(throws: PlayBlock.coolingOff(untilMS: now + 60_000)) { try check(.opening(cost: usd(1_00)), settings: cooling) }
        #expect(throws: Never.self) { try check(.closing, settings: cooling) }
    }

    @Test func sportsNeedsAge21() {
        let eighteen = PlaySettings(age: .adult18)
        #expect(throws: PlayBlock.ageNotConfirmed(required: .adult21)) { try check(.opening(cost: usd(1_00)), market: .sports, settings: eighteen) }
        #expect(throws: Never.self) { try check(.opening(cost: usd(1_00)), market: .prediction, settings: eighteen) }
        #expect(throws: PlayBlock.ageNotConfirmed(required: .adult18)) { try check(.opening(cost: usd(1_00)), settings: PlaySettings(age: .none)) }
    }

    @Test func tierSetsTransactionCountAndSize() {
        #expect(throws: PlayBlock.overTransactionCount(tier: .poor, limit: 3, used: 3)) {
            try check(.opening(cost: usd(10_00)), tier: .poor, transactions: 3)
        }
        #expect(throws: PlayBlock.overTransactionCount(tier: .poor, limit: 3, used: 3)) { try check(.closing, tier: .poor, transactions: 3) }
        #expect(throws: PlayBlock.overTransactionSize(tier: .poor, limit: usd(100_00), requested: usd(150_00))) {
            try check(.opening(cost: usd(150_00)), tier: .poor)
        }
        #expect(throws: Never.self) { try check(.opening(cost: usd(150_00)), tier: .fair) }
    }

    @Test func dailyStakeLimitAndCash() {
        #expect(throws: PlayBlock.overDailyStake(limit: usd(1_000_00), used: usd(950_00), requested: usd(100_00))) {
            try check(.opening(cost: usd(100_00)), tier: .exceptional, staked: 950_00)
        }
        #expect(throws: PlayBlock.insufficientCash(available: usd(50_00), requested: usd(80_00))) {
            try check(.opening(cost: usd(80_00)), cash: 50_00)
        }
    }

    @Test func exclusionsCanBeExtendedButNotShortened() {
        var active = adult
        active.selfExcludedUntilMS = now + 1_000
        var shorter = active
        shorter.selfExcludedUntilMS = now + 10
        var longer = active
        longer.selfExcludedUntilMS = now + 5_000
        #expect(throws: PlayBlock.cannotShortenExclusion) { try PlayGuard.validateChange(from: active, to: shorter, nowMS: now) }
        #expect(throws: PlayBlock.cannotShortenExclusion) { try PlayGuard.validateChange(from: active, to: adult, nowMS: now) }
        #expect(throws: Never.self) { try PlayGuard.validateChange(from: active, to: longer, nowMS: now) }
        #expect(throws: Never.self) { try PlayGuard.validateChange(from: active, to: adult, nowMS: now + 2_000) }
    }

    @Test func settingsRoundTrip() throws {
        let settings = PlaySettings(age: .adult18, dailyStakeLimit: nil, coolOffUntilMS: 5, selfExcludedUntilMS: nil)
        #expect(try PlaySettings(canonicalBytes: settings.canonicalBytes) == settings)
        #expect(try PlaySettings(canonicalBytes: adult.canonicalBytes) == adult)
    }
}
