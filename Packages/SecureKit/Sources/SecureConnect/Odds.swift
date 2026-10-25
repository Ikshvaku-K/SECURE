import Foundation
import SecureCore

/// Conversions between American odds, decimal odds and probabilities.
public enum Odds {
    /// +150 → 2.50, −200 → 1.50.
    public static func decimal(american: Int) -> Double {
        precondition(abs(american) >= 100, "American odds are at least ±100")
        return american > 0 ? 1 + Double(american) / 100 : 1 + 100 / Double(-american)
    }

    /// +150 → 0.40, −200 → 0.667. Includes the bookmaker's margin.
    public static func impliedProbability(american: Int) -> Double {
        precondition(abs(american) >= 100, "American odds are at least ±100")
        return american > 0 ? 100 / Double(american + 100) : Double(-american) / Double(-american + 100)
    }

    /// Decimal odds to American, rounded to the nearest 5 as bookmakers quote them.
    public static func american(decimal: Double) -> Int {
        precondition(decimal > 1, "Decimal odds are above 1")
        if decimal >= 2 { return max(100, Int(((decimal - 1) * 100 / 5).rounded()) * 5) }
        return min(-100, -Int((100 / (decimal - 1) / 5).rounded()) * 5)
    }

    /// Profit on a winning stake in minor units, rounded down to the cent.
    public static func profit(stake: Int64, american: Int) -> Int64 {
        american > 0 ? stake * Int64(american) / 100 : stake * 100 / Int64(-american)
    }

    /// Sum of implied probabilities; anything above 1 is the bookmaker's margin.
    public static func overround(american: [Int]) -> Double {
        american.map(impliedProbability(american:)).reduce(0, +)
    }

    /// Implied probabilities with the margin removed (normalised to sum to 1).
    public static func fairProbabilities(american: [Int]) -> [Double] {
        let implied = american.map(impliedProbability(american:))
        let total = implied.reduce(0, +)
        return implied.map { $0 / total }
    }
}

/// The arithmetic behind the strategies in `StrategyCatalog`, used by the in-app calculators.
public enum StrategyMath {
    /// Expected profit of a bet: p × winnings − (1 − p) × stake.
    public static func expectedValue(probability p: Double, decimalOdds d: Double, stake: Double) -> Double {
        p * (d - 1) * stake - (1 - p) * stake
    }

    /// Expected profit per 100¢ binary contract bought at `priceCents`.
    public static func contractEdge(probability p: Double, priceCents: Int) -> Double {
        p * 100 - Double(priceCents)
    }

    /// Kelly fraction of bankroll, (b·p − q) / b with b = decimal odds − 1. Zero when there is no edge.
    public static func kellyFraction(probability p: Double, decimalOdds d: Double) -> Double {
        let b = d - 1
        guard b > 0 else { return 0 }
        return max(0, (b * p - (1 - p)) / b)
    }

    /// Kelly for a binary contract: buying at `priceCents` is decimal odds of 100 / price.
    public static func kellyFraction(probability p: Double, contractPriceCents: Int) -> Double {
        guard contractPriceCents > 0, contractPriceCents < 100 else { return 0 }
        return kellyFraction(probability: p, decimalOdds: 100 / Double(contractPriceCents))
    }

    public struct DCAResult: Sendable, Equatable {
        public let buys: Int
        public let invested: Double
        public let unitsDCA: Double
        public let valueDCA: Double
        public let averageCostDCA: Double
        public let unitsLumpSum: Double
        public let valueLumpSum: Double
    }

    /// Buys `amountPerBuy` every `every` days through `prices`, and compares it with investing the same total on day one.
    public static func dollarCostAveraging(prices: [Int64], every: Int, amountPerBuy: Double) -> DCAResult? {
        guard let first = prices.first, let last = prices.last, every > 0, amountPerBuy > 0, first > 0 else { return nil }
        let buyDays = Array(stride(from: 0, to: prices.count, by: every))
        let units = buyDays.reduce(0.0) { $0 + amountPerBuy / Double(prices[$1]) }
        let invested = amountPerBuy * Double(buyDays.count)
        let lumpUnits = invested / Double(first)
        return DCAResult(buys: buyDays.count, invested: invested, unitsDCA: units, valueDCA: units * Double(last),
                         averageCostDCA: invested / units, unitsLumpSum: lumpUnits, valueLumpSum: lumpUnits * Double(last))
    }

    public struct MartingaleResult: Sendable, Equatable {
        public let trials: Int
        public let ruined: Int
        public let medianFinal: Double
        public let averageFinal: Double

        public var ruinProbability: Double { trials == 0 ? 0 : Double(ruined) / Double(trials) }
    }

    /// Monte Carlo of the doubling system: after a loss the stake doubles, after a win it resets.
    /// A trial is ruined when the bankroll can no longer cover the next required stake.
    public static func martingale(bankroll: Double, baseStake: Double, winProbability: Double, decimalOdds: Double,
                                  rounds: Int, trials: Int, seed: UInt64) -> MartingaleResult {
        var finals: [Double] = []
        finals.reserveCapacity(trials)
        var ruined = 0
        for trial in 0..<max(0, trials) {
            var g = SimRandom.generator(seed, UInt64(trial))
            var balance = bankroll
            var stake = baseStake
            for _ in 0..<max(0, rounds) {
                if stake > balance {
                    ruined += 1
                    break
                }
                if SimRandom.uniform(&g) < winProbability {
                    balance += stake * (decimalOdds - 1)
                    stake = baseStake
                } else {
                    balance -= stake
                    stake *= 2
                }
            }
            finals.append(balance)
        }
        let sorted = finals.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let average = finals.isEmpty ? 0 : finals.reduce(0, +) / Double(finals.count)
        return MartingaleResult(trials: finals.count, ruined: ruined, medianFinal: median, averageFinal: average)
    }
}
