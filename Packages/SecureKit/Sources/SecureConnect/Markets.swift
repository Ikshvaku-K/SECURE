import Foundation
import SecureCore

public enum MarketKind: String, Sendable, CaseIterable {
    case equity, prediction, sports

    public var displayName: String {
        switch self {
        case .equity: "Stocks & ETFs"
        case .prediction: "Prediction markets"
        case .sports: "Sports"
        }
    }
}

// MARK: - Stocks and ETFs

/// A fictional, simulated security. Prices follow geometric Brownian motion (a random walk on log prices).
public struct Equity: Sendable, Identifiable, Hashable {
    public let ticker: String
    public let name: String
    public let isETF: Bool
    public let sector: String
    public let startPriceMinor: Int64
    public let annualDrift: Double
    public let annualVolatility: Double

    public var id: String { ticker }

    public static let all: [Equity] = [
        Equity(ticker: "ORBT", name: "Orbit Robotics", isETF: false, sector: "Technology", startPriceMinor: 142_00,
               annualDrift: 0.12, annualVolatility: 0.35),
        Equity(ticker: "QNTA", name: "Quanta Software", isETF: false, sector: "Technology", startPriceMinor: 96_00,
               annualDrift: 0.14, annualVolatility: 0.40),
        Equity(ticker: "CBLT", name: "Cobalt Energy", isETF: false, sector: "Energy", startPriceMinor: 58_00,
               annualDrift: 0.06, annualVolatility: 0.28),
        Equity(ticker: "VITA", name: "Vita Health", isETF: false, sector: "Healthcare", startPriceMinor: 73_00,
               annualDrift: 0.08, annualVolatility: 0.22),
        Equity(ticker: "HLIO", name: "Helio Aerospace", isETF: false, sector: "Industrials", startPriceMinor: 188_00,
               annualDrift: 0.10, annualVolatility: 0.30),
        Equity(ticker: "HRVS", name: "Harvest Foods", isETF: false, sector: "Consumer staples", startPriceMinor: 45_00,
               annualDrift: 0.07, annualVolatility: 0.18),
        Equity(ticker: "TMKT", name: "Total Market Index ETF", isETF: true, sector: "Broad market", startPriceMinor: 210_00,
               annualDrift: 0.09, annualVolatility: 0.16),
        Equity(ticker: "AGGB", name: "Aggregate Bond ETF", isETF: true, sector: "Bonds", startPriceMinor: 98_00,
               annualDrift: 0.035, annualVolatility: 0.06),
    ]

    public static func find(_ ticker: String) -> Equity? { all.first { $0.ticker == ticker } }
}

public struct EquityQuote: Sendable, Hashable {
    public let price: Int64
    public let bid: Int64
    public let ask: Int64
    public let previousClose: Int64

    public var change: Int64 { price - previousClose }
    public var changePercent: Double { previousClose == 0 ? 0 : Double(change) / Double(previousClose) * 100 }
}

public enum EquitySimulator {
    /// One simulated trading year of history before day 0.
    public static let historyDays = 252

    /// Closing prices for days `-historyDays … day`, in minor units; index 0 is day `-historyDays`.
    public static func closes(for equity: Equity, through day: Int) -> [Int64] {
        let steps = day + historyDays
        guard steps >= 0 else { return [] }
        var price = Double(equity.startPriceMinor)
        var out = [equity.startPriceMinor]
        out.reserveCapacity(steps + 1)
        let dt = 1.0 / 252
        let mu = equity.annualDrift
        let sigma = equity.annualVolatility
        let seed = SimRandom.seed(equity.ticker)
        if steps > 0 {
            for step in 1...steps {
                var g = SimRandom.generator(seed, SimRandom.day(step - historyDays))
                let z = SimRandom.normal(&g)
                price *= exp((mu - sigma * sigma / 2) * dt + sigma * dt.squareRoot() * z)
                out.append(max(1, Int64(price.rounded())))
            }
        }
        return out
    }

