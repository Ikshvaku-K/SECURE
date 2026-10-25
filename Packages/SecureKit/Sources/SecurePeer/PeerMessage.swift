import Foundation
import SecureCore

/// Identifies one payment attempt between two phones. Random, so neither side can guess or replay it.
public struct OfferID: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 16
    public let bytes: Data

    public init?(_ bytes: Data) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = Data(bytes)
    }

    public static func random() -> OfferID {
        var generator = SystemRandomNumberGenerator()
        return OfferID(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))!
    }

    public var description: String { bytes.prefix(4).map { String(format: "%02x", $0) }.joined() }
}

/// Sent by each phone as soon as the link connects. Nothing in it is trusted: the name is chosen by the sender,
/// and the key only matters once it signs a measurement, transfer or receipt.
public struct PeerHello: Equatable, Sendable {
    public static let maxNameLength = 40

    public var walletKey: WalletPublicKey
    public var displayName: String
    /// The archived NearbyInteraction discovery token for this link; empty when ranging is simulated.
    public var rangingToken: Data

    public init(walletKey: WalletPublicKey, displayName: String, rangingToken: Data) {
        self.walletKey = walletKey
        self.displayName = String(displayName.prefix(Self.maxNameLength))
        self.rangingToken = rangingToken
    }
}

/// Payer → payee: "I'd like to pay you this amount." Carries the payer's half of the session nonce.
public struct PaymentOffer: Equatable, Sendable {
    public var id: OfferID
    public var payer: WalletPublicKey
    public var payee: WalletPublicKey
    public var amount: Money
    public var payerContribution: Data

    public init(id: OfferID, payer: WalletPublicKey, payee: WalletPublicKey, amount: Money, payerContribution: Data) {
        self.id = id
        self.payer = payer
        self.payee = payee
        self.amount = amount
        self.payerContribution = payerContribution
    }
}

/// Payee → payer: "please pay me this amount." The payer answers with an `offer` that reuses this ID, which the
/// payee accepts without asking again (it still approves with Face ID), or with a `failure` if it declines.
public struct PaymentRequest: Equatable, Sendable {
    public static let maxNoteLength = 60

    public var id: OfferID
    public var payee: WalletPublicKey
    public var payer: WalletPublicKey
    public var amount: Money
    /// Shown to the payer, e.g. "Lunch". Unverified text.
    public var note: String?

    public init(id: OfferID, payee: WalletPublicKey, payer: WalletPublicKey, amount: Money, note: String?) {
        self.id = id
        self.payee = payee
        self.payer = payer
        self.amount = amount
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = trimmed.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.maxNoteLength)) }
    }
}

/// Payee → payer: accepted (with the payee's half of the nonce) or declined.
public struct OfferReply: Equatable, Sendable {
    public var id: OfferID
    /// Present when the payee accepted and approved with Face ID.
    public var payeeContribution: Data?

    public init(id: OfferID, payeeContribution: Data?) {
        self.id = id
        self.payeeContribution = payeeContribution
    }

    public var accepted: Bool { payeeContribution != nil }
}

/// Why a phone stopped a payment. Sent to the other side so both screens show the same reason.
public struct PeerFailure: Error, Equatable, Sendable {
    public enum Code: UInt8, Sendable {
        case declined = 1, busy, cancelled, timedOut, proximity, rejected, unsupportedVersion, invalidMessage
    }

    public static let maxMessageLength = 200

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = String(message.prefix(Self.maxMessageLength))
    }
}

/// Everything two phones say to each other during a payment. The steps match `LoopbackPayment` (DESIGN §6),
/// with each side on its own phone.
public enum PeerMessage: Equatable, Sendable {
    case hello(PeerHello)
    /// Payee → payer: a payment request.
    case request(PaymentRequest)
    case offer(PaymentOffer)
    case reply(OfferReply)
    /// The sender's signed distance reading for this session.
    case measurement(OfferID, SignedMeasurement)
    /// Payee → payer: proof, limits and the payer's record check out, for this amount; the payer may commit.
    case ready(OfferID, Money)
    /// Payer → payee, after the payer committed its debit. Also used to re-deliver an unconfirmed payment.
    case transfer(OfferID, SignedTransfer, SpatialProof)
    case receipt(OfferID, SignedReceipt)
    case failure(OfferID?, PeerFailure)

    public static let wireVersion: UInt8 = 1

    public var offerID: OfferID? {
        switch self {
        case .hello: nil
        case .request(let request): request.id
        case .offer(let offer): offer.id
        case .reply(let reply): reply.id
        case .measurement(let id, _), .ready(let id, _), .transfer(let id, _, _), .receipt(let id, _): id
        case .failure(let id, _): id
        }
    }

    private enum Tag: UInt8 {
        case hello = 1, offer, reply, measurement, ready, transfer, receipt, failure, request
    }

    // MARK: Encoding

