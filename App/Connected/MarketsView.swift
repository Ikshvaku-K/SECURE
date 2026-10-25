import Charts
import SecureConnect
import SecureCore
import SecureStore
import SwiftUI

enum MarketRoute: Hashable {
    case equity(String)
    case contract(String)
}

/// Practice trading and betting on simulated markets. Credit tier and responsible-play limits apply to every order.
struct MarketsView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case stocks = "Stocks & ETFs", predictions = "Predictions", sports = "Sports"
        var id: Self { self }
    }

    @Environment(ConnectedModel.self) private var connected
    @State private var segment: Segment = .stocks
    @State private var betTarget: Fixture?

    var body: some View {
        NavigationStack {
            ConnectedGate {
                List {
                    Section { PracticeHeader() }
                    if connected.tier == nil {
                        Section {
                            Label("Set a credit score in Profile to unlock practice transactions.", systemImage: "lock.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section {
                        Picker("Market", selection: $segment) {
                            ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    switch segment {
                    case .stocks:
                        Section("Simulated stocks and ETFs") {
                            ForEach(Equity.all) { equity in
                                NavigationLink(value: MarketRoute.equity(equity.ticker)) { EquityRow(equity: equity, day: connected.simDay) }
                            }
                        }
                    case .predictions:
                        Section("Open events · pays $1 per correct contract") {
                            ForEach(connected.openEvents) { event in
                                NavigationLink(value: MarketRoute.contract(event.id)) { ContractRow(event: event, day: connected.simDay) }
                            }
                        }
                    case .sports:
                        Section("Upcoming · \(SportsCatalog.league)") {
                            ForEach(connected.upcomingGames) { game in
                                Button { betTarget = game } label: { GameRow(game: game) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .navigationDestination(for: MarketRoute.self) { route in
                    switch route {
                    case .equity(let ticker): EquityDetailView(ticker: ticker)
                    case .contract(let id): ContractDetailView(eventID: id)
                    }
                }
            }
            .navigationTitle("Markets")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { PortfolioView() } label: { Label("Portfolio", systemImage: "briefcase") }
                }
            }
            .sheet(item: $betTarget) { BetSheet(fixture: $0) }
            .overlay(alignment: .bottom) { ConnectedBanner() }
        }
    }
}

struct PracticeHeader: View {
    @Environment(ConnectedModel.self) private var connected

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SimulatedBadge()
            if let portfolio = connected.portfolio {
                Text(portfolio.totalValue.formatted())
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                HStack {
                    LabeledValue(title: "Cash", value: portfolio.cash.formatted())
                    Spacer()
                    LabeledValue(title: "Profit / loss", value: signed(portfolio.profit))
                        .foregroundStyle(portfolio.profit.minorUnits >= 0 ? .green : .red)
                }
            }
            HStack {
                Text("Market day \(connected.simDay)").font(.subheadline.weight(.medium))
                Spacer()
                Button { Task { await connected.advanceDay() } } label: { Label("Next day", systemImage: "forward.fill") }
                    .buttonStyle(.borderedProminent)
            }
            AccessLine()
        }
        .padding(.vertical, 4)
    }
}

/// "Good tier · 2 of 10 transactions today · up to $500 each".
struct AccessLine: View {
    @Environment(ConnectedModel.self) private var connected

    var body: some View {
        if let tier = connected.tier {
            Label("\(tier.name) tier · \(connected.transactionsToday) of \(tier.limits.transactionsPerDay) transactions today · up to \(tier.limits.maxPerTransaction.formatted()) each",
                  systemImage: "gauge.with.dots.needle.50percent")
                .font(.caption)
                .foregroundStyle(tier.color)
        }
    }
}

struct EquityRow: View {
    let equity: Equity
    let day: Int

    var body: some View {
        let quote = EquitySimulator.quote(for: equity, day: day)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(equity.ticker).font(.headline.monospaced())
                    if equity.isETF { Text("ETF").font(.caption2.weight(.bold)).padding(.horizontal, 4).background(.quaternary, in: .capsule) }
                }
                Text(equity.name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money(minorUnits: quote.price, currency: .usd).formatted()).monospacedDigit()
                Text((quote.change >= 0 ? "+" : "") + quote.changePercent.formatted(.number.precision(.fractionLength(2))) + " %")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(quote.change >= 0 ? .green : .red)
            }
        }
    }
}

struct ContractRow: View {
    let event: PredictionEvent
    let day: Int

    var body: some View {
        let quote = event.quote(day: day)
        VStack(alignment: .leading, spacing: 6) {
            Text(event.question)
            HStack {
                Text(event.category).font(.caption).foregroundStyle(.secondary)
                Text("· closes day \(event.closeDay)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("YES \(cents(quote.yesAsk))").font(.caption.weight(.semibold)).foregroundStyle(.green)
                Text("NO \(cents(quote.noAsk))").font(.caption.weight(.semibold)).foregroundStyle(.red)
            }
        }
    }
}

struct GameRow: View {
    let game: Fixture

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(game.home.name) vs \(game.away.name)")
                Text("Market day \(game.day) · home team listed first").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(oddsText(game.americanOdds(.home))).monospacedDigit()
                Text(oddsText(game.americanOdds(.away))).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout.weight(.semibold))
        }
        .contentShape(.rect)
    }
}

