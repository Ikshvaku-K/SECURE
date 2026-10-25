import CryptoKit
import Foundation
import SecureConnect
import SecureCore

public enum ConnectedError: Error, Equatable, Sendable {
    case unknownInstitution
    case alreadyLinked
    case play(PlayBlock)
}

public struct CategorySpend: Sendable, Hashable, Identifiable {
    public let category: BankCategory
    public let amount: Money
    public var id: String { category.rawValue }
}

public struct AccountsSummary: Sendable, Equatable {
    public let netWorth: Money
    public let assets: Money
    public let liabilities: Money
    public let spendingThisMonth: [CategorySpend]
    public let lastSyncedMS: Int64?
}

public struct SyncResult: Sendable {
    public let newTransactions: [BankTransaction]
    public let alerts: [AccountAlert]
}

public enum PracticeSide: String, Sendable {
    case buy, sell, yes, no, home, away
}

public enum PracticeAction: String, Sendable {
    case open, close, settle
}

public struct PracticeOrder: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let placedAtMS: Int64
    public let simDay: Int
    public let market: MarketKind
    public let instrument: String
    public let side: PracticeSide
    public let action: PracticeAction
    public let quantity: Int64
    public let priceMinor: Int64
    public let cashDelta: Money
    public let note: String

    public var placedAt: Date { Date(millisecondsSince1970: placedAtMS) }
}

public struct PracticePosition: Sendable, Identifiable, Hashable {
    public let market: MarketKind
    public let instrument: String
    public let side: PracticeSide
    public let quantity: Int64
    public let cost: Money
    /// Current value at the midpoint price.
    public let markValue: Money

    public var id: String { "\(market.rawValue).\(instrument).\(side.rawValue)" }
    public var profit: Money { Money(minorUnits: markValue.minorUnits - cost.minorUnits, currency: cost.currency) }
}

public struct PracticeBet: Sendable, Identifiable, Hashable {
    public enum Status: String, Sendable { case open, won, lost }
    public let id: Int64
    public let fixtureID: String
    public let selection: SportsSelection
    public let stake: Money
    public let americanOdds: Int
    public let placedAtMS: Int64
    public let status: Status
    public let payout: Money
}

public struct PortfolioSnapshot: Sendable {
    public let cash: Money
    public let positions: [PracticePosition]
    public let openBets: [PracticeBet]
    public let startingCash: Money

    /// Cash plus positions at midpoint plus open bets at their stake.
    public var totalValue: Money {
        let marks = positions.reduce(0) { $0 + $1.markValue.minorUnits }
        let bets = openBets.reduce(0) { $0 + $1.stake.minorUnits }
        return Money(minorUnits: cash.minorUnits + marks + bets, currency: cash.currency)
    }

    public var profit: Money { Money(minorUnits: totalValue.minorUnits - startingCash.minorUnits, currency: cash.currency) }
}

public struct AdvanceResult: Sendable, Equatable {
    public let day: Int
    public let settledContracts: Int
    public let settledBets: Int
    public let payout: Money
}

