import Foundation

/// A signed statement by a wallet about one position in its own chain.
public enum ChainClaim: Equatable, Sendable {
    /// The payer's statement: "my entry `payerSeq` is this outgoing transfer, after link `payerPrevLink`".
    case debit(SignedTransfer)
    /// The payee's statement: "my entry `payeeSeq` records this incoming transfer, after link `payeePrevLink`".
    case credit(SignedReceipt)

    public var owner: WalletPublicKey {
        switch self {
        case .debit(let t): t.transfer.payer
        case .credit(let r): r.receipt.payee
        }
    }

    public var seq: Int64 {
        switch self {
        case .debit(let t): t.transfer.payerSeq
        case .credit(let r): r.receipt.payeeSeq
        }
    }

    public var prevLink: Digest32 {
        switch self {
        case .debit(let t): t.transfer.payerPrevLink
        case .credit(let r): r.receipt.payeePrevLink
        }
    }

    /// The owner's link after this entry, recomputed from public data.
    public var link: Digest32 {
        switch self {
        case .debit(let t): ChainLink.afterDebit(t.transfer)
        case .credit(let r): ChainLink.afterCredit(r.receipt)
        }
    }

    public var isSignatureValid: Bool {
        switch self {
        case .debit(let t): t.isSignatureValid
        case .credit(let r): r.isSignatureValid
        }
    }

    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        switch self {
        case .debit(let t):
            w.writeU8(1)
            w.writeBytes(t.canonicalBytes)
        case .credit(let r):
            w.writeU8(2)
            w.writeBytes(r.canonicalBytes)
        }
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        switch try r.readU8() {
        case 1: self = .debit(try SignedTransfer(canonicalBytes: try r.readBytes()))
        case 2: self = .credit(try SignedReceipt(canonicalBytes: try r.readBytes()))
        case let other: throw CanonicalError.invalidValue("claim type \(other)")
        }
        try r.finish()
    }
}

extension SignedReceipt {
    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeBytes(receipt.canonicalBytes)
        w.writeBytes(signature)
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        let receipt = try Receipt(canonicalBytes: try r.readBytes())
        let signature = try r.readBytes()
        try r.finish()
        self.init(receipt: receipt, signature: signature)
    }
}

/// Two signed claims by the same wallet that can't both belong to one honest chain. Anyone can check it.
public struct ForkEvidence: Equatable, Sendable {
    public let earlier: ChainClaim
    public let later: ChainClaim

    public init(earlier: ChainClaim, later: ChainClaim) {
        self.earlier = earlier
        self.later = later
    }

    public var canonicalBytes: Data {
        var w = CanonicalWriter()
        w.writeBytes(earlier.canonicalBytes)
        w.writeBytes(later.canonicalBytes)
        return w.data
    }

    public init(canonicalBytes: Data) throws {
        var r = CanonicalReader(canonicalBytes)
        earlier = try ChainClaim(canonicalBytes: try r.readBytes())
        later = try ChainClaim(canonicalBytes: try r.readBytes())
        try r.finish()
    }

    public var isValid: Bool {
        guard earlier.owner == later.owner, earlier.isSignatureValid, later.isSignatureValid else { return false }
        if earlier.seq == later.seq { return earlier.link != later.link }
        if later.seq == earlier.seq + 1 { return later.prevLink != earlier.link }
        return false
    }
}

/// What this wallet last learned about a peer's chain.
public struct PeerRecord: Equatable, Sendable {
    public var publicKey: WalletPublicKey
    public var displayName: String?
    public var lastClaim: ChainClaim
    public var forkEvidence: ForkEvidence?

    public init(publicKey: WalletPublicKey, displayName: String?, lastClaim: ChainClaim, forkEvidence: ForkEvidence? = nil) {
        self.publicKey = publicKey
        self.displayName = displayName
        self.lastClaim = lastClaim
        self.forkEvidence = forkEvidence
    }
}

public enum ContinuityVerdict: Equatable, Sendable {
    case firstContact
    /// Directly follows the last claim we hold.
    case contiguous
    /// The peer has entries we haven't seen; continuity can't be checked across the gap.
    case gap(missing: ClosedRange<Int64>)
    /// Older than the last claim we hold, e.g. a transfer delivered late. Can't be checked; not proof of fraud.
    case outOfOrder
    /// The same claim again (a retried delivery).
    case duplicate
    /// Proof that the peer forked its chain, e.g. restored an old copy and spent again.
    case fork(ForkEvidence)

    public var isFork: Bool {
        if case .fork = self { return true }
        return false
    }
}

public enum Continuity {
    public static func check(_ claim: ChainClaim, against record: PeerRecord?) -> ContinuityVerdict {
        guard let record else { return .firstContact }
        let last = record.lastClaim
        if claim.seq == last.seq {
            return claim.link == last.link ? .duplicate : .fork(ForkEvidence(earlier: last, later: claim))
        }
        if claim.seq == last.seq + 1 {
            return claim.prevLink == last.link ? .contiguous : .fork(ForkEvidence(earlier: last, later: claim))
        }
        if claim.seq > last.seq + 1 { return .gap(missing: (last.seq + 1)...(claim.seq - 1)) }
        return .outOfOrder
    }
}