struct EquityDetailView: View {
    let ticker: String
    @Environment(ConnectedModel.self) private var connected
    @State private var quantity = 1

    var body: some View {
        if let equity = Equity.find(ticker) {
            let quote = EquitySimulator.quote(for: equity, day: connected.simDay)
            let closes = Array(EquitySimulator.closes(for: equity, through: connected.simDay).suffix(120))
            let position = connected.position(.equity, ticker, .buy)
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(equity.name).font(.subheadline).foregroundStyle(.secondary)
                        Text(Money(minorUnits: quote.price, currency: .usd).formatted())
                            .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("\(equity.sector) · bid \(Money(minorUnits: quote.bid, currency: .usd).formatted()) · ask \(Money(minorUnits: quote.ask, currency: .usd).formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    PriceChart(closes: closes, endDay: connected.simDay)
                }
                if let position {
                    Section("Your position") {
                        LabeledContent("Shares", value: "\(position.quantity)")
                        LabeledContent("Cost", value: position.cost.formatted())
                        LabeledContent("Value", value: position.markValue.formatted())
                        LabeledContent("Profit / loss", value: signed(position.profit))
                    }
                }
                Section {
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...1_000)
                    LabeledContent("Buy cost", value: Money(minorUnits: quote.ask * Int64(quantity), currency: .usd).formatted())
                    HStack {
                        Button("Buy") { Task { await connected.trade(ticker, side: .buy, quantity: Int64(quantity)) } }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Sell") { Task { await connected.trade(ticker, side: .sell, quantity: Int64(quantity)) } }
                            .buttonStyle(.bordered)
                            .disabled((position?.quantity ?? 0) < Int64(quantity))
                    }
                } header: {
                    Text("Trade")
                } footer: {
                    AccessLine()
                }
            }
            .navigationTitle(ticker)
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) { ConnectedBanner() }
        }
    }
}

struct PriceChart: View {
    let closes: [Int64]
    let endDay: Int

    var body: some View {
        let points = closes.enumerated().map { (day: endDay - (closes.count - 1) + $0.offset, price: Double($0.element) / 100) }
        let low = points.map(\.price).min() ?? 0
        let high = points.map(\.price).max() ?? 1
        Chart(points, id: \.day) { point in
            LineMark(x: .value("Market day", point.day), y: .value("Price", point.price))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: (low * 0.97)...(high * 1.03))
        .chartXScale(domain: (points.first?.day ?? 0)...(points.last?.day ?? 1))
        .frame(height: 180)
        .accessibilityLabel("Price over the last \(closes.count) market days")
    }
}

struct ContractDetailView: View {
    let eventID: String
    @Environment(ConnectedModel.self) private var connected
    @State private var side: PracticeSide = .yes
    @State private var quantity = 10
    @State private var myProbability = 0.5