/// The additional features, in their own SQLCipher database (`connected.sqlite`) beside the wallet: the credit profile,
/// linked bank accounts at fictional banks, and a practice-money portfolio for stocks, prediction markets and sports.
/// Nothing here reads or writes the wallet ledger or changes how wallet transfers work. Every practice order passes the
/// credit-tier and responsible-play checks inside the same write transaction that records it.
public actor ConnectedStore {
    public nonisolated let aggregator: any AccountAggregator
    public nonisolated let startingCash: Money
    public nonisolated let databaseURL: URL?

    public private(set) var simDay: Int

    private let db: SQLiteDatabase
    private let calendar: Calendar
    private var currency: CurrencyCode { startingCash.currency }

    public init(directory: URL?, name: String = "connected", secrets: any SecretStore,
                aggregator: any AccountAggregator = SimulatedAggregator(),
                startingCash: Money = Money(minorUnits: 10_000_00, currency: .usd), calendar: Calendar = .current) throws {
        let (db, url) = try ConnectedDatabase.open(directory: directory, name: name, secrets: secrets,
                                                   keyAccount: "\(name).database-key")
        try ConnectedSchema.migrate(db)
        self.db = db
        self.databaseURL = url
        self.aggregator = aggregator
        self.startingCash = startingCash
        self.calendar = calendar
        self.simDay = Int(try Self.metaInt(db, "sim_day") ?? 0)
    }

    // MARK: - Credit profile

    /// The self-reported or demo credit score; nil until the user sets one (practice markets stay locked until then).
    public func creditProfile() throws -> CreditProfile? {
        try Self.meta(db, "credit_profile").flatMap { try? CreditProfile(canonicalBytes: $0) }
    }

    public func setCreditProfile(_ profile: CreditProfile) throws {
        try Self.setMeta(db, "credit_profile", profile.canonicalBytes)
    }

    // MARK: - Linked accounts

    public func linkedAccounts() throws -> [LinkedAccount] {
        try db.query("""
            SELECT a.id, a.institution_id, a.institution_name, a.name, a.kind, a.mask, a.currency,
                   a.opening_balance_minor + COALESCE((SELECT SUM(t.amount_minor) FROM bank_transactions t WHERE t.account_id = a.id), 0),
                   a.linked_at_ms, a.synced_through_ms
            FROM linked_accounts a ORDER BY a.institution_name, a.name
            """) { row in
            LinkedAccount(id: row.text(0), institutionID: row.text(1), institutionName: row.text(2), name: row.text(3),
                          kind: AccountKind(rawValue: row.text(4)) ?? .checking, mask: row.text(5),
                          balance: Money(minorUnits: row.int(7), currency: CurrencyCode(row.text(6)) ?? currency),
                          linkedAtMS: row.int(8), syncedThroughMS: row.int(9))
        }
    }

    public func isLinked(institutionID: String) throws -> Bool {
        (try db.scalarInt("SELECT COUNT(*) FROM linked_accounts WHERE institution_id = ?", [.text(institutionID)]) ?? 0) > 0
    }

    /// Links every account at a simulated institution and imports its recent history.
    @discardableResult
    public func link(institutionID: String, now: Date = Date()) throws -> [LinkedAccount] {
        guard let institution = aggregator.institutions.first(where: { $0.id == institutionID }) else {
            throw ConnectedError.unknownInstitution
        }
        guard try !isLinked(institutionID: institutionID) else { throw ConnectedError.alreadyLinked }
        let nowMS = now.millisecondsSince1970
        let fromMS = nowMS - Int64(aggregator.historyDays) * 86_400_000
        try db.transaction {
            for template in institution.accounts {
                let accountID = "\(institution.id).\(template.key)"
                try db.run("""
                    INSERT INTO linked_accounts (id, institution_id, institution_name, name, kind, mask, currency,
                                                 opening_balance_minor, linked_at_ms, synced_through_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(accountID), .text(institution.id), .text(institution.name), .text(template.name),
                          .text(template.kind.rawValue), .text(template.mask), .text(aggregator.currency.rawValue),
                          .integer(template.openingBalanceMinor), .integer(nowMS), .integer(nowMS)])
                try insert(aggregator.transactions(institution: institution, account: template, fromMS: fromMS, toMS: nowMS))
            }
        }
        return try linkedAccounts().filter { $0.institutionID == institutionID }
    }

    public func unlink(institutionID: String) throws {
        try db.run("DELETE FROM linked_accounts WHERE institution_id = ?", [.text(institutionID)])
    }

    /// Fetches everything posted since each account's last sync. Idempotent: transaction IDs are deterministic.
    public func sync(now: Date = Date()) throws -> SyncResult {
        let nowMS = now.millisecondsSince1970
        var fresh: [BankTransaction] = []
        try db.transaction {
            for account in try linkedAccounts() where account.syncedThroughMS < nowMS {
                guard let institution = aggregator.institutions.first(where: { $0.id == account.institutionID }),
                      let template = institution.accounts.first(where: { "\(institution.id).\($0.key)" == account.id })
                else { continue }
                let transactions = aggregator.transactions(institution: institution, account: template,
                                                           fromMS: account.syncedThroughMS, toMS: nowMS)
                try insert(transactions)
                fresh += transactions
                try db.run("UPDATE linked_accounts SET synced_through_ms = ? WHERE id = ?", [.integer(nowMS), .text(account.id)])
            }
        }
        let accounts = try linkedAccounts()
        var alerts: [AccountAlert] = fresh.filter { $0.amount.minorUnits <= -500_00 }.map { transaction in
            let name = accounts.first { $0.id == transaction.accountID }.map { "\($0.institutionName) \($0.name)" } ?? "Linked account"
            return AccountAlert(id: "large-\(transaction.id)", kind: .largeTransaction, title: "Large transaction",
                                body: "\(Money(minorUnits: -transaction.amount.minorUnits, currency: transaction.amount.currency).formatted()) at \(transaction.merchant) — \(name)")
        }
        if !fresh.isEmpty {
            for account in accounts where account.kind == .checking && account.balance.minorUnits < 200_00 {
                alerts.append(AccountAlert(id: "low-\(account.id)-\(nowMS / 86_400_000)", kind: .lowBalance, title: "Low balance",
                                           body: "\(account.institutionName) \(account.name) is down to \(account.balance.formatted())."))
            }
        }
        return SyncResult(newTransactions: fresh, alerts: alerts)
    }

    public func transactions(accountID: String? = nil, limit: Int = 100) throws -> [BankTransaction] {
        let filter = accountID == nil ? "" : "WHERE account_id = ?"
        let bindings: [SQLValue] = (accountID.map { [SQLValue.text($0)] } ?? []) + [SQLValue.integer(Int64(limit))]
        return try db.query("""
            SELECT id, account_id, posted_at_ms, amount_minor, merchant, category FROM bank_transactions \(filter)
            ORDER BY posted_at_ms DESC, id DESC LIMIT ?
            """, bindings) { row in
            BankTransaction(id: row.text(0), accountID: row.text(1), postedAtMS: row.int(2),
                            amount: Money(minorUnits: row.int(3), currency: currency), merchant: row.text(4),
                            category: BankCategory(rawValue: row.text(5)) ?? .transfer)
        }
    }

    /// Net worth across all linked accounts and this month's spending by category.
    public func summary(now: Date = Date()) throws -> AccountsSummary {
        let accounts = try linkedAccounts()
        // Net worth is every balance added up; money owed on cards is reported separately as liabilities.
        let total = accounts.reduce(Int64(0)) { $0 + $1.balance.minorUnits }
        let liabilities = accounts.filter(\.isLiability).reduce(Int64(0)) { $0 - min(0, $1.balance.minorUnits) }
        let assets = total + liabilities
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!.millisecondsSince1970
        let spending = try db.query("""
            SELECT category, -SUM(amount_minor) FROM bank_transactions
            WHERE amount_minor < 0 AND posted_at_ms >= ? GROUP BY category
            """, [.integer(monthStart)]) { row -> CategorySpend? in
            guard let category = BankCategory(rawValue: row.text(0)), category.isSpending else { return nil }
            return CategorySpend(category: category, amount: Money(minorUnits: row.int(1), currency: currency))
        }.compactMap { $0 }.sorted { $0.amount.minorUnits > $1.amount.minorUnits }
        return AccountsSummary(netWorth: Money(minorUnits: total, currency: currency),
                               assets: Money(minorUnits: assets, currency: currency),
                               liabilities: Money(minorUnits: liabilities, currency: currency),
                               spendingThisMonth: spending, lastSyncedMS: accounts.map(\.syncedThroughMS).max())
    }

    // MARK: - Practice portfolio

    public func cash() throws -> Money {
        Money(minorUnits: startingCash.minorUnits + (try db.scalarInt("SELECT COALESCE(SUM(cash_delta_minor), 0) FROM practice_orders") ?? 0),
              currency: currency)
    }

    public func portfolio() throws -> PortfolioSnapshot {
        let positions = try db.query("SELECT market, instrument, side, quantity, cost_minor FROM practice_positions ORDER BY market, instrument") { row in
            (MarketKind(rawValue: row.text(0)) ?? .equity, row.text(1), PracticeSide(rawValue: row.text(2)) ?? .buy, row.int(3), row.int(4))
        }.map { market, instrument, side, quantity, cost in
            PracticePosition(market: market, instrument: instrument, side: side, quantity: quantity,
                             cost: Money(minorUnits: cost, currency: currency),
                             markValue: Money(minorUnits: markPrice(market: market, instrument: instrument, side: side) * quantity,
                                              currency: currency))
        }
        return PortfolioSnapshot(cash: try cash(), positions: positions, openBets: try bets(status: .open), startingCash: startingCash)
    }

    public func bets(status: PracticeBet.Status? = nil) throws -> [PracticeBet] {
        let filter = status == nil ? "" : "WHERE status = ?"
        return try db.query("SELECT id, fixture_id, selection, stake_minor, american_odds, placed_at_ms, status, payout_minor FROM practice_bets \(filter) ORDER BY id DESC",
                            status.map { [SQLValue.text($0.rawValue)] } ?? []) { row in
            PracticeBet(id: row.int(0), fixtureID: row.text(1), selection: SportsSelection(rawValue: row.text(2)) ?? .home,
                        stake: Money(minorUnits: row.int(3), currency: currency), americanOdds: Int(row.int(4)),
                        placedAtMS: row.int(5), status: PracticeBet.Status(rawValue: row.text(6)) ?? .open,
                        payout: Money(minorUnits: row.int(7), currency: currency))
        }
    }

    public func history(limit: Int = 100) throws -> [PracticeOrder] {
        try db.query("""
            SELECT id, placed_at_ms, sim_day, market, instrument, side, action, quantity, price_minor, cash_delta_minor, note
            FROM practice_orders ORDER BY id DESC LIMIT ?
            """, [.integer(Int64(limit))]) { row in
            PracticeOrder(id: row.int(0), placedAtMS: row.int(1), simDay: Int(row.int(2)),
                          market: MarketKind(rawValue: row.text(3)) ?? .equity, instrument: row.text(4),
                          side: PracticeSide(rawValue: row.text(5)) ?? .buy, action: PracticeAction(rawValue: row.text(6)) ?? .open,
                          quantity: row.int(7), priceMinor: row.int(8), cashDelta: Money(minorUnits: row.int(9), currency: currency),
                          note: row.text(10))
        }
    }

    /// Practice transactions (orders and bets) since local midnight, and the money newly put at risk.
    public func usageToday(now: Date = Date()) throws -> (transactions: Int, staked: Money) {
        let start = calendar.startOfDay(for: now).millisecondsSince1970
        let orders = try db.scalarInt("SELECT COUNT(*) FROM practice_orders WHERE action IN ('open', 'close') AND placed_at_ms >= ?",
                                      [.integer(start)]) ?? 0
        let staked = try db.scalarInt("SELECT COALESCE(-SUM(cash_delta_minor), 0) FROM practice_orders WHERE action = 'open' AND placed_at_ms >= ?",
                                      [.integer(start)]) ?? 0
        return (Int(orders), Money(minorUnits: staked, currency: currency))
    }

    @discardableResult
    public func placeEquityOrder(ticker: String, side: PracticeSide, quantity: Int64, now: Date = Date()) throws -> PracticeOrder {
        guard let equity = Equity.find(ticker) else { throw ConnectedError.play(.unknownInstrument) }
        guard quantity > 0, side == .buy || side == .sell else { throw ConnectedError.play(.invalidQuantity) }
        let quote = EquitySimulator.quote(for: equity, day: simDay)
        return try db.transaction {
            if side == .buy {
                let cost = Money(minorUnits: quote.ask * quantity, currency: currency)
                try guardOrder(.opening(cost: cost), market: .equity, now: now)
                try changePosition(.equity, ticker, .buy, quantity: quantity, cost: cost.minorUnits)
                return try record(.equity, ticker, .buy, .open, quantity, quote.ask, -cost.minorUnits, "", now)
            }
            let held = try positionQuantity(.equity, ticker, .buy)
            guard held >= quantity else { throw ConnectedError.play(.insufficientPosition(held: held, requested: quantity)) }
            try guardOrder(.closing, market: .equity, now: now)
            try changePosition(.equity, ticker, .buy, quantity: -quantity, cost: 0)
            return try record(.equity, ticker, .sell, .close, quantity, quote.bid, quote.bid * quantity, "", now)
        }
    }

    @discardableResult
    public func placeContractOrder(eventID: String, side: PracticeSide, action: PracticeAction, quantity: Int64,
                                   now: Date = Date()) throws -> PracticeOrder {
        guard let event = PredictionCatalog.find(id: eventID) else { throw ConnectedError.play(.unknownInstrument) }
        guard quantity > 0, side == .yes || side == .no, action != .settle else { throw ConnectedError.play(.invalidQuantity) }
        guard event.isOpen(day: simDay) else { throw ConnectedError.play(.marketClosed) }
        let quote = event.quote(day: simDay)
        return try db.transaction {
            if action == .open {
                let price = Int64(side == .yes ? quote.yesAsk : quote.noAsk)
                let cost = Money(minorUnits: price * quantity, currency: currency)
                try guardOrder(.opening(cost: cost), market: .prediction, now: now)
                try changePosition(.prediction, eventID, side, quantity: quantity, cost: cost.minorUnits)
                return try record(.prediction, eventID, side, .open, quantity, price, -cost.minorUnits, "", now)
            }
            let held = try positionQuantity(.prediction, eventID, side)
            guard held >= quantity else { throw ConnectedError.play(.insufficientPosition(held: held, requested: quantity)) }
            try guardOrder(.closing, market: .prediction, now: now)
            let price = Int64(side == .yes ? quote.yesBid : quote.noBid)
            try changePosition(.prediction, eventID, side, quantity: -quantity, cost: 0)
            return try record(.prediction, eventID, side, .close, quantity, price, price * quantity, "", now)
        }
    }

    @discardableResult
    public func placeBet(fixtureID: String, selection: SportsSelection, stake: Money, now: Date = Date()) throws -> PracticeBet {
        guard let fixture = SportsCatalog.find(id: fixtureID) else { throw ConnectedError.play(.unknownInstrument) }
        guard stake.minorUnits > 0 else { throw ConnectedError.play(.invalidQuantity) }
        guard fixture.isOpenForBetting(day: simDay) else { throw ConnectedError.play(.marketClosed) }
        let odds = fixture.americanOdds(selection)
        return try db.transaction {
            try guardOrder(.opening(cost: stake), market: .sports, now: now)
            let nowMS = now.millisecondsSince1970
            try db.run("""
                INSERT INTO practice_bets (fixture_id, selection, stake_minor, american_odds, placed_at_ms, status)
                VALUES (?, ?, ?, ?, ?, 'open')
                """, [.text(fixtureID), .text(selection.rawValue), .integer(stake.minorUnits), .integer(Int64(odds)), .integer(nowMS)])
            let id = try db.scalarInt("SELECT last_insert_rowid()") ?? 0
            _ = try record(.sports, fixtureID, selection == .home ? .home : .away, .open, 1, stake.minorUnits, -stake.minorUnits,
                           "\(fixture.team(selection).name) at \(odds > 0 ? "+" : "")\(odds)", now)
            return PracticeBet(id: id, fixtureID: fixtureID, selection: selection, stake: stake, americanOdds: odds,
                               placedAtMS: nowMS, status: .open, payout: Money(minorUnits: 0, currency: currency))
        }
    }

    /// Moves the simulation forward one day: prices move, contracts whose event closed settle at 100¢ or 0¢,
    /// and bets on games played that day are paid or lost.
    @discardableResult
    public func advanceDay(now: Date = Date()) throws -> AdvanceResult {
        let newDay = simDay + 1
        let result = try db.transaction { () throws -> AdvanceResult in
            var contracts = 0
            var settledBets = 0
            var payout: Int64 = 0
            let contractPositions = try db.query(
                "SELECT instrument, side, quantity FROM practice_positions WHERE market = 'prediction'") { row in
                (row.text(0), PracticeSide(rawValue: row.text(1)) ?? .yes, row.int(2))
            }
            for (eventID, side, quantity) in contractPositions {
                guard let event = PredictionCatalog.find(id: eventID), newDay >= event.closeDay else { continue }
                let wins = (side == .yes) == event.resolvesYes
                let amount: Int64 = wins ? 100 * quantity : 0
                try db.run("DELETE FROM practice_positions WHERE market = 'prediction' AND instrument = ? AND side = ?",
                           [.text(eventID), .text(side.rawValue)])
                _ = try record(.prediction, eventID, side, .settle, quantity, wins ? 100 : 0, amount,
                               event.resolvesYes ? "Resolved YES" : "Resolved NO", now, day: newDay)
                contracts += 1
                payout += amount
            }
            for bet in try bets(status: .open) {
                guard let fixture = SportsCatalog.find(id: bet.fixtureID), newDay >= fixture.day else { continue }
                let won = fixture.winner == bet.selection
                let amount = won ? bet.stake.minorUnits + Odds.profit(stake: bet.stake.minorUnits, american: bet.americanOdds) : 0
                try db.run("UPDATE practice_bets SET status = ?, payout_minor = ? WHERE id = ?",
                           [.text(won ? "won" : "lost"), .integer(amount), .integer(bet.id)])
                _ = try record(.sports, bet.fixtureID, bet.selection == .home ? .home : .away, .settle, 1, amount, amount,
                               "\(fixture.team(fixture.winner).name) won", now, day: newDay)
                settledBets += 1
                payout += amount
            }
            try Self.setMetaInt(db, "sim_day", Int64(newDay))
            return AdvanceResult(day: newDay, settledContracts: contracts, settledBets: settledBets,
                                 payout: Money(minorUnits: payout, currency: currency))
        }
        simDay = newDay
        return result
    }

    /// Clears practice orders, positions and bets and restarts the simulation clock. Responsible-play settings survive.
    public func resetPractice() throws {
        try db.transaction {
            try db.execute("DELETE FROM practice_orders; DELETE FROM practice_positions; DELETE FROM practice_bets;")
            try Self.setMetaInt(db, "sim_day", 0)
        }
        simDay = 0
    }

    // MARK: - Responsible play

    public func playSettings() throws -> PlaySettings {
        guard let data = try Self.meta(db, "play_settings") else { return PlaySettings() }
        return (try? PlaySettings(canonicalBytes: data)) ?? PlaySettings()
    }

    /// Saves new settings. An active cool-off or self-exclusion can be extended but never shortened.
    public func updatePlaySettings(_ settings: PlaySettings, now: Date = Date()) throws {
        let current = try playSettings()
        do {
            try PlayGuard.validateChange(from: current, to: settings, nowMS: now.millisecondsSince1970)
        } catch {
            throw ConnectedError.play(error)
        }
        try Self.setMeta(db, "play_settings", settings.canonicalBytes)
    }

    // MARK: - Internals

    /// The tier comes from the stored credit profile, so every order is checked against the user's current score.
    private func guardOrder(_ order: PlayGuard.Order, market: MarketKind, now: Date) throws {
        let usage = try usageToday(now: now)
        let settings = try playSettings()
        let available = try cash()
        let tier = try creditProfile()?.tier
        do {
            try PlayGuard.check(order, market: market, settings: settings, tier: tier, ordersToday: usage.transactions,
                                stakedToday: usage.staked, cash: available, nowMS: now.millisecondsSince1970)
        } catch {
            throw ConnectedError.play(error)
        }
    }

    private func markPrice(market: MarketKind, instrument: String, side: PracticeSide) -> Int64 {
        switch market {
        case .equity:
            return Equity.find(instrument).map { EquitySimulator.quote(for: $0, day: simDay).price } ?? 0
        case .prediction:
            guard let event = PredictionCatalog.find(id: instrument) else { return 0 }
            let mid = Int64(event.midCents(day: simDay))
            return side == .yes ? mid : 100 - mid
        case .sports:
            return 0
        }
    }

    private func positionQuantity(_ market: MarketKind, _ instrument: String, _ side: PracticeSide) throws -> Int64 {
        try db.scalarInt("SELECT quantity FROM practice_positions WHERE market = ? AND instrument = ? AND side = ?",
                         [.text(market.rawValue), .text(instrument), .text(side.rawValue)]) ?? 0
    }

    /// Adds to a position, or removes from it pro rata (cost basis shrinks proportionally).
    private func changePosition(_ market: MarketKind, _ instrument: String, _ side: PracticeSide, quantity: Int64, cost: Int64) throws {
        let keys: [SQLValue] = [.text(market.rawValue), .text(instrument), .text(side.rawValue)]
        if quantity > 0 {
            try db.run("""
                INSERT INTO practice_positions (market, instrument, side, quantity, cost_minor) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (market, instrument, side) DO UPDATE SET
                    quantity = quantity + excluded.quantity, cost_minor = cost_minor + excluded.cost_minor
                """, keys + [.integer(quantity), .integer(cost)])
            return
        }
        let row = try db.query("SELECT quantity, cost_minor FROM practice_positions WHERE market = ? AND instrument = ? AND side = ?",
                               keys) { ($0.int(0), $0.int(1)) }.first
        guard let (held, heldCost) = row else { return }
        let remaining = held + quantity
        if remaining <= 0 {
            try db.run("DELETE FROM practice_positions WHERE market = ? AND instrument = ? AND side = ?", keys)
        } else {
            try db.run("UPDATE practice_positions SET quantity = ?, cost_minor = ? WHERE market = ? AND instrument = ? AND side = ?",
                       [.integer(remaining), .integer(heldCost * remaining / held)] + keys)
        }
    }

    private func record(_ market: MarketKind, _ instrument: String, _ side: PracticeSide, _ action: PracticeAction,
                        _ quantity: Int64, _ price: Int64, _ cashDelta: Int64, _ note: String, _ now: Date,
                        day: Int? = nil) throws -> PracticeOrder {
        let nowMS = now.millisecondsSince1970
        let orderDay = day ?? simDay
        try db.run("""
            INSERT INTO practice_orders (placed_at_ms, sim_day, market, instrument, side, action, quantity, price_minor,
                                         cash_delta_minor, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.integer(nowMS), .integer(Int64(orderDay)), .text(market.rawValue), .text(instrument), .text(side.rawValue),
                  .text(action.rawValue), .integer(quantity), .integer(price), .integer(cashDelta), .text(note)])
        return PracticeOrder(id: try db.scalarInt("SELECT last_insert_rowid()") ?? 0, placedAtMS: nowMS, simDay: orderDay,
                             market: market, instrument: instrument, side: side, action: action, quantity: quantity,
                             priceMinor: price, cashDelta: Money(minorUnits: cashDelta, currency: currency), note: note)
    }

    private func insert(_ transactions: [BankTransaction]) throws {
        for t in transactions {
            try db.run("""
                INSERT OR IGNORE INTO bank_transactions (id, account_id, posted_at_ms, amount_minor, merchant, category)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.text(t.id), .text(t.accountID), .integer(t.postedAtMS), .integer(t.amount.minorUnits), .text(t.merchant),
                      .text(t.category.rawValue)])
        }
    }

    private static func meta(_ db: SQLiteDatabase, _ key: String) throws -> Data? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.blob(0) }.first
    }

    private static func setMeta(_ db: SQLiteDatabase, _ key: String, _ value: Data) throws {
        try db.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                   [.text(key), .blob(value)])
    }

    private static func metaInt(_ db: SQLiteDatabase, _ key: String) throws -> Int64? {
        try meta(db, key).flatMap { Int64(String(decoding: $0, as: UTF8.self)) }
    }

    private static func setMetaInt(_ db: SQLiteDatabase, _ key: String, _ value: Int64) throws {
        try setMeta(db, key, Data(String(value).utf8))
    }
}

/// Schema of `connected.sqlite`. Kept apart from the wallet ledger: this data is simulated and mutable,
/// the ledger is append-only and hash-chained.
enum ConnectedSchema {
    static let migrations: [String] = [v1]

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = Int(try db.userVersion)
        guard current < migrations.count else { return }
        try db.transaction {
            for index in current..<migrations.count {
                try db.execute(migrations[index])
            }
            try db.execute("PRAGMA user_version = \(migrations.count);")
        }
    }

    static let v1 = """
    CREATE TABLE meta (
        key   TEXT PRIMARY KEY,
        value BLOB NOT NULL
    ) STRICT;

    CREATE TABLE linked_accounts (
        id                    TEXT PRIMARY KEY,
        institution_id        TEXT    NOT NULL,
        institution_name      TEXT    NOT NULL,
        name                  TEXT    NOT NULL,
        kind                  TEXT    NOT NULL CHECK (kind IN ('checking', 'savings', 'credit')),
        mask                  TEXT    NOT NULL,
        currency              TEXT    NOT NULL,
        opening_balance_minor INTEGER NOT NULL,
        linked_at_ms          INTEGER NOT NULL,
        synced_through_ms     INTEGER NOT NULL
    ) STRICT;

    CREATE TABLE bank_transactions (
        id           TEXT PRIMARY KEY,
        account_id   TEXT    NOT NULL REFERENCES linked_accounts(id) ON DELETE CASCADE,
        posted_at_ms INTEGER NOT NULL,
        amount_minor INTEGER NOT NULL,
        merchant     TEXT    NOT NULL,
        category     TEXT    NOT NULL
    ) STRICT;
    CREATE INDEX bank_transactions_by_account_time ON bank_transactions (account_id, posted_at_ms);
    CREATE INDEX bank_transactions_by_time ON bank_transactions (posted_at_ms);

    CREATE TABLE practice_orders (
        id               INTEGER PRIMARY KEY,
        placed_at_ms     INTEGER NOT NULL,
        sim_day          INTEGER NOT NULL,
        market           TEXT    NOT NULL CHECK (market IN ('equity', 'prediction', 'sports')),
        instrument       TEXT    NOT NULL,
        side             TEXT    NOT NULL CHECK (side IN ('buy', 'sell', 'yes', 'no', 'home', 'away')),
        action           TEXT    NOT NULL CHECK (action IN ('open', 'close', 'settle')),
        quantity         INTEGER NOT NULL CHECK (quantity > 0),
        price_minor      INTEGER NOT NULL,
        cash_delta_minor INTEGER NOT NULL,
        note             TEXT    NOT NULL DEFAULT ''
    ) STRICT;
    CREATE INDEX practice_orders_by_time ON practice_orders (placed_at_ms);

    CREATE TABLE practice_positions (
        market     TEXT    NOT NULL,
        instrument TEXT    NOT NULL,
        side       TEXT    NOT NULL,
        quantity   INTEGER NOT NULL CHECK (quantity > 0),
        cost_minor INTEGER NOT NULL,
        PRIMARY KEY (market, instrument, side)
    ) STRICT;

    CREATE TABLE practice_bets (
        id            INTEGER PRIMARY KEY,
        fixture_id    TEXT    NOT NULL,
        selection     TEXT    NOT NULL CHECK (selection IN ('home', 'away')),
        stake_minor   INTEGER NOT NULL CHECK (stake_minor > 0),
        american_odds INTEGER NOT NULL,
        placed_at_ms  INTEGER NOT NULL,
        status        TEXT    NOT NULL CHECK (status IN ('open', 'won', 'lost')),
        payout_minor  INTEGER NOT NULL DEFAULT 0
    ) STRICT;
    """
}

/// Opens (or creates) `<name>.sqlite` encrypted with its own random 256-bit SQLCipher key, held in the secret store
/// under a separate account from the wallet's key. A database whose key is missing is reported, never re-keyed.
enum ConnectedDatabase {
    static func open(directory: URL?, name: String, secrets: any SecretStore, keyAccount: String) throws -> (SQLiteDatabase, URL?) {
        guard let directory else { return (try SQLiteDatabase(path: ":memory:", key: nil), nil) }
        let url = directory.appendingPathComponent("\(name).sqlite")
        let exists = FileManager.default.fileExists(atPath: url.path)
        let key: Data
        if let stored = try secrets.read(keyAccount), stored.count == 32 {
            key = stored
        } else if exists {
            throw StoreError.databaseKeyMissing
        } else {
            key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try secrets.write(key, account: keyAccount)
        }
        let db = try SQLiteDatabase(path: url.path, key: key)
        WalletLocation.protectFile(at: url)
        return (db, url)
    }
}
