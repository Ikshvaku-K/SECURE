import Foundation

/// Direction as seen by the chain's owner. It is part of the public link hash.
/// Whether an incoming transfer counts as a mint or a credit is a local judgement and is not.
public enum LinkDirection: UInt8, Sendable {
    case genesis = 0, outgoing = 1, incoming = 2
}

public enum EntryKind: String, Sendable, CaseIterable {
    case genesis, mint, debit, credit

    public var direction: LinkDirection {
        switch self {
        case .genesis: .genesis
        case .debit: .outgoing
        case .mint, .credit: .incoming
        }
    }
}

/// Chain links cover only data both parties hold (sequence, direction, transfer ID), so a counterparty
/// can recompute a peer's link from a signed transfer or receipt. Local notes such as the category stay out.
public enum ChainLink {
    public static func genesisPayload(owner: WalletPublicKey) -> Digest32 {
        TaggedHash.sha256(.genesis, owner.canonicalBytes)
    }

    public static func genesis(owner: WalletPublicKey) -> Digest32 {
        next(prev: .zero, seq: 0, direction: .genesis, payload: genesisPayload(owner: owner))
    }

    public static func next(prev: Digest32, seq: Int64, direction: LinkDirection, payload: Digest32) -> Digest32 {
        var w = CanonicalWriter()
        w.writeDigest(prev)
        w.writeI64(seq)
        w.writeU8(direction.rawValue)
        w.writeDigest(payload)
        return TaggedHash.sha256(.link, w.data)
    }

    /// The payer's link after this debit. Anyone holding the signed transfer can compute it.
    public static func afterDebit(_ transfer: Transfer) -> Digest32 {
        next(prev: transfer.payerPrevLink, seq: transfer.payerSeq, direction: .outgoing, payload: transfer.id)
    }

    /// The payee's link after recording the transfer named in a receipt.
    public static func afterCredit(_ receipt: Receipt) -> Digest32 {
        next(prev: receipt.payeePrevLink, seq: receipt.payeeSeq, direction: .incoming, payload: receipt.transferID)
    }
}

public struct ChainTip: Equatable, Sendable {
    public let seq: Int64
    public let link: Digest32

    public init(seq: Int64, link: Digest32) {
        self.seq = seq
        self.link = link
    }
}

/// One committed row of the append-only ledger.
public struct LedgerEntry: Equatable, Sendable, Identifiable {
    public let seq: Int64
    public let kind: EntryKind
    public let counterparty: WalletPublicKey?
    public let amount: Money
    /// Local note, never shared and not part of the link.
    public let categoryID: Int64?
    public let transfer: SignedTransfer?
    public let spatialProof: SpatialProof?
    public let createdAtMS: Int64
    public let prevLink: Digest32
    public let link: Digest32

    public init(seq: Int64, kind: EntryKind, counterparty: WalletPublicKey?, amount: Money, categoryID: Int64?,
                transfer: SignedTransfer?, spatialProof: SpatialProof?, createdAtMS: Int64, prevLink: Digest32, link: Digest32) {
        self.seq = seq
        self.kind = kind
        self.counterparty = counterparty
        self.amount = amount
        self.categoryID = categoryID
        self.transfer = transfer
        self.spatialProof = spatialProof
        self.createdAtMS = createdAtMS
        self.prevLink = prevLink
        self.link = link
    }

    public var id: Int64 { seq }

    public var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(createdAtMS) / 1000) }

    /// Signed change to the owner's balance.
    public var signedMinorUnits: Int64 {
        switch kind {
        case .genesis: 0
        case .debit: -amount.minorUnits
        case .mint, .credit: amount.minorUnits
        }
    }

    public static func genesis(owner: WalletPublicKey, currency: CurrencyCode, createdAtMS: Int64) -> LedgerEntry {
        LedgerEntry(seq: 0, kind: .genesis, counterparty: nil, amount: .zero(currency), categoryID: nil, transfer: nil,
                    spatialProof: nil, createdAtMS: createdAtMS, prevLink: .zero, link: ChainLink.genesis(owner: owner))
    }

    /// Builds the next entry on top of `tip` for a transfer this wallet sent or received.
    public static func next(after tip: ChainTip, kind: EntryKind, transfer: SignedTransfer, spatialProof: SpatialProof?,
                            categoryID: Int64?, createdAtMS: Int64) -> LedgerEntry {
        precondition(kind != .genesis)
        let t = transfer.transfer
        let seq = tip.seq + 1
        return LedgerEntry(seq: seq, kind: kind, counterparty: kind == .debit ? t.payee : t.payer, amount: t.amount,
                           categoryID: categoryID, transfer: transfer, spatialProof: spatialProof, createdAtMS: createdAtMS,
                           prevLink: tip.link,
                           link: ChainLink.next(prev: tip.link, seq: seq, direction: kind.direction, payload: t.id))
    }
}

