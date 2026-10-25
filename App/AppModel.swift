import Foundation
import Observation
import SecureCore
import SecureDevice
import SecureStore

struct BudgetRow: Identifiable, Equatable {
    let id: Int64
    let categoryName: String
    let iconName: String
    let spent: Money
    let cap: Money
    let periodLabel: String
    let isOver: Bool
    let reachesAlert: Bool
    let hardCap: Bool

    var fraction: Double { cap.minorUnits == 0 ? 1 : min(1, Double(spent.minorUnits) / Double(cap.minorUnits)) }
}

struct ActivityRow: Identifiable, Hashable {
    let id: Int64
    let entry: LedgerEntry
    let title: String
    let categoryName: String?
    let distanceCM: UInt16?
    let hasReceipt: Bool

    static func == (lhs: ActivityRow, rhs: ActivityRow) -> Bool { lhs.id == rhs.id && lhs.hasReceipt == rhs.hasReceipt }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A payment request waiting for the user's decision.
struct ApprovalRequest: Identifiable, Equatable {
    let id: String
    let payee: String
    let amount: Money
    let categoryID: Int64?
}

struct Banner: Identifiable, Equatable {
    enum Kind { case success, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// App state. Phase 1 runs both sides of every transfer in-process: "Demo Issuer" mints funds and
/// "Demo Shop" receives payments, each with its own encrypted ledger and software key.
@Observable
final class AppModel {
    enum Phase: Equatable { case loading, ready, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var balance = Money.zero(.usd)
    private(set) var budgetRows: [BudgetRow] = []
    private(set) var categories: [SecureStore.Category] = []
    private(set) var activity: [ActivityRow] = []
    private(set) var integrity: IntegrityStatus = .verified
    private(set) var diagnostics = Diagnostics()
    var banner: Banner?
    /// Set when the user opens a payment-request notification; the home screen shows it as an approval sheet.
    var approvalRequest: ApprovalRequest?

    private var wallet: WalletStore?
    private var signer: (any TransactionSigner)?
    private var issuer: DemoPeer?
    private var shop: DemoPeer?
    private var pendingRequests: [String: PendingRequest] = [:]
    private let secrets = KeychainSecretStore(service: "com.example.secure")

    struct Diagnostics: Equatable {
        var signer = ""
        var walletFingerprint = ""
        var cipherVersion = ""
        var fileEncrypted = false
        var chainLength = 0
        var tipLink = ""
        var biometry = ""
        var proximityPolicy = ""
    }

    struct PendingRequest {
        let amount: Money
        let categoryID: Int64?
    }

    /// Simulated proximity until Phase 3 brings NearbyInteraction. Real-device policy rejects simulated proofs,
    /// so debug builds accept them; release builds don't.
    nonisolated static var proximityPolicy: ProximityPolicy {
        #if DEBUG || targetEnvironment(simulator)
        .simulator
        #else
        .device
        #endif
    }

    // MARK: - Startup

