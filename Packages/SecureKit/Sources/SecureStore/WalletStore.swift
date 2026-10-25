import CryptoKit
import Foundation
import SecureCore

public enum StoreError: Error, Equatable, Sendable {
    /// The linked SQLite isn't SQLCipher, so the database would not be encrypted.
    case sqlcipherMissing
    /// The database file exists but its key is gone from the Keychain.
    case databaseKeyMissing
    /// The signer's key isn't the key this database was created for.
    case walletKeyMismatch
    /// Integrity check failed on open; the wallet is read-only.
    case walletLocked(IntegrityStatus)
    /// The chain advanced between preparing and committing a payment. Prepare again.
    case chainMoved
    case blocked(BlockReason)
    case needsOverride(BudgetVerdict)
    case proximity(ProximityFailure)
    case invalidTransfer(String)
    case fork(ForkEvidence)
    case invalidBudget
}

public enum IntegrityStatus: Equatable, Sendable {
    case verified
    /// The database was ahead of the Keychain anchor (the app stopped between the two writes). The anchor was moved forward.
    case anchorAdvanced(from: Int64, to: Int64)
    /// The database is behind the anchor: an older copy was restored.
    case rolledBack(anchorSeq: Int64, databaseSeq: Int64)
    /// The database contradicts the anchor at `atSeq`: history was rewritten.
    case diverged(atSeq: Int64)
    /// The database has history but no anchor exists for it.
    case anchorMissing
    case chainInvalid(ChainViolation)

    public var isLocked: Bool {
        switch self {
        case .verified, .anchorAdvanced: false
        default: true
        }
    }
}

public struct WalletConfiguration: Sendable {
    public var currency: CurrencyCode
    /// Issuers create money: their balance may go negative and incoming transfers from them count as mints.
    public var isIssuer: Bool
    /// Limits on this wallet's own spending.
    public var spendingLimits: OfflineLimits
    /// Largest transfer this wallet accepts from a peer offline, capping double-spend exposure.
    public var acceptanceLimits: OfflineLimits
    public var proximityPolicy: ProximityPolicy
    public var calendar: Calendar

    public init(currency: CurrencyCode = .usd, isIssuer: Bool = false, spendingLimits: OfflineLimits = .none,
                acceptanceLimits: OfflineLimits = .none, proximityPolicy: ProximityPolicy = .device,
                calendar: Calendar = .current) {
        self.currency = currency
        self.isIssuer = isIssuer
        self.spendingLimits = spendingLimits
        self.acceptanceLimits = acceptanceLimits
        self.proximityPolicy = proximityPolicy
        self.calendar = calendar
    }
}

public struct Category: Equatable, Hashable, Sendable, Identifiable {
    public let id: Int64
    public var name: String
    public var iconName: String?
    public var archived: Bool
}

/// Everything the payer decides before the Face ID prompt.
public struct PaymentDraft: Sendable {
    public let payer: WalletPublicKey
    public let payee: WalletPublicKey
    public let amount: Money
    public let categoryID: Int64?
    public let sessionNonce: Digest32
    public let tip: ChainTip
    public let verdict: BudgetVerdict
    public let createdAtMS: Int64

    public func transfer(spatialProof: SpatialProof) -> Transfer {
        Transfer(payer: payer, payee: payee, amount: amount, sessionNonce: sessionNonce, payerSeq: tip.seq + 1,
                 payerPrevLink: tip.link, spatialProofHash: spatialProof.hash, createdAtMS: createdAtMS)
    }
}

public struct AcceptedTransfer: Sendable {
    public let entry: LedgerEntry
    /// Unsigned; the payee signs it with its own signer and returns it to the payer.
    public let receipt: Receipt
    public let wasDuplicate: Bool
}

