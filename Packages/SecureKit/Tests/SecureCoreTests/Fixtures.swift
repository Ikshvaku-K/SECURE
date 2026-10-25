import Foundation
@testable import SecureCore

enum Fixtures {
    static let usd = CurrencyCode.usd

    static func dollars(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: usd) }

    static func randomNonce() -> Digest32 {
        SessionNonce.derive(payerContribution: SessionNonce.randomContribution(),
                            payeeContribution: SessionNonce.randomContribution())
    }

    static func summary(_ cm: UInt16, caps: RangingCapabilities = [.preciseDistance], azimuth: Int16? = nil) -> RangingSummary {
        RangingSummary(distanceCM: cm, spreadCM: 3, samples: 20, azimuthCentiDegrees: azimuth, capabilities: caps, durationMS: 1000)
    }

    static func proof(nonce: Digest32, payer: SoftwareSigner, payee: SoftwareSigner, payerCM: UInt16 = 40, payeeCM: UInt16 = 42,
                      caps: RangingCapabilities = [.preciseDistance]) throws -> SpatialProof {
        let a = ProximityMeasurement(sessionNonce: nonce, observer: payer.publicKey, subject: payee.publicKey,
                                     summary: summary(payerCM, caps: caps))
        let b = ProximityMeasurement(sessionNonce: nonce, observer: payee.publicKey, subject: payer.publicKey,
                                     summary: summary(payeeCM, caps: caps))
        return SpatialProof(payerSide: SignedMeasurement(measurement: a, signature: try payer.signNow(a.signingPayload)),
                            payeeSide: SignedMeasurement(measurement: b, signature: try payee.signNow(b.signingPayload)))
    }

    static func transfer(from payer: SoftwareSigner, to payee: SoftwareSigner, cents: Int64, seq: Int64, prevLink: Digest32,
                         at ms: Int64 = 1_790_000_000_000) throws -> (SignedTransfer, SpatialProof) {
        let nonce = randomNonce()
        let proof = try proof(nonce: nonce, payer: payer, payee: payee)
        let transfer = Transfer(payer: payer.publicKey, payee: payee.publicKey, amount: dollars(cents), sessionNonce: nonce,
                                payerSeq: seq, payerPrevLink: prevLink, spatialProofHash: proof.hash, createdAtMS: ms)
        return (SignedTransfer(transfer: transfer, signature: try payer.signNow(transfer.signingPayload)), proof)
    }

    static func receipt(by payee: SoftwareSigner, for transfer: SignedTransfer, seq: Int64, prevLink: Digest32) throws -> SignedReceipt {
        let receipt = Receipt(transferID: transfer.id, payee: payee.publicKey, payeeSeq: seq, payeePrevLink: prevLink,
                              createdAtMS: transfer.transfer.createdAtMS)
        return SignedReceipt(receipt: receipt, signature: try payee.signNow(receipt.signingPayload))
    }

    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, calendar: Calendar = utcCalendar()) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