    func start() async {
        guard wallet == nil else { return }
        do {
            let opened = try await Task.detached(priority: .userInitiated) { [secrets] in
                try WalletBootstrap.open(secrets: secrets, policy: AppModel.proximityPolicy)
            }.value
            wallet = opened.wallet
            signer = opened.signer
            issuer = opened.issuer
            shop = opened.shop
            try await opened.wallet.pinIssuer(opened.issuer.signer.publicKey)
            NotificationService.shared.onAction = { [weak self] action in
                Task { await self?.handle(action) }
            }
            await NotificationService.shared.requestAuthorization()
            try await seedIfNeeded()
            await refresh()
            phase = .ready
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// First launch: the PRD's example categories and a $200/month Clothing budget.
    private func seedIfNeeded() async throws {
        guard let wallet, try await wallet.categories(includeArchived: true).isEmpty else { return }
        _ = try await wallet.addCategory(name: "Food", iconName: "fork.knife")
        let clothing = try await wallet.addCategory(name: "Clothing", iconName: "tshirt")
        _ = try await wallet.addCategory(name: "Transport", iconName: "tram")
        try await wallet.saveBudget(Budget(id: 0, categoryID: clothing.id, cap: Money(minorUnits: 20_000, currency: .usd),
                                           period: .monthly(anchorDay: 1), alertPercent: 80))
    }

    // MARK: - Reading

    func refresh() async {
        guard let wallet else { return }
        do {
            let categories = try await wallet.categories(includeArchived: true)
            let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
            let statuses = try await wallet.budgetStatuses()
            let entries = try await wallet.entries(limit: 50)
            var rows: [ActivityRow] = []
            for entry in entries where entry.kind != .genesis {
                let receipt = entry.kind == .debit ? try await wallet.receipt(forEntryLink: entry.link) : nil
                let distance = entry.spatialProof.map {
                    UInt16((Int($0.payerSide.measurement.summary.distanceCM) + Int($0.payeeSide.measurement.summary.distanceCM)) / 2)
                }
                rows.append(ActivityRow(id: entry.seq, entry: entry, title: name(for: entry.counterparty),
                                        categoryName: entry.categoryID.flatMap { names[$0]?.name }, distanceCM: distance,
                                        hasReceipt: receipt != nil))
            }
            self.categories = categories.filter { !$0.archived }
            self.budgetRows = statuses.map { status in
                let category = names[status.budget.categoryID]
                return BudgetRow(id: status.budget.id, categoryName: category?.name ?? "Category",
                                 iconName: category?.iconName ?? "tag", spent: status.spentBeforeMoney, cap: status.budget.cap,
                                 periodLabel: Self.label(for: status.budget.period), isOver: status.spentBefore > status.budget.cap.minorUnits,
                                 reachesAlert: status.spentBefore >= status.budget.alertThresholdMinor, hardCap: status.budget.hardCap)
            }
            self.activity = rows
            self.balance = await wallet.balance()
            self.integrity = await wallet.integrity
            self.diagnostics = await makeDiagnostics(wallet)
        } catch {
            banner = Banner(kind: .error, text: Self.describe(error))
        }
    }

    func evaluate(amount: Money, categoryID: Int64?) async -> BudgetVerdict? {
        try? await wallet?.evaluate(amount: amount, categoryID: categoryID)
    }

    func name(for key: WalletPublicKey?) -> String {
        guard let key else { return "Wallet created" }
        if key == issuer?.signer.publicKey { return DemoPeer.issuerName }
        if key == shop?.signer.publicKey { return DemoPeer.shopName }
        return NearbyNames.name(for: key) ?? key.fingerprint
    }

    // MARK: - Actions

    /// Pays Demo Shop. Face ID approves; the Secure Enclave signs on a phone, a Face ID-gated software key on the Simulator.
    @discardableResult
    func pay(amount: Money, categoryID: Int64?, overrideOverBudget: Bool) async -> Bool {
        guard let wallet, let signer, let shop else { return false }
        do {
            let outcome = try await LoopbackPayment.run(from: participant(wallet, signer), to: shop.participant,
                                                        amount: amount, categoryID: categoryID,
                                                        overrideOverBudget: overrideOverBudget)
            await alertIfNeeded(outcome.verdict)
            banner = Banner(kind: .success, text: "Paid \(amount.formatted()) to \(DemoPeer.shopName) · \(outcome.agreedDistanceCM) cm apart")
            await refresh()
            return true
        } catch {
            banner = Banner(kind: .error, text: Self.describe(error))
            await refresh()
            return false
        }
    }

    /// Demo Issuer mints funds to this wallet. Receiving also needs Face ID: the wallet countersigns a receipt.
    func addDemoFunds(_ amount: Money = Money(minorUnits: 50_000, currency: .usd)) async {
        guard let wallet, let signer, let issuer else { return }
        do {
            _ = try await LoopbackPayment.run(from: issuer.participant, to: participant(wallet, signer), amount: amount, categoryID: nil)
            banner = Banner(kind: .success, text: "Received \(amount.formatted()) from \(DemoPeer.issuerName)")
        } catch {
            banner = Banner(kind: .error, text: Self.describe(error))
        }
        await refresh()
    }

    /// Posts the PRD's lock-screen request ("Approve $25 transaction?") after a short delay, so there is
    /// time to lock the phone or leave the app.
    func simulateIncomingRequest() async {
        guard let wallet else { return }
        let clothing = categories.first { $0.name == "Clothing" }
        let amount = Money(minorUnits: 2_500, currency: .usd)
        let id = UUID().uuidString
        pendingRequests[id] = PendingRequest(amount: amount, categoryID: clothing?.id)
        var body = "\(DemoPeer.shopName) requests \(amount.formatted())."
        if let clothing, let status = try? await wallet.budgetStatuses().first(where: { $0.budget.categoryID == clothing.id }) {
            body = "\(clothing.name): \(status.spentBeforeMoney.formatted()) spent of \(status.budget.cap.formatted()) limit. Approve \(amount.formatted()) transaction?"
        }
        await NotificationService.shared.postTransferRequest(requestID: id, title: "\(DemoPeer.shopName) payment request",
                                                             body: body, delay: 5)
        banner = Banner(kind: .success, text: "Request arrives in 5 seconds. Lock the phone to see it on the lock screen.")
    }

    func addCategory(name: String, iconName: String?) async {
        do {
            _ = try await wallet?.addCategory(name: name, iconName: iconName)
        } catch {
            banner = Banner(kind: .error, text: Self.describe(error))
        }
        await refresh()
    }

    func saveBudget(_ budget: Budget) async {
        do {
            try await wallet?.saveBudget(budget)
        } catch {
            banner = Banner(kind: .error, text: Self.describe(error))
        }
        await refresh()
    }

    func deleteBudget(id: Int64) async {
        try? await wallet?.deleteBudget(id: id)
        await refresh()
    }

    func reverify() async {
        guard let wallet else { return }
        let status = (try? await wallet.reverify()) ?? .anchorMissing
        banner = status.isLocked ? Banner(kind: .error, text: Self.describe(StoreError.walletLocked(status)))
                                 : Banner(kind: .success, text: "Chain verified: \(await wallet.entryCount) entries")
        await refresh()
    }

    // MARK: - Nearby payments

    /// The wallet and its signer, for paying and being paid by a phone next to this one (`NearbyModel`).
    var nearbyAccess: (wallet: WalletStore, signer: any TransactionSigner)? {
        guard let wallet, let signer, !integrity.isLocked else { return nil }
        return (wallet, signer)
    }

    /// After a phone-to-phone payment: budget alerts for the payer, then fresh balances and activity.
    func nearbyPaymentFinished(verdict: BudgetVerdict?) async {
        if let verdict { await alertIfNeeded(verdict) }
        await refresh()
    }

    // MARK: - Internals

    private func handle(_ action: NotificationAction) async {
        switch action {
        case .approve(let id):
            guard let request = pendingRequests.removeValue(forKey: id) else { return }
            // Approving from the notification counts as accepting any over-budget warning it showed.
            await pay(amount: request.amount, categoryID: request.categoryID, overrideOverBudget: true)
        case .deny(let id):
            if pendingRequests.removeValue(forKey: id) != nil {
                banner = Banner(kind: .success, text: "Request from \(DemoPeer.shopName) denied")
            }
        case .open(let id):
            // Tapping the notification itself opens an in-app approval sheet with the same Face ID step.
            guard let id, let request = pendingRequests[id] else { return }
            approvalRequest = ApprovalRequest(id: id, payee: DemoPeer.shopName, amount: request.amount, categoryID: request.categoryID)
        }
    }

    /// Approves a request from the in-app sheet: Face ID, then the same signed transfer as any payment.
    func approve(_ request: ApprovalRequest) async -> Bool {
        pendingRequests.removeValue(forKey: request.id)
        return await pay(amount: request.amount, categoryID: request.categoryID, overrideOverBudget: true)
    }

    func deny(_ request: ApprovalRequest) {
        pendingRequests.removeValue(forKey: request.id)
        banner = Banner(kind: .success, text: "Request from \(request.payee) denied")
    }

    private func participant(_ wallet: WalletStore, _ signer: any TransactionSigner) -> PaymentParticipant {
        PaymentParticipant(store: wallet, signer: signer, ranging: SimulatedRanging(trueDistanceMeters: 0.4), displayName: "You")
    }

    private func alertIfNeeded(_ verdict: BudgetVerdict) async {
        let posted = Set(UserDefaults.standard.stringArray(forKey: "postedBudgetAlerts") ?? [])
        var updated = posted
        for status in verdict.statuses where status.reachesAlert || status.isOver {
            let key = "\(status.budget.id)-\(status.window.startMS)-\(status.isOver ? 100 : status.budget.alertPercent)"
            guard !posted.contains(key) else { continue }
            let name = categories.first { $0.id == status.budget.categoryID }?.name ?? "Budget"
            await NotificationService.shared.postBudgetAlert(categoryName: name, status: status)
            updated.insert(key)
        }
        UserDefaults.standard.set(Array(updated), forKey: "postedBudgetAlerts")
    }

    private func makeDiagnostics(_ wallet: WalletStore) async -> Diagnostics {
        var d = Diagnostics()
        d.signer = switch signer?.kind {
        case .secureEnclave: "Secure Enclave (P-256)"
        case .simulatorBiometric: "Simulator: software key + Face ID check"
        case .software: "Software key"
        case nil: "—"
        }
        d.walletFingerprint = wallet.walletKey.fingerprint
        d.cipherVersion = wallet.cipherVersion
        if let url = wallet.databaseURL, let handle = try? FileHandle(forReadingFrom: url) {
            let header = (try? handle.read(upToCount: 16)) ?? Data()
            d.fileEncrypted = header.count == 16 && header != Data("SQLite format 3\0".utf8)
            try? handle.close()
        }
        d.chainLength = await wallet.entryCount
        d.tipLink = await wallet.tip.link.short
        let biometry = BiometryStatus.current()
        d.biometry = biometry.isAvailable ? "\(biometry.name) available" : "\(biometry.name) unavailable"
        d.proximityPolicy = Self.proximityPolicy.allowSimulated ? "Simulated ranging accepted (debug)" : "UWB only"
        return d
    }

    static func label(for period: BudgetPeriod) -> String {
        switch period {
        case .monthly(let day): day == 1 ? "Monthly" : "Monthly from day \(day)"
        case .weekly(let weekday): "Weekly from \(Calendar.current.weekdaySymbols[(weekday - 1) % 7])"
        case .rolling(let days): "Last \(days) days"
        case .custom(_, let days): "Every \(days) days"
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SigningError.userCancelled: return "Cancelled."
        case SigningError.biometryUnavailable(let message): return message
        case StoreError.needsOverride: return "Over budget. Approve the warning to continue."
        case StoreError.blocked(let reason):
            switch reason {
            case .hardCap(let status): return "Blocked: this would exceed the hard cap of \(status.budget.cap.formatted())."
            case .insufficientFunds(let available, _): return "Not enough funds: \(available.formatted()) available."
            case .overTransferLimit(let limit, _): return "Over the offline limit of \(limit.formatted()) per transfer."
            case .overDailyLimit(let limit, _, _): return "Over the daily offline limit of \(limit.formatted())."
            case .invalidAmount: return "Enter an amount above zero."
            }
        case StoreError.walletLocked(let status):
            switch status {
            case .rolledBack: return "Wallet locked: the database is older than its Keychain anchor (restored copy)."
            case .diverged: return "Wallet locked: the database history was rewritten."
            case .anchorMissing: return "Wallet locked: the Keychain anchor is missing."
            case .chainInvalid(let violation): return "Wallet locked: chain check failed (\(violation))."
            case .verified, .anchorAdvanced: return "Wallet locked."
            }
        case StoreError.proximity(let failure): return "Proximity check failed: \(failure)."
        case StoreError.fork: return "Refused: this wallet has forked its chain (double-spend evidence)."
        default: return String(describing: error)
        }
    }
}

/// Opens the wallet and the two demo peers off the main thread.
nonisolated enum WalletBootstrap {
    struct Opened: Sendable {
        let wallet: WalletStore
        let signer: any TransactionSigner
        let issuer: DemoPeer
        let shop: DemoPeer
    }

    static func open(secrets: KeychainSecretStore, policy: ProximityPolicy) throws -> Opened {
        let directory = try WalletLocation.directory(named: "Wallet")
        // No database means a fresh install: start a new identity rather than reuse an old key from sequence 0.
        if !WalletStore.databaseExists(directory: directory, name: "wallet") {
            for account in ["wallet.signing-key", "wallet.chain-anchor", "wallet.database-key"] { try secrets.delete(account) }
        }
        let signer = try WalletSigners.loadOrCreate(account: "wallet.signing-key", secrets: secrets)
        let wallet = try WalletStore(directory: directory, name: "wallet", secrets: secrets, walletKey: signer.publicKey,
                                     configuration: WalletConfiguration(proximityPolicy: policy))
        let issuer = try DemoPeer.open(name: DemoPeer.issuerName, id: "demo-issuer", isIssuer: true, secrets: secrets)
        let shop = try DemoPeer.open(name: DemoPeer.shopName, id: "demo-shop", isIssuer: false, secrets: secrets)
        return Opened(wallet: wallet, signer: signer, issuer: issuer, shop: shop)
    }
}

/// A stand-in counterparty with its own encrypted ledger and software key, until Phase 4 puts it on another phone.
nonisolated struct DemoPeer: Sendable {
    static let issuerName = "Demo Issuer"
    static let shopName = "Demo Shop"

    let name: String
    let store: WalletStore
    let signer: SoftwareSigner

    var participant: PaymentParticipant {
        PaymentParticipant(store: store, signer: signer, ranging: SimulatedRanging(trueDistanceMeters: 0.4), displayName: name)
    }

    static func open(name: String, id: String, isIssuer: Bool, secrets: KeychainSecretStore) throws -> DemoPeer {
        let directory = try WalletLocation.directory(named: "DemoPeers")
        let keyAccount = "\(id).signing-key"
        if !WalletStore.databaseExists(directory: directory, name: id) {
            for account in [keyAccount, "\(id).chain-anchor", "\(id).database-key"] { try secrets.delete(account) }
        }
        let signer: SoftwareSigner
        if let raw = try secrets.read(keyAccount) {
            signer = try SoftwareSigner(rawRepresentation: raw)
        } else {
            signer = SoftwareSigner()
            try secrets.write(signer.rawRepresentation, account: keyAccount)
        }
        let store = try WalletStore(directory: directory, name: id, secrets: secrets, walletKey: signer.publicKey,
                                    configuration: WalletConfiguration(isIssuer: isIssuer, proximityPolicy: .simulator))
        return DemoPeer(name: name, store: store, signer: signer)
    }
}
