import Foundation
import SecureCore

/// Self-attested age. Practice stocks and prediction markets need 18+, sports betting 21+ (as in most US states).
public enum AgeConfirmation: UInt8, Sendable, CaseIterable, Comparable {
    case none = 0, adult18 = 1, adult21 = 2

    public var displayName: String {
        switch self {
        case .none: "Not confirmed"
        case .adult18: "18 or older"
        case .adult21: "21 or older"
        }
    }

    public static func < (lhs: AgeConfirmation, rhs: AgeConfirmation) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PlaySettings: Equatable, Sendable {
    public var age: AgeConfirmation
    /// Most that may be staked on new orders and bets per local day.
    public var dailyStakeLimit: Money?
    public var coolOffUntilMS: Int64?
    public var selfExcludedUntilMS: Int64?

    public init(age: AgeConfirmation = .none, dailyStakeLimit: Money? = Money(minorUnits: 1_000_00, currency: .usd),
                coolOffUntilMS: Int64? = nil, selfExcludedUntilMS: Int64? = nil) {
        self.age = age
        self.dailyStakeLimit = dailyStakeLimit
        self.coolOffUntilMS = coolOffUntilMS
        self.selfExcludedUntilMS = selfExcludedUntilMS
    }

    public func isCoolingOff(atMS ms: Int64) -> Bool { (coolOffUntilMS ?? .min) > ms }
    public func isSelfExcluded(atMS ms: Int64) -> Bool { (selfExcludedUntilMS ?? .min) > ms }

    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeU8(1)
        w.writeU8(age.rawValue)
        w.writeOptional(dailyStakeLimit) { writer, money in
            writer.writeString(money.currency.rawValue)
            writer.writeI64(money.minorUnits)
        }
        w.writeOptional(coolOffUntilMS) { $0.writeI64($1) }
        w.writeOptional(selfExcludedUntilMS) { $0.writeI64($1) }
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        let version = try r.readU8()
        guard version == 1 else { throw CanonicalError.unsupportedVersion(version) }
        guard let age = AgeConfirmation(rawValue: try r.readU8()) else { throw CanonicalError.invalidValue("age") }
        self.age = age
        dailyStakeLimit = try r.readOptional { reader -> Money in
            guard let currency = CurrencyCode(try reader.readString()) else { throw CanonicalError.invalidValue("currency") }
            return Money(minorUnits: try reader.readI64(), currency: currency)
        }
        coolOffUntilMS = try r.readOptional { try $0.readI64() }
        selfExcludedUntilMS = try r.readOptional { try $0.readI64() }
        try r.finish()
    }
}

public enum PlayBlock: Error, Equatable, Sendable {
    case selfExcluded(untilMS: Int64)
    case coolingOff(untilMS: Int64)
    /// Practice markets unlock once a (self-reported or demo) credit score is set.
    case creditScoreRequired
    case ageNotConfirmed(required: AgeConfirmation)
    case overTransactionCount(tier: CreditTier, limit: Int, used: Int)
    case overTransactionSize(tier: CreditTier, limit: Money, requested: Money)
    case overDailyStake(limit: Money, used: Money, requested: Money)
    case insufficientCash(available: Money, requested: Money)
    case insufficientPosition(held: Int64, requested: Int64)
    case marketClosed
    case invalidQuantity
    case unknownInstrument
    /// Cool-offs and self-exclusions can be extended but not shortened or removed before they end.
    case cannotShortenExclusion
}

/// Checks run, in this order, before any practice order or bet is accepted.
public enum PlayGuard {
    public enum Order: Sendable {
        /// Buying or betting: new money at risk.
        case opening(cost: Money)
        /// Selling an existing position: reduces risk, so cool-off and stake limits don't apply.
        case closing
    }

    /// - Parameter tier: the credit tier from the user's profile; nil if no score has been set.
    public static func check(_ order: Order, market: MarketKind, settings: PlaySettings, tier: CreditTier?,
                             ordersToday: Int, stakedToday: Money, cash: Money, nowMS: Int64) throws(PlayBlock) {
        if case .opening = order {
            if let until = settings.selfExcludedUntilMS, until > nowMS { throw .selfExcluded(untilMS: until) }
            if let until = settings.coolOffUntilMS, until > nowMS { throw .coolingOff(untilMS: until) }
        }
        guard let tier else { throw .creditScoreRequired }
        let requiredAge: AgeConfirmation = market == .sports ? .adult21 : .adult18
        guard settings.age >= requiredAge else { throw .ageNotConfirmed(required: requiredAge) }
        let limits = tier.limits
        if ordersToday >= limits.transactionsPerDay {
            throw .overTransactionCount(tier: tier, limit: limits.transactionsPerDay, used: ordersToday)
        }
        guard case .opening(let cost) = order else { return }
        if cost.minorUnits > limits.maxPerTransaction.minorUnits {
            throw .overTransactionSize(tier: tier, limit: limits.maxPerTransaction, requested: cost)
        }
        if let limit = settings.dailyStakeLimit, stakedToday.minorUnits + cost.minorUnits > limit.minorUnits {
            throw .overDailyStake(limit: limit, used: stakedToday, requested: cost)
        }
        guard cost.minorUnits <= cash.minorUnits else { throw .insufficientCash(available: cash, requested: cost) }
    }

    /// Whether `new` settings may replace `old`: an active cool-off or self-exclusion can't end earlier.
    public static func validateChange(from old: PlaySettings, to new: PlaySettings, nowMS: Int64) throws(PlayBlock) {
        if let until = old.coolOffUntilMS, until > nowMS, (new.coolOffUntilMS ?? .min) < until { throw .cannotShortenExclusion }
        if let until = old.selfExcludedUntilMS, until > nowMS, (new.selfExcludedUntilMS ?? .min) < until {
            throw .cannotShortenExclusion
        }
    }
}
