import Foundation
import Observation
import SecureConnect
import SecureCore
import SecureDevice
import SecureStore
import UserNotifications

/// State for the additional features: credit score, linked accounts, practice markets and responsible play.
/// It has its own store and database and never touches the wallet (`AppModel`).
@Observable
final class ConnectedModel {
    enum Phase: Equatable { case loading, ready, failed(String) }

    private(set) var phase: Phase = .loading

    private(set) var creditProfile: CreditProfile?
    private(set) var playSettings = PlaySettings()
    private(set) var transactionsToday = 0
    private(set) var stakedToday = Money.zero(.usd)

    private(set) var accounts: [LinkedAccount] = []
    private(set) var recentTransactions: [BankTransaction] = []
    private(set) var summary: AccountsSummary?

    private(set) var simDay = 0
    private(set) var portfolio: PortfolioSnapshot?
    private(set) var history: [PracticeOrder] = []
    private(set) var settledBets: [PracticeBet] = []

    var banner: Banner?

    private var store: ConnectedStore?
    private let secrets = KeychainSecretStore(service: "com.example.secure")

    var tier: CreditTier? { creditProfile?.tier }
    var linkedInstitutionIDs: Set<String> { Set(accounts.map(\.institutionID)) }
    var openEvents: [PredictionEvent] { PredictionCatalog.openEvents(day: simDay) }
    var upcomingGames: [Fixture] { SportsCatalog.fixtures(fromDay: simDay + 1, throughDay: simDay + 3) }

