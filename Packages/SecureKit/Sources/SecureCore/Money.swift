import Foundation

/// ISO 4217 code, three uppercase letters.
public struct CurrencyCode: Hashable, Sendable, CustomStringConvertible {
    public static let usd = CurrencyCode(unchecked: "USD")

    public let rawValue: String

    public init?(_ rawValue: String) {
        let upper = rawValue.uppercased()
        guard upper.count == 3, upper.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        self.rawValue = upper
    }

    init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    /// Digits after the decimal point. Covers the zero-decimal currencies people are likely to use.
    public var minorUnitDigits: Int {
        switch rawValue {
        case "JPY", "KRW", "VND", "CLP", "ISK", "UGX": 0
        default: 2
        }
    }

    public var description: String { rawValue }
}

public enum MoneyError: Error, Equatable, Sendable {
    case currencyMismatch(CurrencyCode, CurrencyCode)
    case overflow
}

/// An amount in integer minor units (cents for USD). Never floating point.
public struct Money: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let minorUnits: Int64
    public let currency: CurrencyCode

    public init(minorUnits: Int64, currency: CurrencyCode) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public static func zero(_ currency: CurrencyCode) -> Money { Money(minorUnits: 0, currency: currency) }

    /// Parses user input such as "25", "25.5", "$1,250.00". Rejects more decimals than the currency allows,
    /// negative amounts and values that overflow.
    public static func parse(_ text: String, currency: CurrencyCode, locale: Locale = Locale(identifier: "en_US_POSIX")) -> Money? {
        let decimalSeparator = locale.decimalSeparator ?? "."
        let grouping = locale.groupingSeparator ?? ","
        var cleaned = ""
        for character in text {
            if character.isNumber && character.isASCII {
                cleaned.append(character)
            } else if String(character) == decimalSeparator {
                cleaned.append(".")
            } else if String(character) == grouping || character.isWhitespace || character == "$" || character == "€" || character == "£" {
                continue
            } else {
                return nil
            }
        }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let whole = parts.first else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard !(whole.isEmpty && fraction.isEmpty) else { return nil }
        let digits = currency.minorUnitDigits
        guard fraction.count <= digits else { return nil }
        let paddedFraction = fraction.padding(toLength: digits, withPad: "0", startingAt: 0)
        guard let value = Int64((whole.isEmpty ? "0" : String(whole)) + paddedFraction) else { return nil }
        return Money(minorUnits: value, currency: currency)
    }

    public func adding(_ other: Money) throws -> Money {
        guard currency == other.currency else { throw MoneyError.currencyMismatch(currency, other.currency) }
        let (sum, overflow) = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !overflow else { throw MoneyError.overflow }
        return Money(minorUnits: sum, currency: currency)
    }

    public func subtracting(_ other: Money) throws -> Money {
        guard currency == other.currency else { throw MoneyError.currencyMismatch(currency, other.currency) }
        let (difference, overflow) = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !overflow else { throw MoneyError.overflow }
        return Money(minorUnits: difference, currency: currency)
    }

    public var decimalValue: Decimal {
        Decimal(minorUnits) / pow(Decimal(10), currency.minorUnitDigits)
    }

    public func formatted(locale: Locale = .current) -> String {
        decimalValue.formatted(.currency(code: currency.rawValue).locale(locale))
    }

    public var description: String { formatted(locale: Locale(identifier: "en_US")) }

    public static func < (lhs: Money, rhs: Money) -> Bool {
        precondition(lhs.currency == rhs.currency, "comparing different currencies")
        return lhs.minorUnits < rhs.minorUnits
    }
}
