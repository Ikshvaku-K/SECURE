import Foundation

public enum ProtocolVersion {
    public static let current: UInt8 = 1

    static func check(_ reader: inout CanonicalReader) throws {
        let version = try reader.readU8()
        guard version == current else { throw CanonicalError.unsupportedVersion(version) }
    }
}

// MARK: - Session nonce

public enum SessionNonce {
    public static let contributionLength = 16

    /// Each side contributes fresh random bytes, so neither can pick or precompute the session nonce alone.
    public static func derive(payerContribution: Data, payeeContribution: Data) -> Digest32 {
        var writer = CanonicalWriter()
        writer.writeBytes(payerContribution)
        writer.writeBytes(payeeContribution)
        return TaggedHash.sha256(.session, writer.data)
    }

    public static func randomContribution() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<contributionLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

// MARK: - Proximity measurement and proof

/// One phone's signed statement: "during session N, I measured peer P at distance d".
public struct ProximityMeasurement: Equatable, Sendable {
    public var sessionNonce: Digest32
    public var observer: WalletPublicKey
    public var subject: WalletPublicKey
    public var summary: RangingSummary

    public init(sessionNonce: Digest32, observer: WalletPublicKey, subject: WalletPublicKey, summary: RangingSummary) {
        self.sessionNonce = sessionNonce
        self.observer = observer
        self.subject = subject
        self.summary = summary
    }

    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeU8(ProtocolVersion.current)
        w.writeDigest(sessionNonce)
        observer.encode(to: &w)
        subject.encode(to: &w)
        w.writeU16(summary.distanceCM)
        w.writeU16(summary.spreadCM)
        w.writeU16(summary.samples)
        w.writeOptional(summary.azimuthCentiDegrees) { $0.writeI16($1) }
        w.writeOptional(summary.vertical) { $0.writeU8($1.rawValue) }
        w.writeU8(summary.capabilities.rawValue)
        w.writeU32(summary.durationMS)
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        try ProtocolVersion.check(&r)
        sessionNonce = try r.readDigest()
        observer = try WalletPublicKey.decode(from: &r)
        subject = try WalletPublicKey.decode(from: &r)
        let distance = try r.readU16()
        let spread = try r.readU16()
        let samples = try r.readU16()
        let azimuth = try r.readOptional { try $0.readI16() }
        let vertical = try r.readOptional { reader -> VerticalEstimate in
            let raw = try reader.readU8()
            guard let value = VerticalEstimate(rawValue: raw) else { throw CanonicalError.invalidValue("vertical \(raw)") }
            return value
        }
        let capabilities = RangingCapabilities(rawValue: try r.readU8())
        let duration = try r.readU32()
        try r.finish()
        summary = RangingSummary(distanceCM: distance, spreadCM: spread, samples: samples, azimuthCentiDegrees: azimuth,
                                 vertical: vertical, capabilities: capabilities, durationMS: duration)
    }

    public var signingPayload: Data { TaggedHash.signingPayload(.measurement, canonicalBytes) }
}

public struct SignedMeasurement: Equatable, Sendable {
    public let measurement: ProximityMeasurement
    public let signature: Data

    public init(measurement: ProximityMeasurement, signature: Data) {
        self.measurement = measurement
        self.signature = signature
    }

    public var isSignatureValid: Bool {
        measurement.observer.isValidSignature(signature, for: measurement.signingPayload)
    }

    func encode(to writer: inout CanonicalWriter) {
        writer.writeBytes(measurement.canonicalBytes)
        writer.writeBytes(signature)
    }

    static func decode(from reader: inout CanonicalReader) throws -> SignedMeasurement {
        SignedMeasurement(measurement: try ProximityMeasurement(canonicalBytes: try reader.readBytes()),
                          signature: try reader.readBytes())
    }
}

/// Acceptance thresholds for a spatial proof. Starting values; Phase 3 measurements on real phones set the final ones.
public struct ProximityPolicy: Equatable, Sendable {
    public var maxDistanceCM: UInt16
    public var toleranceCM: UInt16
    public var tolerancePercent: Double
    public var requireDirection: Bool
    public var allowSimulated: Bool