    var body: some View {
        if let event = PredictionCatalog.find(id: eventID) {
            let quote = event.quote(day: connected.simDay)
            let price = side == .yes ? quote.yesAsk : quote.noAsk
            let position = connected.position(.prediction, eventID, side)
            List {
                Section {
                    Text(event.question).font(.headline)
                    LabeledContent("Category", value: event.category)
                    LabeledContent("Closes", value: event.isOpen(day: connected.simDay) ? "Market day \(event.closeDay)" : "Closed")
                    HStack {
                        Text("YES \(cents(quote.yesAsk))").foregroundStyle(.green)
                        Spacer()
                        Text("Market says \(quote.mid) % likely").foregroundStyle(.secondary)
                        Spacer()
                        Text("NO \(cents(quote.noAsk))").foregroundStyle(.red)
                    }
                    .font(.callout.weight(.semibold))
                    ProbabilityChart(event: event, day: connected.simDay)
                }
                Section {
                    VStack(alignment: .leading) {
                        Text("Your estimate: \(Int((myProbability * 100).rounded())) % chance of YES")
                        Slider(value: $myProbability, in: 0.01...0.99)
                    }
                    let yesEdge = StrategyMath.contractEdge(probability: myProbability, priceCents: quote.yesAsk)
                    let noEdge = StrategyMath.contractEdge(probability: 1 - myProbability, priceCents: quote.noAsk)
                    LabeledContent("Edge buying YES", value: "\(yesEdge.formatted(.number.precision(.fractionLength(1))))¢ per contract")
                    LabeledContent("Edge buying NO", value: "\(noEdge.formatted(.number.precision(.fractionLength(1))))¢ per contract")
                } header: {
                    Text("Expected value")
                } footer: {
                    Text("Positive edge means the price is below your estimate. It's only as good as your estimate.")
                }
                if let position {
                    Section("Your \(side == .yes ? "YES" : "NO") position") {
                        LabeledContent("Contracts", value: "\(position.quantity)")
                        LabeledContent("Cost", value: position.cost.formatted())
                        LabeledContent("Value now", value: position.markValue.formatted())
                        LabeledContent("Pays if right", value: Money(minorUnits: position.quantity * 100, currency: .usd).formatted())
                    }
                }
                Section {
                    Picker("Side", selection: $side) {
                        Text("YES").tag(PracticeSide.yes)
                        Text("NO").tag(PracticeSide.no)
                    }
                    .pickerStyle(.segmented)
                    Stepper("Contracts: \(quantity)", value: $quantity, in: 1...500)
                    LabeledContent("Cost (max loss)", value: Money(minorUnits: Int64(price * quantity), currency: .usd).formatted())
                    LabeledContent("Pays if right", value: Money(minorUnits: Int64(100 * quantity), currency: .usd).formatted())
                    HStack {
                        Button("Buy \(side == .yes ? "YES" : "NO")") {
                            Task { await connected.trade(event: eventID, side: side, action: .open, quantity: Int64(quantity)) }
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Sell") {
                            Task { await connected.trade(event: eventID, side: side, action: .close, quantity: Int64(quantity)) }
                        }
                        .buttonStyle(.bordered)
                        .disabled((position?.quantity ?? 0) < Int64(quantity))
                    }
                    .disabled(!event.isOpen(day: connected.simDay))
                } header: {
                    Text("Trade")
                } footer: {
                    AccessLine()
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) { ConnectedBanner() }
        }
    }
}

struct ProbabilityChart: View {
    let event: PredictionEvent
    let day: Int

    var body: some View {
        let last = min(day, event.closeDay)
        let points = (event.openDay...max(event.openDay, last)).map { (day: $0, chance: event.midCents(day: $0)) }
        Chart(points, id: \.day) { point in
            LineMark(x: .value("Market day", point.day), y: .value("Chance %", point.chance))
            PointMark(x: .value("Market day", point.day), y: .value("Chance %", point.chance))
        }
        .chartYScale(domain: 0...100)
        .frame(height: 140)
        .accessibilityLabel("Market probability since the event opened")
    }
}

struct BetSheet: View {
    let fixture: Fixture
    @Environment(ConnectedModel.self) private var connected
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SportsSelection = .home
    @State private var stakeText = "10"

    private var stake: Money? { Money.parse(stakeText, currency: .usd, locale: .current) }

