import Foundation
import SecureCore

public enum AccountKind: String, Sendable, CaseIterable {
    case checking, savings, credit

    public var displayName: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .credit: "Credit card"
        }
    }
}

public enum BankCategory: String, Sendable, CaseIterable {
    case food, clothing, transport, housing, utilities, entertainment, health, income, transfer, interest

    public var displayName: String { rawValue.capitalized }

    public var symbol: String {
        switch self {
        case .food: "fork.knife"
        case .clothing: "tshirt"
        case .transport: "tram"
        case .housing: "house"
        case .utilities: "bolt"
        case .entertainment: "film"
        case .health: "cross.case"
        case .income: "arrow.down.circle"
        case .transfer: "arrow.left.arrow.right"
        case .interest: "percent"
        }
    }

    /// Counts as spending in summaries. Income, transfers between your own accounts and interest don't.
    public var isSpending: Bool {
        switch self {
        case .income, .transfer, .interest: false
        default: true
        }
    }
}

public struct AccountTemplate: Sendable, Hashable {
    public let key: String
    public let name: String
    public let kind: AccountKind
    /// Fictional last four digits.
    public let mask: String
    public let openingBalanceMinor: Int64
    /// Paid on the 1st and 15th (checking only).
    public let payrollMinor: Int64
    /// Paid on the 1st (checking only).
    public let rentMinor: Int64
}

/// A fictional bank. Every name here is invented; nothing connects to a real institution.
public struct Institution: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let symbol: String
    public let accounts: [AccountTemplate]

    public static let simulated: [Institution] = [
        Institution(id: "harbor-federal", name: "Harbor Federal (demo)", symbol: "building.columns", accounts: [
            AccountTemplate(key: "checking", name: "Everyday Checking", kind: .checking, mask: "4821",
                            openingBalanceMinor: 3_200_00, payrollMinor: 2_150_00, rentMinor: 1_400_00),
            AccountTemplate(key: "savings", name: "High-Yield Savings", kind: .savings, mask: "9034",
                            openingBalanceMinor: 8_500_00, payrollMinor: 0, rentMinor: 0),
        ]),
        Institution(id: "summit-cu", name: "Summit Credit Union (demo)", symbol: "mountain.2", accounts: [
            AccountTemplate(key: "card", name: "Rewards Card", kind: .credit, mask: "1177",
                            openingBalanceMinor: -450_00, payrollMinor: 0, rentMinor: 0),
        ]),
        Institution(id: "meridian", name: "Meridian Bank (demo)", symbol: "globe.americas", accounts: [
            AccountTemplate(key: "checking", name: "Student Checking", kind: .checking, mask: "6650",
                            openingBalanceMinor: 1_150_00, payrollMinor: 640_00, rentMinor: 0),
        ]),
    ]
}

public struct LinkedAccount: Sendable, Identifiable, Hashable {
    public let id: String
    public let institutionID: String
    public let institutionName: String
    public let name: String
    public let kind: AccountKind
    public let mask: String
    /// Negative for a credit card means money owed.
    public let balance: Money
    public let linkedAtMS: Int64
    public let syncedThroughMS: Int64

    public init(id: String, institutionID: String, institutionName: String, name: String, kind: AccountKind, mask: String,
                balance: Money, linkedAtMS: Int64, syncedThroughMS: Int64) {
        self.id = id
        self.institutionID = institutionID
        self.institutionName = institutionName
        self.name = name
        self.kind = kind
        self.mask = mask
        self.balance = balance
        self.linkedAtMS = linkedAtMS
        self.syncedThroughMS = syncedThroughMS
    }

    public var isLiability: Bool { kind == .credit }
}

public struct BankTransaction: Sendable, Identifiable, Hashable {
    public let id: String
    public let accountID: String
    public let postedAtMS: Int64
    /// Negative = money leaving the account (or added to a card balance).
    public let amount: Money
    public let merchant: String
    public let category: BankCategory

    public init(id: String, accountID: String, postedAtMS: Int64, amount: Money, merchant: String, category: BankCategory) {
        self.id = id
        self.accountID = accountID
        self.postedAtMS = postedAtMS
        self.amount = amount
        self.merchant = merchant
        self.category = category
    }

    public var postedAt: Date { Date(millisecondsSince1970: postedAtMS) }
}