public enum ChainViolation: Error, Equatable, Sendable {
    case empty
    case badGenesis
    case sequenceGap(expected: Int64, found: Int64)
    case brokenLink(seq: Int64)
    case linkMismatch(seq: Int64)
    case missingTransfer(seq: Int64)
    case badSignature(seq: Int64)
    case wrongParty(seq: Int64)
    case amountMismatch(seq: Int64)
    case positionMismatch(seq: Int64)
    case proofMismatch(seq: Int64)
    case negativeBalance(seq: Int64)
    case overflow(seq: Int64)
    case undecodable(seq: Int64)
}

public struct ChainSummary: Equatable, Sendable {
    public let tip: ChainTip
    public let entryCount: Int
    public let balances: [CurrencyCode: Int64]

    public init(tip: ChainTip, entryCount: Int, balances: [CurrencyCode: Int64]) {
        self.tip = tip
        self.entryCount = entryCount
        self.balances = balances
    }

    public func balance(_ currency: CurrencyCode) -> Money {
        Money(minorUnits: balances[currency] ?? 0, currency: currency)
    }
}

public enum ChainVerifier {
    /// Full verification: genesis bound to `owner`, contiguous sequence, every link recomputed, every transfer
    /// signature checked, debits signed by the owner at the position they claim, balances never negative
    /// (unless this wallet is an issuer).
    public static func verify(_ entries: [LedgerEntry], owner: WalletPublicKey, allowNegativeBalance: Bool) throws -> ChainSummary {
        guard let genesis = entries.first else { throw ChainViolation.empty }
        guard genesis.seq == 0, genesis.kind == .genesis, genesis.prevLink == .zero,
              genesis.link == ChainLink.genesis(owner: owner) else { throw ChainViolation.badGenesis }

        var previous = genesis.link
        var balances: [CurrencyCode: Int64] = [:]
        for (index, entry) in entries.enumerated().dropFirst() {
            let seq = entry.seq
            guard seq == Int64(index) else { throw ChainViolation.sequenceGap(expected: Int64(index), found: seq) }
            guard entry.prevLink == previous else { throw ChainViolation.brokenLink(seq: seq) }
            guard entry.kind != .genesis, let signed = entry.transfer else { throw ChainViolation.missingTransfer(seq: seq) }
            guard signed.isSignatureValid else { throw ChainViolation.badSignature(seq: seq) }
            let transfer = signed.transfer
            guard transfer.amount == entry.amount else { throw ChainViolation.amountMismatch(seq: seq) }
            if let proof = entry.spatialProof, proof.hash != transfer.spatialProofHash {
                throw ChainViolation.proofMismatch(seq: seq)
            }
            switch entry.kind {
            case .debit:
                guard transfer.payer == owner, entry.counterparty == transfer.payee else { throw ChainViolation.wrongParty(seq: seq) }
                guard transfer.payerSeq == seq, transfer.payerPrevLink == entry.prevLink else {
                    throw ChainViolation.positionMismatch(seq: seq)
                }
            case .mint, .credit:
                guard transfer.payee == owner, entry.counterparty == transfer.payer else { throw ChainViolation.wrongParty(seq: seq) }
            case .genesis:
                throw ChainViolation.missingTransfer(seq: seq)
            }
            let expected = ChainLink.next(prev: entry.prevLink, seq: seq, direction: entry.kind.direction, payload: transfer.id)
            guard entry.link == expected else { throw ChainViolation.linkMismatch(seq: seq) }

            let currency = entry.amount.currency
            let (updated, overflow) = (balances[currency] ?? 0).addingReportingOverflow(entry.signedMinorUnits)
            guard !overflow else { throw ChainViolation.overflow(seq: seq) }
            guard allowNegativeBalance || updated >= 0 else { throw ChainViolation.negativeBalance(seq: seq) }
            balances[currency] = updated
            previous = entry.link
        }
        let last = entries[entries.count - 1]
        return ChainSummary(tip: ChainTip(seq: last.seq, link: last.link), entryCount: entries.count, balances: balances)
    }
}
