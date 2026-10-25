import SecureConnect
import SecureCore
import SwiftUI

/// The strategy guide and calculators. General education, not personal advice.
struct LearnView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(StrategyCatalog.disclaimer, systemImage: "info.circle").font(.footnote)
                }
                Section("Calculators") {
                    NavigationLink { ExpectedValueCalculator() } label: { Label("Expected value", systemImage: "plusminus") }
                    NavigationLink { KellyCalculator() } label: { Label("Kelly bet size", systemImage: "percent") }
                    NavigationLink { DCABacktestView() } label: { Label("DCA backtest", systemImage: "calendar") }
                    NavigationLink { MartingaleSimulatorView() } label: { Label("Martingale simulator", systemImage: "exclamationmark.triangle") }
                }
                ForEach(Strategy.Group.allCases.filter { $0 != .sports || AppFeatures.sportsBetting }, id: \.self) { group in
                    Section(group.title) {
                        ForEach(StrategyCatalog.strategies(in: group)) { strategy in
                            NavigationLink { StrategyDetailView(strategy: strategy) } label: { StrategyRow(strategy: strategy) }
                        }
                    }
                }
            }
            .navigationTitle("Learn")
        }
    }
}

struct StrategyRow: View {
    let strategy: Strategy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(strategy.name)
            Text(strategy.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Tag(text: strategy.complexity.title)
                Tag(text: strategy.availability.title)
            }
        }
        .padding(.vertical, 2)
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: .capsule)
    }
}

struct StrategyDetailView: View {
    let strategy: Strategy

