import Foundation
import SecureCore

/// A FICO-style credit score, 300–850. In this build it is self-reported or taken from a demo profile,
/// never pulled from a credit bureau, so it is always shown as unverified.
public struct CreditScore: Hashable, Sendable, Comparable {
    public static let range = 300...850

    public let value: Int

    public init?(_ value: Int) {
        guard Self.range.contains(value) else { return nil }
        self.value = value
    }

    public var tier: CreditTier { CreditTier.forScore(self) }

    public static func < (lhs: CreditScore, rhs: CreditScore) -> Bool { lhs.value < rhs.value }
}

/// Five bands matching FICO's published ranges. The band sets how many practice-market transactions
/// (orders and bets) the user may make per day and how large each may be. It does not touch wallet transfers.
public enum CreditTier: UInt8, CaseIterable, Sendable, Comparable {
    case poor = 1, fair, good, veryGood, exceptional

    public var name: String {
        switch self {
        case .poor: "Poor"
        case .fair: "Fair"
        case .good: "Good"
        case .veryGood: "Very good"
        case .exceptional: "Exceptional"
        }
    }

    public var scoreRange: ClosedRange<Int> {
        switch self {
        case .poor: 300...579
        case .fair: 580...669
        case .good: 670...739
        case .veryGood: 740...799
        case .exceptional: 800...850
        }
    }

    public static func forScore(_ score: CreditScore) -> CreditTier {
        allCases.first { $0.scoreRange.contains(score.value) } ?? .poor
    }

    public var limits: TierLimits { TierLimits.standard(for: self) }

    public static func < (lhs: CreditTier, rhs: CreditTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Daily access granted by a tier in the practice markets.
public struct TierLimits: Equatable, Sendable {
    /// Orders and bets (buys, sells and bets each count as one transaction).
    public var transactionsPerDay: Int
    /// Largest amount a single buy or bet may put at risk.
    public var maxPerTransaction: Money

    public init(transactionsPerDay: Int, maxPerTransaction: Money) {
        self.transactionsPerDay = transactionsPerDay
        self.maxPerTransaction = maxPerTransaction
    }

    public static func standard(for tier: CreditTier, currency: CurrencyCode = .usd) -> TierLimits {
        func dollars(_ value: Int64) -> Money { Money(minorUnits: value * 100, currency: currency) }
        return switch tier {
        case .poor: TierLimits(transactionsPerDay: 3, maxPerTransaction: dollars(100))
        case .fair: TierLimits(transactionsPerDay: 5, maxPerTransaction: dollars(250))
        case .good: TierLimits(transactionsPerDay: 10, maxPerTransaction: dollars(500))
        case .veryGood: TierLimits(transactionsPerDay: 20, maxPerTransaction: dollars(1_000))
        case .exceptional: TierLimits(transactionsPerDay: 50, maxPerTransaction: dollars(2_500))
        }
    }
}

public enum CreditSource: UInt8, Sendable {
    /// Typed in by the user.
    case selfReported = 1
    /// One of the built-in demo profiles.
    case demoProfile = 2

    public var displayName: String {
        switch self {
        case .selfReported: "Self-reported (unverified)"
        case .demoProfile: "Demo profile (simulated)"
        }
    }
}

public struct CreditProfile: Equatable, Sendable {
    public var score: CreditScore
    public var source: CreditSource
    /// Demo persona name, if any.
    public var label: String?
    public var updatedAtMS: Int64

    public init(score: CreditScore, source: CreditSource, label: String? = nil, updatedAtMS: Int64) {
        self.score = score
        self.source = source
        self.label = label
        self.updatedAtMS = updatedAtMS
    }

    public var tier: CreditTier { score.tier }

    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeU8(1)
        w.writeU16(UInt16(score.value))
        w.writeU8(source.rawValue)
        w.writeOptional(label) { $0.writeString($1) }
        w.writeI64(updatedAtMS)
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        let version = try r.readU8()
        guard version == 1 else { throw CanonicalError.unsupportedVersion(version) }
        guard let score = CreditScore(Int(try r.readU16())) else { throw CanonicalError.invalidValue("score") }
        guard let source = CreditSource(rawValue: try r.readU8()) else { throw CanonicalError.invalidValue("source") }
        self.score = score
        self.source = source
        label = try r.readOptional { try $0.readString() }
        updatedAtMS = try r.readI64()
        try r.finish()
    }
}

/// Built-in personas for trying each tier.
public struct DemoCreditProfile: Sendable, Identifiable, Hashable {
    public let name: String
    public let score: Int
    public var id: String { name }

    public static let all: [DemoCreditProfile] = [
        DemoCreditProfile(name: "Alex", score: 540),
        DemoCreditProfile(name: "Jordan", score: 610),
        DemoCreditProfile(name: "Sam", score: 700),
        DemoCreditProfile(name: "Riley", score: 765),
        DemoCreditProfile(name: "Priya", score: 815),
    ]
}
