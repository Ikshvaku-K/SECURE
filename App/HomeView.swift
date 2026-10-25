import SecureCore
import SecureStore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPay = false
    @State private var showingBudgetEditor = false
    @State private var working = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    BalanceHeader(balance: model.balance, integrity: model.integrity, fingerprint: model.diagnostics.walletFingerprint)
                }

                Section {
                    NavigationLink { NearbyView() } label: {
                        Label("Pay or get paid nearby", systemImage: "iphone.radiowaves.left.and.right")
                    }
                    Button { showingPay = true } label: {
                        Label("Pay \(DemoPeer.shopName)", systemImage: "wave.3.right")
                    }
                    Button {
                        Task { working = true; await model.addDemoFunds(); working = false }
                    } label: {
                        Label("Receive $500 from \(DemoPeer.issuerName)", systemImage: "arrow.down.circle")
                    }
                    Button {
                        Task { await model.simulateIncomingRequest() }
                    } label: {
                        Label("Simulate a payment request", systemImage: "bell.badge")
                    }
                } footer: {
                    Text("Nearby payments measure the real distance with UWB on iPhone (simulated in the Simulator). Demo Shop payments use a simulated 0.40 m.")
                }
                .disabled(model.integrity.isLocked || working)

                Section("Budgets") {
                    ForEach(model.budgetRows) { row in
                        BudgetRowView(row: row)
                            .swipeActions {
                                Button("Delete", role: .destructive) { Task { await model.deleteBudget(id: row.id) } }
                            }
                    }
                    Button { showingBudgetEditor = true } label: { Label("Add budget", systemImage: "plus") }
                }

                Section("Activity") {
                    if model.activity.isEmpty {
                        Text("No transfers yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.activity) { row in
                        NavigationLink(value: row) { ActivityRowView(row: row) }
                    }
                }
            }
            .navigationTitle("S.E.C.U.R.E")
            .navigationDestination(for: ActivityRow.self) { EntryDetailView(row: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { DiagnosticsView() } label: { Image(systemName: "checkmark.shield") }
                        .accessibilityLabel("Security diagnostics")
                }
            }
            .refreshable { await model.refresh() }
            .sheet(isPresented: $showingPay) { PayView() }
            .sheet(isPresented: $showingBudgetEditor) { BudgetEditorView() }
            .sheet(item: $model.approvalRequest) { ApprovalSheet(request: $0) }
            .overlay(alignment: .bottom) { BannerView() }
        }
    }
}

struct BalanceHeader: View {
    let balance: Money
    let integrity: IntegrityStatus
    let fingerprint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Balance").font(.subheadline).foregroundStyle(.secondary)
            Text(balance.formatted())
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                Image(systemName: integrity.isLocked ? "lock.trianglebadge.exclamationmark.fill" : "checkmark.seal.fill")
                    .foregroundStyle(integrity.isLocked ? .red : .green)
                Text(integrity.isLocked ? "Locked: integrity check failed" : "Chain verified")
                Spacer()
                Text(fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct BudgetRowView: View {
    let row: BudgetRow

    var tint: Color { row.isOver ? .red : row.reachesAlert ? .orange : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(row.categoryName, systemImage: row.iconName)
                if row.hardCap {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.secondary).accessibilityLabel("Hard cap")
                }
                Spacer()
                Text("\(row.spent.formatted()) of \(row.cap.formatted())").monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: row.fraction).tint(tint)
            Text(row.periodLabel).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ActivityRowView: View {
    let row: ActivityRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(row.entry.kind == .debit ? Color.primary : Color.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(amountText)
                .monospacedDigit()
                .foregroundStyle(row.entry.kind == .debit ? Color.primary : Color.green)
        }
    }

    private var icon: String {
        switch row.entry.kind {
        case .debit: "arrow.up.right"
        case .credit: "arrow.down.left"
        case .mint: "sparkles"
        case .genesis: "flag"
        }
    }

    private var amountText: String {
        (row.entry.kind == .debit ? "−" : "+") + row.entry.amount.formatted()
    }

    private var subtitle: String {
        var parts = [row.entry.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let category = row.categoryName { parts.append(category) }
        if let distance = row.distanceCM { parts.append("\(distance) cm") }
        return parts.joined(separator: " · ")
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let banner = model.banner {
            Label(banner.text, systemImage: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: .capsule)
                .foregroundStyle(banner.kind == .success ? Color.primary : Color.red)
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: banner.id) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { if model.banner?.id == banner.id { model.banner = nil } }
                }
                .onTapGesture { withAnimation { model.banner = nil } }
        }
    }
}