    /// Price with a 0.05 % half-spread on each side (at least one cent).
    public static func quote(for equity: Equity, day: Int) -> EquityQuote {
        let history = closes(for: equity, through: day)
        let price = history.last ?? equity.startPriceMinor
        let previous = history.count > 1 ? history[history.count - 2] : price
        let halfSpread = max(1, price / 2_000)
        return EquityQuote(price: price, bid: max(1, price - halfSpread), ask: price + halfSpread, previousClose: previous)
    }
}

// MARK: - Prediction markets

public struct ContractQuote: Sendable, Hashable {
    public let mid: Int
    public let yesBid: Int
    public let yesAsk: Int

    public var noBid: Int { 100 - yesAsk }
    public var noAsk: Int { 100 - yesBid }
}

/// A yes/no event contract paying 100¢ if the event happens. Questions are fictional ("Avalon" is an invented country).
public struct PredictionEvent: Sendable, Identifiable, Hashable {
    public let id: String
    public let question: String
    public let category: String
    public let openDay: Int
    public let closeDay: Int
    let trueProbability: Double
    let seed: UInt64

    /// The outcome, fixed from the start but not shown until the close.
    public var resolvesYes: Bool {
        var g = SimRandom.generator(seed, 0xFACE)
        return SimRandom.uniform(&g) < trueProbability
    }

    public func isOpen(day: Int) -> Bool { openDay <= day && day < closeDay }

    /// Midpoint in cents. While open it starts near the true probability and drifts toward the outcome
    /// with shrinking noise, as information arrives; at the close it settles at 100 or 0.
    public func midCents(day: Int) -> Int {
        if day >= closeDay { return resolvesYes ? 100 : 0 }
        let current = max(day, openDay)
        let progress = Double(current - openDay) / Double(closeDay - openDay)
        var startGenerator = SimRandom.generator(seed, 0x0BE9)
        let start = min(0.92, max(0.08, trueProbability + 0.04 * SimRandom.normal(&startGenerator)))
        let target: Double = resolvesYes ? 1 : 0
        var dayGenerator = SimRandom.generator(seed, SimRandom.day(current))
        let noise = 0.05 * SimRandom.normal(&dayGenerator) * (1 - progress)
        let value = start + (target - start) * progress * progress + noise
        return Int((min(0.97, max(0.03, value)) * 100).rounded())
    }

    /// One-cent spread each side of the midpoint.
    public func quote(day: Int) -> ContractQuote {
        let mid = midCents(day: day)
        return ContractQuote(mid: mid, yesBid: max(1, mid - 1), yesAsk: min(99, mid + 1))
    }
}

public enum PredictionCatalog {
    private static let templates: [(question: String, category: String, probability: ClosedRange<Double>)] = [
        ("Will it rain in Harbor City on the closing day?", "Weather", 0.25...0.65),
        ("Will the Riverfront Festival sell out before it opens?", "Culture", 0.30...0.70),
        ("Will the Central Bank of Avalon cut interest rates at its next meeting?", "Economics", 0.20...0.60),
        ("Will Avalon's monthly inflation figure come in under 3%?", "Economics", 0.40...0.75),
        ("Will Metro Line 4 open on schedule?", "Infrastructure", 0.15...0.45),
        ("Will the film \"Starfall\" top the box office this weekend?", "Entertainment", 0.30...0.80),
        ("Will Harbor City record a temperature above 30°C this week?", "Weather", 0.20...0.50),
        ("Will the city council pass the bike-lane budget?", "Local politics", 0.45...0.80),
        ("Will Orbit Robotics (simulated) announce a new product this week?", "Business", 0.10...0.40),
        ("Will the Summit Marathon set a new course record?", "Sports", 0.05...0.25),
        ("Will Avalon's unemployment rate fall this month?", "Economics", 0.35...0.65),
        ("Will the Harbor City Hawks reach the league final?", "Sports", 0.15...0.55),
    ]