    public var encoded: Data {
        var w = CanonicalWriter()
        w.writeU8(Self.wireVersion)
        switch self {
        case .hello(let hello):
            w.writeU8(Tag.hello.rawValue)
            hello.walletKey.encode(to: &w)
            w.writeString(hello.displayName)
            w.writeBytes(hello.rangingToken)
        case .request(let request):
            w.writeU8(Tag.request.rawValue)
            w.writeFixed(request.id.bytes)
            request.payee.encode(to: &w)
            request.payer.encode(to: &w)
            Self.write(request.amount, to: &w)
            w.writeOptional(request.note) { $0.writeString($1) }
        case .offer(let offer):
            w.writeU8(Tag.offer.rawValue)
            w.writeFixed(offer.id.bytes)
            offer.payer.encode(to: &w)
            offer.payee.encode(to: &w)
            Self.write(offer.amount, to: &w)
            w.writeBytes(offer.payerContribution)
        case .reply(let reply):
            w.writeU8(Tag.reply.rawValue)
            w.writeFixed(reply.id.bytes)
            w.writeOptional(reply.payeeContribution) { $0.writeBytes($1) }
        case .measurement(let id, let signed):
            w.writeU8(Tag.measurement.rawValue)
            w.writeFixed(id.bytes)
            w.writeBytes(signed.measurement.canonicalBytes)
            w.writeBytes(signed.signature)
        case .ready(let id, let amount):
            w.writeU8(Tag.ready.rawValue)
            w.writeFixed(id.bytes)
            Self.write(amount, to: &w)
        case .transfer(let id, let signed, let proof):
            w.writeU8(Tag.transfer.rawValue)
            w.writeFixed(id.bytes)
            w.writeBytes(signed.canonicalBytes)
            w.writeBytes(proof.canonicalBytes)
        case .receipt(let id, let signed):
            w.writeU8(Tag.receipt.rawValue)
            w.writeFixed(id.bytes)
            w.writeBytes(signed.receipt.canonicalBytes)
            w.writeBytes(signed.signature)
        case .failure(let id, let failure):
            w.writeU8(Tag.failure.rawValue)
            w.writeOptional(id) { $0.writeFixed($1.bytes) }
            w.writeU8(failure.code.rawValue)
            w.writeString(failure.message)
        }
        return w.data
    }

    public init(encoded data: Data) throws {
        var r = CanonicalReader(data)
        let version = try r.readU8()
        guard version == Self.wireVersion else { throw CanonicalError.unsupportedVersion(version) }
        guard let tag = Tag(rawValue: try r.readU8()) else { throw CanonicalError.invalidValue("message type") }
        switch tag {
        case .hello:
            let key = try WalletPublicKey.decode(from: &r)
            let name = try r.readString()
            guard name.count <= PeerHello.maxNameLength else { throw CanonicalError.invalidValue("display name") }
            self = .hello(PeerHello(walletKey: key, displayName: name, rangingToken: try r.readBytes()))
        case .request:
            let id = try Self.readID(&r)
            let payee = try WalletPublicKey.decode(from: &r)
            let payer = try WalletPublicKey.decode(from: &r)
            let amount = try Self.readMoney(&r)
            let note = try r.readOptional { try $0.readString() }
            if let note, note.count > PaymentRequest.maxNoteLength { throw CanonicalError.invalidValue("note") }
            self = .request(PaymentRequest(id: id, payee: payee, payer: payer, amount: amount, note: note))
        case .offer:
            let id = try Self.readID(&r)
            let payer = try WalletPublicKey.decode(from: &r)
            let payee = try WalletPublicKey.decode(from: &r)
            let amount = try Self.readMoney(&r)
            let contribution = try r.readBytes()
            guard contribution.count == SessionNonce.contributionLength else { throw CanonicalError.invalidValue("contribution") }
            self = .offer(PaymentOffer(id: id, payer: payer, payee: payee, amount: amount, payerContribution: contribution))
        case .reply:
            let id = try Self.readID(&r)
            let contribution = try r.readOptional { try $0.readBytes() }
            if let contribution, contribution.count != SessionNonce.contributionLength {
                throw CanonicalError.invalidValue("contribution")
            }
            self = .reply(OfferReply(id: id, payeeContribution: contribution))
        case .measurement:
            let id = try Self.readID(&r)
            let measurement = try ProximityMeasurement(canonicalBytes: try r.readBytes())
            self = .measurement(id, SignedMeasurement(measurement: measurement, signature: try r.readBytes()))
        case .ready:
            self = .ready(try Self.readID(&r), try Self.readMoney(&r))
        case .transfer:
            let id = try Self.readID(&r)
            let signed = try SignedTransfer(canonicalBytes: try r.readBytes())
            self = .transfer(id, signed, try SpatialProof(canonicalBytes: try r.readBytes()))
        case .receipt:
            let id = try Self.readID(&r)
            let receipt = try Receipt(canonicalBytes: try r.readBytes())
            self = .receipt(id, SignedReceipt(receipt: receipt, signature: try r.readBytes()))
        case .failure:
            let id = try r.readOptional { try Self.readID(&$0) }
            guard let code = PeerFailure.Code(rawValue: try r.readU8()) else { throw CanonicalError.invalidValue("failure code") }
            self = .failure(id, PeerFailure(code, try r.readString()))
        }
        try r.finish()
    }

    private static func write(_ money: Money, to w: inout CanonicalWriter) {
        w.writeI64(money.minorUnits)
        w.writeString(money.currency.rawValue)
    }

    private static func readMoney(_ r: inout CanonicalReader) throws -> Money {
        let minor = try r.readI64()
        guard minor > 0 else { throw CanonicalError.invalidValue("amount") }
        guard let currency = CurrencyCode(try r.readString()) else { throw CanonicalError.invalidValue("currency") }
        return Money(minorUnits: minor, currency: currency)
    }

    private static func readID(_ r: inout CanonicalReader) throws -> OfferID {
        OfferID(try r.readFixed(OfferID.byteCount))!
    }
}