    public init(maxDistanceCM: UInt16 = 100, toleranceCM: UInt16 = 25, tolerancePercent: Double = 0.20,
                requireDirection: Bool = false, allowSimulated: Bool = false) {
        self.maxDistanceCM = maxDistanceCM
        self.toleranceCM = toleranceCM
        self.tolerancePercent = tolerancePercent
        self.requireDirection = requireDirection
        self.allowSimulated = allowSimulated
    }

    /// For real devices: simulated measurements are rejected.
    public static let device = ProximityPolicy()
    /// For the Simulator and tests, where UWB doesn't exist.
    public static let simulator = ProximityPolicy(allowSimulated: true)
}

public enum ProximityFailure: Error, Equatable, Sendable {
    case wrongParticipants
    case nonceMismatch
    case badSignature(WalletPublicKey)
    case simulatedNotAllowed
    case directionRequired
    case tooFar(distanceCM: UInt16, limitCM: UInt16)
    case disagreement(payerCM: UInt16, payeeCM: UInt16)
}

/// Both phones' signed measurements of the same session. Neither phone alone can produce it.
public struct SpatialProof: Equatable, Sendable {
    /// Measured by the payer, about the payee.
    public let payerSide: SignedMeasurement
    /// Measured by the payee, about the payer.
    public let payeeSide: SignedMeasurement

    public init(payerSide: SignedMeasurement, payeeSide: SignedMeasurement) {
        self.payerSide = payerSide
        self.payeeSide = payeeSide
    }

    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeU8(ProtocolVersion.current)
        payerSide.encode(to: &w)
        payeeSide.encode(to: &w)
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        try ProtocolVersion.check(&r)
        payerSide = try SignedMeasurement.decode(from: &r)
        payeeSide = try SignedMeasurement.decode(from: &r)
        try r.finish()
    }

    public var hash: Digest32 { TaggedHash.sha256(.proof, canonicalBytes) }

    /// Checks participants, nonce, both signatures and the distance rules. Returns the agreed distance (mean of both sides).
    @discardableResult
    public func verify(sessionNonce: Digest32, payer: WalletPublicKey, payee: WalletPublicKey,
                       policy: ProximityPolicy) throws -> UInt16 {
        let a = payerSide.measurement
        let b = payeeSide.measurement
        guard a.observer == payer, a.subject == payee, b.observer == payee, b.subject == payer else {
            throw ProximityFailure.wrongParticipants
        }
        guard a.sessionNonce == sessionNonce, b.sessionNonce == sessionNonce else { throw ProximityFailure.nonceMismatch }
        guard payerSide.isSignatureValid else { throw ProximityFailure.badSignature(payer) }
        guard payeeSide.isSignatureValid else { throw ProximityFailure.badSignature(payee) }
        if !policy.allowSimulated,
           a.summary.capabilities.contains(.simulated) || b.summary.capabilities.contains(.simulated) {
            throw ProximityFailure.simulatedNotAllowed
        }
        if policy.requireDirection, a.summary.azimuthCentiDegrees == nil, b.summary.azimuthCentiDegrees == nil {
            throw ProximityFailure.directionRequired
        }
        let farthest = max(a.summary.distanceCM, b.summary.distanceCM)
        guard farthest <= policy.maxDistanceCM else {
            throw ProximityFailure.tooFar(distanceCM: farthest, limitCM: policy.maxDistanceCM)
        }
        let difference = abs(Int(a.summary.distanceCM) - Int(b.summary.distanceCM))
        let allowed = max(Double(policy.toleranceCM), policy.tolerancePercent * Double(farthest))
        guard Double(difference) <= allowed else {
            throw ProximityFailure.disagreement(payerCM: a.summary.distanceCM, payeeCM: b.summary.distanceCM)
        }
        return UInt16((Int(a.summary.distanceCM) + Int(b.summary.distanceCM)) / 2)
    }
}

// MARK: - Transfer and receipt

/// What the payer signs in the Secure Enclave. Category is deliberately absent: it stays on the payer's phone.
public struct Transfer: Equatable, Sendable {
    public var payer: WalletPublicKey
    public var payee: WalletPublicKey
    public var amount: Money
    public var sessionNonce: Digest32
    /// The sequence number this debit takes in the payer's chain.
    public var payerSeq: Int64
    /// The payer's chain link just before this debit.
    public var payerPrevLink: Digest32
    public var spatialProofHash: Digest32
    public var createdAtMS: Int64