    /// One new event opens each day; each stays open 3–11 days.
    public static func event(index: Int) -> PredictionEvent {
        let template = templates[index % templates.count]
        let seed = SimRandom.seed("event-\(index)")
        var g = SimRandom.generator(seed, 0x0D0D)
        let range = template.probability
        let probability = range.lowerBound + SimRandom.uniform(&g) * (range.upperBound - range.lowerBound)
        let openDay = index - 8
        return PredictionEvent(id: "evt-\(index)", question: template.question, category: template.category, openDay: openDay,
                               closeDay: openDay + 3 + (index % 5) * 2, trueProbability: probability, seed: seed)
    }

    public static func openEvents(day: Int) -> [PredictionEvent] {
        (max(0, day - 3)...max(0, day + 8)).map(event(index:)).filter { $0.isOpen(day: day) }
    }

    public static func find(id: String) -> PredictionEvent? {
        guard id.hasPrefix("evt-"), let index = Int(id.dropFirst(4)), index >= 0 else { return nil }
        return event(index: index)
    }
}

// MARK: - Sports

public struct Team: Sendable, Hashable {
    public let name: String
    public let rating: Double
}

public enum SportsSelection: String, Sendable, CaseIterable {
    case home, away
}

/// A simulated game between fictional teams. Win probability comes from Elo-style ratings with home advantage;
/// the simulated bookmaker adds a 4.5 % margin.
public struct Fixture: Sendable, Identifiable, Hashable {
    public static let bookmakerMargin = 0.045
    public static let homeAdvantage = 60.0

    public let id: String
    public let league: String
    public let day: Int
    public let home: Team
    public let away: Team
    let seed: UInt64

    public var homeWinProbability: Double {
        1 / (1 + pow(10, (away.rating - home.rating - Self.homeAdvantage) / 400))
    }

    public func probability(_ selection: SportsSelection) -> Double {
        selection == .home ? homeWinProbability : 1 - homeWinProbability
    }

    public func americanOdds(_ selection: SportsSelection) -> Int {
        Odds.american(decimal: 1 / (probability(selection) * (1 + Self.bookmakerMargin)))
    }

    public var winner: SportsSelection {
        var g = SimRandom.generator(seed, 0xBA11)
        return SimRandom.uniform(&g) < homeWinProbability ? .home : .away
    }

    public func team(_ selection: SportsSelection) -> Team { selection == .home ? home : away }

    /// Bets are accepted until the game's day arrives.
    public func isOpenForBetting(day currentDay: Int) -> Bool { currentDay < day }
}

public enum SportsCatalog {
    public static let league = "Harbor League (simulated)"

    public static let teams: [Team] = [
        Team(name: "Harbor City Hawks", rating: 1620),
        Team(name: "Summit United", rating: 1580),
        Team(name: "Riverside Rovers", rating: 1500),
        Team(name: "Ironbridge Giants", rating: 1660),
        Team(name: "Lakeside Lynx", rating: 1450),
        Team(name: "Mesa Comets", rating: 1540),
        Team(name: "Northgate Knights", rating: 1700),
        Team(name: "Pinecrest Foxes", rating: 1420),
    ]

    /// Two games per day.
    public static func fixture(index: Int) -> Fixture {
        let home = teams[(index * 3) % teams.count]
        var away = teams[(index * 5 + 1) % teams.count]
        if away == home { away = teams[(index * 5 + 2) % teams.count] }
        return Fixture(id: "fx-\(index)", league: league, day: index / 2 - 2, home: home, away: away,
                       seed: SimRandom.seed("fixture-\(index)"))
    }

    public static func fixtures(fromDay: Int, throughDay: Int) -> [Fixture] {
        guard throughDay >= fromDay else { return [] }
        let first = max(0, (fromDay + 2) * 2)
        let last = max(0, (throughDay + 2) * 2 + 1)
        return (first...last).map(fixture(index:)).filter { $0.day >= fromDay && $0.day <= throughDay }
    }

    public static func find(id: String) -> Fixture? {
        guard id.hasPrefix("fx-"), let index = Int(id.dropFirst(3)), index >= 0 else { return nil }
        return fixture(index: index)
    }
}
