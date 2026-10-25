import SecureCore
import SecureStore
import SwiftUI

struct PayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var categoryID: Int64?
    @State private var verdict: BudgetVerdict?
    @State private var confirmingOverBudget = false
    @State private var working = false
    @FocusState private var amountFocused: Bool

    private var amount: Money? { Money.parse(amountText, currency: .usd, locale: .current) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .focused($amountFocused)
                }
                Section("Category") {
                    Picker("Category", selection: $categoryID) {
                        Text("None").tag(Int64?.none)
                        ForEach(model.categories) { category in
                            Label(category.name, systemImage: category.iconName ?? "tag").tag(Int64?.some(category.id))
                        }
                    }
                }
                Section {
                    LabeledContent("To", value: DemoPeer.shopName)
                    LabeledContent("Proximity", value: "Simulated, 0.40 m")
                } footer: {
                    Text("The category stays on this phone. The shop only sees the amount and both signed distance measurements.")
                }
                if let verdict {
                    Section("Budget check") { VerdictView(verdict: verdict) }
                }
            }
            .navigationTitle("Pay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { submit() } label: {
                        if working { ProgressView() } else { Label("Pay with Face ID", systemImage: "faceid") }
                    }
                    .disabled(amount == nil || amount?.minorUnits == 0 || working || isBlocked)
                }
            }
            .task(id: "\(amountText)|\(String(describing: categoryID))") {
                guard let amount, amount.minorUnits > 0 else { verdict = nil; return }
                verdict = await model.evaluate(amount: amount, categoryID: categoryID)
            }
            .confirmationDialog("Over budget", isPresented: $confirmingOverBudget, titleVisibility: .visible) {
                Button("Pay anyway", role: .destructive) { submit(overrideOverBudget: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This payment goes over your budget. Approving it still needs Face ID.")
            }
            .onAppear {
                amountFocused = true
                if categoryID == nil { categoryID = model.categories.first { $0.name == "Clothing" }?.id }
            }
        }
    }

    private var isBlocked: Bool {
        if case .blocked = verdict { return true }
        return false
    }

    private func submit(overrideOverBudget: Bool = false) {
        guard let amount else { return }
        if case .overBudget = verdict, !overrideOverBudget {
            confirmingOverBudget = true
            return
        }
        working = true
        Task {
            let paid = await model.pay(amount: amount, categoryID: categoryID, overrideOverBudget: overrideOverBudget)
            working = false
            if paid { dismiss() }
        }
    }
}

struct VerdictView: View {
    let verdict: BudgetVerdict

    var body: some View {
        switch verdict {
        case .blocked(let reason):
            Label(AppModel.describe(StoreError.blocked(reason)), systemImage: "hand.raised.fill").foregroundStyle(.red)
        case .ok(let statuses), .alert(let statuses), .overBudget(let statuses):
            if statuses.isEmpty {
                Label("No budget for this category", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
            ForEach(statuses, id: \.budget.id) { status in
                let color: Color = status.isOver ? .red : status.reachesAlert ? .orange : .green
                VStack(alignment: .leading, spacing: 4) {
                    Label(status.isOver ? "Over budget" : status.reachesAlert ? "Near the limit" : "Within budget",
                          systemImage: status.isOver ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(color)
                    Text("\(status.spentBeforeMoney.formatted()) → \(status.spentAfterMoney.formatted()) of \(status.budget.cap.formatted())")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