    func start() async {
        guard store == nil else { return }
        do {
            store = try await Task.detached(priority: .userInitiated) { [secrets] in
                try ConnectedBootstrap.open(secrets: secrets)
            }.value
            await refresh()
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    func refresh() async {
        guard let store else { return }
        do {
            creditProfile = try await store.creditProfile()
            playSettings = try await store.playSettings()
            let usage = try await store.usageToday()
            transactionsToday = usage.transactions
            stakedToday = usage.staked
            accounts = try await store.linkedAccounts()
            recentTransactions = try await store.transactions(limit: 40)
            summary = accounts.isEmpty ? nil : try await store.summary()
            simDay = await store.simDay
            portfolio = try await store.portfolio()
            history = try await store.history(limit: 60)
            settledBets = try await store.bets().filter { $0.status != .open }
        } catch {
            show(error)
        }
    }

    // MARK: - Credit score and responsible play

    func setScore(_ value: Int, source: CreditSource, label: String? = nil) async {
        guard let store, let score = CreditScore(value) else { return }
        await run("Score set to \(value) (\(score.tier.name))") {
            try await store.setCreditProfile(CreditProfile(score: score, source: source, label: label,
                                                           updatedAtMS: Date().millisecondsSince1970))
        }
    }

    func updatePlaySettings(_ settings: PlaySettings, message: String = "Responsible-play settings saved") async {
        guard let store else { return }
        await run(message) { try await store.updatePlaySettings(settings) }
    }

    func startCoolOff(days: Int) async {
        var settings = playSettings
        settings.coolOffUntilMS = Date().addingTimeInterval(TimeInterval(days) * 86_400).millisecondsSince1970
        await updatePlaySettings(settings, message: "Cool-off started for \(days == 1 ? "24 hours" : "\(days) days")")
    }

    func selfExclude(days: Int) async {
        var settings = playSettings
        settings.selfExcludedUntilMS = Date().addingTimeInterval(TimeInterval(days) * 86_400).millisecondsSince1970
        await updatePlaySettings(settings, message: "Self-excluded from practice markets for \(days) days")
    }

    // MARK: - Linked accounts

    func link(_ institution: Institution) async {
        guard let store else { return }
        await run("Connected \(institution.name)") { _ = try await store.link(institutionID: institution.id) }
    }

    func unlink(_ institutionID: String) async {
        guard let store else { return }
        await run("Disconnected") { try await store.unlink(institutionID: institutionID) }
    }

    func sync() async {
        guard let store else { return }
        do {
            let result = try await store.sync()
            for alert in result.alerts { await post(alert) }
            banner = Banner(kind: .success, text: result.newTransactions.isEmpty
                            ? "Up to date" : "\(result.newTransactions.count) new transactions")
        } catch {
            show(error)
        }
        await refresh()
    }

    func transactions(for accountID: String) async -> [BankTransaction] {
        (try? await store?.transactions(accountID: accountID, limit: 200)) ?? []
    }

    // MARK: - Practice markets

    func trade(_ ticker: String, side: PracticeSide, quantity: Int64) async {
        guard let store else { return }
        await run("\(side == .buy ? "Bought" : "Sold") \(quantity) \(ticker)") {
            _ = try await store.placeEquityOrder(ticker: ticker, side: side, quantity: quantity)
        }
    }

    func trade(event: String, side: PracticeSide, action: PracticeAction, quantity: Int64) async {
        guard let store else { return }
        await run("\(action == .open ? "Bought" : "Sold") \(quantity) \(side == .yes ? "YES" : "NO")") {
            _ = try await store.placeContractOrder(eventID: event, side: side, action: action, quantity: quantity)
        }
    }

    @discardableResult
    func bet(on fixture: Fixture, selection: SportsSelection, stake: Money) async -> Bool {
        guard let store else { return false }
        return await run("Bet \(stake.formatted()) on \(fixture.team(selection).name)") {
            _ = try await store.placeBet(fixtureID: fixture.id, selection: selection, stake: stake)
        }
    }

    func advanceDay() async {
        guard let store else { return }
        do {
            let result = try await store.advanceDay()
            var parts = ["Market day \(result.day)"]
            if result.settledContracts + result.settledBets > 0 {
                parts.append("\(result.settledContracts + result.settledBets) settled, \(result.payout.formatted()) paid")
            }
            banner = Banner(kind: .success, text: parts.joined(separator: " · "))
        } catch {
            show(error)
        }
        await refresh()
    }

    func resetPractice() async {
        guard let store else { return }
        await run("Practice account reset to \(store.startingCash.formatted())") { try await store.resetPractice() }
    }

    func position(_ market: MarketKind, _ instrument: String, _ side: PracticeSide) -> PracticePosition? {
        portfolio?.positions.first { $0.market == market && $0.instrument == instrument && $0.side == side }
    }

    // MARK: - Internals

    @discardableResult
    private func run(_ success: String, _ action: () async throws -> Void) async -> Bool {
        var succeeded = false
        do {
            try await action()
            banner = Banner(kind: .success, text: success)
            succeeded = true
        } catch {
            show(error)
        }
        await refresh()
        return succeeded
    }

    private func show(_ error: Error) {
        banner = Banner(kind: .error, text: Self.describe(error))
    }

    private func post(_ alert: AccountAlert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "account-\(alert.id)", content: content, trigger: nil))
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ConnectedError.unknownInstitution: return "Unknown bank."
        case ConnectedError.alreadyLinked: return "That bank is already connected."
        case ConnectedError.play(let block): return describe(block)
        default: return String(describing: error)
        }
    }

    static func describe(_ block: PlayBlock) -> String {
        func date(_ ms: Int64) -> String { Date(millisecondsSince1970: ms).formatted(date: .abbreviated, time: .shortened) }
        return switch block {
        case .selfExcluded(let until): "Self-excluded from practice markets until \(date(until))."
        case .coolingOff(let until): "Cooling off until \(date(until)). You can still sell."
        case .creditScoreRequired: "Set a credit score in Profile to unlock practice markets."
        case .ageNotConfirmed(let required):
            required == .adult21 ? "Sports needs age 21+ (Profile ▸ Responsible play)." : "Confirm you're 18+ in Profile ▸ Responsible play."
        case .overTransactionCount(let tier, let limit, _): "The \(tier.name) tier allows \(limit) practice transactions a day."
        case .overTransactionSize(let tier, let limit, _): "The \(tier.name) tier allows up to \(limit.formatted()) per transaction."
        case .overDailyStake(let limit, let used, _): "Over your daily stake limit of \(limit.formatted()) (\(used.formatted()) used today)."
        case .insufficientCash(let available, _): "Not enough practice cash: \(available.formatted()) available."
        case .insufficientPosition(let held, _): "You only hold \(held)."
        case .marketClosed: "This market has closed."
        case .invalidQuantity: "Enter an amount above zero."
        case .unknownInstrument: "Unknown market."
        case .cannotShortenExclusion: "An active cool-off or self-exclusion can't be shortened."
        }
    }
}

/// Opens the connected-features database off the main thread, in its own folder and with its own Keychain key.
nonisolated enum ConnectedBootstrap {
    static func open(secrets: KeychainSecretStore) throws -> ConnectedStore {
        try ConnectedStore(directory: try WalletLocation.directory(named: "Connected"), secrets: secrets)
    }
}