    public init(payer: WalletPublicKey, payee: WalletPublicKey, amount: Money, sessionNonce: Digest32, payerSeq: Int64,
                payerPrevLink: Digest32, spatialProofHash: Digest32, createdAtMS: Int64) {
        self.payer = payer
        self.payee = payee
        self.amount = amount
        self.sessionNonce = sessionNonce
        self.payerSeq = payerSeq
        self.payerPrevLink = payerPrevLink
        self.spatialProofHash = spatialProofHash
        self.createdAtMS = createdAtMS
    }

    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeU8(ProtocolVersion.current)
        payer.encode(to: &w)
        payee.encode(to: &w)
        w.writeI64(amount.minorUnits)
        w.writeString(amount.currency.rawValue)
        w.writeDigest(sessionNonce)
        w.writeI64(payerSeq)
        w.writeDigest(payerPrevLink)
        w.writeDigest(spatialProofHash)
        w.writeI64(createdAtMS)
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        try ProtocolVersion.check(&r)
        payer = try WalletPublicKey.decode(from: &r)
        payee = try WalletPublicKey.decode(from: &r)
        let minor = try r.readI64()
        guard minor > 0 else { throw CanonicalError.invalidValue("amount must be positive") }
        guard let currency = CurrencyCode(try r.readString()) else { throw CanonicalError.invalidValue("currency") }
        amount = Money(minorUnits: minor, currency: currency)
        sessionNonce = try r.readDigest()
        payerSeq = try r.readI64()
        guard payerSeq > 0 else { throw CanonicalError.invalidValue("payer sequence must be positive") }
        payerPrevLink = try r.readDigest()
        spatialProofHash = try r.readDigest()
        createdAtMS = try r.readI64()
        try r.finish()
    }

    /// Stable ID over the unsigned fields, so ECDSA signature malleability can't create a second ID for the same transfer.
    public var id: Digest32 { TaggedHash.sha256(.transfer, canonicalBytes) }

    public var signingPayload: Data { TaggedHash.signingPayload(.transfer, canonicalBytes) }
}

public struct SignedTransfer: Equatable, Sendable {
    public let transfer: Transfer
    public let signature: Data

    public init(transfer: Transfer, signature: Data) {
        self.transfer = transfer
        self.signature = signature
    }

    public var id: Digest32 { transfer.id }

    public var isSignatureValid: Bool { transfer.payer.isValidSignature(signature, for: transfer.signingPayload) }

    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeBytes(transfer.canonicalBytes)
        w.writeBytes(signature)
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        transfer = try Transfer(canonicalBytes: try r.readBytes())
        signature = try r.readBytes()
        try r.finish()
    }
}

/// The payee's countersignature: "I recorded transfer T at position seq of my chain".
public struct Receipt: Equatable, Sendable {
    public var transferID: Digest32
    public var payee: WalletPublicKey
    public var payeeSeq: Int64
    public var payeePrevLink: Digest32
    public var createdAtMS: Int64

    public init(transferID: Digest32, payee: WalletPublicKey, payeeSeq: Int64, payeePrevLink: Digest32, createdAtMS: Int64) {
        self.transferID = transferID
        self.payee = payee
        self.payeeSeq = payeeSeq
        self.payeePrevLink = payeePrevLink
        self.createdAtMS = createdAtMS
    }

    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeU8(ProtocolVersion.current)
        w.writeDigest(transferID)
        payee.encode(to: &w)
        w.writeI64(payeeSeq)
        w.writeDigest(payeePrevLink)
        w.writeI64(createdAtMS)
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        try ProtocolVersion.check(&r)
        transferID = try r.readDigest()
        payee = try WalletPublicKey.decode(from: &r)
        payeeSeq = try r.readI64()
        payeePrevLink = try r.readDigest()
        createdAtMS = try r.readI64()
        try r.finish()
    }

    public var signingPayload: Data { TaggedHash.signingPayload(.receipt, canonicalBytes) }
}

public struct SignedReceipt: Equatable, Sendable {
    public let receipt: Receipt
    public let signature: Data

    public init(receipt: Receipt, signature: Data) {
        self.receipt = receipt
        self.signature = signature
    }

    public var isSignatureValid: Bool { receipt.payee.isValidSignature(signature, for: receipt.signingPayload) }
}