/// The wallet's encrypted ledger. All reads and writes go through this actor, which owns the single
/// SQLCipher connection and keeps the Keychain anchor in step with the chain tip.
public actor WalletStore {
    public nonisolated let walletKey: WalletPublicKey
    public nonisolated let configuration: WalletConfiguration
    public nonisolated let cipherVersion: String
    public nonisolated let databaseURL: URL?

    public private(set) var integrity: IntegrityStatus
    /// Set when a commit saw the device clock earlier than the previous entry.
    public private(set) var clockWentBackwards = false

    private let db: SQLiteDatabase
    private let secrets: any SecretStore
    private let accounts: SecretAccounts
    private var summary: ChainSummary
    private var issuerKeys: Set<WalletPublicKey>
    private var lastCreatedAtMS: Int64

    /// True if a database for `name` already exists in `directory`. Use it to decide whether a fresh
    /// wallet identity is needed: a reinstall must not reuse an old key from sequence 0 again.
    public static func databaseExists(directory: URL, name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).sqlite").path)
    }

    /// Opens or creates the wallet `name` in `directory` (nil = in memory, unencrypted; demo and tests only).
    /// Verifies the whole chain and compares its tip with the Keychain anchor; any mismatch locks the wallet.
    public init(directory: URL?, name: String, secrets: any SecretStore, walletKey: WalletPublicKey,
                configuration: WalletConfiguration, now: Date = Date()) throws {
        let accounts = SecretAccounts(name: name)
        let url = directory?.appendingPathComponent("\(name).sqlite")
        let db: SQLiteDatabase
        if let url {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let key: Data
            if let stored = try secrets.read(accounts.databaseKey), stored.count == 32 {
                key = stored
            } else if exists {
                throw StoreError.databaseKeyMissing
            } else {
                key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                try secrets.write(key, account: accounts.databaseKey)
            }
            db = try SQLiteDatabase(path: url.path, key: key)
            WalletLocation.protectFile(at: url)
        } else {
            db = try SQLiteDatabase(path: ":memory:", key: nil)
        }
        try Schema.migrate(db)

        var created = false
        if let stored = try Self.meta(db, "wallet_key") {
            guard (try? WalletPublicKey(canonicalBytes: stored)) == walletKey else { throw StoreError.walletKeyMismatch }
        } else {
            created = true
            try db.transaction {
                try Self.setMeta(db, "wallet_key", walletKey.canonicalBytes)
                try Self.setMeta(db, "currency", Data(configuration.currency.rawValue.utf8))
                try Self.insert(db, LedgerEntry.genesis(owner: walletKey, currency: configuration.currency,
                                                       createdAtMS: now.millisecondsSince1970))
            }
        }

        let issuers = try Self.loadIssuerKeys(db)
        let (entries, decodeFailure) = Self.loadEntries(db)
        var summary: ChainSummary
        var integrity: IntegrityStatus
        do {
            if let decodeFailure { throw decodeFailure }
            summary = try ChainVerifier.verify(entries, owner: walletKey, allowNegativeBalance: configuration.isIssuer)
            let anchor = try ChainAnchor.read(secrets, account: accounts.anchor)
            integrity = ChainAnchor.evaluate(anchor: anchor, entries: entries, genesisLink: ChainLink.genesis(owner: walletKey),
                                             created: created)
            if !integrity.isLocked {
                try ChainAnchor(genesisLink: ChainLink.genesis(owner: walletKey), tip: summary.tip)
                    .write(secrets, account: accounts.anchor)
            }
        } catch let violation as ChainViolation {
            integrity = .chainInvalid(violation)
            let last = entries.last
            summary = ChainSummary(tip: ChainTip(seq: last?.seq ?? -1, link: last?.link ?? .zero),
                                   entryCount: entries.count, balances: [:])
        }

        self.walletKey = walletKey
        self.configuration = configuration
        self.cipherVersion = db.cipherVersion
        self.databaseURL = url
        self.db = db
        self.secrets = secrets
        self.accounts = accounts
        self.summary = summary
        self.integrity = integrity
        self.issuerKeys = issuers
        self.lastCreatedAtMS = entries.last?.createdAtMS ?? 0
    }

    // MARK: - Reading

    public var tip: ChainTip { summary.tip }
    public var entryCount: Int { summary.entryCount }

    public func balance(_ currency: CurrencyCode? = nil) -> Money {
        summary.balance(currency ?? configuration.currency)
    }

    /// What may be spent now; nil for an issuer, which has no balance limit.
    public func spendable(_ currency: CurrencyCode? = nil) -> Money? {
        configuration.isIssuer ? nil : balance(currency)
    }

    public func entries(limit: Int = 200) throws -> [LedgerEntry] {
        try db.query(Self.entrySelect + " ORDER BY seq DESC LIMIT ?", [.integer(Int64(limit))]) { try Self.decodeEntry($0) }
    }

    public func receipt(forEntryLink link: Digest32) throws -> SignedReceipt? {
        try db.query("SELECT receipt FROM receipts WHERE entry_link = ?", [.blob(link.bytes)]) {
            try SignedReceipt(canonicalBytes: $0.blob(0))
        }.first
    }

    public func peers() throws -> [PeerRecord] {
        try db.query("SELECT public_key, display_name, last_claim, fork_evidence FROM peers ORDER BY updated_ms DESC") {
            try Self.decodePeer($0)
        }
    }

    public func peer(_ key: WalletPublicKey) throws -> PeerRecord? {
        try db.query("SELECT public_key, display_name, last_claim, fork_evidence FROM peers WHERE public_key = ?",
                     [.blob(key.canonicalBytes)]) { try Self.decodePeer($0) }.first
    }

    public func isIssuer(_ key: WalletPublicKey) -> Bool { issuerKeys.contains(key) }

    /// Re-runs full verification against the anchor, e.g. from a diagnostics screen.
    @discardableResult
    public func reverify() throws -> IntegrityStatus {
        let (entries, decodeFailure) = Self.loadEntries(db)
        do {
            if let decodeFailure { throw decodeFailure }
            let verified = try ChainVerifier.verify(entries, owner: walletKey, allowNegativeBalance: configuration.isIssuer)
            let anchor = try ChainAnchor.read(secrets, account: accounts.anchor)
            let status = ChainAnchor.evaluate(anchor: anchor, entries: entries, genesisLink: ChainLink.genesis(owner: walletKey),
                                              created: false)
            summary = verified
            if !status.isLocked {
                try ChainAnchor(genesisLink: ChainLink.genesis(owner: walletKey), tip: verified.tip)
                    .write(secrets, account: accounts.anchor)
            }
            integrity = status
        } catch let violation as ChainViolation {
            integrity = .chainInvalid(violation)
        }
        return integrity
    }

    // MARK: - Categories and budgets

    public func categories(includeArchived: Bool = false) throws -> [Category] {
        try db.query("SELECT id, name, icon_name, archived FROM categories" + (includeArchived ? "" : " WHERE archived = 0")
                     + " ORDER BY name COLLATE NOCASE") {
            Category(id: $0.int(0), name: $0.text(1), iconName: $0.optionalText(2), archived: $0.int(3) == 1)
        }
    }

    @discardableResult
    public func addCategory(name: String, iconName: String? = nil) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.run("INSERT INTO categories (name, icon_name) VALUES (?, ?)", [.text(trimmed), .optional(iconName)])
        let id = try db.scalarInt("SELECT id FROM categories WHERE name = ?", [.text(trimmed)]) ?? 0
        return Category(id: id, name: trimmed, iconName: iconName, archived: false)
    }

    /// Categories used by ledger entries can't be deleted (the ledger is append-only), only archived.
    public func setCategoryArchived(id: Int64, archived: Bool) throws {
        try db.run("UPDATE categories SET archived = ? WHERE id = ?", [.integer(archived ? 1 : 0), .integer(id)])
    }

    public func budgets() throws -> [Budget] {
        try db.query("SELECT id, category_id, cap_minor, currency, period, anchor, start_date, length_days, alert_pct, hard_cap FROM budgets ORDER BY id") {
            try decodeBudget($0)
        }
    }

    /// Inserts when `budget.id == 0`, otherwise updates.
    @discardableResult
    public func saveBudget(_ budget: Budget) throws -> Budget {
        guard budget.period.isValid, (1...100).contains(budget.alertPercent), budget.cap.minorUnits >= 0 else {
            throw StoreError.invalidBudget
        }
        var anchor: Int64?, startDate: String?, length: Int64?
        let periodName: String
        switch budget.period {
        case .monthly(let day): periodName = "monthly"; anchor = Int64(day)
        case .weekly(let weekday): periodName = "weekly"; anchor = Int64(weekday)
        case .rolling(let days): periodName = "rolling"; length = Int64(days)
        case .custom(let start, let days): periodName = "custom"; startDate = isoDay(start); length = Int64(days)
        }
        let values: [SQLValue] = [.integer(budget.categoryID), .integer(budget.cap.minorUnits), .text(budget.cap.currency.rawValue),
                                  .text(periodName), .optional(anchor), .optional(startDate), .optional(length),
                                  .integer(Int64(budget.alertPercent)), .integer(budget.hardCap ? 1 : 0)]
        if budget.id == 0 {
            try db.run("INSERT INTO budgets (category_id, cap_minor, currency, period, anchor, start_date, length_days, alert_pct, hard_cap) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", values)
            var saved = budget
            saved.id = try db.scalarInt("SELECT last_insert_rowid()") ?? 0
            return saved
        }
        try db.run("UPDATE budgets SET category_id = ?, cap_minor = ?, currency = ?, period = ?, anchor = ?, start_date = ?, length_days = ?, alert_pct = ?, hard_cap = ? WHERE id = ?",
                   values + [.integer(budget.id)])
        return budget
    }

    public func deleteBudget(id: Int64) throws {
        try db.run("DELETE FROM budgets WHERE id = ?", [.integer(id)])
    }

    /// Current spending against every budget, for display.
    public func budgetStatuses(now: Date = Date()) throws -> [BudgetStatus] {
        try budgets().compactMap { budget in
            guard let window = budget.period.window(containing: now, calendar: configuration.calendar) else { return nil }
            return BudgetStatus(budget: budget, window: window,
                                spentBefore: try spent(categoryID: budget.categoryID, currency: budget.cap.currency, window: window),
                                requested: 0)
        }
    }

    public func spent(categoryID: Int64, currency: CurrencyCode, window: BudgetWindow) throws -> Int64 {
        try db.scalarInt("""
            SELECT COALESCE(SUM(amount_minor), 0) FROM ledger
            WHERE kind = 'debit' AND category_id = ? AND currency = ? AND created_at_ms >= ? AND created_at_ms < ?
            """, [.integer(categoryID), .text(currency.rawValue), .integer(window.startMS), .integer(window.endMS)]) ?? 0
    }

    public func evaluate(amount: Money, categoryID: Int64?, now: Date = Date()) throws -> BudgetVerdict {
        let budgets = try budgets()
        let startOfDay = configuration.calendar.startOfDay(for: now).millisecondsSince1970
        let spentToday = try db.scalarInt(
            "SELECT COALESCE(SUM(amount_minor), 0) FROM ledger WHERE kind = 'debit' AND currency = ? AND created_at_ms >= ?",
            [.text(amount.currency.rawValue), .integer(startOfDay)]) ?? 0
        return try BudgetEngine.evaluate(amount: amount, categoryID: categoryID, budgets: budgets, now: now,
                                         calendar: configuration.calendar, available: spendable(amount.currency),
                                         limits: configuration.spendingLimits, spentToday: spentToday) { budget, window in
            try spent(categoryID: budget.categoryID, currency: budget.cap.currency, window: window)
        }
    }

    // MARK: - Issuers

    public func pinIssuer(_ key: WalletPublicKey) throws {
        guard !issuerKeys.contains(key) else { return }
        issuerKeys.insert(key)
        var w = CanonicalWriter()
        let sorted = issuerKeys.map(\.canonicalBytes).sorted { $0.lexicographicallyPrecedes($1) }
        w.writeU32(UInt32(sorted.count))
        sorted.forEach { w.writeBytes($0) }
        try Self.setMeta(db, "issuer_keys", w.data)
    }

    // MARK: - Paying

    /// Step 1 for the payer: budget and balance check before any Face ID prompt.
    /// Throws `.blocked` for hard stops; an over-budget verdict is returned so the UI can ask for an override.
    public func preparePayment(amount: Money, categoryID: Int64?, payee: WalletPublicKey, sessionNonce: Digest32,
                               now: Date = Date()) throws -> PaymentDraft {
        try ensureUnlocked()
        guard payee != walletKey else { throw StoreError.invalidTransfer("payer and payee are the same wallet") }
        let verdict = try evaluate(amount: amount, categoryID: categoryID, now: now)
        if case .blocked(let reason) = verdict { throw StoreError.blocked(reason) }
        return PaymentDraft(payer: walletKey, payee: payee, amount: amount, categoryID: categoryID, sessionNonce: sessionNonce,
                            tip: summary.tip, verdict: verdict, createdAtMS: now.millisecondsSince1970)
    }

    /// Step 2 for the payer, after signing: re-checks budgets inside the write transaction and appends the debit.
    /// The debit is committed before the transfer is handed over, so the same funds can never be signed twice.
    @discardableResult
    public func commitDebit(_ signed: SignedTransfer, spatialProof: SpatialProof, categoryID: Int64?,
                            overrideOverBudget: Bool, now: Date = Date()) throws -> LedgerEntry {
        try ensureUnlocked()
        let transfer = signed.transfer
        guard transfer.payer == walletKey, signed.isSignatureValid else { throw StoreError.invalidTransfer("not signed by this wallet") }
        guard spatialProof.hash == transfer.spatialProofHash else { throw StoreError.invalidTransfer("spatial proof does not match transfer") }
        let entry = try db.transaction { () throws -> LedgerEntry in
            let tip = summary.tip
            guard transfer.payerSeq == tip.seq + 1, transfer.payerPrevLink == tip.link else { throw StoreError.chainMoved }
            let verdict = try evaluate(amount: transfer.amount, categoryID: categoryID, now: now)
            if case .blocked(let reason) = verdict { throw StoreError.blocked(reason) }
            guard verdict.allowsCommit(overrideOverBudget: overrideOverBudget) else { throw StoreError.needsOverride(verdict) }
            let entry = LedgerEntry.next(after: tip, kind: .debit, transfer: signed, spatialProof: spatialProof,
                                         categoryID: categoryID, createdAtMS: now.millisecondsSince1970)
            try Self.insert(db, entry)
            return entry
        }
        didAppend(entry)
        return entry
    }

    /// Step 3 for the payer: keep the payee's countersignature and learn the payee's chain position.
    public func storeReceipt(_ signed: SignedReceipt, now: Date = Date()) throws {
        guard signed.isSignatureValid else { throw StoreError.invalidTransfer("bad receipt signature") }
        let receipt = signed.receipt
        guard let entry = try entry(transferID: receipt.transferID), entry.kind == .debit else {
            throw StoreError.invalidTransfer("receipt for an unknown transfer")
        }
        guard entry.counterparty == receipt.payee else { throw StoreError.invalidTransfer("receipt from the wrong payee") }
        let claim = ChainClaim.credit(signed)
        let verdict = Continuity.check(claim, against: try peer(receipt.payee))
        if case .fork(let evidence) = verdict {
            try recordFork(evidence, peer: receipt.payee, now: now)
            throw StoreError.fork(evidence)
        }
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO receipts (entry_link, receipt, received_at_ms) VALUES (?, ?, ?)",
                       [.blob(entry.link.bytes), .blob(signed.canonicalBytes), .integer(now.millisecondsSince1970)])
            try advancePeer(receipt.payee, displayName: nil, claim: claim, verdict: verdict, now: now)
        }
    }

    // MARK: - Receiving

    /// The payee's "Ready" check, run before the payer signs, so a valid transfer is never refused after the payer's debit.
    public func preflightIncoming(amount: Money, payer: WalletPublicKey, sessionNonce: Digest32, spatialProof: SpatialProof) throws {
        try ensureUnlocked()
        guard payer != walletKey else { throw StoreError.invalidTransfer("payer and payee are the same wallet") }
        try verifyProof(spatialProof, sessionNonce: sessionNonce, payer: payer)
        try checkAcceptanceLimits(amount)
        if let evidence = try peer(payer)?.forkEvidence, evidence.isValid { throw StoreError.fork(evidence) }
    }

    /// Verifies and records an incoming transfer. Re-delivery of a recorded transfer is idempotent.
    public func acceptTransfer(_ signed: SignedTransfer, spatialProof: SpatialProof, expectedNonce: Digest32,
                               categoryID: Int64? = nil, payerName: String? = nil, now: Date = Date()) throws -> AcceptedTransfer {
        try ensureUnlocked()
        let transfer = signed.transfer
        guard transfer.payee == walletKey else { throw StoreError.invalidTransfer("not addressed to this wallet") }
        guard transfer.payer != walletKey else { throw StoreError.invalidTransfer("payer and payee are the same wallet") }
        guard transfer.sessionNonce == expectedNonce else { throw StoreError.invalidTransfer("session nonce mismatch") }
        guard signed.isSignatureValid else { throw StoreError.invalidTransfer("bad payer signature") }
        guard spatialProof.hash == transfer.spatialProofHash else { throw StoreError.invalidTransfer("spatial proof does not match transfer") }
        try verifyProof(spatialProof, sessionNonce: expectedNonce, payer: transfer.payer)
        try checkAcceptanceLimits(transfer.amount)

        if let existing = try entry(transferID: signed.id) {
            return AcceptedTransfer(entry: existing, receipt: receipt(for: existing), wasDuplicate: true)
        }
        let record = try peer(transfer.payer)
        if let evidence = record?.forkEvidence, evidence.isValid { throw StoreError.fork(evidence) }
        let claim = ChainClaim.debit(signed)
        let verdict = Continuity.check(claim, against: record)
        switch verdict {
        case .fork(let evidence):
            try recordFork(evidence, peer: transfer.payer, now: now)
            throw StoreError.fork(evidence)
        case .duplicate:
            throw StoreError.invalidTransfer("transfer already seen")
        case .firstContact, .contiguous, .gap, .outOfOrder:
            break
        }

        let kind: EntryKind = issuerKeys.contains(transfer.payer) ? .mint : .credit
        let entry = try db.transaction { () throws -> LedgerEntry in
            let entry = LedgerEntry.next(after: summary.tip, kind: kind, transfer: signed, spatialProof: spatialProof,
                                         categoryID: categoryID, createdAtMS: now.millisecondsSince1970)
            try Self.insert(db, entry)
            try advancePeer(transfer.payer, displayName: payerName, claim: claim, verdict: verdict, now: now)
            return entry
        }
        didAppend(entry)
        return AcceptedTransfer(entry: entry, receipt: receipt(for: entry), wasDuplicate: false)
    }

    // MARK: - Internals

    private func ensureUnlocked() throws {
        guard !integrity.isLocked else { throw StoreError.walletLocked(integrity) }
    }

    private func verifyProof(_ proof: SpatialProof, sessionNonce: Digest32, payer: WalletPublicKey) throws {
        do {
            try proof.verify(sessionNonce: sessionNonce, payer: payer, payee: walletKey, policy: configuration.proximityPolicy)
        } catch let failure as ProximityFailure {
            throw StoreError.proximity(failure)
        }
    }

    private func checkAcceptanceLimits(_ amount: Money) throws {
        if let limit = configuration.acceptanceLimits.perTransfer, limit.currency == amount.currency,
           amount.minorUnits > limit.minorUnits {
            throw StoreError.blocked(.overTransferLimit(limit: limit, requested: amount))
        }
    }

    private func receipt(for entry: LedgerEntry) -> Receipt {
        Receipt(transferID: entry.transfer!.id, payee: walletKey, payeeSeq: entry.seq, payeePrevLink: entry.prevLink,
                createdAtMS: entry.createdAtMS)
    }

    /// Updates the in-memory summary and the Keychain anchor after a committed append.
    private func didAppend(_ entry: LedgerEntry) {
        var balances = summary.balances
        balances[entry.amount.currency, default: 0] += entry.signedMinorUnits
        summary = ChainSummary(tip: ChainTip(seq: entry.seq, link: entry.link), entryCount: summary.entryCount + 1,
                               balances: balances)
        if entry.createdAtMS < lastCreatedAtMS { clockWentBackwards = true }
        lastCreatedAtMS = max(lastCreatedAtMS, entry.createdAtMS)
        // If this write fails, the next open finds the database one step ahead and repairs the anchor.
        try? ChainAnchor(genesisLink: ChainLink.genesis(owner: walletKey), tip: summary.tip).write(secrets, account: accounts.anchor)
    }

    private func advancePeer(_ key: WalletPublicKey, displayName: String?, claim: ChainClaim, verdict: ContinuityVerdict,
                             now: Date) throws {
        let advances: Bool
        switch verdict {
        case .firstContact, .contiguous, .gap: advances = true
        case .outOfOrder, .duplicate, .fork: advances = false
        }
        let ms = Int64(now.millisecondsSince1970)
        if advances {
            try db.run("""
                INSERT INTO peers (public_key, display_name, last_claim, last_seq, first_seen_ms, updated_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (public_key) DO UPDATE SET
                    last_claim = excluded.last_claim, last_seq = excluded.last_seq, updated_ms = excluded.updated_ms,
                    display_name = COALESCE(excluded.display_name, peers.display_name)
                WHERE excluded.last_seq > peers.last_seq
                """, [.blob(key.canonicalBytes), .optional(displayName), .blob(claim.canonicalBytes), .integer(claim.seq),
                      .integer(ms), .integer(ms)])
        } else if let displayName {
            try db.run("UPDATE peers SET display_name = ?, updated_ms = ? WHERE public_key = ?",
                       [.text(displayName), .integer(ms), .blob(key.canonicalBytes)])
        }
    }

    private func recordFork(_ evidence: ForkEvidence, peer key: WalletPublicKey, now: Date) throws {
        let ms = now.millisecondsSince1970
        try db.run("""
            INSERT INTO peers (public_key, last_claim, last_seq, first_seen_ms, updated_ms, fork_evidence)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (public_key) DO UPDATE SET fork_evidence = excluded.fork_evidence, updated_ms = excluded.updated_ms
            """, [.blob(key.canonicalBytes), .blob(evidence.earlier.canonicalBytes), .integer(evidence.earlier.seq),
                  .integer(ms), .integer(ms), .blob(evidence.canonicalBytes)])
    }

    private func entry(transferID: Digest32) throws -> LedgerEntry? {
        try db.query(Self.entrySelect + " WHERE transfer_id = ?", [.blob(transferID.bytes)]) { try Self.decodeEntry($0) }.first
    }

    private func decodeBudget(_ row: SQLRow) throws -> Budget {
        let period: BudgetPeriod
        switch row.text(4) {
        case "monthly": period = .monthly(anchorDay: Int(row.int(5)))
        case "weekly": period = .weekly(anchorWeekday: Int(row.int(5)))
        case "rolling": period = .rolling(days: Int(row.int(7)))
        default:
            guard let start = row.optionalText(6).flatMap(date(fromISODay:)) else { throw StoreError.invalidBudget }
            period = .custom(start: start, lengthDays: Int(row.int(7)))
        }
        guard let currency = CurrencyCode(row.text(3)) else { throw StoreError.invalidBudget }
        return Budget(id: row.int(0), categoryID: row.int(1), cap: Money(minorUnits: row.int(2), currency: currency),
                      period: period, alertPercent: Int(row.int(8)), hardCap: row.int(9) == 1)
    }

    private func isoDay(_ date: Date) -> String {
        let c = configuration.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func date(fromISODay text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return configuration.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: - Row mapping

    private static let entrySelect = """
        SELECT seq, kind, counterparty_key, amount_minor, currency, category_id, transfer, spatial_proof,
               created_at_ms, prev_link, link FROM ledger
        """

    private static func decodeEntry(_ row: SQLRow) throws -> LedgerEntry {
        let seq = row.int(0)
        guard let kind = EntryKind(rawValue: row.text(1)),
              let currency = CurrencyCode(row.text(4)),
              let prevLink = Digest32(row.blob(9)),
              let link = Digest32(row.blob(10))
        else { throw ChainViolation.undecodable(seq: seq) }
        do {
            return LedgerEntry(seq: seq, kind: kind,
                               counterparty: try row.optionalBlob(2).map { try WalletPublicKey(canonicalBytes: $0) },
                               amount: Money(minorUnits: row.int(3), currency: currency),
                               categoryID: row.optionalInt(5),
                               transfer: try row.optionalBlob(6).map { try SignedTransfer(canonicalBytes: $0) },
                               spatialProof: try row.optionalBlob(7).map { try SpatialProof(canonicalBytes: $0) },
                               createdAtMS: row.int(8), prevLink: prevLink, link: link)
        } catch {
            throw ChainViolation.undecodable(seq: seq)
        }
    }

    private static func decodePeer(_ row: SQLRow) throws -> PeerRecord {
        PeerRecord(publicKey: try WalletPublicKey(canonicalBytes: row.blob(0)), displayName: row.optionalText(1),
                   lastClaim: try ChainClaim(canonicalBytes: row.blob(2)),
                   forkEvidence: try row.optionalBlob(3).map { try ForkEvidence(canonicalBytes: $0) })
    }

    private static func loadEntries(_ db: SQLiteDatabase) -> ([LedgerEntry], ChainViolation?) {
        var entries: [LedgerEntry] = []
        do {
            entries = try db.query(entrySelect + " ORDER BY seq") { try decodeEntry($0) }
            return (entries, nil)
        } catch let violation as ChainViolation {
            return (entries, violation)
        } catch {
            return (entries, .undecodable(seq: Int64(entries.count)))
        }
    }

    private static func insert(_ db: SQLiteDatabase, _ e: LedgerEntry) throws {
        try db.run("""
            INSERT INTO ledger (seq, kind, counterparty_key, amount_minor, currency, category_id, session_nonce, transfer_id,
                                transfer, spatial_proof, spatial_proof_hash, created_at_ms, prev_link, link)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.integer(e.seq), .text(e.kind.rawValue), .optional(e.counterparty?.canonicalBytes),
                  .integer(e.amount.minorUnits), .text(e.amount.currency.rawValue), .optional(e.categoryID),
                  .optional(e.transfer?.transfer.sessionNonce.bytes), .optional(e.transfer?.id.bytes),
                  .optional(e.transfer?.canonicalBytes), .optional(e.spatialProof?.canonicalBytes),
                  .optional(e.spatialProof?.hash.bytes), .integer(e.createdAtMS), .blob(e.prevLink.bytes), .blob(e.link.bytes)])
    }

    private static func meta(_ db: SQLiteDatabase, _ key: String) throws -> Data? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.blob(0) }.first
    }

    private static func setMeta(_ db: SQLiteDatabase, _ key: String, _ value: Data) throws {
        try db.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                   [.text(key), .blob(value)])
    }

    private static func loadIssuerKeys(_ db: SQLiteDatabase) throws -> Set<WalletPublicKey> {
        guard let data = try meta(db, "issuer_keys") else { return [] }
        var r = CanonicalReader(data)
        let count = try r.readU32()
        var keys = Set<WalletPublicKey>()
        for _ in 0..<count { keys.insert(try WalletPublicKey(canonicalBytes: try r.readBytes())) }
        try r.finish()
        return keys
    }
}

/// Keychain account names for one wallet.
struct SecretAccounts {
    let databaseKey: String
    let anchor: String

    init(name: String) {
        databaseKey = "\(name).database-key"
        anchor = "\(name).chain-anchor"
    }
}
