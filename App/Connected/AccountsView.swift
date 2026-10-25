import Charts
import SecureConnect
import SecureCore
import SecureStore
import SwiftUI

/// Linked bank accounts at fictional banks, monitored in one place.
struct AccountsView: View {
    @Environment(ConnectedModel.self) private var connected
    @State private var showingConnect = false

    var body: some View {
        NavigationStack {
            ConnectedGate {
                List {
                    if connected.accounts.isEmpty {
                        ContentUnavailableView {
                            Label("No accounts linked", systemImage: "building.columns")
                        } description: {
                            Text("Connect a simulated bank to see balances and transactions from every account in one place.")
                        } actions: {
                            Button("Connect a bank") { showingConnect = true }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        if let summary = connected.summary {
                            Section { NetWorthHeader(summary: summary) }
                            if !summary.spendingThisMonth.isEmpty {
                                Section("Spending this month") { SpendingChart(spending: summary.spendingThisMonth) }
                            }
                        }
                        ForEach(groupedAccounts, id: \.0) { institution, accounts in
                            Section(institution) {
                                ForEach(accounts) { account in
                                    NavigationLink(value: account) { AccountRow(account: account) }
                                }
                            }
                        }
                        Section("Recent activity, all accounts") {
                            ForEach(connected.recentTransactions.prefix(15)) { transaction in
                                TransactionRow(transaction: transaction, accountName: accountName(transaction.accountID))
                            }
                        }
                    }
                }
                .navigationDestination(for: LinkedAccount.self) { AccountDetailView(account: $0) }
                .refreshable { await connected.sync() }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await connected.sync() } } label: { Label("Sync", systemImage: "arrow.clockwise") }
                        .disabled(connected.accounts.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingConnect = true } label: { Label("Connect a bank", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showingConnect) { ConnectBankSheet() }
            .overlay(alignment: .bottom) { ConnectedBanner() }
        }
    }

    private var groupedAccounts: [(String, [LinkedAccount])] {
        Dictionary(grouping: connected.accounts, by: \.institutionName).sorted { $0.key < $1.key }
    }

    private func accountName(_ id: String) -> String {
        connected.accounts.first { $0.id == id }.map { "\($0.name) ••\($0.mask)" } ?? ""
    }
}

struct NetWorthHeader: View {
    let summary: AccountsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Net worth").font(.subheadline).foregroundStyle(.secondary)
            Text(summary.netWorth.formatted())
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
            HStack {
                LabeledValue(title: "Assets", value: summary.assets.formatted())
                Spacer()
                LabeledValue(title: "Owed on cards", value: summary.liabilities.formatted())
            }
            HStack {
                SimulatedBadge(text: "Simulated banks")
                Spacer()
                if let synced = summary.lastSyncedMS {
                    Text("Synced \(Date(millisecondsSince1970: synced).formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct LabeledValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}

struct SpendingChart: View {
    let spending: [CategorySpend]

    var body: some View {
        Chart(spending) { item in
            BarMark(x: .value("Spent", NSDecimalNumber(decimal: item.amount.decimalValue).doubleValue),
                    y: .value("Category", item.category.displayName))
                .foregroundStyle(by: .value("Category", item.category.displayName))
                .annotation(position: .trailing) {
                    Text(item.amount.formatted()).font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .frame(height: CGFloat(spending.count) * 30 + 10)
        .accessibilityLabel("Spending by category this month")
    }
}

struct AccountRow: View {
    let account: LinkedAccount

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                Text("\(account.kind.displayName) ••\(account.mask)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(account.balance.formatted())
                .monospacedDigit()
                .foregroundStyle(account.balance.minorUnits < 0 ? .red : .primary)
        }
    }
}

struct TransactionRow: View {
    let transaction: BankTransaction
    var accountName: String = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.category.symbol).frame(width: 26).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant)
                Text([transaction.postedAt.formatted(date: .abbreviated, time: .omitted), accountName]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(signed(transaction.amount))
                .monospacedDigit()
                .foregroundStyle(transaction.amount.minorUnits > 0 ? .green : .primary)
        }
    }
}

struct ConnectBankSheet: View {
    @Environment(ConnectedModel.self) private var connected
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Institution.simulated) { institution in
                        HStack(spacing: 12) {
                            Image(systemName: institution.symbol).font(.title2).frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(institution.name)
                                Text(institution.accounts.map(\.name).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if connected.linkedInstitutionIDs.contains(institution.id) {
                                Label("Connected", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                            } else {
                                Button("Connect") { Task { await connected.link(institution) } }.buttonStyle(.bordered)
                            }
                        }
                    }
                } footer: {
                    Text("These banks are fictional. Connecting creates simulated accounts with generated activity: no sign-in, no credentials and nothing leaves the phone.")
                }
            }
            .navigationTitle("Connect a bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct AccountDetailView: View {
    let account: LinkedAccount
    @Environment(ConnectedModel.self) private var connected
    @Environment(\.dismiss) private var dismiss
    @State private var transactions: [BankTransaction] = []
    @State private var confirmingDisconnect = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(account.institutionName).font(.subheadline).foregroundStyle(.secondary)
                    Text(account.balance.formatted()).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("\(account.kind.displayName) ••\(account.mask)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Transactions") {
                ForEach(transactions) { TransactionRow(transaction: $0) }
            }
            Section {
                Button("Disconnect \(account.institutionName)", role: .destructive) { confirmingDisconnect = true }
            }
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { transactions = await connected.transactions(for: account.id) }
        .confirmationDialog("Disconnect \(account.institutionName)?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await connected.unlink(account.institutionID)
                    dismiss()
                }
            }
        } message: {
            Text("Its simulated accounts and transactions are removed from this phone.")
        }
    }
}
