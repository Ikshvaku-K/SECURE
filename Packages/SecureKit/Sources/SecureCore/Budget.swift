import Foundation

public enum BudgetPeriod: Equatable, Sendable {
    /// Starts on `anchorDay` each month, clamped to the month's length (31 → 30 in April, 28/29 in February).
    case monthly(anchorDay: Int)
    /// Starts on `anchorWeekday` (1 = Sunday … 7 = Saturday, as in `Calendar`).
    case weekly(anchorWeekday: Int)
    /// The last `days` days up to now.
    case rolling(days: Int)
    /// Repeating blocks of `lengthDays` starting at `start`.
    case custom(start: Date, lengthDays: Int)

    public var isValid: Bool {
        switch self {
        case .monthly(let day): (1...31).contains(day)
        case .weekly(let weekday): (1...7).contains(weekday)
        case .rolling(let days): days > 0
        case .custom(_, let length): length > 0
        }
    }

    /// The half-open window `[start, end)` that contains `now`, or nil if a custom period hasn't started.
    public func window(containing now: Date, calendar: Calendar) -> BudgetWindow? {
        guard isValid else { return nil }
        switch self {
        case .monthly(let anchorDay):
            func firstOfMonth(_ date: Date) -> Date {
                calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
            }
            func anchor(inMonthOf date: Date) -> Date {
                let first = firstOfMonth(date)
                let days = calendar.range(of: .day, in: .month, for: first)!.count
                return calendar.date(byAdding: .day, value: min(anchorDay, days) - 1, to: first)!
            }
            var start = anchor(inMonthOf: now)
            if start > now {
                start = anchor(inMonthOf: calendar.date(byAdding: .month, value: -1, to: firstOfMonth(now))!)
            }
            let end = anchor(inMonthOf: calendar.date(byAdding: .month, value: 1, to: firstOfMonth(start))!)
            return BudgetWindow(start: start, end: end)

        case .weekly(let anchorWeekday):
            let today = calendar.startOfDay(for: now)
            let back = (calendar.component(.weekday, from: today) - anchorWeekday + 7) % 7
            let start = calendar.date(byAdding: .day, value: -back, to: today)!
            return BudgetWindow(start: start, end: calendar.date(byAdding: .day, value: 7, to: start)!)

        case .rolling(let days):
            // End is just after `now` so a debit recorded this millisecond still counts.
            return BudgetWindow(start: calendar.date(byAdding: .day, value: -days, to: now)!,
                                end: now.addingTimeInterval(0.001))

        case .custom(let startDate, let lengthDays):
            let origin = calendar.startOfDay(for: startDate)
            let today = calendar.startOfDay(for: now)
            guard today >= origin else { return nil }
            let elapsed = calendar.dateComponents([.day], from: origin, to: today).day ?? 0
            let start = calendar.date(byAdding: .day, value: (elapsed / lengthDays) * lengthDays, to: origin)!
            return BudgetWindow(start: start, end: calendar.date(byAdding: .day, value: lengthDays, to: start)!)
        }
    }
}

public struct BudgetWindow: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var startMS: Int64 { Int64((start.timeIntervalSince1970 * 1000).rounded(.down)) }
    public var endMS: Int64 { Int64((end.timeIntervalSince1970 * 1000).rounded(.up)) }
}

public struct Budget: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var categoryID: Int64
    public var cap: Money
    public var period: BudgetPeriod
    /// Warn once spending reaches this share of the cap.
    public var alertPercent: Int
    /// Block instead of warn when the cap would be exceeded.
    public var hardCap: Bool

    public init(id: Int64, categoryID: Int64, cap: Money, period: BudgetPeriod, alertPercent: Int = 80, hardCap: Bool = false) {
        self.id = id
        self.categoryID = categoryID
        self.cap = cap
        self.period = period
        self.alertPercent = alertPercent
        self.hardCap = hardCap
    }

    public var alertThresholdMinor: Int64 { cap.minorUnits * Int64(alertPercent) / 100 }
}

public struct BudgetStatus: Equatable, Sendable {
    public let budget: Budget
    public let window: BudgetWindow
    public let spentBefore: Int64
    public let requested: Int64