    var body: some View {
        List {
            Section { Text(strategy.summary).font(.headline) }
            Section("How it works") { Text(strategy.howItWorks) }
            Section("Example") { Text(strategy.example) }
            Section("When it's used") { Text(strategy.whenUsed) }
            Section("Risks") {
                ForEach(strategy.risks, id: \.self) { risk in Label(risk, systemImage: "exclamationmark.triangle").foregroundStyle(.primary) }
            }
            Section("Details") {
                LabeledContent("Complexity", value: strategy.complexity.title)
                LabeledContent("Time horizon", value: strategy.horizon)
                LabeledContent("In this app", value: strategy.availability.title)
                Text(strategy.practiceNote).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(strategy.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ExpectedValueCalculator: View {
    enum Mode: String, CaseIterable, Identifiable {
        case contract = "Contract price", odds = "Betting odds"
        var id: Self { self }
    }

    @State private var mode: Mode = .contract
    @State private var probability = 0.55
    @State private var priceCents = 40
    @State private var american = 150
    @State private var stake = 10.0

    var body: some View {
        Form {
            Picker("Priced as", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Section("Your estimate") {
                Text("\(Int((probability * 100).rounded())) % chance").monospacedDigit()
                Slider(value: $probability, in: 0.01...0.99)
            }
            switch mode {
            case .contract:
                Section("Contract") {
                    Stepper("Price: \(cents(priceCents))", value: $priceCents, in: 1...99)
                    LabeledContent("Market's implied chance", value: "\(priceCents) %")
                    LabeledContent("Expected value", value: "\(StrategyMath.contractEdge(probability: probability, priceCents: priceCents).formatted(.number.precision(.fractionLength(1))))¢ per contract")
                    LabeledContent("Kelly fraction", value: percent(StrategyMath.kellyFraction(probability: probability, contractPriceCents: priceCents)))
                }
            case .odds:
                Section("Bet") {
                    Stepper("Odds: \(oddsText(american))", value: $american, in: -1_000...1_000, step: 5)
                    Stepper("Stake: $\(Int(stake))", value: $stake, in: 1...1_000)
                    let odds = abs(american) < 100 ? 100 : american
                    LabeledContent("Implied chance", value: percent(Odds.impliedProbability(american: odds)))
                    LabeledContent("Expected profit", value: "$" + StrategyMath.expectedValue(probability: probability, decimalOdds: Odds.decimal(american: odds), stake: stake).formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("Kelly fraction", value: percent(StrategyMath.kellyFraction(probability: probability, decimalOdds: Odds.decimal(american: odds))))
                }
            }
            Section { Text("EV = probability × win − (1 − probability) × stake. Positive EV needs your estimate to beat the price, after costs.").font(.footnote) }
        }
        .navigationTitle("Expected value")
    }
}

struct KellyCalculator: View {
    @State private var probability = 0.55
    @State private var american = 100
    @State private var bankroll = 1_000.0

    var body: some View {
        let odds = abs(american) < 100 ? 100 : american
        let full = StrategyMath.kellyFraction(probability: probability, decimalOdds: Odds.decimal(american: odds))
        Form {
            Section("Inputs") {
                Text("Win probability: \(Int((probability * 100).rounded())) %")
                Slider(value: $probability, in: 0.01...0.99)
                Stepper("Odds: \(oddsText(odds))", value: $american, in: -1_000...1_000, step: 5)
                Stepper("Bankroll: $\(Int(bankroll))", value: $bankroll, in: 100...100_000, step: 100)
            }
            Section("Suggested stake") {
                if full == 0 {
                    Label("No edge at these odds: Kelly says don't bet.", systemImage: "hand.raised")
                } else {
                    LabeledContent("Full Kelly", value: "\(percent(full)) · $\(Int(full * bankroll))")
                    LabeledContent("Half Kelly", value: "\(percent(full / 2)) · $\(Int(full / 2 * bankroll))")
                    LabeledContent("Quarter Kelly", value: "\(percent(full / 4)) · $\(Int(full / 4 * bankroll))")
                }
            }
            Section { Text("f* = (b·p − q) / b, where b = decimal odds − 1. Overestimating p leads to overbetting, which is why many use half or quarter Kelly.").font(.footnote) }
        }
        .navigationTitle("Kelly bet size")
    }
}

struct DCABacktestView: View {
    @Environment(ConnectedModel.self) private var connected
    @State private var ticker = "TMKT"
    @State private var amount = 100.0
    @State private var every = 21

    var body: some View {
        let closes = Equity.find(ticker).map { EquitySimulator.closes(for: $0, through: connected.simDay) } ?? []
        let result = StrategyMath.dollarCostAveraging(prices: closes, every: every, amountPerBuy: amount * 100)
        Form {
            Section("Plan") {
                Picker("Investment", selection: $ticker) { ForEach(Equity.all) { Text("\($0.ticker) · \($0.name)").tag($0.ticker) } }
                Stepper("Invest $\(Int(amount)) each time", value: $amount, in: 10...5_000, step: 10)
                Stepper("Every \(every) market days", value: $every, in: 1...63)
            }
            if let result {
                Section("Over \(closes.count) simulated market days") {
                    LabeledContent("Purchases", value: "\(result.buys)")
                    LabeledContent("Invested", value: dollars(result.invested))
                    LabeledContent("DCA value now", value: dollars(result.valueDCA))
                    LabeledContent("DCA average cost", value: dollars(result.averageCostDCA))
                    LabeledContent("Lump sum on day one, value now", value: dollars(result.valueLumpSum))
                }
                Section {
                    Text(result.valueLumpSum >= result.valueDCA
                         ? "Here the lump sum came out ahead, which is typical when prices mostly rise."
                         : "Here DCA came out ahead, which happens when prices fall after the start.")
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("DCA backtest")
    }

    private func dollars(_ minor: Double) -> String { (minor / 100).formatted(.currency(code: "USD")) }
}

struct MartingaleSimulatorView: View {
    @State private var bankroll = 1_000.0
    @State private var baseStake = 10.0
    @State private var winProbability = 0.4762
    @State private var rounds = 500

    var body: some View {
        let result = StrategyMath.martingale(bankroll: bankroll, baseStake: baseStake, winProbability: winProbability,
                                             decimalOdds: 2.0, rounds: rounds, trials: 2_000, seed: 2026)
        Form {
            Section("Setup (even-money bets)") {
                Stepper("Bankroll: $\(Int(bankroll))", value: $bankroll, in: 100...100_000, step: 100)
                Stepper("Base stake: $\(Int(baseStake))", value: $baseStake, in: 1...500)
                Text("Win chance per bet: \(percent(winProbability))")
                Slider(value: $winProbability, in: 0.40...0.55)
                Stepper("Bets per session: \(rounds)", value: $rounds, in: 50...5_000, step: 50)
            }
            Section("Across 2,000 simulated sessions") {
                LabeledContent("Sessions that went bust", value: percent(result.ruinProbability))
                LabeledContent("Median ending bankroll", value: "$\(Int(result.medianFinal))")
                LabeledContent("Average ending bankroll", value: "$\(Int(result.averageFinal))")
            }
            Section {
                Text("47.6 % is the break-even rate at −110 odds. Doubling after losses wins small amounts most of the time, until a losing streak needs a stake larger than the bankroll.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Martingale simulator")
    }
}