public struct AccountAlert: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case largeTransaction, lowBalance }
    public let id: String
    public let kind: Kind
    public let title: String
    public let body: String

    public init(id: String, kind: Kind, title: String, body: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Source of linked-account data. The simulated aggregator is the only implementation in this build;
/// a real one (e.g. through an aggregator's API and a backend) would conform to the same protocol.
public protocol AccountAggregator: Sendable {
    var institutions: [Institution] { get }
    /// Days of history fetched when an institution is first linked.
    var historyDays: Int { get }
    var currency: CurrencyCode { get }
    /// Transactions posted in `[fromMS, toMS)`, oldest first.
    func transactions(institution: Institution, account: AccountTemplate, fromMS: Int64, toMS: Int64) -> [BankTransaction]
}

/// Synthetic but realistic-looking activity: paychecks, rent, utilities, groceries, card purchases and payments.
/// Deterministic per account and day, so re-syncing returns the same transactions with the same IDs.
public struct SimulatedAggregator: AccountAggregator {
    public let institutions = Institution.simulated
    public let historyDays = 60
    public let currency: CurrencyCode

    static let msPerDay: Int64 = 86_400_000

    public init(currency: CurrencyCode = .usd) {
        self.currency = currency
    }

    public func transactions(institution: Institution, account: AccountTemplate, fromMS: Int64, toMS: Int64) -> [BankTransaction] {
        guard toMS > fromMS else { return [] }
        let firstDay = Self.floorDiv(fromMS, Self.msPerDay)
        let lastDay = Self.floorDiv(toMS - 1, Self.msPerDay)
        return (firstDay...lastDay)
            .flatMap { transactions(onDay: $0, institution: institution, account: account) }
            .filter { $0.postedAtMS >= fromMS && $0.postedAtMS < toMS }
            .sorted { ($0.postedAtMS, $0.id) < ($1.postedAtMS, $1.id) }
    }

    private struct Item {
        let minute: Int64
        let amountMinor: Int64
        let merchant: String
        let category: BankCategory
    }

    private static let merchants: [BankCategory: [(String, ClosedRange<Double>)]] = [
        .food: [("Green Basket Market", 18...95), ("Corner Coffee", 3.5...9), ("Luigi's Kitchen", 14...48), ("Fresh Mart", 12...70)],
        .transport: [("Metro Transit", 2.5...6), ("QuickFuel", 25...60), ("RideNow", 9...32)],
        .entertainment: [("Starlight Cinema", 12...30), ("StreamBox", 9.99...15.99), ("Arcade 99", 8...25)],
        .health: [("Wellness Pharmacy", 6...45)],
        .clothing: [("Thread & Needle", 22...140), ("Denim Depot", 35...120), ("Northside Apparel", 18...90)],
    ]

    private func transactions(onDay day: Int64, institution: Institution, account: AccountTemplate) -> [BankTransaction] {
        let accountID = "\(institution.id).\(account.key)"
        var g = SimRandom.generator(SimRandom.seed(accountID), UInt64(bitPattern: day))
        let dayOfMonth = Self.dayOfMonth(day)
        var items: [Item] = []

        switch account.kind {
        case .checking:
            if account.payrollMinor > 0, dayOfMonth == 1 || dayOfMonth == 15 {
                items.append(Item(minute: 9 * 60, amountMinor: account.payrollMinor, merchant: "Northwind Payroll", category: .income))
            }
            if account.rentMinor > 0, dayOfMonth == 1 {
                items.append(Item(minute: 10 * 60, amountMinor: -account.rentMinor, merchant: "Maple Court Apartments", category: .housing))
            }
            if dayOfMonth == 5 {
                let bill = 95_00 + Int64(SimRandom.uniform(&g) * 45_00)
                items.append(Item(minute: 11 * 60, amountMinor: -bill, merchant: "City Power & Water", category: .utilities))
            }
            if account.rentMinor > 0, dayOfMonth == 20 {
                items.append(Item(minute: 12 * 60, amountMinor: -600_00, merchant: "Card payment", category: .transfer))
            }
            items += purchases(&g, palette: [(.food, 0.6), (.transport, 0.25), (.entertainment, 0.1), (.health, 0.05)],
                               scale: account.rentMinor > 0 ? 1 : 0.6)
        case .savings:
            if dayOfMonth == 1 {
                let interest = 28_00 + Int64(SimRandom.uniform(&g) * 8_00)
                items.append(Item(minute: 6 * 60, amountMinor: interest, merchant: "Interest paid", category: .interest))
            }
            if dayOfMonth == 16 {
                items.append(Item(minute: 8 * 60, amountMinor: 200_00, merchant: "Transfer from checking", category: .transfer))
            }
        case .credit:
            if dayOfMonth == 20 {
                items.append(Item(minute: 12 * 60, amountMinor: 600_00, merchant: "Payment received", category: .transfer))
            }
            items += purchases(&g, palette: [(.food, 0.35), (.clothing, 0.25), (.entertainment, 0.25), (.transport, 0.15)], scale: 1)
        }

        return items.enumerated().map { index, item in
            BankTransaction(id: "\(accountID).\(day).\(index)", accountID: accountID,
                            postedAtMS: day * Self.msPerDay + item.minute * 60_000,
                            amount: Money(minorUnits: item.amountMinor, currency: currency),
                            merchant: item.merchant, category: item.category)
        }
    }

    private func purchases(_ g: inout SplitMix64, palette: [(BankCategory, Double)], scale: Double) -> [Item] {
        let counts = [0, 0, 1, 1, 1, 2]
        let count = counts[min(counts.count - 1, Int(SimRandom.uniform(&g) * Double(counts.count)))]
        return (0..<count).map { slot in
            var pick = SimRandom.uniform(&g)
            var category = palette[0].0
            for (candidate, weight) in palette {
                if pick < weight { category = candidate; break }
                pick -= weight
            }
            let options = Self.merchants[category] ?? [("Store", 5...50)]
            let (merchant, range) = options[min(options.count - 1, Int(SimRandom.uniform(&g) * Double(options.count)))]
            let dollars = (range.lowerBound + SimRandom.uniform(&g) * (range.upperBound - range.lowerBound)) * scale
            let minute = Int64(13 * 60 + slot * 180) + Int64(SimRandom.uniform(&g) * 120)
            return Item(minute: minute, amountMinor: -max(1_00, Int64((dollars * 100).rounded())), merchant: merchant, category: category)
        }
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func dayOfMonth(_ day: Int64) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.day, from: Date(timeIntervalSince1970: TimeInterval(day) * 86_400))
    }
}