    public init(budget: Budget, window: BudgetWindow, spentBefore: Int64, requested: Int64) {
        self.budget = budget
        self.window = window
        self.spentBefore = spentBefore
        self.requested = requested
    }

    public var spentAfter: Int64 { spentBefore + requested }
    public var isOver: Bool { spentAfter > budget.cap.minorUnits }
    public var reachesAlert: Bool { spentAfter >= budget.alertThresholdMinor }
    public var spentAfterMoney: Money { Money(minorUnits: spentAfter, currency: budget.cap.currency) }
    public var spentBeforeMoney: Money { Money(minorUnits: spentBefore, currency: budget.cap.currency) }
}

public struct OfflineLimits: Equatable, Sendable {
    public var perTransfer: Money?
    public var perDay: Money?

    public init(perTransfer: Money? = nil, perDay: Money? = nil) {
        self.perTransfer = perTransfer
        self.perDay = perDay
    }

    public static let none = OfflineLimits()
}

public enum BlockReason: Equatable, Sendable {
    case hardCap(BudgetStatus)
    case insufficientFunds(available: Money, requested: Money)
    case overTransferLimit(limit: Money, requested: Money)
    case overDailyLimit(limit: Money, spentToday: Money, requested: Money)
    case invalidAmount
}

public enum BudgetVerdict: Equatable, Sendable {
    /// Within every budget and below every alert threshold.
    case ok([BudgetStatus])
    /// Within budget but at or past an alert threshold: proceed, then notify.
    case alert([BudgetStatus])
    /// Would exceed at least one soft cap: needs an explicit override (and Face ID).
    case overBudget([BudgetStatus])
    case blocked(BlockReason)

    public var statuses: [BudgetStatus] {
        switch self {
        case .ok(let s), .alert(let s), .overBudget(let s): s
        case .blocked(.hardCap(let status)): [status]
        case .blocked: []
        }
    }

    public func allowsCommit(overrideOverBudget: Bool) -> Bool {
        switch self {
        case .ok, .alert: true
        case .overBudget: overrideOverBudget
        case .blocked: false
        }
    }
}

public enum BudgetEngine {
    /// Decides whether a debit may proceed.
    /// - Parameters:
    ///   - spent: sum of debits in the budget's category inside the window, in minor units.
    ///   - available: spendable balance, or nil for an issuer (no balance limit).
    ///   - spentToday: total debits since local midnight, for the daily offline limit.
    public static func evaluate(amount: Money, categoryID: Int64?, budgets: [Budget], now: Date, calendar: Calendar,
                                available: Money?, limits: OfflineLimits, spentToday: Int64,
                                spent: (Budget, BudgetWindow) throws -> Int64) rethrows -> BudgetVerdict {
        guard amount.minorUnits > 0 else { return .blocked(.invalidAmount) }
        if let available, available.currency == amount.currency, amount.minorUnits > available.minorUnits {
            return .blocked(.insufficientFunds(available: available, requested: amount))
        }
        if let limit = limits.perTransfer, limit.currency == amount.currency, amount.minorUnits > limit.minorUnits {
            return .blocked(.overTransferLimit(limit: limit, requested: amount))
        }
        if let limit = limits.perDay, limit.currency == amount.currency, spentToday + amount.minorUnits > limit.minorUnits {
            return .blocked(.overDailyLimit(limit: limit, spentToday: Money(minorUnits: spentToday, currency: amount.currency),
                                            requested: amount))
        }

        var statuses: [BudgetStatus] = []
        for budget in budgets where budget.categoryID == categoryID && budget.cap.currency == amount.currency {
            guard let window = budget.period.window(containing: now, calendar: calendar) else { continue }
            statuses.append(BudgetStatus(budget: budget, window: window, spentBefore: try spent(budget, window),
                                         requested: amount.minorUnits))
        }
        if let hard = statuses.first(where: { $0.isOver && $0.budget.hardCap }) { return .blocked(.hardCap(hard)) }
        if statuses.contains(where: \.isOver) { return .overBudget(statuses) }
        if statuses.contains(where: \.reachesAlert) { return .alert(statuses) }
        return .ok(statuses)
    }
}
