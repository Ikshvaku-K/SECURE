import Foundation
import Testing
@testable import SecureCore

@Suite("Canonical encoding")
struct CanonicalEncodingTests {
    @Test func roundTripsEveryFieldType() throws {
        var w = CanonicalWriter()
        w.writeU8(7)
        w.writeU16(0xBEEF)
        w.writeU32(0xDEAD_BEEF)
        w.writeI64(-42)
        w.writeBool(true)
        w.writeString("Clothing")
        w.writeBytes(Data([1, 2, 3]))
        w.writeOptional(Int16(-5)) { $0.writeI16($1) }
        w.writeOptional(Int16?.none) { $0.writeI16($1) }

        var r = CanonicalReader(w.data)
        #expect(try r.readU8() == 7)
        #expect(try r.readU16() == 0xBEEF)
        #expect(try r.readU32() == 0xDEAD_BEEF)
        #expect(try r.readI64() == -42)
        #expect(try r.readBool())
        #expect(try r.readString() == "Clothing")
        #expect(try r.readBytes() == Data([1, 2, 3]))
        #expect(try r.readOptional { try $0.readI16() } == -5)
        #expect(try r.readOptional { try $0.readI16() } == nil)
        try r.finish()
    }

    @Test func integersAreBigEndian() {
        var w = CanonicalWriter()
        w.writeU32(1)
        #expect(w.data == Data([0, 0, 0, 1]))
    }

    @Test func rejectsTruncationTrailingBytesAndOversizedFields() {
        var truncated = CanonicalReader(Data([0, 0, 0, 5, 1, 2]))
        #expect(throws: CanonicalError.truncated) { try truncated.readBytes() }

        var trailing = CanonicalReader(Data([1, 2]))
        _ = try? trailing.readU8()
        #expect(throws: CanonicalError.trailingBytes(1)) { try trailing.finish() }

        var w = CanonicalWriter()
        w.writeU32(UInt32(CanonicalReader.maxFieldLength + 1))
        var oversized = CanonicalReader(w.data)
        #expect(throws: CanonicalError.fieldTooLarge(CanonicalReader.maxFieldLength + 1)) { try oversized.readBytes() }

        var badBool = CanonicalReader(Data([2]))
        #expect(throws: CanonicalError.self) { try badBool.readBool() }
    }

    @Test func hexRoundTrip() {
        let data = Data([0x00, 0x0f, 0xa0, 0xff])
        #expect(data.hexString == "000fa0ff")
        #expect(Data(hexString: "000FA0ff") == data)
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
    }

    @Test func taggedHashesAreDomainSeparated() {
        let body = Data("same bytes".utf8)
        #expect(TaggedHash.sha256(.transfer, body) != TaggedHash.sha256(.receipt, body))
        #expect(TaggedHash.signingPayload(.transfer, body) != TaggedHash.signingPayload(.measurement, body))
    }
}

@Suite("Money")
struct MoneyTests {
    @Test(arguments: [("25", 2500), ("25.5", 2550), ("25.50", 2550), ("$1,250.00", 125_000), (".5", 50), ("0", 0)])
    func parsesUserInput(text: String, cents: Int64) {
        #expect(Money.parse(text, currency: .usd) == Money(minorUnits: cents, currency: .usd))
    }

    @Test(arguments: ["", ".", "25.555", "-5", "abc", "1.2.3", "99999999999999999999"])
    func rejectsBadInput(text: String) {
        #expect(Money.parse(text, currency: .usd) == nil)
    }

    @Test func zeroDecimalCurrencies() throws {
        let yen = try #require(CurrencyCode("jpy"))
        #expect(Money.parse("500", currency: yen)?.minorUnits == 500)
        #expect(Money.parse("500.5", currency: yen) == nil)
    }

    @Test func arithmeticChecksCurrencyAndOverflow() throws {
        let a = Money(minorUnits: 100, currency: .usd)
        #expect(try a.adding(a).minorUnits == 200)
        let euro = Money(minorUnits: 1, currency: CurrencyCode("EUR")!)
        #expect(throws: MoneyError.currencyMismatch(.usd, CurrencyCode("EUR")!)) { try a.adding(euro) }
        #expect(throws: MoneyError.overflow) { try Money(minorUnits: .max, currency: .usd).adding(a) }
    }

    @Test func formats() {
        #expect(Money(minorUnits: 18_000, currency: .usd).formatted(locale: Locale(identifier: "en_US")) == "$180.00")
    }

    @Test func currencyCodeValidation() {
        #expect(CurrencyCode("usd")?.rawValue == "USD")
        #expect(CurrencyCode("US") == nil)
        #expect(CurrencyCode("U$D") == nil)
    }
}