    var body: some View {
        let odds = [fixture.americanOdds(.home), fixture.americanOdds(.away)]
        let fair = Odds.fairProbabilities(american: odds)
        NavigationStack {
            Form {
                Section {
                    Picker("Pick", selection: $selection) {
                        Text("\(fixture.home.name) \(oddsText(odds[0]))").tag(SportsSelection.home)
                        Text("\(fixture.away.name) \(oddsText(odds[1]))").tag(SportsSelection.away)
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Market day \(fixture.day) · \(fixture.league)")
                }
                Section("Odds explained") {
                    ForEach(SportsSelection.allCases, id: \.self) { side in
                        let index = side == .home ? 0 : 1
                        LabeledContent(fixture.team(side).name,
                                       value: "implied \(percent(Odds.impliedProbability(american: odds[index]))) · fair \(percent(fair[index]))")
                    }
                    LabeledContent("Bookmaker margin", value: percent(Odds.overround(american: odds) - 1))
                }
                Section {
                    TextField("Stake", text: $stakeText).keyboardType(.decimalPad)
                    if let stake, stake.minorUnits > 0 {
                        let american = fixture.americanOdds(selection)
                        let payout = stake.minorUnits + Odds.profit(stake: stake.minorUnits, american: american)
                        LabeledContent("Returns if it wins", value: Money(minorUnits: payout, currency: .usd).formatted())
                    }
                } header: {
                    Text("Stake (practice money)")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        AccessLine()
                        Text("Sports needs age 21+ confirmed in Profile. Bets settle when you reach the game's market day.")
                    }
                }
            }
            .navigationTitle("Bet slip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Place bet") {
                        guard let stake else { return }
                        Task { if await connected.bet(on: fixture, selection: selection, stake: stake) { dismiss() } }
                    }
                    .disabled(stake == nil || stake?.minorUnits == 0)
                }
            }
            .overlay(alignment: .bottom) { ConnectedBanner() }
        }
    }
}

struct PortfolioView: View {
    @Environment(ConnectedModel.self) private var connected
    @State private var confirmingReset = false

    var body: some View {
        List {
            if let portfolio = connected.portfolio {
                Section {
                    LabeledContent("Total value", value: portfolio.totalValue.formatted())
                    LabeledContent("Cash", value: portfolio.cash.formatted())
                    LabeledContent("Started with", value: portfolio.startingCash.formatted())
                    LabeledContent("Profit / loss", value: signed(portfolio.profit))
                } header: {
                    SimulatedBadge()
                }
                Section("Positions") {
                    if portfolio.positions.isEmpty { Text("No open positions").foregroundStyle(.secondary) }
                    ForEach(portfolio.positions) { position in
                        LabeledContent(label(position), value: "\(position.markValue.formatted()) (\(signed(position.profit)))")
                    }
                }
                Section("Open bets") {
                    if portfolio.openBets.isEmpty { Text("No open bets").foregroundStyle(.secondary) }
                    ForEach(portfolio.openBets) { bet in LabeledContent(betLabel(bet), value: bet.stake.formatted()) }
                }
            }
            Section("Settled bets") {
                ForEach(connected.settledBets) { bet in
                    LabeledContent(betLabel(bet), value: bet.status == .won ? "Won \(bet.payout.formatted())" : "Lost")
                }
            }
            Section("History") {
                ForEach(connected.history) { order in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(order.action.rawValue.capitalized) · \(order.instrument) · \(order.side.rawValue.uppercased()) × \(order.quantity)")
                        Text("Day \(order.simDay) · \(signed(order.cashDelta))\(order.note.isEmpty ? "" : " · \(order.note)")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button("Reset practice account", role: .destructive) { confirmingReset = true }
            } footer: {
                Text("Clears practice positions, bets and history and restarts at market day 0. Your credit score and responsible-play settings stay.")
            }
        }
        .navigationTitle("Portfolio")
        .confirmationDialog("Reset the practice account?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { Task { await connected.resetPractice() } }
        }
        .overlay(alignment: .bottom) { ConnectedBanner() }
    }

    private func label(_ position: PracticePosition) -> String {
        switch position.market {
        case .equity: "\(position.instrument) × \(position.quantity)"
        case .prediction: "\(position.side == .yes ? "YES" : "NO") × \(position.quantity) · \(PredictionCatalog.find(id: position.instrument)?.question ?? position.instrument)"
        case .sports: position.instrument
        }
    }

    private func betLabel(_ bet: PracticeBet) -> String {
        let team = SportsCatalog.find(id: bet.fixtureID)?.team(bet.selection).name ?? bet.fixtureID
        return "\(team) \(oddsText(bet.americanOdds))"
    }
}
