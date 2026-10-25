import Foundation
import Testing
@testable import SecureConnect
@testable import SecureCore

/// 2026-09-01 00:00 UTC.
let september1MS: Int64 = 1_788_220_800_000
let dayMS: Int64 = 86_400_000

@Suite("Simulated banks")
struct BankingTests {
    let aggregator = SimulatedAggregator()
    let harbor = Institution.simulated[0]

    @Test func isDeterministic() {
        let a = aggregator.transactions(institution: harbor, account: harbor.accounts[0], fromMS: september1MS,
                                        toMS: september1MS + 30 * dayMS)
        let b = aggregator.transactions(institution: harbor, account: harbor.accounts[0], fromMS: september1MS,
                                        toMS: september1MS + 30 * dayMS)
        #expect(a == b)
        #expect(a.count > 20)
    }

    @Test func paysPayrollOnThe1stAnd15th() {
        let month = aggregator.transactions(institution: harbor, account: harbor.accounts[0], fromMS: september1MS,
                                            toMS: september1MS + 30 * dayMS)
        let paydays = month.filter { $0.category == .income }.map { SimulatedAggregator.dayOfMonth($0.postedAtMS / dayMS) }
        #expect(paydays == [1, 15])
        #expect(month.contains { $0.category == .housing && $0.amount.minorUnits == -1_400_00 })
    }

    @Test func transactionsStayInRangeAndInOrder() {
        let from = september1MS + 3 * dayMS + 12_345
        let to = september1MS + 20 * dayMS
        let items = aggregator.transactions(institution: harbor, account: harbor.accounts[0], fromMS: from, toMS: to)
        #expect(items.allSatisfy { $0.postedAtMS >= from && $0.postedAtMS < to })
        #expect(items.map(\.postedAtMS) == items.map(\.postedAtMS).sorted())
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func splittingTheRangeReturnsTheSameTransactions() {
        let card = Institution.simulated[1]
        let start = september1MS
        let middle = september1MS + 11 * dayMS + 7_200_000
        let end = september1MS + 25 * dayMS
        let whole = aggregator.transactions(institution: card, account: card.accounts[0], fromMS: start, toMS: end)
        let parts = aggregator.transactions(institution: card, account: card.accounts[0], fromMS: start, toMS: middle)
            + aggregator.transactions(institution: card, account: card.accounts[0], fromMS: middle, toMS: end)
        #expect(whole == parts)
    }

    @Test func institutionsAreClearlyFictional() {
        #expect(Institution.simulated.allSatisfy { $0.name.hasSuffix("(demo)") })
        #expect(Institution.simulated.flatMap(\.accounts).contains { $0.kind == .credit && $0.openingBalanceMinor < 0 })
    }
}

@Suite("Simulated markets")
struct MarketTests {
    @Test func pricesAreDeterministicPositiveAndComplete() {
        let orbit = Equity.find("ORBT")!
        let a = EquitySimulator.closes(for: orbit, through: 30)
        #expect(a == EquitySimulator.closes(for: orbit, through: 30))
        #expect(a.count == EquitySimulator.historyDays + 31)
        #expect(a.allSatisfy { $0 > 0 })
    }

    @Test func advancingDaysNeverRewritesHistory() {
        for equity in Equity.all {
            let earlier = EquitySimulator.closes(for: equity, through: 10)
            let later = EquitySimulator.closes(for: equity, through: 40)
            #expect(Array(later.prefix(earlier.count)) == earlier)
        }
    }

    @Test func bondFundIsCalmerThanATechStock() {
        func volatility(_ ticker: String) -> Double {
            let closes = EquitySimulator.closes(for: Equity.find(ticker)!, through: 0).map(Double.init)
            let returns = zip(closes.dropFirst(), closes).map { log($0 / $1) }
            let mean = returns.reduce(0, +) / Double(returns.count)
            return (returns.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(returns.count)).squareRoot()
        }
        #expect(volatility("AGGB") < volatility("ORBT") / 2)
    }

    @Test func quotesHaveASpread() {
        for equity in Equity.all {
            let quote = EquitySimulator.quote(for: equity, day: 5)
            #expect(quote.bid < quote.price && quote.price < quote.ask)
        }
    }

    @Test func contractsSettleToTheirOutcome() {
        for index in 0..<60 {
            let event = PredictionCatalog.event(index: index)
            for day in event.openDay..<event.closeDay {
                #expect((3...97).contains(event.midCents(day: day)))
            }
            #expect(event.midCents(day: event.closeDay) == (event.resolvesYes ? 100 : 0))
        }
    }

    @Test func thereAreAlwaysOpenEvents() {
        for day in 0..<60 {
            let open = PredictionCatalog.openEvents(day: day)
            #expect(!open.isEmpty)
            #expect(open.allSatisfy { $0.isOpen(day: day) })
        }
    }

    @Test func contractBuyPricesAlwaysTotal102Cents() {
        for index in 0..<40 {
            let event = PredictionCatalog.event(index: index)
            let quote = event.quote(day: event.openDay)
            #expect(quote.yesAsk + quote.noAsk == 102)
        }
    }

    @Test func gamesCarryTheMarginAndFavourStrongerTeams() {
        for index in 0..<40 {
            let fixture = SportsCatalog.fixture(index: index)
            let odds = [fixture.americanOdds(.home), fixture.americanOdds(.away)]
            #expect((1.02...1.08).contains(Odds.overround(american: odds)))
            let favourite: SportsSelection = fixture.homeWinProbability >= 0.5 ? .home : .away
            let underdog: SportsSelection = favourite == .home ? .away : .home
            #expect(Odds.impliedProbability(american: fixture.americanOdds(favourite))
                    >= Odds.impliedProbability(american: fixture.americanOdds(underdog)))
        }
    }

    @Test func twoGamesPerDay() {
        let games = SportsCatalog.fixtures(fromDay: 0, throughDay: 4)
        #expect(games.count == 10)
        #expect(games.allSatisfy { $0.home != $0.away })
    }

    @Test func outcomesTrackProbabilities() {
        let games = (0..<600).map(SportsCatalog.fixture(index:))
        let expected = games.map(\.homeWinProbability).reduce(0, +) / Double(games.count)
        let observed = Double(games.filter { $0.winner == .home }.count) / Double(games.count)
        #expect(abs(observed - expected) < 0.06)
    }

    @Test func idsRoundTrip() {
        #expect(PredictionCatalog.find(id: "evt-7") == PredictionCatalog.event(index: 7))
        #expect(SportsCatalog.find(id: "fx-9") == SportsCatalog.fixture(index: 9))
        #expect(PredictionCatalog.find(id: "evt-x") == nil)
        #expect(SportsCatalog.find(id: "game-1") == nil)
    }
}
